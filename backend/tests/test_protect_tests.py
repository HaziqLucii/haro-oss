"""Protected tests: deny rules on the agent's edit tools, honestly labelled.

The mechanism was verified against the real CLI (notes/claude-code-stream-json.md
section 12); these pin haro's side: pattern derivation, argv rendering, the
"blocked" stream row, config round-trip, and the receipt/gate labelling.
"""

import asyncio

from haro import protect_tests as pt
from haro import receipt as receipt_svc
from haro.adapters.claude_code import ClaudeCodeAdapter
from haro.config import load_project_settings, write_project_agent
from haro.models import AgentRun
from haro.runner import DEFAULT_SESSION  # noqa: F401  (import check: runner still loads)

from test_agents_flag import _capture_cmd
from test_receipt import _gate, _setup


import fnmatch
import re

_JS_ONLY = re.compile(r"(?:\.(?:test|spec)\.[cm]?[jt]sx?$)|(?:^|/)__tests__/").search
_PY_AWARE = re.compile(
    r"(?:\.(?:test|spec)\.[cm]?[jt]sx?$)|(?:^|/)__tests__/|(?:^|/)test_[^/]*\.py$|_test\.py$"
).search


def _is_js(p):
    return bool(_JS_ONLY(p))


def _is_py_aware(p):
    return bool(_PY_AWARE(p))


def _rule_matches(rule: str, path: str) -> bool:
    """Approximation of the CLI's gitignore-style match, enough to assert coverage."""
    if rule.startswith("/"):
        return path == rule[1:].replace("\\", "")
    if rule == "**/__tests__/**":
        return "/__tests__/" in f"/{path}"
    return fnmatch.fnmatchcase(path.rpartition("/")[2], rule.rpartition("/")[2])


def test_patterns_are_anchored_explicit_paths_for_existing_tests_only():
    got = pt.protected_patterns(
        ["src/a.ts", "src/a.test.ts", "web/__tests__/b.ts", "README.md"], is_test=_is_js
    )
    assert got == ["/src/a.test.ts", "/web/__tests__/b.ts"]


def test_root_test_is_anchored_so_a_new_nested_one_stays_writable():
    (rule,) = pt.protected_patterns(["a.test.ts"], is_test=_is_js)
    assert rule == "/a.test.ts"
    assert _rule_matches(rule, "a.test.ts")
    assert not _rule_matches(rule, "sub/a.test.ts")


def test_metacharacters_parens_and_leading_bang_are_escaped():
    assert pt.protected_patterns(["app/(g)/[id]/page.test.ts"], is_test=_is_js) == [
        r"/app/\(g\)/\[id\]/page.test.ts"
    ]
    assert pt.escape_glob("!n.test.ts") == r"\!n.test.ts"
    assert pt.protected_patterns(["!n.test.ts"], is_test=_is_js) == [r"/\!n.test.ts"]


def test_many_js_tests_collapse_to_filename_globs():
    files = [f"src/m{i}.test.ts" for i in range(pt.MAX_EXPLICIT_PATHS + 1)] + ["src/x/y.spec.tsx"]
    assert pt.protected_patterns(files, is_test=_is_js) == ["**/*.spec.tsx", "**/*.test.ts"]


def test_collapse_never_emits_a_directory_glob_and_never_matches_source():
    tests = [f"pkg/test_{i}.py" for i in range(pt.MAX_EXPLICIT_PATHS)] + ["pkg/util_test.py"]
    tests.append("pkg/odd.test.ts")
    src = ["pkg/__init__.py", "pkg/core.py", "pkg/helpers.py", "pkg/conftest.py"]
    for pred in (_is_py_aware, _is_js):
        rules = pt.protected_patterns(tests + src, is_test=pred, max_explicit=10)
        assert not any(r.rstrip("/").endswith("/**") and r != "**/__tests__/**" for r in rules)
        for s_ in src:
            assert not any(_rule_matches(r, s_) for r in rules), (pred, rules, s_)
        for t in tests:
            if pred(t):
                assert any(_rule_matches(r, t) for r in rules), (pred, t)
    py = pt.protected_patterns(tests + src, is_test=_is_py_aware, max_explicit=10)
    assert py == ["**/*.test.ts", "**/*_test.py", "**/test_*.py"]


