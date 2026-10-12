"""The pre-write half of the scope fence: the verdict the CLI's PreToolUse hook gets, the inline
settings JSON that wires it, and the opt-in that keeps the user's own CLAUDE.md out of a run."""

import asyncio
import json

import pytest

from haro import scope_fence
from haro.adapters import claude_code
from haro.config import load_project_settings


@pytest.fixture(autouse=True)
def _clean_registry():
    yield
    scope_fence._ARMED.clear()


def _arm(tmp_path, patterns):
    wt = tmp_path / "wt"
    wt.mkdir(exist_ok=True)
    armed = scope_fence.arm(scope_fence.Fence.build(patterns), str(wt))
    return wt, armed


def _edit(wt, rel, tool="Edit"):
    return {"tool_name": tool, "tool_input": {"file_path": str(wt / rel)}, "cwd": str(wt)}


def test_an_edit_inside_the_fence_is_allowed(tmp_path):
    wt, armed = _arm(tmp_path, ["src/**"])
    assert scope_fence.judge(armed.token, _edit(wt, "src/a.ts")) == {}
    assert armed.blocked == []


def test_an_edit_outside_is_denied_with_a_reason_and_remembered_once(tmp_path):
    wt, armed = _arm(tmp_path, ["src/**"])
    out = scope_fence.judge(armed.token, _edit(wt, "docs/b.md", tool="Write"))
    scope_fence.judge(armed.token, _edit(wt, "docs/b.md"))
    hook = out["hookSpecificOutput"]
    assert hook["permissionDecision"] == "deny" and hook["hookEventName"] == "PreToolUse"
    assert "`src/**`" in hook["permissionDecisionReason"] and "docs/b.md" in hook["permissionDecisionReason"]
    assert armed.blocked == ["docs/b.md"]


def test_notebook_edits_are_judged_by_their_notebook_path(tmp_path):
    wt, armed = _arm(tmp_path, ["src/**"])
    ev = {"tool_name": "NotebookEdit", "tool_input": {"notebook_path": str(wt / "n.ipynb")}}
    assert scope_fence.judge(armed.token, ev)["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_other_tools_paths_outside_the_worktree_and_unknown_runs_are_allowed(tmp_path):
    wt, armed = _arm(tmp_path, ["src/**"])
    assert scope_fence.judge(armed.token, {"tool_name": "Bash", "tool_input": {"command": "ls"}}) == {}
    assert scope_fence.judge(armed.token, {"tool_name": "Read", "tool_input": {"file_path": str(wt / "x")}}) == {}
    outside = {"tool_name": "Write", "tool_input": {"file_path": str(tmp_path / "elsewhere.txt")}}
    assert scope_fence.judge(armed.token, outside) == {}
    assert scope_fence.judge("nope", _edit(wt, "docs/b.md")) == {}
    assert armed.blocked == []


def test_a_disarmed_run_is_no_longer_judged(tmp_path):
    wt, armed = _arm(tmp_path, ["src/**"])
    scope_fence.disarm(armed)
    assert scope_fence.judge(armed.token, _edit(wt, "docs/b.md")) == {}


def test_settings_json_carries_the_http_hook_on_the_edit_tools():
    out = json.loads(claude_code._run_settings("http://127.0.0.1:9/hooks/fence/run_1", False))
    hook = out["hooks"]["PreToolUse"][0]
    assert hook["matcher"] == "Edit|Write|MultiEdit|NotebookEdit"
    assert hook["hooks"] == [{"type": "http", "url": "http://127.0.0.1:9/hooks/fence/run_1"}]
    assert "claudeMdExcludes" not in out


def test_settings_json_can_exclude_only_the_user_claude_md(monkeypatch):
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", "/home/x/.claude")
    out = json.loads(claude_code._run_settings(None, True))
    assert out == {"claudeMdExcludes": ["/home/x/.claude/CLAUDE.md"]}


def test_no_settings_json_when_there_is_nothing_to_add():
    assert claude_code._run_settings(None, False) is None


def test_the_user_claude_md_exclusion_is_off_unless_configured(tmp_path):
    (tmp_path / ".haro").mkdir()
    assert load_project_settings(str(tmp_path)).agent_ignore_user_claude_md is False
    (tmp_path / ".haro/settings.toml").write_text("[agent]\nignore_user_claude_md = true\n")
    assert load_project_settings(str(tmp_path)).agent_ignore_user_claude_md is True


def test_the_endpoint_answers_with_the_verdict(tmp_path):
    """The handler is called directly, as in the rest of the suite: a TestClient needs an extra
    package (httpx2) the install surface does not carry."""
    from haro.main import app, fence_hook

    assert any(
        getattr(r, "path", None) == "/hooks/fence/{token}" and "POST" in r.methods
        for r in app.routes
    )
    wt, armed = _arm(tmp_path, ["src/**"])
    ok = asyncio.run(fence_hook(armed.token, _edit(wt, "src/a.ts")))
    no = asyncio.run(fence_hook(armed.token, _edit(wt, "docs/b.md")))
    assert ok == {}
    assert no["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert armed.blocked == ["docs/b.md"]


def test_a_relative_path_is_judged_against_the_worktree(tmp_path):
    wt, armed = _arm(tmp_path, ["src/**"])
    ev = {"tool_name": "Edit", "tool_input": {"file_path": "docs/b.md"}}
    assert scope_fence.judge(armed.token, ev)["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert scope_fence.judge(armed.token, {"tool_name": "Edit", "tool_input": {"file_path": "src/a.ts"}}) == {}


def test_the_run_id_is_not_the_key_and_each_arming_has_its_own_token(tmp_path):
    wt, a = _arm(tmp_path, ["src/**"])
    _, b = _arm(tmp_path, ["src/**"])
    assert a.token != b.token and len(a.token) >= 16
    assert scope_fence.judge("run_1", _edit(wt, "docs/b.md")) == {}


def test_an_old_cli_gets_no_settings_json(monkeypatch):
    monkeypatch.setattr(claude_code, "_SNAPSHOT_FLAG", False)
    assert asyncio.run(claude_code._modern_cli()) is False
    monkeypatch.setattr(claude_code, "_SNAPSHOT_FLAG", True)
    assert asyncio.run(claude_code._modern_cli()) is True
