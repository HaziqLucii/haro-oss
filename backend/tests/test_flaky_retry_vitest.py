"""Regression tests for the known-flaky retry against REAL vitest (skipped when the
sandbox repo's node_modules is absent). Each one is a false-green the mocked-adapter
tests could not see."""

from __future__ import annotations

import asyncio
import os
from pathlib import Path

import pytest

from haro.adapters.test_runner.vitest import VitestAdapter, only_args
from haro.gate import retried_all_passed, run_gate
from haro.models import WorkspaceStatus
from tests.test_degraded_gate import _setup
from tests.test_flaky_retry import QUIET

SANDBOX_MODULES = Path("/home/deprecated/Projects/synthesis-sandbox/node_modules")
pytestmark = pytest.mark.skipif(
    not (SANDBOX_MODULES / ".bin" / "vitest").exists(), reason="sandbox vitest not installed"
)

FLAKY = 'import {test,expect} from "vitest"\ntest("flaky one", () => expect(1).toBe(2))\n'


def _project(tmp_path: Path, files: dict[str, str]) -> Path:
    root = tmp_path / "proj"
    (root / "src").mkdir(parents=True)
    (root / "package.json").write_text('{"type":"module"}')
    os.symlink(SANDBOX_MODULES, root / "node_modules")
    for name, body in files.items():
        (root / "src" / name).write_text(body)
    return root


class _Pinned(VitestAdapter):
    def __init__(self, cwd: Path):
        super().__init__()
        self._cwd = str(cwd)

    async def run(self, *, cwd, **kw):
        return await super().run(cwd=self._cwd, **kw)


def _gate(tmp_path, proj, known):
    store, hub, ws, project = _setup(tmp_path / "state" if (tmp_path / "state").mkdir() is None else tmp_path, QUIET)
    for f, n in known:
        store.add_known_flaky(project.id, f, n)
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Pinned(proj), workspace=ws, project_path=project.path))
    return ws, store.latest_test(ws.id)


def test_a_file_that_fails_to_import_blocks_the_retry(tmp_path):
    proj = _project(tmp_path, {
        "flaky.test.js": FLAKY,
        "broken.test.js": 'import "./does-not-exist.js"\nimport {test} from "vitest"\ntest("x", () => {})\n',
    })
    ws, run = _gate(tmp_path, proj, [("src/flaky.test.js", "flaky one")])
    assert ws.status == WorkspaceStatus.gate_red
    assert run.flaky_retried == []


def test_duplicate_names_cannot_hide_a_failing_twin(tmp_path):
    body = (
        'import {test,expect} from "vitest"\n'
        'test("same", () => expect(1).toBe(2))\ntest("same", () => {})\n'
    )
    proj = _project(tmp_path, {"dup.test.js": body})
    ws, run = _gate(tmp_path, proj, [("src/dup.test.js", "same")])
    assert ws.status == WorkspaceStatus.gate_red
    assert run.flaky_retried == []


def test_retried_all_passed_needs_every_twin_and_a_green_retry():
    from haro.adapters.test_runner.base import CaseResult
    from haro.adapters.test_runner.base import TestResult as R

    t = {("a.js", "same")}
    twins = [CaseResult("a.js", "same", "failed"), CaseResult("a.js", "same", "passed")]
    assert not retried_all_passed(t, R(ok=True, cases=twins))
    assert not retried_all_passed(t, R(ok=False, cases=[CaseResult("a.js", "same", "passed")]))
    assert retried_all_passed(t, R(ok=True, cases=[CaseResult("a.js", "same", "passed")]))


def test_only_args_uses_space_joined_anchored_names():
    args = only_args([("a.test.js", "grp > nested"), ("a.test.js", "add")])
    assert args[-1] == "^grp\\ nested$|^add$"


def test_retry_finds_a_test_inside_a_describe_and_does_not_run_its_prefix_sibling(tmp_path):
    body = (
        'import {describe,test,expect} from "vitest"\n'
        'describe("grp", () => { test("nested", () => {}) })\n'
        'test("add", () => {})\ntest("add many", () => { throw new Error("must not run") })\n'
    )
    proj = _project(tmp_path, {"n.test.js": body})

    async def go():
        a = VitestAdapter()
        return (
            await a.run(cwd=str(proj), only=[("src/n.test.js", "grp > nested")]),
            await a.run(cwd=str(proj), only=[("src/n.test.js", "add")]),
        )

    nested, add = asyncio.run(go())
    assert [(c.name, c.status) for c in nested.cases if c.status != "skipped"] == [("grp > nested", "passed")]
    assert retried_all_passed({("src/n.test.js", "grp > nested")}, nested)
    ran = [c.name for c in add.cases if c.status != "skipped"]
    assert ran == ["add"]


def test_a_known_flaky_test_inside_a_describe_is_retried_green(tmp_path):
    # failing case only on the first invocation (a marker file), i.e. genuinely flaky
    marker = tmp_path / "seen"
    body = (
        'import {describe,test,expect} from "vitest"\nimport fs from "node:fs"\n'
        f'describe("grp", () => {{ test("nested", () => {{ const m = {str(marker)!r}; '
        'if (!fs.existsSync(m)) { fs.writeFileSync(m, "1"); throw new Error("first time") } }) })\n'
    )
    proj = _project(tmp_path, {"g.test.js": body})
    ws, run = _gate(tmp_path, proj, [("src/g.test.js", "grp > nested")])
    assert ws.status == WorkspaceStatus.gate_green
    assert run.flaky_retried == ["src/g.test.js::grp > nested"]


def test_detect_flaky_ignores_a_deterministic_duplicate_pair(tmp_path, monkeypatch):
    from haro import analytics
    from haro.adapters.test_runner.base import CaseResult
    from haro.adapters.test_runner.base import TestResult as R

    calls = {"n": 0}

    class Fake:
        async def run(self, *, cwd, **_k):
            calls["n"] += 1
            flip = "passed" if calls["n"] % 2 else "failed"
            return R(ok=False, cases=[
                CaseResult("a.js", "same", "failed"), CaseResult("a.js", "same", "passed"),
                CaseResult("a.js", "real flake", flip),
            ])

    monkeypatch.setattr(analytics, "VitestAdapter", lambda: Fake())
    monkeypatch.setattr(analytics, "ensure_deps", lambda *a, **k: None)
    monkeypatch.setattr(analytics, "_resolve", lambda project, path: (path, path))
    from haro.models import Project, Workspace

    project = Project(id="p", name="p", path=str(tmp_path), default_branch="main")
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(tmp_path), base_ref="main")
    out = asyncio.run(analytics.detect_flaky(workspace=ws, project=project, runs=4))
    assert [f["name"] for f in out["flaky"]] == ["real flake"]