def test_a_glob_that_would_hit_a_source_file_falls_back_to_explicit_paths():
    tests = ["a/test_x.py", "b/test_y.py", "c/test_z.py"]
    src = ["d/test_helper_data.py"]
    rules = pt.protected_patterns(tests + src, is_test=lambda p: p in tests, max_explicit=1)
    assert rules == ["/a/test_x.py", "/b/test_y.py", "/c/test_z.py"]


def test_runs_protected_needs_every_editing_run_protected():
    on = AgentRun(workspace_id="w", adapter="claude-code", protect_tests=True)
    off = AgentRun(workspace_id="w", adapter="claude-code")
    plan = AgentRun(workspace_id="w", adapter="claude-code", plan=True)
    assert pt.runs_protected([on, plan]) is True
    assert pt.runs_protected([on, off]) is False
    assert pt.runs_protected([plan]) is False
    assert pt.runs_protected([]) is False


def test_adapter_renders_one_deny_rule_per_tool_per_pattern():
    cmd = _capture_cmd(deny_edit_paths=["tests/x.py"])
    rules = cmd[cmd.index("--disallowedTools") + 1:]
    assert rules == [f"{t}(tests/x.py)" for t in ("Edit", "Write", "MultiEdit", "NotebookEdit")]
    assert "bypassPermissions" in cmd


def test_no_deny_flag_by_default():
    assert "--disallowedTools" not in _capture_cmd()


