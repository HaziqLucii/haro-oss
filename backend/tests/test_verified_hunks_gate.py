"""Verified Hunks, wired into the gate + the endpoint (backlog/verified-hunks.md §1–§2).

Two invariants carry the feature:

  * **Green-only.** A red gate leaves NO cached proof behind, so no badge can ever be drawn
    from a previous green's measurement.
  * **One coverage run, shared.** The per-line map is measured once on a green gate and
    reused by both diff-level signals, so switching verified hunks on next to code-to-check
    costs nothing — and switching code-to-check *off* must not take the map away.

The endpoint is driven directly (``asyncio.run`` against the module-level ``main.store``),
the pattern the other route tests use.
"""

from __future__ import annotations

import asyncio

# Aliased: pytest would try to *collect* these Test*-named imports.
from haro.adapters.test_runner.base import TestRunnerAdapter
from haro.adapters.test_runner.base import TestResult as RunResult
from haro import main
from haro.gate import run_gate
from haro.hub import Hub
from haro.models import Project, Workspace, WorkspaceStatus
from haro.store import Store

DIFF = (
    "diff --git a/src/math.ts b/src/math.ts\n"
    "--- a/src/math.ts\n"
    "+++ b/src/math.ts\n"
    "@@ -0,0 +1,3 @@\n"
    "+export const add = (a, b) => a + b\n"
    "+export const sub = (a, b) => a - b\n"
    "+export const wild = () => { throw new Error('cold') }\n"
)

HITS = {"src/math.ts": {1: 2, 2: 1, 3: 0}}


class _Adapter(TestRunnerAdapter):
    name = "vitest"

    def __init__(self, *, ok=True, line_hits=HITS):
        self._ok = ok
        self._line_hits = line_hits

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        return RunResult(ok=self._ok, total=2, passed=2 if self._ok else 0,
                         failed=0 if self._ok else 1, cases=[])

    async def coverage_lines(self, *, cwd, repo_root=None):
        return self._line_hits


def _setup(tmp_path, monkeypatch, *, verified="true", code_to_check="warn", diff=DIFF):
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(tmp_path), base_ref="main",
    )
    store.workspaces[ws.id] = ws

    haro_dir = tmp_path / ".haro"
    haro_dir.mkdir(exist_ok=True)
    body = "[gate]\n"
    if verified:
        body += f"verified_hunks = {verified}\n"
    body += "[workflow]\ntamper_alarm = 'off'\n"
    if code_to_check != "warn":
        body += f"code_to_check = '{code_to_check}'\n"
    (haro_dir / "settings.toml").write_text(body)

    async def fake_diff(*_a, **_k):
        return diff, None

    async def fake_head(*_a, **_k):
        return "abc1234"

    monkeypatch.setattr("haro.git_ops.diff", fake_diff)
    monkeypatch.setattr("haro.git_ops.head_sha", fake_head)
    return store, hub, ws, project


def _gate(store, hub, ws, project, adapter=None):
    asyncio.run(
        run_gate(store=store, hub=hub, adapter=adapter or _Adapter(), workspace=ws,
                 project_path=project.path)
    )


def test_a_green_gate_caches_the_line_map_with_the_diff_it_measured(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project)

    snap = store.get_line_hits(ws.id)
    assert snap is not None
    assert snap["line_hits"] == HITS
    # The diff rides along BECAUSE the annotation is only valid against that exact diff.
    assert snap["diff"] == DIFF
    assert snap["sha"] == "abc1234"


def test_explicitly_off_means_nothing_is_cached(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, monkeypatch, verified="false")
    _gate(store, hub, ws, project)
    assert store.get_line_hits(ws.id) is None


def test_a_red_gate_leaves_no_proof_behind(tmp_path, monkeypatch):
    """Green-only, and it has to be enforced where the verdict is known: a stale badge
    drawn from an earlier green is worse than no badge."""
    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project)
    assert store.get_line_hits(ws.id) is not None, "precondition: the green run cached a map"

    _gate(store, hub, ws, project, adapter=_Adapter(ok=False))
    assert ws.status == WorkspaceStatus.gate_red
    assert store.get_line_hits(ws.id) is None


def test_the_map_is_measured_even_with_code_to_check_off(tmp_path, monkeypatch):
    """The two diff-level signals share one coverage run, so neither can switch the other
    off by accident."""
    store, hub, ws, project = _setup(tmp_path, monkeypatch, code_to_check="off")
    _gate(store, hub, ws, project)

    assert store.get_line_hits(ws.id)["line_hits"] == HITS
    # None (never ran), not [] (ran and found nothing) — code to check really is off.
    assert store.latest_test(ws.id).unchecked_items is None


