"""Manual-rail assist runs (assist.py): the read-only guarantee and the text hygiene.

The load-bearing tests: the built command carries a read-only tool whitelist and never
bypassPermissions; a fake assistant that writes a file, edits, or reaches for Bash fails the
job; fenced code is stripped deterministically. Nothing here runs the real `claude`.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import stat
import subprocess

import pytest

from haro import assist
from haro.adapters.base import NormalizedEvent
from haro.models import ManualPlan, PlanStep


def _git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()


def _repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "t@example.com")
    _git(repo, "config", "user.name", "t")
    (repo / "f.txt").write_text("x\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "init")
    return repo


def _values_after(cmd, flag):
    i = cmd.index(flag) + 1
    out = []
    while i < len(cmd) and not cmd[i].startswith("--"):
        out.append(cmd[i])
        i += 1
    return out


# ------------------------------------------------------------------- the command
def test_command_is_read_only_and_never_bypasses_permissions():
    cmd = assist.build_command(
        prompt="p", system="s", model="sonnet", effort="high", max_budget_usd=2.0
    )
    assert _values_after(cmd, "--tools") == ["Read", "Grep", "Glob", "WebFetch", "WebSearch"]
    assert _values_after(cmd, "--allowedTools") == ["Read", "Grep", "Glob", "WebFetch", "WebSearch"]
    for banned in ("Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Task", "Agent"):
        assert banned not in _values_after(cmd, "--tools")
        assert banned not in _values_after(cmd, "--allowedTools")
        assert banned in _values_after(cmd, "--disallowedTools")
    assert _values_after(cmd, "--permission-mode") == ["dontAsk"]
    assert "bypassPermissions" not in cmd
    assert "--dangerously-skip-permissions" not in cmd
    assert "--allow-dangerously-skip-permissions" not in cmd
    assert "--strict-mcp-config" in cmd
    assert cmd[cmd.index("--model") + 1] == "sonnet"
    assert cmd[cmd.index("--effort") + 1] == "high"
    assert cmd[cmd.index("--max-budget-usd") + 1] == "2.0"
    assert cmd[:3] == ["claude", "-p", "p"]


def test_command_omits_unset_knobs():
    cmd = assist.build_command(prompt="p", system="s")
    for flag in ("--model", "--effort", "--max-budget-usd"):
        assert flag not in cmd


# ------------------------------------------------------------------ fence stripping
def test_fenced_blocks_become_the_marker_and_inline_code_stays():
    text = "Read `src/a.ts`.\n```ts\nconst x = 1\n```\nThen done."
    assert assist.strip_code_fences(text) == (
        f"Read `src/a.ts`.\n{assist.CODE_REMOVED}\nThen done."
    )


def test_tilde_and_indented_and_unclosed_fences():
    assert assist.strip_code_fences("a\n  ~~~py\n  x\n  ~~~\nb") == f"a\n  {assist.CODE_REMOVED}\nb"
    # an unclosed fence swallows the rest: a truncated reply must not leak code
    assert assist.strip_code_fences("a\n```js\nleak\nmore") == f"a\n{assist.CODE_REMOVED}"


def test_longer_fence_needs_an_equally_long_close():
    text = "````\n```\ninner\n```\n````\nafter"
    assert assist.strip_code_fences(text) == f"{assist.CODE_REMOVED}\nafter"


def test_one_line_triple_backtick_block_is_removed():
    assert assist.strip_code_fences("```x = 1```") == assist.CODE_REMOVED


def test_stripping_is_deterministic_and_idempotent():
    text = "1. step\n```\ncode\n```\n2. step"
    once = assist.strip_code_fences(text)
    assert once == assist.strip_code_fences(text)
    assert assist.strip_code_fences(once) == once


def test_a_fence_opened_mid_line_does_not_leak_or_swallow_later_steps():
    text = "1. Add ``` def f(): return 1\n2. second step\n3. third ``` and go on\n4. fourth"
    out = assist.strip_code_fences(text)
    assert "def f()" not in out and "return 1" not in out
    assert "1. Add " in out and "4. fourth" in out
    # the fence closes on line 3 (mid-line), so the prose after it survives
    assert "and go on" in out and "2. second step" not in out
    assert out.count(assist.CODE_REMOVED) == 1


def test_a_mid_line_fence_closed_on_the_same_line_keeps_the_rest_of_the_line():
    out = assist.strip_code_fences("1. Add ```def f(): return 1``` then test it\n2. next")
    assert out == f"1. Add {assist.CODE_REMOVED} then test it\n2. next"


def test_an_unclosed_mid_line_fence_swallows_the_rest_rather_than_leak():
    out = assist.strip_code_fences("1. ok\n2. Add ``` def f(): return 1\n3. more code")
    assert "def f()" not in out and "more code" not in out and out.startswith("1. ok")


def test_a_later_line_start_fence_is_not_confused_by_an_earlier_mid_line_one():
    text = "1. Add ``` x ``` done\n2. two\n```\nreal block\n```\n3. three"
    out = assist.strip_code_fences(text)
    assert "real block" not in out and "2. two" in out and "3. three" in out


def test_only_a_blank_line_separated_indented_block_is_code():
    text = (
        "TITLE: T\n"
        "1. step one\n"
        "\n"
        "    def f(): return 1\n"
        "\tprint(x)\n"
        "2. step two\n"
        "   a wrapped line\n"
        "WHY THIS ORDER: because"
    )
    out = assist.strip_indented_code(text)
    assert "def f()" not in out and "print(x)" not in out
    assert out.count(assist.CODE_REMOVED) == 1
    assert "   a wrapped line" in out
    title, steps, why = assist.parse_plan(out)
    assert steps == ["step one", "step two a wrapped line"]
    assert why == "because"


def test_indented_lines_right_under_a_step_belong_to_it():
    out = assist.strip_indented_code("1. step one\n    continues here\n\tand here")
    assert assist.CODE_REMOVED not in out
    plan = assist.make_plan(
        prompt="p", text="1. step one\n    continues here\n\tand here", model=None,
        effort=None, cost_usd=None,
    )
    assert [s.text for s in plan.steps] == ["step one continues here and here"]


def test_a_hanging_indent_under_step_ten_is_kept():
    lines = [f"{i}. step {i}" for i in range(1, 10)]
    lines += ["10. a long tenth step that wraps", "    onto a four-space hanging indent", "11. eleventh"]
    plan = assist.make_plan(prompt="p", text="\n".join(lines), model=None, effort=None, cost_usd=None)
    assert len(plan.steps) == 11
    assert plan.steps[9].text == "a long tenth step that wraps onto a four-space hanging indent"


def test_sub_bullets_fold_into_their_step_instead_of_becoming_steps():
    text = "1. Update the handler:\n    - check x\n    - check y\n2. Next step\n  - tiny sub"
    plan = assist.make_plan(prompt="p", text=text, model=None, effort=None, cost_usd=None)
    assert [s.text for s in plan.steps] == [
        "Update the handler: check x; check y",
        "Next step tiny sub",
    ]


def test_a_whole_list_indented_together_stays_separate_steps():
    text = "  1. first\n  2. second\n     - sub of second\n  3. third"
    _, steps, _ = assist.parse_plan(assist.strip_indented_code(text))
    assert steps == ["first", "second sub of second", "third"]


def test_a_blank_line_ends_the_attachment_so_the_next_block_is_code():
    text = "1. step\n    prose under it\n\n    code after the blank line\n2. next"
    plan = assist.make_plan(prompt="p", text=text, model=None, effort=None, cost_usd=None)
    assert [s.text for s in plan.steps] == ["step prose under it", "next"]
    assert "code after" not in plan.model_dump_json()


def test_step_text_never_carries_indented_code_into_a_stored_plan():
    plan = assist.make_plan(
        prompt="p",
        text="TITLE: T\n1. step one\n\n    def f(): return 1\n2. step two",
        model=None, effort=None, cost_usd=None,
    )
    assert [s.text for s in plan.steps] == ["step one", "step two"]
    assert "def f" not in plan.model_dump_json()


def test_source_titles_and_reasons_are_prose_on_one_line():
    reply = (
        '{"answer": "See it.", "sources": [{"kind": "repo", "title": "a.ts ```x = 1``` here", '
        '"target": "a.ts", "why": "line one\\n```\\nsecret()\\n```\\nline two\\n    indented()"}]}'
    )
    answer, sources = assist.parse_research(reply)
    src = sources[0]
    assert "x = 1" not in src["title"] and "secret" not in src["why"] and "indented" not in src["why"]
    assert "\n" not in src["title"] and "\n" not in src["why"]
    assert src["why"].startswith("line one") and "line two" in src["why"]
    assert answer == "See it."


def test_clean_field_caps_length():
    assert len(assist.clean_field("word " * 100)) == 200
    assert assist.clean_field("a\n\nb") == "a b"


# ------------------------------------------------------------------ plan parsing
def test_plan_parser_reads_title_steps_and_why():
    reply = (
        "TITLE: Dedupe Stripe webhooks\n"
        "1. Read `src/billing/webhooks.ts` and find the handler.\n"
        "   Note the retry path.\n"
        "2) Add a **processed_events** table.\n"
        "3. Dedupe inside the transaction.\n"
        "WHY THIS ORDER: Reproduce first, fix second."
    )
    title, steps, why = assist.parse_plan(reply, "prompt")
    assert title == "Dedupe Stripe webhooks"
    assert steps == [
        "Read `src/billing/webhooks.ts` and find the handler. Note the retry path.",
        "Add a processed_events table.",
        "Dedupe inside the transaction.",
    ]
    assert why == "Reproduce first, fix second."


def test_plan_parser_tolerates_bullets_bold_and_a_why_on_the_next_line():
    title, steps, why = assist.parse_plan(
        "**Title:** X y\n- [ ] one\n- two\n**Why this order:**\nBecause.", "p"
    )
    assert (title, steps, why) == ("X y", ["one", "two"], "Because.")


def test_missing_title_falls_back_to_the_prompt():
    title, steps, _ = assist.parse_plan("1. only step", "Build the login form\nmore")
    assert title == "Build the login form" and steps == ["only step"]


def test_make_plan_strips_fences_and_refuses_an_empty_reply():
    plan = assist.make_plan(
        prompt="p", text="TITLE: T\n1. a\n```\nsecret code\n```\n2. b", model="sonnet",
        effort=None, cost_usd=0.1,
    )
    assert [s.text for s in plan.steps] == ["a", "b"]
    assert plan.model == "sonnet" and plan.cost_usd == 0.1 and not plan.saved
    with pytest.raises(ValueError):
        assist.make_plan(prompt="p", text="I cannot help", model=None, effort=None, cost_usd=None)


def test_plan_markdown_only_includes_saved_plans():
    saved = ManualPlan(title="T", steps=[PlanStep(text="a", done=True), PlanStep(text="b")],
                       why="w", saved=True)
    unsaved = ManualPlan(title="U", steps=[PlanStep(text="z")])
    assert assist.plan_markdown([unsaved]) == ""
    md = assist.plan_markdown([unsaved, saved])
    assert md.startswith("## Plan")
    assert "- [x] a" in md and "- [ ] b" in md and "Why this order: w" in md
    assert "z" not in md and "AI edits: 0" in md


def test_plan_markdown_says_unverified_when_the_guard_could_not_check():
    checked = ManualPlan(title="A", steps=[PlanStep(text="a")], saved=True)
    unchecked = ManualPlan(title="B", steps=[PlanStep(text="b")], saved=True, guard_note="note")
    assert "AI edits: 0" in assist.plan_markdown([checked])
    md = assist.plan_markdown([checked, unchecked])
    assert "AI edits: unverified" in md and "AI edits: 0" not in md


# ---------------------------------------------------------------- research parsing
def test_research_parser_reads_json_even_when_wrapped_in_prose():
    text = 'Sure:\n{"answer": "It is in a.ts.", "sources": [{"kind": "repo", "title": "t", "target": "a.ts:3", "why": "w"}]}'
    answer, sources = assist.parse_research(text)
    assert answer == "It is in a.ts."
    assert sources == [{"kind": "repo", "title": "t", "target": "a.ts:3", "why": "w"}]


def test_research_parser_falls_back_to_plain_text_without_code():
    answer, sources = assist.parse_research("Look at a.ts.\n```\nsecret()\n```")
    assert sources == [] and "secret" not in answer and "Look at a.ts." in answer


def test_verify_sources_drops_pointers_to_nothing(tmp_path):
    repo = _repo(tmp_path)
    sha = _git(repo, "rev-parse", "HEAD")
    sources = [
        {"kind": "repo", "title": "real", "target": "f.txt:1", "why": ""},
        {"kind": "repo", "title": "ghost", "target": "nope.ts:9", "why": ""},
        {"kind": "repo", "title": "escape", "target": "../etc/passwd", "why": ""},
        {"kind": "git", "title": "", "target": sha[:10], "why": ""},
        {"kind": "git", "title": "", "target": "deadbeef00", "why": ""},
        {"kind": "web", "title": "site", "target": "https://example.com/x", "why": ""},
        {"kind": "doc", "title": "bad", "target": "javascript:alert(1)", "why": ""},
    ]
    rows, dropped = asyncio.run(assist.verify_sources(str(repo), sources))
    assert [r.title for r in rows][:1] == ["real"]
    assert {r.source for r in rows} == {"repo", "git", "web"}
    assert next(r for r in rows if r.source == "git").target == "f.txt"
    assert all(r.action in ("jump", "open") for r in rows)
    assert dropped == 3  # the seventh source is past the cap of six and never looked at


# ----------------------------------------------------------------------- git guard
def _job(worktree, source, *, excused=lambda: set(), emitted=None, internal_writer=lambda: False):
    async def emit(kind, payload):
        if emitted is not None:
            emitted.append((kind, payload))

    return asyncio.run(
        assist.run_job(
            worktree=str(worktree), prompt="p", system="s", model="sonnet", effort=None,
            max_budget_usd=1.0, max_parallel=0, emit=emit, excused=excused,
            internal_writer=internal_writer, source=source,
        )
    )


def _clean_source(cmd, cwd):
    async def gen():
        yield NormalizedEvent("token", {"system": True, "text": "session started"})
        yield NormalizedEvent("tool_call", {"tool": "Read", "summary": "f.txt"})
        yield NormalizedEvent("token", {"text": "1. do it\n```\ncode\n```"})
        yield NormalizedEvent("done", {"result": "1. do it", "cost_usd": 0.02})

    return gen()


def test_a_clean_run_returns_its_text_and_cost(tmp_path):
    repo = _repo(tmp_path)
    emitted: list = []
    res = _job(repo, _clean_source, emitted=emitted)
    assert res.error is None and res.text == "1. do it" and res.cost_usd == 0.02
    kinds = [k for k, _ in emitted]
    assert kinds[0] == "started" and "token" in kinds
    tokens = [p["text"] for k, p in emitted if k == "token"]
    assert all("code\n" not in t.replace(assist.CODE_REMOVED, "") for t in tokens)
    assert all("session started" not in t for t in tokens)


def test_an_assistant_that_writes_a_file_fails_the_job(tmp_path):
    repo = _repo(tmp_path)

    def source(cmd, cwd):
        async def gen():
            (repo / "sneaky.txt").write_text("hi")
            yield NormalizedEvent("done", {"result": "ok"})

        return gen()

    res = _job(repo, source)
    assert res.violation and res.error.startswith(assist.VIOLATION)
    assert "sneaky.txt" in res.error and res.text == ""


def test_a_second_edit_to_an_already_dirty_file_is_caught(tmp_path):
    repo = _repo(tmp_path)
    (repo / "f.txt").write_text("dirty\n")

    def source(cmd, cwd):
        async def gen():
            (repo / "f.txt").write_text("dirtier\n")
            yield NormalizedEvent("done", {"result": "ok"})

        return gen()

    res = _job(repo, source)
    assert res.violation and "f.txt" in res.error


def test_a_commit_during_the_run_fails_it(tmp_path):
    repo = _repo(tmp_path)

    def source(cmd, cwd):
        async def gen():
            _git(repo, "commit", "-q", "--allow-empty", "-m", "sneaky")
            yield NormalizedEvent("done", {"result": "ok"})

        return gen()

    res = _job(repo, source)
    assert res.violation and "HEAD" in res.error


def test_files_the_dev_saved_through_haro_are_excused(tmp_path):
    repo = _repo(tmp_path)

    def source(cmd, cwd):
        async def gen():
            (repo / "mine.txt").write_text("dev typing")
            (repo / "dir").mkdir()
            (repo / "dir" / "a.txt").write_text("dev typing")
            yield NormalizedEvent("done", {"result": "ok"})

        return gen()

    assert _job(repo, source).violation  # unexcused, the same writes trip the guard
    (repo / "mine.txt").unlink()
    shutil.rmtree(repo / "dir")
    res = _job(repo, source, excused=lambda: {"mine.txt", "dir"})
    assert res.error is None and not res.violation


def test_an_attempted_edit_or_foreign_tool_is_logged_not_a_violation(tmp_path, caplog):
    # The CLI answers a call to a tool it does not have with "No such tool available" and
    # writes nothing, so an ATTEMPT is not a change: only the git guard can fail a job.
    repo = _repo(tmp_path)

    def attempting(cmd, cwd):
        async def gen():
            yield NormalizedEvent("file_edit", {"tool": "Write", "path": "f.txt"})
            yield NormalizedEvent("tool_call", {"tool": "Bash", "summary": "rm -rf"})
            yield NormalizedEvent("tool_call", {"tool": "Read", "summary": "f.txt"})
            yield NormalizedEvent("done", {"result": "1. still a plan", "cost_usd": 0.01})

        return gen()

    emitted: list = []
    with caplog.at_level("WARNING", logger="haro.assist"):
        res = _job(repo, attempting, emitted=emitted)
    assert res.error is None and not res.violation
    assert res.text == "1. still a plan" and res.cost_usd == 0.01
    assert res.blocked_calls == ["Write", "Bash"]
    assert [p["tool"] for k, p in emitted if k == "blocked"] == ["Write", "Bash"]
    assert "tried Write" in caplog.text and "tried Bash" in caplog.text


def test_an_attempted_write_that_really_wrote_still_fails_on_the_guard(tmp_path):
    repo = _repo(tmp_path)

    def source(cmd, cwd):
        async def gen():
            yield NormalizedEvent("file_edit", {"tool": "Write", "path": "real.txt"})
            (repo / "real.txt").write_text("it did write")
            yield NormalizedEvent("done", {"result": "ok"})

        return gen()

    res = _job(repo, source)
    assert res.violation and res.error.startswith(assist.VIOLATION) and "real.txt" in res.error
    assert res.blocked_calls == ["Write"] and res.text == ""


def test_a_haro_internal_writer_makes_the_guard_inconclusive_not_failed(tmp_path, caplog):
    repo = _repo(tmp_path)

    def source(cmd, cwd):
        async def gen():
            (repo / "coverage.txt").write_text("the gate wrote this")
            yield NormalizedEvent("done", {"result": "1. plan"})

        return gen()

    with caplog.at_level("WARNING", logger="haro.assist"):
        res = _job(repo, source, internal_writer=lambda: True)
    assert res.error is None and not res.violation and res.text == "1. plan"
    assert res.inconclusive and "coverage.txt" in res.inconclusive
    assert res.inconclusive.startswith("haro couldn't check the files during this run")
    assert "the assistant had no edit tools" in res.inconclusive
    assert "inconclusive" in caplog.text
    # No haro writer and the same change: it is the assistant's, and the job fails.
    (repo / "coverage.txt").unlink()
    res = _job(repo, source, internal_writer=lambda: False)
    assert res.violation


def test_rewriting_a_dirty_file_with_the_same_bytes_is_not_a_change(tmp_path):
    repo = _repo(tmp_path)
    (repo / "f.txt").write_text("dirty\n")

    def source(cmd, cwd):
        async def gen():
            os.utime(repo / "f.txt", (1, 1))  # a new mtime, the same content
            (repo / "f.txt").write_text("dirty\n")
            yield NormalizedEvent("done", {"result": "ok"})

        return gen()

    res = _job(repo, source)
    assert res.error is None and not res.violation


def test_a_stopped_job_still_gets_its_guard_check(tmp_path):
    repo = _repo(tmp_path)

    async def scenario(write: bool):
        started = asyncio.Event()

        def source(cmd, cwd):
            async def gen():
                if write:
                    (repo / "half.txt").write_text("written before the stop")
                started.set()
                await asyncio.sleep(30)
                yield NormalizedEvent("done", {"result": "never"})

            return gen()

        async def emit(kind, payload):
            pass

        task = asyncio.create_task(
            assist.run_job(
                worktree=str(repo), prompt="p", system="s", model=None, effort=None,
                max_budget_usd=None, max_parallel=0, emit=emit, source=source,
            )
        )
        await started.wait()
        task.cancel()
        return await task

    res = asyncio.run(scenario(True))
    assert res.stopped and res.violation and "half.txt" in res.error
    (repo / "half.txt").unlink()
    res = asyncio.run(scenario(False))
    assert res.stopped and not res.violation and res.error is None and res.text == ""


def test_an_adapter_error_is_returned_not_raised(tmp_path):
    repo = _repo(tmp_path)

    def source(cmd, cwd):
        async def gen():
            yield NormalizedEvent("error", {"message": "budget exceeded", "cost_usd": 0.5})

        return gen()

    res = _job(repo, source)
    assert res.error == "budget exceeded" and not res.violation and res.cost_usd == 0.5


# ---------------------------------------------- the real spawn path, with a fake claude
def _fake_claude(bindir, body: str):
    bindir.mkdir()
    exe = bindir / "claude"
    exe.write_text("#!/bin/sh\n" + body)
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)


def _run_real_path(repo):
    async def emit(kind, payload):
        pass

    return asyncio.run(
        assist.run_job(
            worktree=str(repo), prompt="p", system="s", model="sonnet", effort=None,
            max_budget_usd=1.0, max_parallel=0, emit=emit,
        )
    )


def test_the_spawned_process_gets_the_whitelist_and_its_stream_is_parsed(tmp_path, monkeypatch):
    repo = _repo(tmp_path)
    argv_file = tmp_path / "argv.txt"
    _fake_claude(
        tmp_path / "bin",
        f"""printf '%s\\n' "$@" > {argv_file}