def _edit_then_denied(adapter, tool_id="t1", denied=True):
    adapter._normalize(
        {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": tool_id, "name": "Edit",
             "input": {"file_path": "/wt/tests/x.py", "old_string": "a", "new_string": "b"}}]}}
    )
    msg = ("<tool_use_error>File is in a directory that is denied by your permission "
           "settings.</tool_use_error>") if denied else "ok"
    return adapter._normalize(
        {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": tool_id, "is_error": denied, "content": msg}]}}
    )


def test_denied_edit_on_a_protected_run_surfaces_as_a_blocked_row():
    a = ClaudeCodeAdapter()
    a._protected, a._cwd = True, "/wt"
    (ev,) = _edit_then_denied(a)
    assert ev.type == "tool_call"
    assert ev.payload["blocked"] is True
    assert ev.payload["summary"] == "Edit blocked: tests are protected for this run (tests/x.py)"
    text = ev.payload["summary"].lower()
    assert "read-only" not in text and "cannot" not in text


def test_successful_edit_or_unprotected_run_emits_nothing():
    a = ClaudeCodeAdapter()
    a._protected, a._cwd = True, "/wt"
    assert [e.type for e in _edit_then_denied(a, denied=False)] == ["file_edit"]
    assert a._pending_edits == {}
    b = ClaudeCodeAdapter()
    assert _edit_then_denied(b) == []


def test_config_round_trip(tmp_path):
    write_project_agent(
        str(tmp_path), default_model="sonnet", default_effort="", max_budget_usd=5.0,
        cost_warn_usd=20.0, protect_tests="existing",
    )
    assert load_project_settings(str(tmp_path)).protect_tests == "existing"
    write_project_agent(
        str(tmp_path), default_model="sonnet", default_effort="", max_budget_usd=5.0,
        cost_warn_usd=20.0,
    )
    assert load_project_settings(str(tmp_path)).protect_tests == "off"


def test_protected_run_is_labelled_on_the_gate_and_receipt(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, monkeypatch, tamper_alarm="warn")
    store.add_run(AgentRun(workspace_id=ws.id, adapter="claude-code", protect_tests=True))
    _gate(store, hub, ws, project)
    assert store.latest_test(ws.id).tests_protected is True
    rcpt = asyncio.run(receipt_svc.build_receipt(
        store=store, workspace=ws, settings=load_project_settings(project.path)))
    assert rcpt.tamper.protected is True
    assert ("Existing tests were edit-protected for the agent "
            "(tamper alarm still checks the diff).") in receipt_svc.render_markdown(rcpt)


def test_unprotected_run_gets_no_protection_claim(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, monkeypatch, tamper_alarm="warn")
    store.add_run(AgentRun(workspace_id=ws.id, adapter="claude-code"))
    _gate(store, hub, ws, project)
    assert store.latest_test(ws.id).tests_protected is False
    rcpt = asyncio.run(receipt_svc.build_receipt(
        store=store, workspace=ws, settings=load_project_settings(project.path)))
    assert "edit-protected" not in receipt_svc.render_markdown(rcpt)


def _start(tmp_path, monkeypatch, *, settings_body="", req_protect=None, with_tests=True):
    import subprocess

    from haro import main
    from haro.hub import Hub
    from haro.models import Project, StartAgentRequest, Workspace
    from haro.store import Store

    repo = tmp_path / "repo"
    (repo / "tests").mkdir(parents=True)
    if with_tests:
        (repo / "tests" / "a.test.ts").write_text("x=1\n")
    else:
        (repo / "tests" / "keep.txt").write_text("x=1\n")
    (repo / "src.py").write_text("y=1\n")
    if settings_body:
        (repo / ".haro").mkdir()
        (repo / ".haro" / "settings.toml").write_text(settings_body)
    for cmd in (["init", "-q", "-b", "main"], ["add", "-A"],
                ["-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "i"]):
        subprocess.run(["git", *cmd], cwd=repo, check=True)

    store = Store()
    proj = Project(name="p", path=str(repo), default_branch="main")
    store.projects[proj.id] = proj
    ws = Workspace(project_id=proj.id, name="w", branch="b", worktree_path=str(repo), base_ref="main")
    store.add_workspace(ws)
    seen: dict = {}

    async def fake_run_agent(**kw):
        seen.update(kw)

    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr(main, "hub", Hub())
    monkeypatch.setattr(main, "run_agent", fake_run_agent)

    async def go():
        run = await main.start_agent(ws.id, StartAgentRequest(task="t", protect_tests=req_protect))
        await asyncio.gather(*store.workspace_tasks(ws.id), return_exceptions=True)
        return run

    return asyncio.run(go()), seen


def test_start_agent_protects_from_project_setting(tmp_path, monkeypatch):
    run, seen = _start(tmp_path, monkeypatch, settings_body='[agent]\nprotect_tests = "existing"\n')
    assert run.protect_tests is True
    assert seen["deny_edit_paths"] == ["/tests/a.test.ts"]


def test_per_run_toggle_overrides_the_setting(tmp_path, monkeypatch):
    on_run, _ = _start(tmp_path / "a", monkeypatch, req_protect=True)
    assert on_run.protect_tests is True
    off_run, seen = _start(
        tmp_path / "b", monkeypatch,
        settings_body='[agent]\nprotect_tests = "existing"\n', req_protect=False,
    )
    assert off_run.protect_tests is False
    assert seen["deny_edit_paths"] is None


def test_zero_tests_at_base_is_not_labelled_protected(tmp_path, monkeypatch):
    run, seen = _start(tmp_path, monkeypatch, req_protect=True, with_tests=False)
    assert run.protect_tests is False
    assert seen["deny_edit_paths"] is None


def test_refused_edit_never_shows_a_file_edit_row_but_a_landed_one_does():
    a = ClaudeCodeAdapter()
    a._protected, a._cwd = True, "/wt"
    use = {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t1", "name": "Edit",
         "input": {"file_path": "/wt/src/ok.py", "old_string": "a", "new_string": "b"}}]}}
    assert a._normalize(use) == []  # held until the result says whether it landed
    (ev,) = a._normalize({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "updated"}]}})
    assert ev.type == "file_edit"
    denied = _edit_then_denied(_prot())
    assert [e.type for e in denied] == ["tool_call"]


def test_unresolved_held_edit_is_flushed_at_stream_end():
    a = ClaudeCodeAdapter()
    a._protected = True
    a._normalize({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t9", "name": "Write",
         "input": {"file_path": "/wt/x.py", "content": "z"}}]}})
    assert [e.type for e in a._flush_held_edits()] == ["file_edit"]
    assert a._flush_held_edits() == []


def _prot():
    a = ClaudeCodeAdapter()
    a._protected, a._cwd = True, "/wt"
    return a
