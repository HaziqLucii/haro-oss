"""The sandbox degradation wiring in gate.py (usp-critique-round3.md Move D,
step 1): `[gate] sandbox = true` requested but not achieved must degrade —
same §0 rule test_degraded_gate.py exercises for coverage/tamper — never a
silent green claiming to be offline when it wasn't."""

from __future__ import annotations

import asyncio

from haro.adapters.test_runner.base import TestResult as RunResult
from haro.adapters.test_runner.base import TestRunnerAdapter
from haro.gate import run_gate
from haro.hub import Hub
from haro.models import Project, Workspace
from haro.models import TestRunStatus as RunStatus
from haro.store import Store


class _Adapter(TestRunnerAdapter):
    def __init__(self, name: str, result: RunResult):
        self.name = name
        self._result = result

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        return self._result


def _setup(tmp_path, toml: str):
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path=str(tmp_path), base_ref="main")
    store.workspaces[ws.id] = ws
    haro = tmp_path / ".haro"
    haro.mkdir(exist_ok=True)
    haro.joinpath("settings.toml").write_text(toml)
    return store, hub, ws, project


def test_sandbox_requested_but_not_achieved_degrades_a_vitest_run(tmp_path):
    store, hub, ws, project = _setup(tmp_path, "[gate]\nsandbox = true\nverified_hunks = false\n\n[workflow]\ntamper_alarm = 'off'\ncode_to_check = 'off'\n")
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[], sandboxed=False, sandbox_profile=None)

    asyncio.run(run_gate(
        store=store, hub=hub, adapter=_Adapter("vitest", result), workspace=ws, project_path=str(tmp_path),
    ))

    run = store.latest_test(ws.id)
    assert run.status == RunStatus.passed
    assert run.degraded_reasons
    assert "bwrap" in run.degraded_reasons[0]
    assert run.sandbox_profile is None
    assert ws.gate.degraded is True


def test_sandbox_requested_but_unsupported_runner_names_the_runner(tmp_path):
    store, hub, ws, project = _setup(tmp_path, "[gate]\nsandbox = true\nrunner = 'command'\ncommand = 'true'\n")
    result = RunResult(ok=True, total=0, passed=0, failed=0, cases=[])  # CommandAdapter never sets sandboxed

    asyncio.run(run_gate(
        store=store, hub=hub, adapter=_Adapter("command", result), workspace=ws, project_path=str(tmp_path),
    ))

    run = store.latest_test(ws.id)
    assert run.degraded_reasons
    assert "command" in run.degraded_reasons[0]


def test_sandbox_achieved_does_not_degrade_and_stamps_the_profile(tmp_path):
    store, hub, ws, project = _setup(tmp_path, "[gate]\nsandbox = true\nverified_hunks = false\n\n[workflow]\ntamper_alarm = 'off'\ncode_to_check = 'off'\n")
    result = RunResult(
        ok=True, total=1, passed=1, failed=0, cases=[],
        sandboxed=True, sandbox_profile="deadbeefdeadbeef",
    )

    asyncio.run(run_gate(
        store=store, hub=hub, adapter=_Adapter("vitest", result), workspace=ws, project_path=str(tmp_path),
    ))

    run = store.latest_test(ws.id)
    assert run.degraded_reasons == []
    assert run.sandbox_profile == "deadbeefdeadbeef"
    assert ws.gate.degraded is False


def test_sandbox_off_by_default_never_degrades_an_unsandboxed_run(tmp_path):
    # `sandbox` defaults to False (not set here at all) — everything else disabled
    # just to isolate the sandbox-specific assertion from unrelated diff-read noise
    # (tmp_path isn't a real git repo).
    store, hub, ws, project = _setup(tmp_path, "[gate]\nverified_hunks = false\n\n[workflow]\ntamper_alarm = 'off'\ncode_to_check = 'off'\n")
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])

    asyncio.run(run_gate(
        store=store, hub=hub, adapter=_Adapter("vitest", result), workspace=ws, project_path=str(tmp_path),
    ))

    run = store.latest_test(ws.id)
    assert run.degraded_reasons == []
    assert run.sandbox_profile is None
