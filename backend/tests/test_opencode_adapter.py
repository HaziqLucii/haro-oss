"""OpenCodeAdapter: the stream of ``opencode run --format json`` as haro's five event types, the
command it spawns, and the adapter's wiring (settings, route guards). The events below are the
shapes captured from opencode 1.18.26; the process is a scripted fake."""

from __future__ import annotations

import asyncio
import json
import tempfile
from pathlib import Path

import pytest
from fastapi import HTTPException

from haro import config, main
from haro.adapters import opencode as oc
from haro.adapters.opencode import OpenCodeAdapter
from haro.hub import Hub
from haro.models import AgentConfig, Project, StartAgentRequest, Workspace
from haro.store import Store

SID = "ses_test"


def ev(kind: str, **part) -> dict:
    return {"type": kind, "sessionID": SID, "part": part}


def step_finish(total_in=100, out=10, read=900, write=0, cost=0.0, reason="stop") -> dict:
    return ev("step_finish", reason=reason, tokens={"input": total_in, "output": out, "cache": {"read": read, "write": write}}, cost=cost)


UNIFIED = (
    "Index: /w/f.txt\n===================================================================\n"
    "--- /w/f.txt\n+++ /w/f.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"
)

EDIT_RUN = [
    ev("step_start"),
    ev("tool_use", tool="read", state={"status": "completed", "input": {"filePath": "/w/f.txt"}}),
    step_finish(reason="tool-calls", cost=0.002),
    ev("step_start"),
    ev(
        "tool_use", tool="edit",
        state={"status": "completed", "input": {"filePath": "/w/f.txt", "oldString": "two", "newString": "TWO"}, "metadata": {"diff": UNIFIED}},
    ),
    ev("tool_use", tool="bash", state={"status": "completed", "input": {"command": "cat f.txt"}}),
    step_finish(reason="tool-calls", cost=0.003),
    ev("step_start"),
    ev("text", text="ok"),
    step_finish(cost=0.001),
]


class _Out:
    def __init__(self, lines):
        self._lines = lines

    def __aiter__(self):
        return self._gen()

    async def _gen(self):
        for line in self._lines:
            raw = line if isinstance(line, bytes) else (json.dumps(line) if isinstance(line, dict) else line).encode()
            yield raw + b"\n"


class _Err:
    def __init__(self, data: bytes):
        self._data = data

    async def read(self):
        return self._data


class _Proc:
    def __init__(self, lines, code=0, stderr=b""):
        self.stdout, self.stderr = _Out(lines), _Err(stderr)
        self._code, self.returncode, self.pid = code, None, 2**22 + 7

    async def wait(self):
        self.returncode = self._code
        return self._code

    async def communicate(self):
        """For the short `models` / `export` calls: the lines are the whole stdout."""
        self.returncode = self._code
        def raw(line):
            if isinstance(line, bytes):
                return line
            return (json.dumps(line) if isinstance(line, dict) else line).encode()

        body = b"".join(raw(l) + b"\n" for l in self.stdout._lines)
        return body, self.stderr._data