def test_a_runner_without_coverage_lines_caches_no_map_and_still_goes_green(tmp_path, monkeypatch):
    class _Bare(TestRunnerAdapter):
        name = "command"

        async def run(self, *, cwd, emit=None, changed_since=None, only=None):
            return RunResult(ok=True, total=1, passed=1, cases=[])

    store, hub, ws, project = _setup(tmp_path, monkeypatch)
    _gate(store, hub, ws, project, adapter=_Bare())
    assert ws.status == WorkspaceStatus.gate_green
    assert store.get_line_hits(ws.id)["line_hits"] is None


# --------------------------------------------------------------------------- #
# GET /workspaces/{id}/verified-hunks
# --------------------------------------------------------------------------- #
def _register(tmp_path, *, verified="true"):
    """Register a project + green workspace on the module-level store the route reads."""
    haro_dir = tmp_path / ".haro"
    haro_dir.mkdir(exist_ok=True)
    body = "[gate]\n"
    if verified:
        body += f"verified_hunks = {verified}\n"
    (haro_dir / "settings.toml").write_text(body)

    project = Project(name="demo", path=str(tmp_path), default_branch="main")
    main.store.add_project(project)
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(tmp_path), base_ref="main", status=WorkspaceStatus.gate_green,
    )
    main.store.workspaces[ws.id] = ws
    return project, ws


def _cleanup(project, ws):
    main.store.remove_workspace(ws.id)
    main.store.remove_project(project.id)


def _get(ws_id):
    return asyncio.run(main.get_verified_hunks(ws_id))


def test_the_endpoint_annotates_the_current_diff(tmp_path, monkeypatch):
    project, ws = _register(tmp_path)
    try:
        main.store.set_line_hits(ws.id, sha="abc1234", line_hits=HITS, diff=DIFF)

        async def fake_diff(*_a, **_k):
            return DIFF, None

        monkeypatch.setattr("haro.git_ops.diff", fake_diff)
        res = _get(ws.id)
        assert res.supported and not res.stale
        assert res.gate_sha == "abc1234"
        f = res.files[0]
        assert f.path == "src/math.ts"
        assert (f.executed, f.unexecuted) == (2, 1)
        # JSON keys are strings on the wire; the client parses them back.
        assert f.lines == {"1": 2, "2": 1, "3": 0}
    finally:
        _cleanup(project, ws)


def test_the_endpoint_says_why_when_it_cannot_say_anything(tmp_path, monkeypatch):
    """Every unsupported case names its own fix — 'off' wants Gate settings, a missing
    provider wants an npm install. A blank surface would read as 'nothing to flag'."""
    project, ws = _register(tmp_path, verified="false")
    try:
        res = _get(ws.id)
        assert not res.supported and res.files == []
        assert "Gate settings" in (res.note or "")
    finally:
        _cleanup(project, ws)


def test_the_endpoint_refuses_when_no_green_gate_measured_this_tree(tmp_path):
    project, ws = _register(tmp_path)
    try:
        res = _get(ws.id)  # nothing cached
        assert not res.supported
        assert "no green gate" in (res.note or "")
    finally:
        _cleanup(project, ws)


def test_the_endpoint_reports_a_missing_coverage_provider_distinctly(tmp_path):
    project, ws = _register(tmp_path)
    try:
        main.store.set_line_hits(ws.id, sha="abc", line_hits=None, diff=DIFF)
        res = _get(ws.id)
        assert not res.supported
        assert "coverage provider" in (res.note or "")
    finally:
        _cleanup(project, ws)


def test_the_endpoint_marks_a_moved_file_stale_and_strips_its_line_data(tmp_path, monkeypatch):
    project, ws = _register(tmp_path)
    try:
        main.store.set_line_hits(ws.id, sha="abc", line_hits=HITS, diff=DIFF)
        edited = DIFF.replace(
            "+export const add = (a, b) => a + b\n",
            "+export const add = (a, b) => a + b\n+export const sneaky = () => 1\n",
        )

        async def fake_diff(*_a, **_k):
            return edited, None

        monkeypatch.setattr("haro.git_ops.diff", fake_diff)
        res = _get(ws.id)
        assert res.supported and res.stale
        assert res.files[0].stale and res.files[0].lines == {}
    finally:
        _cleanup(project, ws)
