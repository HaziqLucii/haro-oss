"""Re-run failed only — the tight inner fix loop.

Two seams: the Vitest CLI arg builder (`only_args`) that narrows a run to just the
red tests, and `run_gate`'s handling of the ``only`` list (scope="failed", the list
forwarded to the adapter, and the flaky/coverage extra runs skipped on a partial
re-run).
"""

import asyncio

from haro import gate
from haro.adapters.test_runner.base import CaseResult
from haro.adapters.test_runner.base import TestResult as RunResult  # aliased: pytest tries to collect Test*
from haro.adapters.test_runner.vitest import only_args
from haro.models import Project, Workspace
from haro.store import Store


def test_only_args_files_are_deduped_and_sorted():
    args = only_args([("b.test.ts", "x"), ("a.test.ts", "y"), ("b.test.ts", "z")])
    assert args[:2] == ["a.test.ts", "b.test.ts"]  # unique + sorted files first
    assert args[2] == "-t"


def test_only_args_name_pattern_is_an_escaped_regex_or():
    args = only_args([("f.ts", "adds 1 + 1"), ("f.ts", "handles a.b")])
    pattern = args[args.index("-t") + 1]
    # regex-special chars in names are escaped so they match literally
    assert r"adds\ 1\ \+\ 1" in pattern or r"adds 1 \+ 1" in pattern
    assert r"a\.b" in pattern
    assert "|" in pattern  # OR of the two names


class _FakeHub:
    async def publish(self, *_a, **_k):
        pass


class _FakeAdapter:
    name = "vitest"

    def __init__(self, result: RunResult):
        self._result = result
        self.calls: list[dict] = []

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        self.calls.append({"changed_since": changed_since, "only": only})
        return self._result


def _run_gate(adapter, only):
    store = Store()
    project = Project(id="p", name="proj", path="", default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path="/tmp/wt", base_ref="main",
    )
    store.workspaces[ws.id] = ws
    return asyncio.run(
        gate.run_gate(
            store=store, hub=_FakeHub(), adapter=adapter, workspace=ws,
            project_path=project.path, only=only,
        )
    )


def test_run_gate_with_only_marks_scope_failed_and_forwards_the_list():
    only = [("a.test.ts", "was red")]
    adapter = _FakeAdapter(
        RunResult(ok=True, total=1, passed=1, cases=[CaseResult("a.test.ts", "was red", "passed")])
    )
    test = _run_gate(adapter, only)
    assert test.scope == "failed"
    assert adapter.calls[0]["only"] == only


def test_run_gate_all_scope_when_no_only():
    adapter = _FakeAdapter(RunResult(ok=True, total=1, passed=1))
    assert _run_gate(adapter, None).scope == "all"
