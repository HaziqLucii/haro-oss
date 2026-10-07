"""Manual-rail endpoints: plan jobs, plan CRUD, research scopes, pinned docs, man pages, and
how a saved plan reaches the PR body and the receipt. The AI is always a stub."""

from __future__ import annotations

import asyncio
import subprocess

import pytest
from fastapi import HTTPException

from haro import assist, integrate, main, receipt as receipt_svc, research
from haro.adapters.base import NormalizedEvent
from haro.config import load_project_settings
from haro.hub import Hub
from haro.models import (
    AssistPlanRequest,
    AssistResearchRequest,
    PatchPlanRequest,
    PinnedDoc,
    PinnedDocsRequest,
    PlanStepPatch,
    Project,
    SetModeRequest,
    StagePathsRequest,
    StartAgentRequest,
    Workspace,
)
from haro.store import Store


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
    (repo / "f.txt").write_text("needle in a haystack\n")
    (repo / "g.txt").write_text("other\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "add needle handling")
    return repo


def _wire(monkeypatch, tmp_path, **ws_kw):
    repo = _repo(tmp_path)
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(repo), default_branch="main", stack=["react"])
    store.projects[project.id] = project
    ws = Workspace(
        project_id="p", name="w", branch="main", worktree_path=str(repo), base_ref="main", **ws_kw
    )
    store.workspaces[ws.id] = ws
    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr(main, "hub", hub)
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    return store, hub, ws, repo


PLAN_REPLY = "TITLE: Wire the thing\n1. Read `f.txt`.\n```\nleak()\n```\n2. Edit g.txt by hand.\nWHY THIS ORDER: read first."


def _stub_claude(
    monkeypatch, reply, *, cost=0.05, side_effect=None, hold=None, pre_effect=None, events=()
):
    seen: dict = {}

    def source(cmd, cwd, *, sandbox=False):
        seen["cmd"] = cmd

        async def gen():
            if pre_effect:
                pre_effect()
            for ev in events:
                yield ev
            if hold is not None:
                await hold.wait()
            if side_effect:
                side_effect()
            yield NormalizedEvent("token", {"text": reply})
            yield NormalizedEvent("done", {"result": reply, "cost_usd": cost})

        return gen()

    monkeypatch.setattr(assist, "_claude_source", source)
    return seen


async def _finish(store, ws):
    await store.assist_tasks[ws.id]


def _run(coro):
    return asyncio.run(coro)


def _channel(hub, ws, kind):
    return [m for m in hub.history(ws.id) if m.get("channel") == "assist" and m.get("kind") == kind]