echo '{{"type":"system","subtype":"init","model":"m","session_id":"s"}}'
echo '{{"type":"assistant","message":{{"content":[{{"type":"text","text":"1. a"}}]}}}}'
echo '{{"type":"result","subtype":"success","result":"1. a","total_cost_usd":0.03,"usage":{{}}}}'
""",
    )
    monkeypatch.setenv("PATH", f"{tmp_path / 'bin'}{os.pathsep}{os.environ['PATH']}")
    res = _run_real_path(repo)
    assert res.error is None and res.text == "1. a" and res.cost_usd == 0.03
    argv = argv_file.read_text().split("\n")
    assert "bypassPermissions" not in argv and "dontAsk" in argv
    assert argv[argv.index("--tools") + 1 : argv.index("--tools") + 6] == [
        "Read", "Grep", "Glob", "WebFetch", "WebSearch",
    ]


def test_a_real_process_that_writes_into_the_worktree_is_caught(tmp_path, monkeypatch):
    repo = _repo(tmp_path)
    _fake_claude(
        tmp_path / "bin",
        """echo tampered > sneaky.txt
echo '{"type":"result","subtype":"success","result":"1. a","usage":{}}'
""",
    )
    monkeypatch.setenv("PATH", f"{tmp_path / 'bin'}{os.pathsep}{os.environ['PATH']}")
    res = _run_real_path(repo)
    assert res.violation and res.error.startswith(assist.VIOLATION) and "sneaky.txt" in res.error


def test_a_missing_claude_cli_is_a_clean_error(tmp_path, monkeypatch):
    repo = _repo(tmp_path)
    monkeypatch.setattr(assist.shutil, "which", lambda name: None)
    res = _run_real_path(repo)
    assert res.error and "claude" in res.error


# --------------------------------------------------------------------- refs in prompt
def test_refs_resolve_files_and_issue_titles(tmp_path):
    repo = _repo(tmp_path)

    async def view_issue(path, n):
        if n == 12:
            return {"available": True, "title": "Duplicate webhooks"}
        raise RuntimeError("gh offline")

    out = asyncio.run(
        assist.resolve_refs(str(repo), str(repo), "fix @f.txt and #12 and #99 and @ghost.ts", view_issue)
    )
    assert "- file: f.txt" in out and "- issue #12: Duplicate webhooks" in out
    assert "ghost.ts" not in out.split("pointed at:")[1] and "#99" not in out.split("pointed at:")[1]
    assert asyncio.run(assist.resolve_refs(str(repo), str(repo), "plain", view_issue)) == "plain"


def test_clean_field_never_cuts_a_word():
    long = "First sentence here. " + "word " * 120
    out = assist.clean_field(long, cap=400)
    assert out == "First sentence here." or out.endswith("…")
    assert len(out) <= 401
    two = ("Shipping cost is computed in calculateShipping. It adds the weekend surcharge. "
           "The existing tests only check a Saturday and a Sunday, not the edges.")
    out2 = assist.clean_field(two, cap=100)
    assert out2 == "Shipping cost is computed in calculateShipping. It adds the weekend surcharge."
    assert assist.clean_field("short", cap=400) == "short"
    no_space = "x" * 500
    assert assist.clean_field(no_space, cap=400).endswith("…")