@pytest.fixture
def spawned(monkeypatch):
    """Patches the spawn; `.cmd` / `.kw` hold what it was called with, `.proc` is set per test."""
    box = type("Box", (), {})()
    box.cmd, box.kw, box.proc = None, None, _Proc(EDIT_RUN)
    box.export = _Proc([{"messages": []}])  # what `opencode export` answers; a test sets the model
    box.exports = []

    async def fake_exec(*cmd, **kw):
        if len(cmd) > 1 and cmd[1] == "export":
            box.exports.append(list(cmd))
            return box.export
        box.cmd, box.kw = list(cmd), kw
        return box.proc

    monkeypatch.setattr(oc.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(oc, "find_opencode", lambda: "/bin/opencode")
    return box


def run(**kw):
    async def go():
        out = []
        async for e in OpenCodeAdapter().run(task="do it", cwd="/w", **kw):
            out.append(e)
        return out

    return asyncio.run(go())


def test_an_edit_run_becomes_haros_events(spawned):
    events = run(model="deepseek/deepseek-v4-flash")
    kinds = [e.type for e in events]
    assert kinds == ["token", "tool_call", "file_edit", "tool_call", "token", "done"]
    banner = events[0].payload
    assert banner["system"] and banner["session_id"] == SID and "deepseek/deepseek-v4-flash" in banner["text"]
    assert events[1].payload == {"tool": "Read", "summary": "f.txt"}
    edit = events[2].payload
    assert (edit["tool"], edit["path"], edit["added"], edit["removed"]) == ("Edit", "f.txt", 1, 1)
    assert edit["diff"] == [{"sign": "-", "text": "two"}, {"sign": "+", "text": "TWO"}]
    assert events[3].payload == {"tool": "Bash", "summary": "cat f.txt"}
    assert events[4].payload == {"text": "ok"}
    done = events[5].payload
    assert done["session_id"] == SID
    assert (done["tokens_in"], done["tokens_out"]) == (300, 30)
    assert done["cost_usd"] == pytest.approx(0.006)
    assert done["context_tokens"] == 1000 and done["context_cached"] == 900, "the last step's window"


def test_exactly_one_terminal_event(spawned):
    assert sum(1 for e in run() if e.type in ("done", "error")) == 1


def test_a_write_has_no_diff_so_its_lines_come_from_the_input(spawned):
    spawned.proc = _Proc([
        ev("step_start"),
        ev("tool_use", tool="write", state={"status": "completed", "input": {"filePath": "/w/a/new.txt", "content": "x\ny\n"}, "metadata": {}}),
        step_finish(),
    ])
    edit = [e for e in run() if e.type == "file_edit"][0].payload
    assert (edit["tool"], edit["path"], edit["added"], edit["removed"]) == ("Write", "a/new.txt", 2, 0)


def test_a_failed_tool_is_a_row_that_says_so_not_an_edit(spawned):
    spawned.proc = _Proc([
        ev("step_start"),
        ev("tool_use", tool="edit", state={"status": "error", "input": {"filePath": "/w/f.txt"}, "error": "oldString not found"}),
        step_finish(),
    ])
    events = run()
    assert "file_edit" not in [e.type for e in events]
    row = [e for e in events if e.type == "tool_call"][0].payload
    assert row["tool"] == "Edit" and "failed: oldString not found" in row["summary"]


def test_the_command_closes_stdin_and_carries_model_resume_plan_and_instructions(spawned):
    run(model="deepseek/deepseek-v4-flash", resume="ses_old", plan=True, instructions="Be brief.")
    cmd = spawned.cmd
    assert cmd[:4] == ["/bin/opencode", "run", "--format", "json"]
    assert cmd[cmd.index("-m") + 1] == "deepseek/deepseek-v4-flash"
    assert cmd[cmd.index("-s") + 1] == "ses_old"
    assert cmd[cmd.index("--agent") + 1] == "plan"
    assert "--auto" in cmd
    sep = cmd.index("--")
    assert cmd[sep + 1].startswith("Project instructions") and "Be brief." in cmd[sep + 1] and cmd[sep + 1].endswith("do it")
    assert spawned.kw["stdin"] == asyncio.subprocess.DEVNULL, "an open stdin makes `opencode run` wait forever"
    assert spawned.kw["cwd"] == "/w" and spawned.kw["start_new_session"] is True


def test_the_run_is_pinned_to_the_worktree_by_dir_and_pwd(spawned, monkeypatch):
    """OpenCode takes its directory from $PWD, not the real cwd: from a backend whose PWD is `/` the
    agent worked in `/`. So `--dir` and PWD both name the worktree."""
    monkeypatch.setenv("PWD", "/")
    run()
    cmd = spawned.cmd
    assert cmd[cmd.index("--dir") + 1] == "/w"
    assert spawned.kw["env"]["PWD"] == "/w"


def test_with_no_model_chosen_the_real_one_is_looked_up_and_reported(spawned):
    spawned.export = _Proc([{"messages": [{"info": {"role": "user", "model": {"providerID": "deepseek", "modelID": "deepseek-v4-flash"}}}]}])
    events = run()
    banner = events[0].payload
    assert "opencode default" in banner["text"], "the banner cannot know yet"
    metas = [e.payload for e in events if e.type == "token" and e.payload.get("meta")]
    assert metas and metas[-1]["model"] == "deepseek/deepseek-v4-flash" and metas[-1]["system"] is True
    assert spawned.exports and spawned.exports[0][2] == SID
    assert events[-1].type == "done"


def test_a_model_that_was_chosen_is_not_looked_up(spawned):
    run(model="deepseek/deepseek-v4-flash")
    assert spawned.exports == []


def test_a_lookup_that_finds_nothing_leaves_the_banner_alone(spawned):
    events = run()
    assert not [e for e in events if e.type == "token" and e.payload.get("meta")]
    assert events[-1].type == "done"


def test_a_model_that_is_not_provider_slash_model_is_left_out(spawned):
    run(model="sonnet")
    assert "-m" not in spawned.cmd
    assert "--agent" not in spawned.cmd and "-s" not in spawned.cmd


def test_a_resumed_run_carries_the_label_without_the_banner(spawned):
    banner = run(resume="ses_old", model="a/b")[0].payload
    assert banner["meta"] is True and "text" not in banner


def test_an_error_event_is_the_one_terminal_error(spawned):
    spawned.proc = _Proc(
        [{"type": "error", "sessionID": SID, "error": {"name": "UnknownError", "data": {"message": "Unexpected server error."}}}],
        code=1,
    )
    events = run()
    assert [e.type for e in events] == ["error"]
    assert events[0].payload["message"] == "Unexpected server error." and events[0].payload["exit_code"] == 1


def test_a_failed_exit_without_events_reports_stderr(spawned):
    spawned.proc = _Proc([], code=2, stderr=b"config invalid at line 3")
    events = run()
    assert [e.type for e in events] == ["error"] and "config invalid" in events[0].payload["message"]


def test_the_budget_cap_ends_the_run(spawned, monkeypatch):
    ended: list[bool] = []

    async def fake_terminate(proc, **_):
        ended.append(True)

    monkeypatch.setattr(oc, "terminate_tree", fake_terminate)

    async def go():
        out = []
        async for e in OpenCodeAdapter().run(task="x", cwd="/w", max_budget_usd=0.004):
            out.append(e)
        return out

    events = asyncio.run(go())
    assert events[-1].type == "error" and "budget" in events[-1].payload["message"]
    assert ended, "the process tree was ended"


def test_missing_binary_says_how_to_install(monkeypatch):
    monkeypatch.setattr(oc, "find_opencode", lambda: None)
    events = run()
    assert [e.type for e in events] == ["error"] and "opencode.ai" in events[0].payload["message"]


def test_run_takes_what_it_enforces_itself_and_none_of_claudes_hook_params():
    import inspect

    params = inspect.signature(OpenCodeAdapter.run).parameters
    for taken in ("plan", "deny_edit_paths", "scope_paths", "guard_commands", "run_log_dir", "app_control", "browser_mcp", "gh_token", "agents"):
        assert taken in params, taken
    for absent in ("fence_hook_url", "hook_matcher", "exclude_user_claude_md"):
        assert absent not in params, "no hook to call: haro must not arm one for this adapter"


# -- haro's features handed to the run -------------------------------------------------


def test_the_fence_denies_everything_and_allows_its_paths_and_protected_tests_win_over_it():
    cfg = oc.inline_config(scope_paths=["src/**", "docs/"], deny_edit_paths=["src/a.test.ts"], guard_commands=False, browser_url=None)
    edit = cfg["permission"]["edit"]
    assert list(edit) == ["*", "src/*", "docs/*", "src/a.test.ts"], "order matters: the last matching rule wins"
    assert edit["*"] == "deny" and edit["src/*"] == "allow" and edit["src/a.test.ts"] == "deny"
    assert "bash" not in cfg["permission"] and "mcp" not in cfg


def test_no_fence_and_no_protection_leaves_edits_alone():
    assert oc.inline_config(scope_paths=None, deny_edit_paths=None, guard_commands=False, browser_url=None) == {}
    only = oc.inline_config(scope_paths=None, deny_edit_paths=["t/x.test.ts"], guard_commands=False, browser_url=None)
    assert only["permission"]["edit"] == {"t/x.test.ts": "deny"}


def test_paths_become_opencode_patterns():
    assert oc._edit_globs(["./src/**/*.ts", "/abs/start.md", "lib/", "plain", "file.py"]) == [
        "src/*/*.ts", "abs/start.md", "lib/*", "plain", "plain/*", "file.py",
    ]


def test_the_command_guard_denies_destructive_commands_and_secret_reads_but_not_the_examples():
    perm = oc.inline_config(scope_paths=None, deny_edit_paths=None, guard_commands=True, browser_url=None)["permission"]
    assert perm["bash"]["*"] == "allow" and perm["bash"]["git reset --hard*"] == "deny" and perm["bash"]["git push --force*"] == "deny"
    assert perm["read"]["*.env"] == "deny" and perm["read"]["*.pem"] == "deny"
    assert list(perm["read"]).index("*.env.example") > list(perm["read"]).index("*.env.*"), "the example file is let back in after"
    assert perm["read"]["*.env.example"] == "allow"


def test_the_shared_browser_is_a_remote_mcp_server_in_the_config():
    cfg = oc.inline_config(scope_paths=None, deny_edit_paths=None, guard_commands=False, browser_url="http://localhost:4003/mcp")
    assert cfg["mcp"]["haro_browser"] == {"type": "remote", "url": "http://localhost:4003/mcp", "enabled": True}


def test_haros_config_is_layered_over_one_the_user_already_set():
    merged = json.loads(oc._merge_config({"permission": {"edit": {"*": "deny"}}}, json.dumps({"permission": {"bash": {"*": "ask"}}, "theme": "x"})))
    assert merged["permission"] == {"bash": {"*": "ask"}, "edit": {"*": "deny"}} and merged["theme"] == "x"
    assert oc._merge_config({}, "keep") == "keep"
    assert json.loads(oc._merge_config({"mcp": {}}, "not json")) == {"mcp": {}}


def test_the_spawned_process_gets_the_haro_environment_and_config(spawned, monkeypatch):
    monkeypatch.delenv("OPENCODE_CONFIG_CONTENT", raising=False)
    run(
        scope_paths=["src/**"], deny_edit_paths=["src/t.test.ts"], guard_commands=True,
        run_log_dir="/logs/ws", app_control={"api": "http://127.0.0.1:41417", "workspace_id": "ws_1", "bin_dir": "/h/.haro/bin"},
        browser_mcp={"url": "http://localhost:4003/mcp"}, gh_token="tok_proj", instructions="Be brief.",
    )
    env = spawned.kw["env"]
    assert env["HARO_API"] == "http://127.0.0.1:41417" and env["HARO_WORKSPACE_ID"] == "ws_1"
    assert env["HARO_RUN_LOG"] == "/logs/ws/run.log" and env["HARO_LOG_DIR"] == "/logs/ws"
    assert env["PATH"].startswith("/h/.haro/bin:") and env["GH_TOKEN"] == "tok_proj" and env["PWD"] == "/w"
    cfg = json.loads(env["OPENCODE_CONFIG_CONTENT"])
    assert cfg["permission"]["edit"]["src/t.test.ts"] == "deny" and cfg["mcp"]["haro_browser"]["url"].endswith("/mcp")
    message = spawned.cmd[spawned.cmd.index("--") + 1]
    assert "/h/.haro/bin/haro-app" in message, "PATH does not survive OpenCode's shell: the full path is given"


def test_with_nothing_to_hand_over_no_config_is_set(spawned, monkeypatch):
    monkeypatch.delenv("OPENCODE_CONFIG_CONTENT", raising=False)
    run()
    assert "OPENCODE_CONFIG_CONTENT" not in spawned.kw["env"] and "GH_TOKEN" not in spawned.kw["env"]


def test_the_browser_note_speaks_opencodes_tool_names(spawned):
    run(browser_mcp={"url": "http://x/mcp"}, instructions="Use its tools (names start with `mcp__haro_browser__browser_`); the Playwright plugin's own tools are disabled for this run.")
    message = spawned.cmd[spawned.cmd.index("--") + 1]
    assert "haro_browser_browser_" in message and "mcp__haro_browser" not in message


def test_a_browser_call_keeps_claudes_tool_name_so_the_rails_badge_works(spawned):
    spawned.proc = _Proc([
        ev("step_start"),
        ev("tool_use", tool="haro_browser_browser_navigate", state={"status": "completed", "input": {"url": "https://x"}}),
        step_finish(),
    ])
    row = [e for e in run() if e.type == "tool_call"][0].payload
    assert row["tool"] == "mcp__haro_browser__browser_navigate"


# -- the runner hands over what to enforce ----------------------------------------------


class _Enforcing(OpenCodeAdapter):
    def __init__(self):
        super().__init__()
        self.kw: dict = {}

    async def run(self, *, task, cwd, scope_paths=None, guard_commands=False, deny_edit_paths=None, **_):
        from haro.adapters.base import NormalizedEvent

        self.kw = {"scope_paths": scope_paths, "guard_commands": guard_commands}
        yield NormalizedEvent("done", {})


def test_the_runner_gives_a_self_enforcing_adapter_the_fence_and_the_guard_switch(tmp_path):
    import subprocess

    from haro.models import AgentRun
    from haro.runner import run_agent

    # the fence snapshots the worktree, so it needs a real repository (it fails closed without one)
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "a.ts").write_text("a\n")
    for args in (["init", "-q", "-b", "main"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"]):
        subprocess.run(["git", *args], cwd=tmp_path, check=True, capture_output=True)
    store = Store()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(ws)
    adapter = _Enforcing()
    r = AgentRun(workspace_id=ws.id, adapter="opencode", task="t", scope=["src/**"])
    store.add_run(r)
    asyncio.run(run_agent(store=store, hub=Hub(), adapter=adapter, workspace=ws, run=r, auto_gate=False, command_guard=True))
    assert adapter.kw == {"scope_paths": ["src/**"], "guard_commands": True}


def test_without_a_fence_or_the_guard_it_is_handed_nothing(tmp_path):
    from haro.models import AgentRun
    from haro.runner import run_agent

    store = Store()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(ws)
    adapter = _Enforcing()
    r = AgentRun(workspace_id=ws.id, adapter="opencode", task="t")
    store.add_run(r)
    asyncio.run(run_agent(store=store, hub=Hub(), adapter=adapter, workspace=ws, run=r, auto_gate=False, command_guard=False))
    assert adapter.kw == {"scope_paths": None, "guard_commands": False}


# -- settings and routes ---------------------------------------------------------------


def _project_with(toml: str):
    store, hub = Store(), Hub()
    path = tempfile.mkdtemp(prefix="haro-proj-")
    (Path(path) / ".haro").mkdir()
    (Path(path) / ".haro" / "settings.toml").write_text(toml)
    project = Project(name="p", path=path, default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(project_id=project.id, name="w", branch="haro/w", worktree_path=tempfile.mkdtemp(prefix="haro-wt-"), base_ref="main")
    store.add_workspace(ws)
    return store, project, ws


def test_settings_read_and_round_trip_the_opencode_adapter():
    _, project, _ = _project_with('[agent]\nadapter = "opencode"\nopencode_model = "deepseek/deepseek-v4-flash"\n')
    s = config.load_project_settings(project.path)
    assert (s.agent_adapter, s.opencode_model) == ("opencode", "deepseek/deepseek-v4-flash")
    config.write_project_agent(
        project.path, default_model="sonnet", default_effort="", max_budget_usd=5.0, cost_warn_usd=20.0,
        agent_adapter="opencode", opencode_model="opencode/big-pickle",
    )
    again = config.load_project_settings(project.path)
    assert (again.agent_adapter, again.opencode_model) == ("opencode", "opencode/big-pickle")


def test_an_unknown_adapter_in_a_settings_file_reads_as_claude_code():
    assert config.agent_adapter_name("OpenCode ") == "opencode"
    assert config.agent_adapter_name("gpt-agent") == "claude-code"
    assert config.agent_adapter_name(None) == "claude-code"
    _, project, _ = _project_with('[agent]\nadapter = "gpt-agent"\n')
    assert config.load_project_settings(project.path).agent_adapter == "claude-code"


def test_the_api_model_accepts_opencode_and_rejects_the_rest():
    assert AgentConfig(adapter="opencode", opencode_model="a/b").opencode_model == "a/b"
    with pytest.raises(ValueError):
        AgentConfig(adapter="gpt-agent")


def test_start_agent_refuses_opencode_under_the_sandbox():
    async def go():
        store, _, ws = _project_with('[agent]\nadapter = "opencode"\nsandbox = true\n')
        main.store = store
        with pytest.raises(HTTPException) as e:
            await main.start_agent(ws.id, StartAgentRequest(task="x"))
        assert e.value.status_code == 400 and "sandbox" in e.value.detail and "opencode" in e.value.detail

    asyncio.run(go())


def test_start_agent_no_longer_falls_back_to_claude_for_an_unknown_adapter():
    async def go():
        store, _, ws = _project_with("")
        main.store = store
        with pytest.raises(HTTPException) as e:
            await main.start_agent(ws.id, StartAgentRequest(task="x", adapter="gpt-agent"))
        assert e.value.status_code == 400 and "unknown adapter" in e.value.detail

    asyncio.run(go())


def test_a_plan_request_on_the_local_adapter_is_refused_not_run_as_an_unfenced_edit():
    async def go():
        store, _, ws = _project_with('[agent]\nadapter = "local"\n')
        main.store = store
        with pytest.raises(HTTPException) as e:
            await main.start_agent(ws.id, StartAgentRequest(task="x", plan=True))
        assert e.value.status_code == 400 and "no plan mode" in e.value.detail

    asyncio.run(go())


# -- review fixes ----------------------------------------------------------------------


def test_stderr_escape_codes_are_stripped_from_the_error(spawned):
    spawned.proc = _Proc([], code=1, stderr=b"\x1b[91m\x1b[1mError: \x1b[0mSession not found")
    message = run()[0].payload["message"]
    assert message == "Error: Session not found" and "\x1b" not in message


def test_done_carries_the_last_steps_words_as_the_result_a_plan_is_kept_from(spawned):
    spawned.proc = _Proc([
        ev("step_start"),
        ev("text", text="Reading the code first."),
        ev("tool_use", tool="read", state={"status": "completed", "input": {"filePath": "/w/a.py"}}),
        step_finish(reason="tool-calls"),
        ev("step_start"),
        ev("text", text="1. Add the cache."),
        ev("text", text="2. Test it."),
        step_finish(),
    ])
    done = run(plan=True)[-1]
    assert done.type == "done" and done.payload["result"] == "1. Add the cache.\n\n2. Test it."


def test_a_final_step_with_no_words_keeps_the_previous_answer(spawned):
    spawned.proc = _Proc([
        ev("step_start"), ev("text", text="Done: fixed it."), step_finish(reason="tool-calls"),
        ev("step_start"), ev("tool_use", tool="bash", state={"status": "completed", "input": {"command": "ls"}}), step_finish(),
    ])
    assert run()[-1].payload["result"] == "Done: fixed it."


class _Recorder(OpenCodeAdapter):
    """Stands in for a backend in `run_agent`: records the resume id it is handed and issues one."""

    def __init__(self, name: str, issues: str | None = None):
        super().__init__()
        self.name = name
        self.seen: list = []
        self.issues = issues

    async def run(self, *, task, cwd, resume=None, **_):
        from haro.adapters.base import NormalizedEvent

        self.seen.append(resume)
        if self.issues:
            yield NormalizedEvent("token", {"text": "x", "system": True, "session_id": self.issues})
        yield NormalizedEvent("done", {"session_id": self.issues})


def _run_agent(ws, store, adapter):
    from haro.models import AgentRun
    from haro.runner import run_agent

    run_ = AgentRun(workspace_id=ws.id, adapter=adapter.name, task="t")
    store.add_run(run_)
    asyncio.run(run_agent(store=store, hub=Hub(), adapter=adapter, workspace=ws, run=run_, auto_gate=False))


def test_a_resume_id_is_only_handed_to_the_backend_that_issued_it(tmp_path):
    store = Store()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(ws)
    ws.session_resume = {"main": "claude-uuid"}  # an older workspace: no adapter recorded, so Claude's
    ws.last_session_id = "claude-uuid"

    opencode = _Recorder("opencode", issues="ses_abc")
    _run_agent(ws, store, opencode)
    assert opencode.seen == [None], "OpenCode must not be handed a Claude id"
    assert ws.session_resume["main"] == "ses_abc" and ws.session_resume_adapter["main"] == "opencode"

    again = _Recorder("opencode", issues="ses_abc")
    _run_agent(ws, store, again)
    assert again.seen == ["ses_abc"], "its own id continues"

    claude = _Recorder("claude-code")
    _run_agent(ws, store, claude)
    assert claude.seen == [None], "and Claude does not get OpenCode's id back"


def test_an_older_workspace_still_resumes_with_claude(tmp_path):
    store = Store()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(ws)
    ws.session_resume = {"main": "claude-uuid"}
    claude = _Recorder("claude-code")
    _run_agent(ws, store, claude)
    assert claude.seen == ["claude-uuid"]


def test_clearing_the_context_forgets_which_backend_wrote_the_id():
    store = Store()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path="/x", base_ref="main")
    store.add_workspace(ws)
    ws.session_resume, ws.session_resume_adapter = {"main": "ses_1"}, {"main": "opencode"}
    assert store.clear_context(ws.id) is True
    assert ws.session_resume == {} and ws.session_resume_adapter == {}


def test_a_personal_save_can_clear_the_opencode_model():
    _, project, _ = _project_with('[agent]\nopencode_model = "team/model"\n')
    config.write_project_agent(
        project.path, default_model="sonnet", default_effort="", max_budget_usd=5.0, cost_warn_usd=20.0,
        agent_adapter="opencode", opencode_model="", target="local",
    )
    assert config.load_project_settings(project.path).opencode_model == "", "the shared model must not come back"


# -- the model list for the Settings picker ----------------------------------------------


def test_list_models_reads_provider_slash_model_lines(monkeypatch):
    proc = _Proc([b"opencode/big-pickle", b"\x1b[0mdeepseek/deepseek-v4-flash", b"not a model line", b"opencode/big-pickle"])

    async def fake_exec(*cmd, **kw):
        assert cmd[1] == "models" and kw["stdin"] == asyncio.subprocess.DEVNULL
        return proc

    monkeypatch.setattr(oc.asyncio, "create_subprocess_exec", fake_exec)
    models, error = asyncio.run(oc.list_models("/w", binary="/bin/opencode"))
    assert (models, error) == (["opencode/big-pickle", "deepseek/deepseek-v4-flash"], None)


def test_list_models_says_why_it_cannot(monkeypatch):
    monkeypatch.setattr(oc, "find_opencode", lambda: None)
    models, error = asyncio.run(oc.list_models("/w"))
    assert models == [] and "opencode.ai" in error

    async def failing(*cmd, **kw):
        return _Proc([], code=1, stderr=b"\x1b[91mboom\x1b[0m")

    monkeypatch.setattr(oc.asyncio, "create_subprocess_exec", failing)
    models, error = asyncio.run(oc.list_models("/w", binary="/bin/opencode"))
    assert models == [] and error == "boom"


def test_the_models_route_answers_for_the_project(monkeypatch):
    async def fake_list(path):
        return ["a/b", "c/d"], None

    monkeypatch.setattr(main, "opencode_list_models", fake_list)
    store, project, _ = _project_with("")
    main.store = store
    out = asyncio.run(main.get_opencode_models(project.id))
    assert out.models == ["a/b", "c/d"] and out.available and out.error is None
    with pytest.raises(HTTPException) as e:
        asyncio.run(main.get_opencode_models("nope"))
    assert e.value.status_code == 404


# -- roles per phase on OpenCode ---------------------------------------------------------


def test_opencode_roles_round_trip_with_their_case_and_colons():
    _, project, _ = _project_with('[roles]\nenabled = true\n')
    config.write_project_roles(
        project.path, enabled=True,
        opencode_plan="Deepseek/V4-Pro", opencode_build="ollama/qwen2.5:7b", opencode_scout="opencode/big-pickle",
    )
    s = config.load_project_settings(project.path)
    assert s.roles_enabled
    assert (s.opencode_role_plan, s.opencode_role_build) == ("Deepseek/V4-Pro", "ollama/qwen2.5:7b"), "not lower-cased, colon kept"
    assert (s.opencode_role_review, s.opencode_role_scout) == ("", "opencode/big-pickle")


def test_the_roles_api_carries_the_opencode_models():
    _, project, _ = _project_with("")
    main.store = Store()
    main.store.projects[project.id] = project
    from haro.models import RolesUpdateRequest

    out = asyncio.run(main.set_project_roles(project.id, RolesUpdateRequest(enabled=True, opencode_plan="a/b", opencode_review="c/d")))
    assert (out.opencode_plan, out.opencode_review, out.opencode_build) == ("a/b", "c/d", "")
    assert asyncio.run(main.get_project_roles(project.id)).opencode_plan == "a/b"


def test_a_subagent_exists_only_for_a_step_with_a_model_and_stays_plain():
    from haro.roles import opencode_agents

    assert opencode_agents("", "") is None
    both = opencode_agents(" opencode/big-pickle ", "deepseek/deepseek-flash")
    assert set(both) == {"scout", "code-review"}
    assert both["scout"]["model"] == "opencode/big-pickle" and both["scout"]["mode"] == "subagent"
    assert set(both["scout"]) == {"description", "mode", "prompt", "model"}, "no permission/tools override: it broke delegation on the free tier"
    assert set(opencode_agents("a/b", "")) == {"scout"}


def test_the_agents_go_into_the_runs_config(spawned, monkeypatch):
    monkeypatch.delenv("OPENCODE_CONFIG_CONTENT", raising=False)
    run(agents={"scout": {"description": "d", "mode": "subagent", "prompt": "p", "model": "a/b"}})
    assert json.loads(spawned.kw["env"]["OPENCODE_CONFIG_CONTENT"])["agent"]["scout"]["model"] == "a/b"


class _Capture(OpenCodeAdapter):
    made: list = []

    def __init__(self, *, model: str = "", **kw):
        super().__init__(model=model, **kw)
        _Capture.made.append(model)

    async def run(self, **_):
        from haro.adapters.base import NormalizedEvent

        yield NormalizedEvent("done", {})


def _start(toml, **req):
    async def go():
        store, _, ws = _project_with(toml)
        main.store = store
        _Capture.made = []
        real = main.OpenCodeAdapter
        main.OpenCodeAdapter = _Capture
        try:
            try:
                await main.start_agent(ws.id, StartAgentRequest(task="x", **req))
            except HTTPException:
                pass
            for t in store.workspace_tasks(ws.id):
                t.cancel()
            await asyncio.gather(*store.workspace_tasks(ws.id), return_exceptions=True)
        finally:
            main.OpenCodeAdapter = real
        return list(_Capture.made)

    return asyncio.run(go())


ROLES = (
    '[agent]\nadapter = "opencode"\nopencode_model = "base/model"\n'
    '[roles]\nenabled = true\nopencode_plan = "p/plan"\nopencode_build = "b/build"\n'
)


def test_each_step_runs_on_its_own_model_when_roles_are_on():
    assert _start(ROLES, role="plan", plan=True) == ["p/plan"]
    assert _start(ROLES, role="build") == ["b/build"]


def test_a_pick_for_this_run_beats_the_role_and_an_empty_step_falls_back():
    assert _start(ROLES, role="build", model="x/pick") == ["x/pick"]
    assert _start(ROLES.replace('opencode_build = "b/build"\n', ""), role="build") == ["base/model"]


def test_with_roles_off_the_projects_model_is_used_for_every_step():
    assert _start(ROLES.replace("enabled = true", "enabled = false"), role="plan", plan=True) == ["base/model"]