# ------------------------------------------------------------------------ plan job
def test_plan_job_stores_a_stripped_plan_and_streams_on_the_assist_channel(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    seen = _stub_claude(monkeypatch, PLAN_REPLY)

    async def scenario():
        job = await main.assist_plan(ws.id, AssistPlanRequest(prompt="Build it with @f.txt"))
        assert job.kind == "plan" and job.status == "running"
        await _finish(store, ws)
        return job

    job = _run(scenario())
    assert store.assist_jobs[ws.id].status == "done"
    assert len(ws.plans) == 1
    plan = ws.plans[0]
    assert plan.title == "Wire the thing" and plan.why == "read first."
    assert [s.text for s in plan.steps] == ["Read `f.txt`.", "Edit g.txt by hand."]
    assert plan.model == "sonnet" and plan.cost_usd == 0.05 and not plan.saved
    assert "leak" not in plan.model_dump_json()
    assert "- file: f.txt" in seen["cmd"][2]
    assert "bypassPermissions" not in seen["cmd"]

    assert _channel(hub, ws, "started") and _channel(hub, ws, "token")
    done = _channel(hub, ws, "done")[0]
    assert done["job"] == "plan" and done["job_id"] == job.id
    assert done["plan"]["id"] == plan.id and "leak" not in str(done)
    assert not _channel(hub, ws, "error")


def test_plan_job_works_in_agent_mode_too(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    _stub_claude(monkeypatch, PLAN_REPLY)

    async def scenario():
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        await _finish(store, ws)

    _run(scenario())
    assert len(ws.plans) == 1


def test_a_guard_trip_fails_the_job_loudly_and_stores_nothing(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(monkeypatch, PLAN_REPLY, side_effect=lambda: (repo / "x.txt").write_text("!"))

    async def scenario():
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        await _finish(store, ws)

    _run(scenario())
    assert ws.plans == []
    job = store.assist_jobs[ws.id]
    assert job.status == "error" and job.error.startswith(assist.VIOLATION)
    assert _channel(hub, ws, "error")[0]["message"].startswith(assist.VIOLATION)
    assert not _channel(hub, ws, "done")


def test_a_reply_without_steps_is_an_error_not_an_empty_plan(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    _stub_claude(monkeypatch, "I would rather not.")

    async def scenario():
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        await _finish(store, ws)

    _run(scenario())
    assert ws.plans == [] and store.assist_jobs[ws.id].status == "error"


def test_second_job_is_409_and_stop_settles_the_first(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    _stub_claude(monkeypatch, PLAN_REPLY, hold=asyncio.Event())

    async def scenario():
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        with pytest.raises(HTTPException) as e:
            await main.assist_plan(ws.id, AssistPlanRequest(prompt="y"))
        assert e.value.status_code == 409
        with pytest.raises(HTTPException) as e:
            await main.assist_research(ws.id, AssistResearchRequest(query="q", scope="ask"))
        assert e.value.status_code == 409
        with pytest.raises(HTTPException) as e:
            await main.set_workspace_mode(ws.id, SetModeRequest(mode="manual"))
        assert e.value.status_code == 409 and "assistant" in e.value.detail
        out = await main.stop_assist(ws.id)
        assert out == {"stopped": True}
        assert not store.assist_running(ws.id)
        assert (await main.stop_assist(ws.id)) == {"stopped": False}

    _run(scenario())
    assert store.assist_jobs[ws.id].status == "stopped" and ws.plans == []
    assert _channel(hub, ws, "stopped")


def test_refused_while_a_mode_switch_is_in_progress(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    store.mode_switching.add(ws.id)
    with pytest.raises(HTTPException) as e:
        _run(main.assist_plan(ws.id, AssistPlanRequest(prompt="x")))
    assert e.value.status_code == 409 and "switching" in e.value.detail


def test_blank_prompt_and_unknown_workspace(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    with pytest.raises(HTTPException) as e:
        _run(main.assist_plan(ws.id, AssistPlanRequest(prompt="   ")))
    assert e.value.status_code == 400
    with pytest.raises(HTTPException) as e:
        _run(main.assist_plan("nope", AssistPlanRequest(prompt="x")))
    assert e.value.status_code == 404


def test_model_resolution_honours_the_plan_role_then_defaults(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    (repo / ".haro").mkdir()
    (repo / ".haro" / "settings.toml").write_text("[roles]\nenabled = true\nplan = 'opus:high'\n")
    ps = load_project_settings(str(repo))
    assert main._assist_model(ps, None, None) == ("opus", "high")
    assert main._assist_model(ps, "haiku", "low") == ("haiku", "low")
    assert main._assist_model(None, None, None) == ("sonnet", None)


# ------------------------------------------------------------------- plan CRUD
def _with_plan(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(monkeypatch, PLAN_REPLY)

    async def scenario():
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        await _finish(store, ws)

    _run(scenario())
    return store, hub, ws, ws.plans[0]


def test_plan_crud_tick_edit_save_delete(monkeypatch, tmp_path):
    store, hub, ws, plan = _with_plan(monkeypatch, tmp_path)
    assert _run(main.list_plans(ws.id)) == [plan]

    out = _run(main.patch_plan(ws.id, plan.id, PatchPlanRequest(
        steps=[PlanStepPatch(text="Read `f.txt`.", done=True), PlanStepPatch(text="Edit g.txt by hand.")]
    )))
    assert [s.done for s in out.steps] == [True, False] and out.steps[0].done_at is not None
    first_tick = out.steps[0].done_at

    out = _run(main.patch_plan(ws.id, plan.id, PatchPlanRequest(
        title="  Better title ",
        steps=[PlanStepPatch(text="Read `f.txt`.", done=True), PlanStepPatch(text="A new step"), PlanStepPatch(text="  ")],
    )))
    assert out.title == "Better title"
    assert [s.text for s in out.steps] == ["Read `f.txt`.", "A new step"]
    assert out.steps[0].done_at == first_tick  # an unchanged tick keeps its time

    out = _run(main.patch_plan(ws.id, plan.id, PatchPlanRequest(steps=[PlanStepPatch(text="Read `f.txt`.")])))
    assert out.steps[0].done is False and out.steps[0].done_at is None

    assert out.saved is False
    out = _run(main.patch_plan(ws.id, plan.id, PatchPlanRequest(saved=True)))
    assert out.saved and out.saved_at is not None

    with pytest.raises(HTTPException) as e:
        _run(main.patch_plan(ws.id, plan.id, PatchPlanRequest(steps=[])))
    assert e.value.status_code == 400
    with pytest.raises(HTTPException) as e:
        _run(main.patch_plan(ws.id, plan.id, PatchPlanRequest(title=" ")))
    assert e.value.status_code == 400
    with pytest.raises(HTTPException) as e:
        _run(main.patch_plan(ws.id, "plan_nope", PatchPlanRequest(saved=True)))
    assert e.value.status_code == 404

    assert _run(main.delete_plan(ws.id, plan.id)) == {"deleted": plan.id}
    assert ws.plans == []


def test_plans_survive_a_snapshot_round_trip(monkeypatch, tmp_path):
    _, _, ws, plan = _with_plan(monkeypatch, tmp_path)
    again = Workspace.model_validate_json(ws.model_dump_json())
    assert again.plans[0].id == plan.id and again.plans[0].steps[1].text == "Edit g.txt by hand."
    assert Workspace(project_id="p", name="n", branch="b", worktree_path="/x", base_ref="m").plans == []


# --------------------------------------------------------- saved plan: PR body + receipt
def test_saved_plan_reaches_the_pr_body(monkeypatch, tmp_path):
    store, hub, ws, plan = _with_plan(monkeypatch, tmp_path)
    _run(main.patch_plan(ws.id, plan.id, PatchPlanRequest(saved=True)))
    md = assist.plan_markdown(ws.plans)

    repo = tmp_path / "repo"
    _git(repo, "remote", "add", "origin", "https://example.invalid/o/r.git")
    calls: list[tuple] = []

    async def fake_gh(*args, cwd):
        calls.append(args)
        return 0, "https://github.com/o/r/pull/1" if args[:2] == ("pr", "create") else "", ""

    async def noop(*a, **k):
        return None

    monkeypatch.setattr(integrate.git_ops, "push_branch", noop)
    monkeypatch.setattr(integrate.git_ops, "delete_remote_branch", noop)
    monkeypatch.setattr(integrate, "_gh", fake_gh)
    from haro import git_ops

    wt = tmp_path / "wt"
    asyncio.run(git_ops.add_worktree(repo, wt, "feat", "main"))
    (wt / "n.txt").write_text("new\n")
    ws2 = Workspace(project_id="p", name="w2", branch="feat", worktree_path=str(wt), base_ref="main")
    project = store.projects["p"]

    asyncio.run(integrate.integrate(
        workspace=ws2, project=project, message="title\n\nbody", plan_markdown=md,
        receipt_markdown="# haro gate receipt: GREEN\n",
    ))
    body = next(c for c in calls if c[:2] == ("pr", "create"))[5]
    assert "## Plan" in body and "Read `f.txt`." in body and "Why this order: read first." in body
    assert body.index("## Plan") < body.index("GREEN")
    assert "leak" not in body


def test_unsaved_plan_stays_out_of_the_pr_body():
    assert assist.plan_markdown([ManualPlanStub()]) == ""


def ManualPlanStub():
    from haro.models import ManualPlan, PlanStep

    return ManualPlan(title="t", steps=[PlanStep(text="s")])


def test_receipt_carries_plan_and_research_lines(monkeypatch, tmp_path):
    store, hub, ws, plan = _with_plan(monkeypatch, tmp_path)
    settings = load_project_settings(ws.worktree_path)

    async def build():
        return await receipt_svc.build_receipt(store=store, workspace=ws, settings=settings)

    r = _run(build())
    assert r.plan is None and r.research is None
    assert "Plan:" not in receipt_svc.render_markdown(r)

    _run(main.patch_plan(ws.id, plan.id, PatchPlanRequest(saved=True)))
    _run(main.assist_research(ws.id, AssistResearchRequest(query="needle", scope="repo")))
    _run(main.assist_research(ws.id, AssistResearchRequest(query="needle", scope="git")))
    r = _run(build())
    assert r.plan.steps == 2 and r.plan.ai_edits == 0 and r.research.lookups == 2
    md = receipt_svc.render_markdown(r)
    assert "- Plan: haro AI · 2 steps · AI edits: 0" in md
    assert "- Research: 2 lookups" in md


# ----------------------------------------------------------------------- research
def test_repo_scope_finds_pointers_without_ai(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    monkeypatch.setattr(assist, "_claude_source", lambda *a, **k: pytest.fail("no AI for repo"))
    out = _run(main.assist_research(ws.id, AssistResearchRequest(query="needle", scope="repo")))
    assert out.job_id is None and out.answer is None
    row = out.rows[0]
    assert (row.source, row.target, row.action) == ("repo", "f.txt:1", "jump")
    assert "needle" in row.why


def test_git_scope_pickaxe_grep_and_blame(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    out = _run(main.assist_research(ws.id, AssistResearchRequest(query="needle", scope="git")))
    assert len(out.rows) == 1  # found by both the pickaxe and the message, listed once
    row = out.rows[0]
    assert row.source == "git" and row.action == "jump" and row.target in ("f.txt", "g.txt")
    assert "add needle handling" in row.title

    blame = _run(main.assist_research(ws.id, AssistResearchRequest(query="f.txt:1", scope="git")))
    assert blame.rows[0].target == "f.txt:1" and "blame" in blame.rows[0].title
    assert "add needle handling" in blame.rows[0].why

    none = _run(main.assist_research(ws.id, AssistResearchRequest(query="zzzznotthere", scope="git")))
    assert none.rows == []


def test_git_query_that_looks_like_an_option_is_only_a_search_term(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    out = _run(main.assist_research(ws.id, AssistResearchRequest(query="--output=/tmp/pwned", scope="git")))
    assert out.rows == []


def test_man_scope_parses_apropos_lines(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)

    class Proc:
        returncode = 0

        async def communicate(self):
            return (b"ls(1), lls(1) - list directory contents\nls (1p) - list\ngarbage line\n", b"")

    async def fake_exec(*args, **kw):
        assert args[:2] == ("man", "-k")
        return Proc()

    monkeypatch.setattr(research.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(research.shutil, "which", lambda n: "/usr/bin/man")
    out = _run(main.assist_research(ws.id, AssistResearchRequest(query="list", scope="man")))
    assert [(r.title, r.target, r.action) for r in out.rows] == [
        ("ls(1)", "ls(1)", "read"), ("ls(1p)", "ls(1p)", "read"),
    ]


def test_man_page_read_strips_overstrikes_and_rejects_bad_names(monkeypatch):
    assert research.strip_overstrikes("N\x08NA\x08AM\x08ME\x08E _\x08x") == "NAME x"
    assert research.parse_man_page("ls(1)") == ("ls", "1")
    assert research.parse_man_page("printf") == ("printf", None)
    assert research.parse_man_page("-k") is None and research.parse_man_page("a b") is None
    assert research.parse_man_page("x;rm") is None

    class Proc:
        returncode = 0

        async def communicate(self):
            return (b"L\x08LS\x08S(1)\n\nlist stuff\n", b"")

    seen = {}

    async def fake_exec(*args, **kw):
        seen["args"] = args
        return Proc()

    monkeypatch.setattr(research.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(research.shutil, "which", lambda n: "/usr/bin/man")
    page = _run(main.get_man_page("ls(1)"))
    assert page.text.startswith("LS(1)") and not page.truncated
    assert seen["args"] == ("man", "-P", "cat", "1", "ls")
    with pytest.raises(HTTPException) as e:
        _run(main.get_man_page("-k"))
    assert e.value.status_code == 404


def test_web_scope_builds_links_and_fetches_nothing(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    monkeypatch.setattr(research.asyncio, "create_subprocess_exec", lambda *a, **k: pytest.fail("no process"))
    out = _run(main.assist_research(ws.id, AssistResearchRequest(query="use effect cleanup", scope="web")))
    urls = [r.target for r in out.rows]
    assert any("site%3Areact.dev" in u and "use%20effect%20cleanup" in u for u in urls)
    assert urls[-1] == "https://duckduckgo.com/?q=use%20effect%20cleanup"
    assert all(r.action == "open" and r.source == "web" for r in out.rows)


def test_ask_scope_runs_a_stubbed_assistant_and_drops_dead_pointers(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    reply = (
        '{"answer": "It lives in f.txt.", "sources": ['
        '{"kind": "repo", "title": "the file", "target": "f.txt:1", "why": "here"},'
        '{"kind": "repo", "title": "ghost", "target": "missing.ts:4", "why": "made up"},'
        '{"kind": "web", "title": "docs", "target": "https://example.com/d", "why": "official"}]}'
    )
    seen = _stub_claude(monkeypatch, reply)

    async def scenario():
        out = await main.assist_research(ws.id, AssistResearchRequest(query="where is needle", scope="ask"))
        assert out.job_id and out.rows == []
        await _finish(store, ws)

    _run(scenario())
    done = _channel(hub, ws, "done")[0]
    assert done["job"] == "research" and done["answer"] == "It lives in f.txt."
    assert [r["title"] for r in done["rows"]] == ["the file", "docs"]
    assert "1 source(s) dropped" in done["note"]
    assert "--disallowedTools" in seen["cmd"] and "Bash" not in seen["cmd"][seen["cmd"].index("--tools") + 1 :][:5]
    assert store.assist_jobs[ws.id].rows[0].action == "jump"
    assert store.assist_jobs[ws.id].note == done["note"]


ASK_REPLY = (
    '{"answer": "It lives in f.txt.", "sources": ['
    '{"kind": "repo", "title": "the file", "target": "f.txt:1", "why": "here"},'
    '{"kind": "repo", "title": "ghost", "target": "missing.ts:4", "why": "made up"}]}'
)


def _ask(store, ws, query):
    async def go():
        await main.assist_research(ws.id, AssistResearchRequest(query=query, scope="ask"))
        await _finish(store, ws)

    _run(go())


def test_a_successful_ask_stores_its_answer_rows_and_note_on_the_entry(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(monkeypatch, ASK_REPLY)
    _ask(store, ws, "where is needle")
    e = ws.research_log.entries[-1]
    assert e.scope == "ask" and e.query == "where is needle"
    assert e.answer == "It lives in f.txt."
    assert [r.title for r in e.rows] == ["the file"] and e.rows[0].action == "jump"
    assert "1 source(s) dropped" in e.note
    assert e.blocked_calls == []
    assert ws.research_log.count == 1 and ws.research_log.unverified is False


def test_a_blocked_call_and_guard_note_are_kept_with_the_answer(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(
        monkeypatch,
        ASK_REPLY,
        events=[NormalizedEvent("file_edit", {"tool": "Write", "path": "x"})],
        side_effect=lambda: (repo / "o.txt").write_text("x"),
    )
    store.mutation_running.add(ws.id)
    _ask(store, ws, "q")
    e = ws.research_log.entries[-1]
    assert e.answer and e.guard_note
    assert e.blocked_calls == ["Write"]
    assert ws.research_log.unverified is True


def test_only_the_last_ten_asks_keep_answers_and_the_counts_do_not_change(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(monkeypatch, ASK_REPLY)
    _run(main.assist_research(ws.id, AssistResearchRequest(query="repo q", scope="repo")))
    for i in range(12):
        _ask(store, ws, f"ask {i}")
    log = ws.research_log
    asks = [e for e in log.entries if e.scope == "ask"]
    assert log.count == 13 and len(log.entries) == 13
    assert [e.query for e in asks if e.answer] == [f"ask {i}" for i in range(2, 12)]
    old = asks[0]
    assert old.query == "ask 0" and old.answer is None and old.rows == [] and old.note is None
    assert log.entries[0].scope == "repo" and log.entries[0].answer is None
    assert log.unverified is False


def test_a_failed_or_stopped_ask_stores_nothing(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    hold = asyncio.Event()
    _stub_claude(monkeypatch, ASK_REPLY, hold=hold)

    async def stopped():
        await main.assist_research(ws.id, AssistResearchRequest(query="stop me", scope="ask"))
        await asyncio.sleep(0)
        await main.stop_assist(ws.id)

    _run(stopped())
    assert store.assist_jobs[ws.id].status == "stopped"
    _stub_claude(monkeypatch, ASK_REPLY, events=[NormalizedEvent("error", {"message": "boom"})])
    _ask(store, ws, "garbage")
    assert store.assist_jobs[ws.id].status == "error"
    for e in ws.research_log.entries:
        assert e.answer is None and e.rows == [] and e.note is None and e.blocked_calls == []
    assert ws.research_log.count == 2


def test_an_old_snapshot_without_the_new_fields_hydrates(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    raw = ws.model_dump()
    raw["research_log"] = {
        "count": 3,
        "unverified": True,
        "entries": [{"scope": "ask", "query": "old q", "at": 1.0, "guard_note": "n"}],
    }
    again = Workspace.model_validate(raw)
    e = again.research_log.entries[0]
    assert e.query == "old q" and e.answer is None and e.rows == [] and e.blocked_calls == []
    assert again.research_log.count == 3 and again.research_log.unverified is True
    assert Workspace.model_validate_json(again.model_dump_json()).research_log == again.research_log


def test_every_call_is_logged_and_only_the_last_twenty_entries_are_kept(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)

    async def scenario():
        for i in range(23):
            await main.assist_research(ws.id, AssistResearchRequest(query=f"q{i}", scope="repo"))
        await main.assist_research(ws.id, AssistResearchRequest(query="w", scope="web"))

    _run(scenario())
    log = ws.research_log
    assert log.count == 24 and len(log.entries) == 20
    assert log.entries[-1].scope == "web" and log.entries[0].query == "q4"


def test_blank_research_query_is_400(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    with pytest.raises(HTTPException) as e:
        _run(main.assist_research(ws.id, AssistResearchRequest(query=" ", scope="repo")))
    assert e.value.status_code == 400 and ws.research_log.count == 0


# ------------------------------------------------------------------- pinned docs
def test_pinned_docs_round_trip_validate_and_dedupe(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    assert _run(main.get_pinned_docs("p")) == []
    out = _run(main.put_pinned_docs("p", PinnedDocsRequest(docs=[
        PinnedDoc(title="Stripe API", url="https://docs.stripe.com/api"),
        PinnedDoc(title="", url="https://react.dev/reference"),
        PinnedDoc(title="dup", url="https://docs.stripe.com/api"),
    ])))
    assert [(d.title, d.url) for d in out] == [
        ("Stripe API", "https://docs.stripe.com/api"), ("react.dev", "https://react.dev/reference"),
    ]
    assert _run(main.get_pinned_docs("p")) == out
    for bad in ("javascript:alert(1)", "file:///etc/passwd", "not a url"):
        with pytest.raises(HTTPException) as e:
            _run(main.put_pinned_docs("p", PinnedDocsRequest(docs=[PinnedDoc(title="x", url=bad)])))
        assert e.value.status_code == 400
    with pytest.raises(HTTPException) as e:
        _run(main.get_pinned_docs("nope"))
    assert e.value.status_code == 404
    again = Project.model_validate_json(store.projects["p"].model_dump_json())
    assert len(again.pinned_docs) == 2


# ------------------------------------------------------- PR body keeps its filled text
def _pr_repo(tmp_path, monkeypatch, messages):
    from haro import git_panel

    repo = _repo(tmp_path)
    _git(repo, "remote", "add", "origin", "https://example.invalid/o/r.git")
    for i, msg in enumerate(messages):
        (repo / f"c{i}.txt").write_text("x")
        _git(repo, "add", "-A")
        _git(repo, "commit", "-qm", msg)
    calls: list[tuple] = []

    async def fake_gh(*args, cwd):
        calls.append(args)
        return 0, "https://github.com/o/r/pull/3", ""

    async def noop(*a, **k):
        return None

    async def has_remote(*a, **k):
        return True

    monkeypatch.setattr(git_panel, "_gh", fake_gh)
    monkeypatch.setattr(git_panel.git_ops, "push_branch", noop)
    monkeypatch.setattr(git_panel.git_ops, "has_remote", has_remote)
    return repo, calls


def test_the_plan_is_appended_to_the_filled_body_not_substituted(monkeypatch, tmp_path):
    from haro import git_panel

    repo, calls = _pr_repo(
        tmp_path, monkeypatch, ["add the thing\n\nwhy the thing exists, in the commit body"]
    )
    plan = "## Plan\n\n- [ ] read the handler\n"
    asyncio.run(git_panel.create_pr(str(repo), "main", "main~1", plan_markdown=plan))
    args = calls[0]
    assert args[args.index("--title") + 1] == "add the thing"
    body = args[args.index("--body") + 1]
    assert body.startswith("why the thing exists, in the commit body")
    assert body.endswith("- [ ] read the handler")
    assert "--fill" not in args


def test_a_multi_commit_branch_gets_a_bullet_per_commit_then_the_plan(monkeypatch, tmp_path):
    from haro import git_panel

    repo, calls = _pr_repo(tmp_path, monkeypatch, ["first change", "second change"])
    asyncio.run(git_panel.create_pr(str(repo), "main", "main~2", plan_markdown="## Plan\n\n- [ ] s\n"))
    body = calls[0][calls[0].index("--body") + 1]
    assert body.startswith("- first change\n- second change\n\n## Plan")


def test_an_explicit_body_keeps_its_text_and_gets_the_plan_after_it(monkeypatch, tmp_path):
    from haro import git_panel

    repo, calls = _pr_repo(tmp_path, monkeypatch, ["only commit"])
    asyncio.run(
        git_panel.create_pr(
            str(repo), "main", "main~1", body="trust report text", plan_markdown="## Plan\n\n- [ ] s\n"
        )
    )
    body = calls[0][calls[0].index("--body") + 1]
    assert body == "trust report text\n\n## Plan\n\n- [ ] s"


def test_without_a_plan_the_pr_still_uses_fill(monkeypatch, tmp_path):
    from haro import git_panel

    repo, calls = _pr_repo(tmp_path, monkeypatch, ["only commit"])
    asyncio.run(git_panel.create_pr(str(repo), "main", "main~1"))
    assert "--fill" in calls[0] and "--body" not in calls[0]


# ------------------------------------------------- fix round: false alarms and haro's writes
def test_an_attempted_write_does_not_fail_a_plan_job(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(
        monkeypatch, PLAN_REPLY,
        events=[NormalizedEvent("file_edit", {"tool": "Write", "path": "x.txt"})],
    )

    async def scenario():
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        await _finish(store, ws)

    _run(scenario())
    job = store.assist_jobs[ws.id]
    assert job.status == "done" and job.error is None and len(ws.plans) == 1
    assert job.blocked_calls == ["Write"]
    assert _channel(hub, ws, "blocked")[0]["tool"] == "Write"
    assert _channel(hub, ws, "done")[0]["blocked_calls"] == ["Write"]
    assert not _channel(hub, ws, "error")


def test_the_agent_cannot_start_while_the_assistant_runs(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    _stub_claude(monkeypatch, PLAN_REPLY, hold=asyncio.Event())

    async def scenario():
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        with pytest.raises(HTTPException) as e:
            await main.start_agent(ws.id, StartAgentRequest(task="edit things"))
        assert e.value.status_code == 409 and "assistant" in e.value.detail
        await main.stop_assist(ws.id)

    _run(scenario())


def test_a_gate_run_during_the_job_makes_the_guard_inconclusive(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    hold = asyncio.Event()
    _stub_claude(
        monkeypatch, PLAN_REPLY, hold=hold,
        side_effect=lambda: (repo / "node_modules_link").write_text("the gate made this"),
    )

    async def scenario():
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        store.note_internal_write(ws.id)  # what run_gate does on entry
        hold.set()
        await _finish(store, ws)

    _run(scenario())
    job = store.assist_jobs[ws.id]
    assert job.status == "done" and job.error is None and len(ws.plans) == 1
    assert job.guard_note and "node_modules_link" in job.guard_note
    assert _channel(hub, ws, "done")[0]["guard_note"] == job.guard_note
    assert ws.id not in store.assist_internal  # cleared when the job settles


def test_internal_writes_are_only_noted_while_a_job_runs(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path)
    store.note_internal_write(ws.id)
    assert ws.id not in store.assist_internal
    _stub_claude(monkeypatch, PLAN_REPLY, hold=asyncio.Event())

    async def scenario():
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        await main.git_stage(ws.id, StagePathsRequest(paths=["f.txt"]))
        assert ws.id in store.assist_internal
        await main.stop_assist(ws.id)

    _run(scenario())


def test_stopping_a_job_that_already_wrote_reports_the_change(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    _stub_claude(
        monkeypatch, PLAN_REPLY, hold=asyncio.Event(),
        pre_effect=lambda: (repo / "half.txt").write_text("x"),
    )

    async def scenario():
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        await asyncio.sleep(0.2)
        await main.stop_assist(ws.id)

    _run(scenario())
    job = store.assist_jobs[ws.id]
    assert job.status == "error" and job.error.startswith(assist.VIOLATION)
    assert _channel(hub, ws, "error") and not _channel(hub, ws, "stopped")
    assert ws.plans == []


# ---------------------------------- second fix round: writers already live, visible notes, titles
def _job_with_live_writer(monkeypatch, tmp_path, arm):
    """Run a plan job whose stub writes a file, with `arm(store, ws)` having made a haro
    writer live BEFORE the POST. Returns (store, hub, ws)."""
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    _stub_claude(
        monkeypatch, PLAN_REPLY,
        side_effect=lambda: (repo / "vitest_snapshot.txt").write_text("the gate wrote this"),
    )

    async def scenario():
        cleanup = arm(store, ws)
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        assert ws.id in store.assist_internal
        await _finish(store, ws)
        if cleanup:
            await cleanup()

    _run(scenario())
    return store, hub, ws


def test_a_gate_started_before_the_job_makes_the_guard_inconclusive(monkeypatch, tmp_path):
    holder = {}

    def arm(store, ws):
        holder["t"] = asyncio.create_task(asyncio.sleep(30))
        store.gate_tasks[ws.id] = holder["t"]

        async def cleanup():
            holder["t"].cancel()

        return cleanup

    store, hub, ws = _job_with_live_writer(monkeypatch, tmp_path, arm)
    job = store.assist_jobs[ws.id]
    assert job.status == "done" and job.error is None and len(ws.plans) == 1
    assert "vitest_snapshot.txt" in job.guard_note
    assert ws.plans[0].guard_note == job.guard_note


def test_a_running_dev_server_counts_for_the_whole_job(monkeypatch, tmp_path):
    from types import SimpleNamespace

    def arm(store, ws):
        store.run_procs[(ws.id, "app")] = SimpleNamespace(returncode=None)

    store, hub, ws = _job_with_live_writer(monkeypatch, tmp_path, arm)
    assert store.assist_jobs[ws.id].status == "done"
    assert ws.plans[0].guard_note


def test_a_mutation_pass_in_flight_counts(monkeypatch, tmp_path):
    def arm(store, ws):
        store.mutation_running.add(ws.id)

    store, hub, ws = _job_with_live_writer(monkeypatch, tmp_path, arm)
    assert store.assist_jobs[ws.id].status == "done" and ws.plans[0].guard_note


def test_a_stopped_dev_server_or_finished_gate_does_not_excuse_a_write(monkeypatch, tmp_path):
    from types import SimpleNamespace

    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    _stub_claude(
        monkeypatch, PLAN_REPLY, side_effect=lambda: (repo / "sneaky.txt").write_text("x")
    )
    store.run_procs[(ws.id, "app")] = SimpleNamespace(returncode=0)  # exited
    store.run_procs[("ws_other", "app")] = SimpleNamespace(returncode=None)  # someone else's

    async def scenario():
        done = asyncio.create_task(asyncio.sleep(0))
        await done
        store.gate_tasks[ws.id] = done  # finished
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        assert ws.id not in store.assist_internal
        await _finish(store, ws)

    _run(scenario())
    job = store.assist_jobs[ws.id]
    assert job.status == "error" and job.error.startswith(assist.VIOLATION)


def test_the_plan_keeps_its_guard_note_and_blocked_calls(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    _stub_claude(
        monkeypatch, PLAN_REPLY,
        side_effect=lambda: (repo / "out.txt").write_text("gate output"),
        events=[NormalizedEvent("file_edit", {"tool": "Write", "path": "x"})],
    )

    async def scenario():
        store.mutation_running.add(ws.id)
        await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        await _finish(store, ws)

    _run(scenario())
    plan = ws.plans[0]
    assert plan.guard_note.startswith("haro couldn't check the files during this run")
    assert plan.blocked_calls == ["Write"]
    done = _channel(hub, ws, "done")[0]
    assert done["plan"]["guard_note"] == plan.guard_note and done["plan"]["blocked_calls"] == ["Write"]
    again = Workspace.model_validate_json(ws.model_dump_json())
    assert again.plans[0].guard_note == plan.guard_note


def test_an_unverified_ask_is_recorded_on_its_research_entry(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    reply = '{"answer": "In f.txt.", "sources": []}'
    _stub_claude(monkeypatch, reply, side_effect=lambda: (repo / "o.txt").write_text("x"))

    async def scenario():
        store.mutation_running.add(ws.id)
        await main.assist_research(ws.id, AssistResearchRequest(query="q", scope="ask"))
        await _finish(store, ws)

    _run(scenario())
    assert ws.research_log.entries[-1].guard_note
    assert _channel(hub, ws, "done")[0]["guard_note"] == ws.research_log.entries[-1].guard_note


def test_the_receipt_says_unverified_instead_of_zero(monkeypatch, tmp_path):
    store, hub, ws, plan = _with_plan(monkeypatch, tmp_path)
    settings = load_project_settings(ws.worktree_path)
    _run(main.patch_plan(ws.id, plan.id, PatchPlanRequest(saved=True)))

    def build():
        return _run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings))

    r = build()
    assert r.plan.unverified is False
    assert "AI edits: 0" in receipt_svc.render_markdown(r)

    plan.guard_note = "haro couldn't check the files during this run (x); the assistant had no edit tools."
    r = build()
    md = receipt_svc.render_markdown(r)
    assert r.plan.unverified and r.plan.ai_edits == 0
    assert "AI edits: unverified" in md and "AI edits: 0" not in md
    assert "AI edits: unverified" in assist.plan_markdown(ws.plans)

    _run(main.assist_research(ws.id, AssistResearchRequest(query="q", scope="repo")))
    ws.research_log.entries[-1].guard_note = "note"
    assert "Research: 1 lookup · AI edits: unverified" in receipt_svc.render_markdown(build())


def test_a_multi_commit_pr_with_a_plan_keeps_fills_title_rule(monkeypatch, tmp_path):
    from haro import git_panel

    repo, calls = _pr_repo(tmp_path, monkeypatch, ["first change", "second change"])
    asyncio.run(
        git_panel.create_pr(str(repo), "feat/two-changes_here", "main~2", plan_markdown="## Plan\n\n- [ ] s\n")
    )
    args = calls[0]
    assert args[args.index("--title") + 1] == "feat/two changes here"


def test_a_single_commit_pr_with_a_plan_titles_with_the_commit_subject(monkeypatch, tmp_path):
    from haro import git_panel

    repo, calls = _pr_repo(tmp_path, monkeypatch, ["the one commit"])
    asyncio.run(git_panel.create_pr(str(repo), "feat/x", "main~1", plan_markdown="## Plan\n\n- [ ] s\n"))
    assert calls[0][calls[0].index("--title") + 1] == "the one commit"


def test_an_explicit_body_keeps_the_tip_subject_as_its_title(monkeypatch, tmp_path):
    from haro import git_panel

    repo, calls = _pr_repo(tmp_path, monkeypatch, ["first change", "second change"])
    asyncio.run(
        git_panel.create_pr(
            str(repo), "feat/x-y", "main~2", body="report", plan_markdown="## Plan\n\n- [ ] s\n"
        )
    )
    assert calls[0][calls[0].index("--title") + 1] == "second change"


# ---------------------------------- integrator: Live Gate and mutation baseline count as haro writers
def test_a_live_gate_run_during_a_job_is_noted_before_it_writes(monkeypatch, tmp_path):
    from types import SimpleNamespace

    from haro import gate

    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    store.assist_writes[ws.id] = set()  # an assist job is running
    seen: list[bool] = []
    monkeypatch.setattr(
        gate, "load_project_settings",
        lambda _p: SimpleNamespace(gate_watch=True, gate_dir=None),
    )
    monkeypatch.setattr(gate, "ensure_deps", lambda *_a: seen.append(ws.id in store.assist_internal))

    class _Adapter:
        name = "vitest"

        async def run(self, **_k):
            raise RuntimeError("stop here")

    _run(gate.run_watch(store=store, hub=hub, adapter=_Adapter(), workspace=ws, project_path=str(repo)))
    assert seen == [True]


def test_an_unchecked_ask_stays_unverified_after_it_ages_out(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path)
    ws.research_log.unverified = True
    ws.research_log.count = 25
    ws.research_log.entries = []
    settings = load_project_settings(str(repo))
    r = _run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings))
    assert r.research is not None and r.research.unverified is True
    assert "AI edits: unverified" in receipt_svc.render_markdown(r)


def test_get_assist_returns_the_text_and_blocked_calls_so_far_then_the_result(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    hold = asyncio.Event()
    _stub_claude(
        monkeypatch, PLAN_REPLY, hold=hold,
        events=[
            NormalizedEvent("file_edit", {"tool": "Write", "path": "x.txt"}),
            NormalizedEvent("token", {"text": "Reading the repo. "}),
        ],
    )

    async def scenario():
        assert await main.get_assist_job(ws.id) is None
        started = await main.assist_plan(ws.id, AssistPlanRequest(prompt="x"))
        for _ in range(500):
            await asyncio.sleep(0.01)
            if store.assist_jobs[ws.id].text:
                break
        mid = await main.get_assist_job(ws.id)
        assert mid.id == started.id and mid.status == "running"
        assert mid.text == "Reading the repo. " and mid.blocked_calls == ["Write"]
        assert mid.plan_id is None
        hold.set()
        await _finish(store, ws)
        return await main.get_assist_job(ws.id)

    done = _run(scenario())
    assert done.status == "done" and done.plan_id == ws.plans[0].id
    assert done.blocked_calls == ["Write"]
    with pytest.raises(HTTPException) as e:
        _run(main.get_assist_job("nope"))
    assert e.value.status_code == 404


# ------------------------------------------- one-box Search: git lookups folded into `ask`
def _reply(*sources, answer="Look there."):
    import json

    return json.dumps({"answer": answer, "sources": list(sources)})


def _src(kind, target, title="t", why="w"):
    return {"kind": kind, "title": title, "target": target, "why": why}


def test_identifier_extraction_picks_code_names_and_ignores_prose():
    ex = research.extract_identifiers
    assert ex("where is the rate limit computed") == []
    assert ex("who calls `handleRetry` and \"max_attempts\"") == ["handleRetry", "max_attempts"]
    assert ex("look at src/a.ts:12 and getUserName") == ["src/a.ts:12", "getUserName"]
    assert ex("why does RateLimiter use retry_count and config.max.size?") == [
        "RateLimiter", "retry_count", "config.max.size",
    ]
    assert ex("it's what isn't there, e.g. this") == []
    assert ex("`useThing` `useThing` useThing") == ["useThing"]
    assert ex("a `ab` b") == []
    assert len(ex("fooBar bazQux quuxCorge graultWaldo")) == 3
    assert ex("blame `src/x.py:9`") == ["src/x.py:9"]


def test_an_ask_merges_git_hits_for_its_identifiers_as_git_rows(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(monkeypatch, _reply(_src("repo", "f.txt:1", "the file")))
    _ask(store, ws, "who touched `needle` and f.txt:1")
    done = _channel(hub, ws, "done")[0]
    rows = done["rows"]
    assert [r["source"] for r in rows] == ["repo", "git", "git"]
    hit = next(r for r in rows if r["source"] == "git" and "blame" not in r["title"])
    assert hit["action"] == "jump" and "add needle handling" in hit["title"]
    blame = next(r for r in rows if "blame" in r["title"])
    assert blame["target"] == "f.txt:1"
    e = ws.research_log.entries[-1]
    assert [r.source for r in e.rows] == ["repo", "git", "git"]
    assert [r.source for r in store.assist_jobs[ws.id].rows] == ["repo", "git", "git"]


def test_a_question_without_identifiers_runs_no_git_lookup(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")

    async def boom(*a, **k):
        pytest.fail("no lookup")

    monkeypatch.setattr(research, "research_git", boom)
    _stub_claude(monkeypatch, ASK_REPLY)
    _ask(store, ws, "where is needle")
    assert [r["source"] for r in _channel(hub, ws, "done")[0]["rows"]] == ["repo"]
    assert ws.git_search_before_green is False


def test_a_git_hit_the_model_already_listed_is_not_repeated(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    sha = _git(repo, "rev-parse", "HEAD")
    _stub_claude(monkeypatch, _reply(_src("git", sha, "the commit")))
    _ask(store, ws, "who added `needle`")
    rows = _channel(hub, ws, "done")[0]["rows"]
    assert [(r["source"], r["title"]) for r in rows] == [("git", "the commit")]

    _stub_claude(monkeypatch, _reply(_src("git", sha[:9], "short sha")))
    _ask(store, ws, "who added `needle` again")
    rows = _channel(hub, ws, "done")[-1]["rows"]
    assert [r["title"] for r in rows] == ["short sha"]


def test_git_hits_never_push_the_rows_past_eight(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    for i in range(6):
        (repo / "g.txt").write_text(f"other {i}\n")
        _git(repo, "commit", "-qam", f"tweak needle {i}")
    six = [_src("repo", "f.txt:1", f"r{i}") for i in range(6)]
    _stub_claude(monkeypatch, _reply(*six))
    _ask(store, ws, "history of `needle`")
    rows = _channel(hub, ws, "done")[0]["rows"]
    assert len(rows) == 8 and [r["source"] for r in rows] == ["repo"] * 6 + ["git"] * 2

    _stub_claude(monkeypatch, _reply(_src("repo", "f.txt:1", "only one")))
    _ask(store, ws, "history of `needle`")
    rows = _channel(hub, ws, "done")[-1]["rows"]
    assert len(rows) == 8 and rows[0]["source"] == "repo" and {r["source"] for r in rows[1:]} == {"git"}


def test_git_hits_spread_across_identifiers_round_robin(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    for i in range(4):
        (repo / "g.txt").write_text(f"alpha_one {i}\n")
        _git(repo, "commit", "-qam", f"alpha_one change {i}")
    (repo / "g.txt").write_text("beta_two\n")
    _git(repo, "commit", "-qam", "beta_two lands")
    hits = _run(research.merge_git_hits(str(repo), "`alpha_one` and `beta_two`", [], cap=3))
    titles = [h.title for h in hits]
    assert len(titles) == 3
    assert any("beta_two" in t for t in titles) and any("alpha_one" in t for t in titles)


def test_blame_for_a_path_that_does_not_exist_is_skipped(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    assert _run(research.merge_git_hits(str(repo), "nope/ghost.py:3", [])) == []


def test_an_ask_that_returned_git_rows_sets_the_regression_hunter_fact(monkeypatch, tmp_path):
    import dataclasses

    from haro import xp, xp_hooks

    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(monkeypatch, _reply(_src("repo", "f.txt:1")))
    _ask(store, ws, "who touched `needle`")
    assert ws.git_search_before_green is True
    facts = xp_hooks.merge_facts(store, ws, ["f.txt"], at=1.0)
    assert facts.regression_search is True
    got = xp.award_for(dataclasses.replace(facts, green=True), [])
    assert "regression_hunter" in [a.kind for a in got]


def test_a_model_git_source_alone_does_not_set_the_fact(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    sha = _git(repo, "rev-parse", "HEAD")
    _stub_claude(monkeypatch, _reply(_src("git", sha)))
    _ask(store, ws, "who added it")
    assert [r["source"] for r in _channel(hub, ws, "done")[0]["rows"]] == ["git"]
    assert ws.git_search_before_green is False


def test_the_fact_needs_a_row_haro_itself_added(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    sha = _git(repo, "rev-parse", "HEAD")
    _stub_claude(monkeypatch, _reply(_src("git", sha)))
    _ask(store, ws, "who added `needle`")
    rows = _channel(hub, ws, "done")[0]["rows"]
    assert len(rows) == 1, "haro's only hit is the commit the model already listed"
    assert ws.git_search_before_green is False

    _stub_claude(monkeypatch, _reply(_src("repo", "f.txt:1")))
    _ask(store, ws, "who added `needle`")
    assert ws.git_search_before_green is True


@pytest.mark.parametrize("target", ["", "HEAD", "the commit that added it", "  ", "zzzzzzz"])
def test_a_junk_model_git_target_does_not_hide_haros_hits(monkeypatch, tmp_path, target):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(monkeypatch, _reply(_src("git", target, "the commit"), _src("repo", "f.txt:1", "file")))
    _ask(store, ws, "who added `needle`")
    done = _channel(hub, ws, "done")[0]
    assert [r["source"] for r in done["rows"]] == ["repo", "git"]
    assert "add needle handling" in done["rows"][1]["title"]
    assert ws.git_search_before_green is True


def test_merge_ignores_non_hex_model_shas(monkeypatch, tmp_path):
    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    rows = _run(research.merge_git_hits(str(repo), "`needle`", [], {"", "head", "nothex!"}))
    assert [r.source for r in rows] == ["git"]


# ------------------------------------------- git lookup resource use: slow git is killed
def _fake_bin(tmp_path, name, body):
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir(exist_ok=True)
    script = bin_dir / name
    script.write_text("#!/bin/sh\n" + body)
    script.chmod(0o755)
    return bin_dir


def _alive(pid):
    import os

    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def _slow_git(monkeypatch, tmp_path):
    pidfile = tmp_path / "pids"
    bin_dir = _fake_bin(tmp_path, "git", f'echo $$ >> "{pidfile}"\nexec sleep 30\n')
    monkeypatch.setenv("PATH", f"{bin_dir}:" + __import__("os").environ["PATH"])
    return pidfile


def _pids(pidfile):
    return [int(x) for x in pidfile.read_text().split()] if pidfile.exists() else []


def test_a_slow_git_call_is_killed_at_its_timeout_and_frees_the_lock(monkeypatch, tmp_path):
    import time

    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    pidfile = _slow_git(monkeypatch, tmp_path)
    # Long enough that the fake git has always recorded its pid before the kill.
    monkeypatch.setattr(research, "GIT_CALL_TIMEOUT", 1.0)
    t0 = time.monotonic()
    rows, note = _run(research.research_git(str(repo), "needle"))
    assert time.monotonic() - t0 < 5
    assert rows == [] and "timed out" in note
    pids = _pids(pidfile)
    assert len(pids) == 1 and not _alive(pids[0])
    from haro import git_ops

    assert not git_ops._lock_for(str(repo)).locked()


def test_the_overall_lookup_budget_kills_what_is_still_running(monkeypatch, tmp_path):
    import time

    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    pidfile = _slow_git(monkeypatch, tmp_path)
    monkeypatch.setattr(research, "GIT_LOOKUP_TIMEOUT", 0.4)
    monkeypatch.setattr(research, "GIT_CALL_TIMEOUT", 30)
    t0 = time.monotonic()
    base = [research.ResearchRow(source="repo", title="r", target="f.txt", action="jump")]
    out = _run(research.merge_git_hits(str(repo), "`needle` and `haystack`", base))
    assert time.monotonic() - t0 < 5
    assert out == base
    time.sleep(0.2)
    pids = _pids(pidfile)
    assert pids and not any(_alive(p) for p in pids)
    from haro import git_ops

    assert not git_ops._lock_for(str(repo)).locked()


# ------------------------------------------------ man pages cited by the model
def test_the_ask_prompt_allows_man_sources():
    assert "man:<page>" in assist.ASK_SYSTEM and "man" in assist.ASK_SYSTEM.split("kind")[1][:40]


def test_man_exists_uses_man_w(monkeypatch, tmp_path):
    bin_dir = _fake_bin(
        tmp_path, "man",
        'for a; do last=$a; done\n[ "$1" = "-w" ] || exit 2\n'
        '[ "$last" = "ls" ] && { echo /usr/share/man/man1/ls.1; exit 0; }\nexit 1\n',
    )
    monkeypatch.setenv("PATH", f"{bin_dir}:" + __import__("os").environ["PATH"])
    assert _run(research.man_exists("ls")) is True
    assert _run(research.man_exists("ls(1)")) is True
    assert _run(research.man_exists("nopage")) is False
    assert _run(research.man_exists("-k")) is False
    assert _run(research.man_exists("")) is False


def test_a_cited_man_page_that_exists_is_a_read_row_and_a_missing_one_is_dropped(
    monkeypatch, tmp_path
):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")

    async def exists(page):
        return page in ("ls(1)", "grep")

    monkeypatch.setattr(research, "man_exists", exists)
    _stub_claude(
        monkeypatch,
        _reply(
            _src("man", "man:ls(1)", "ls"),
            _src("doc", "man:grep", "grep"),
            _src("man", "nopage(1)", "ghost"),
            _src("doc", "man:ghost", "ghost 2"),
        ),
    )
    _ask(store, ws, "how do I list files")
    done = _channel(hub, ws, "done")[0]
    assert [(r["source"], r["action"], r["target"]) for r in done["rows"]] == [
        ("man", "read", "ls(1)"),
        ("man", "read", "grep"),
    ]
    assert "2 source(s) dropped" in done["note"]


def test_the_fact_is_not_set_after_a_green_gate(monkeypatch, tmp_path):
    from haro.models import TestRun, TestRunStatus

    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    store.add_test(TestRun(workspace_id=ws.id, runner="vitest", status=TestRunStatus.passed))
    _stub_claude(monkeypatch, _reply(_src("repo", "f.txt:1")))
    _ask(store, ws, "who touched `needle`")
    assert ws.git_search_before_green is False


def test_scope_defaults_to_ask(monkeypatch, tmp_path):
    assert AssistResearchRequest(query="x").scope == "ask"
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(monkeypatch, ASK_REPLY)

    async def go():
        out = await main.assist_research(ws.id, AssistResearchRequest(query="where is needle"))
        assert out.scope == "ask" and out.job_id
        await _finish(store, ws)

    _run(go())
    assert ws.research_log.entries[-1].scope == "ask"


def test_an_overlong_source_target_is_dropped_not_truncated(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    long_url = "https://example.com/" + "a" * assist.MAX_TARGET_LEN
    ok_url = "https://example.com/" + "a" * (assist.MAX_TARGET_LEN - 20)
    _stub_claude(
        monkeypatch,
        _reply(_src("web", long_url, "too long"), _src("doc", ok_url, "fine")),
    )
    _ask(store, ws, "docs")
    done = _channel(hub, ws, "done")[0]
    assert [r["title"] for r in done["rows"]] == ["fine"]
    assert all(len(r["target"]) <= assist.MAX_TARGET_LEN for r in done["rows"])
    assert "1 source(s) dropped" in done["note"]


def test_blocked_calls_are_deduplicated_in_order(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    evs = [
        NormalizedEvent("file_edit", {"tool": "Write", "path": "a"}),
        NormalizedEvent("tool_call", {"tool": "Bash"}),
        NormalizedEvent("file_edit", {"tool": "Write", "path": "b"}),
        NormalizedEvent("tool_call", {"tool": "Bash"}),
        NormalizedEvent("file_edit", {"tool": "Write", "path": "c"}),
    ]
    _stub_claude(monkeypatch, ASK_REPLY, events=evs)
    _ask(store, ws, "q")
    assert ws.research_log.entries[-1].blocked_calls == ["Write", "Bash"]
    job = store.assist_jobs[ws.id]
    assert job.blocked_calls == ["Write", "Bash"]
    assert [m["tool"] for m in _channel(hub, ws, "blocked")] == ["Write", "Bash"]
    assert _channel(hub, ws, "done")[0]["blocked_calls"] == ["Write", "Bash"]


def test_the_same_question_and_answer_as_the_newest_entry_is_stored_once(monkeypatch, tmp_path):
    store, hub, ws, _ = _wire(monkeypatch, tmp_path, mode="manual")
    _stub_claude(monkeypatch, ASK_REPLY)
    _ask(store, ws, "where is needle")
    _ask(store, ws, "where is needle")
    asks = [e for e in ws.research_log.entries if e.scope == "ask"]
    assert [bool(e.answer) for e in asks] == [True, False]
    assert ws.research_log.count == 2
    assert store.assist_jobs[ws.id].answer == "It lives in f.txt."
    assert len(_channel(hub, ws, "done")) == 2

    _stub_claude(monkeypatch, _reply(_src("repo", "f.txt:1"), answer="A different answer."))
    _ask(store, ws, "where is needle")
    asks = [e for e in ws.research_log.entries if e.scope == "ask"]
    assert [bool(e.answer) for e in asks] == [True, False, True]


def test_a_timed_out_git_call_takes_its_child_processes_with_it(monkeypatch, tmp_path):
    import time

    store, hub, ws, repo = _wire(monkeypatch, tmp_path, mode="manual")
    pidfile = tmp_path / "child-pids"
    # git that spawns a child (like a textconv driver) and waits on it, instead of exec'ing
    bin_dir = _fake_bin(tmp_path, "git", f'sleep 30 &\necho $! >> "{pidfile}"\nwait\n')
    monkeypatch.setenv("PATH", f"{bin_dir}:" + __import__("os").environ["PATH"])
    monkeypatch.setattr(research, "GIT_CALL_TIMEOUT", 1.0)
    rows, note = _run(research.research_git(str(repo), "needle"))
    assert rows == [] and "timed out" in note
    time.sleep(0.2)
    pids = _pids(pidfile)
    assert pids and not any(_alive(p) for p in pids)
