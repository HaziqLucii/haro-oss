"""Code to check, wired into the gate (backlog/code-to-check.md §3).

The load-bearing assertion here is that this signal is **advisory**: rows must land on the
run and on the glance summary, and the verdict must stay exactly what the tests earned. There
is deliberately no ``unchecked_blocked`` twin of ``tamper_blocked``, so "a dependency changed"
can never refuse a merge until §4 decides that on real counts.
"""

from __future__ import annotations

import asyncio

# Aliased: pytest would try to *collect* these Test*-named imports.
from haro.adapters.test_runner.base import TestRunnerAdapter
from haro.adapters.test_runner.base import TestResult as RunResult
from haro.gate import run_gate
from haro.hub import Hub
from haro.models import Project, Workspace, WorkspaceStatus
from haro.store import Store

DIFF = (
    "diff --git a/src/new.ts b/src/new.ts\n"
    "--- a/src/new.ts\n"
    "+++ b/src/new.ts\n"
    "@@ -0,0 +1,4 @@\n"
    "+export const a = 1\n"
    "+export const b = 2\n"
    "+export const c = 3\n"
    "+export const d = 4\n"
    "diff --git a/package.json b/package.json\n"
    "--- a/package.json\n"
    "+++ b/package.json\n"
    "@@ -1 +1,2 @@\n"
    '+  "left-pad": "^1.0.0"\n'
)


class _Adapter(TestRunnerAdapter):
    """Green suite, and a coverage map that instruments the js family but has never seen
    src/new.ts — so the diff above should yield one no_test_file row and one new_dep row."""

    name = "vitest"

    def __init__(self, line_hits=None):
        self._line_hits = line_hits if line_hits is not None else {"src/known.ts": {1: 1}}

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        return RunResult(ok=True, total=2, passed=2, failed=0, cases=[])

    async def coverage_lines(self, *, cwd, repo_root=None):
        return self._line_hits


def _setup(tmp_path, monkeypatch, *, code_to_check="warn", adapter=None):
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
    body = "[workflow]\ntamper_alarm = 'off'\n"
    if code_to_check != "warn":
        body += f"code_to_check = '{code_to_check}'\n"
    (haro_dir / "settings.toml").write_text(body)

    async def fake_diff(*_a, **_k):
        return DIFF, None

    monkeypatch.setattr("haro.git_ops.diff", fake_diff)
    return store, hub, ws, project, adapter or _Adapter()


def test_rows_land_on_the_run_and_the_glance_summary(tmp_path, monkeypatch):
    store, hub, ws, project, adapter = _setup(tmp_path, monkeypatch)
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))

    run = store.latest_test(ws.id)
    kinds = [i.kind for i in run.unchecked_items]
    assert "no_test_file" in kinds and "new_dep" in kinds
    assert run.unchecked_note  # a compact one-liner for the rail
    # Denormalized for the dashboard/rail badge with no fetch-per-card, same rule as tamper.
    assert ws.gate.unchecked_count == len(run.unchecked_items)


def test_the_signal_is_advisory_and_never_downgrades_a_green(tmp_path, monkeypatch):
    """THE law of this feature. Rows are present AND the verdict is untouched."""
    store, hub, ws, project, adapter = _setup(tmp_path, monkeypatch)
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))

    run = store.latest_test(ws.id)
    assert run.unchecked_items, "precondition: this diff must produce rows"
    assert ws.status == WorkspaceStatus.gate_green
    assert run.status.value == "passed"
    # There is no unchecked_blocked field to accidentally consult.
    assert not hasattr(run, "unchecked_blocked")


def test_off_mode_skips_the_pass_entirely(tmp_path, monkeypatch):
    """None, NOT []. The distinction is the whole point of the tri-state: `[]` is a
    measured claim ("nothing to check") that the pane renders as an earned green, and a
    pass that never ran has not earned it."""
    store, hub, ws, project, adapter = _setup(tmp_path, monkeypatch, code_to_check="off")
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    run = store.latest_test(ws.id)
    assert run.unchecked_items is None
    assert run.unchecked_note is None
    assert run.unchecked_covered_files is None
    assert ws.gate.unchecked_count is None


def test_a_red_gate_records_nothing(tmp_path, monkeypatch):
    """Entry rule, matching the tamper alarm: a red is already blocked, so spending an
    instrumented coverage run on it buys nothing."""

    class _Red(_Adapter):
        async def run(self, *, cwd, emit=None, changed_since=None, only=None):
            return RunResult(ok=False, total=1, passed=0, failed=1, cases=[])

    store, hub, ws, project, _ = _setup(tmp_path, monkeypatch, adapter=_Red())
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Red(), workspace=ws, project_path=project.path))
    run = store.latest_test(ws.id)
    # None, not [] — a red gate never measured the diff, and the rail pane must say so
    # rather than showing the clean state over a run that checked nothing.
    assert run.unchecked_items is None
    assert ws.gate.unchecked_count is None
    assert ws.status == WorkspaceStatus.gate_red


def test_no_coverage_provider_still_reports_the_coverage_free_rules(tmp_path, monkeypatch):
    """`coverage_lines` returning None must not mean "everything is unchecked" — the
    risk rules stand on their own."""

    class _NoCov(_Adapter):
        async def coverage_lines(self, *, cwd, repo_root=None):
            return None

    store, hub, ws, project, _ = _setup(tmp_path, monkeypatch, adapter=_NoCov())
    asyncio.run(run_gate(store=store, hub=hub, adapter=_NoCov(), workspace=ws, project_path=project.path))
    kinds = [i.kind for i in store.latest_test(ws.id).unchecked_items]
    assert kinds == ["new_dep"]  # the dep change, and nothing invented from missing coverage


def test_an_adapter_without_coverage_lines_does_not_crash_the_gate(tmp_path, monkeypatch):
    """pytest/command/offense adapters have no coverage_lines; the gate must still pass."""

    class _Bare(TestRunnerAdapter):
        name = "command"

        async def run(self, *, cwd, emit=None, changed_since=None, only=None):
            return RunResult(ok=True, total=1, passed=1, cases=[])

    store, hub, ws, project, _ = _setup(tmp_path, monkeypatch, adapter=_Bare())
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Bare(), workspace=ws, project_path=project.path))
    assert ws.status == WorkspaceStatus.gate_green
    assert [i.kind for i in store.latest_test(ws.id).unchecked_items] == ["new_dep"]


# --- the tick: what turns a report into a worklist ------------------------- #

def test_rows_carry_a_key_a_tick_can_be_stored_against(tmp_path, monkeypatch):
    store, hub, ws, project, adapter = _setup(tmp_path, monkeypatch)
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    rows = store.latest_test(ws.id).unchecked_items
    assert rows and all(r.key for r in rows)
    assert len({r.key for r in rows}) == len(rows)


def test_the_glance_count_ignores_rows_already_ticked_off(tmp_path, monkeypatch):
    """A badge that keeps counting finished work is a badge people switch off."""
    store, hub, ws, project, adapter = _setup(tmp_path, monkeypatch)
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    rows = store.latest_test(ws.id).unchecked_items
    total = len(rows)

    ws.checked_rows = [rows[0].key]
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    assert ws.gate.unchecked_count == total - 1
    # The row itself is still recorded — ticked means answered, not deleted.
    assert len(store.latest_test(ws.id).unchecked_items) == total


def test_a_tick_survives_a_re_gate_that_reproduces_the_same_claim(tmp_path, monkeypatch):
    store, hub, ws, project, adapter = _setup(tmp_path, monkeypatch)
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    key = store.latest_test(ws.id).unchecked_items[0].key
    ws.checked_rows = [key]

    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    assert ws.checked_rows == [key], "re-asking an answered question is how a list becomes wallpaper"


def test_ticks_are_pruned_to_the_live_rows(tmp_path, monkeypatch):
    """Otherwise the list grows into a junk drawer of keys for claims that no longer exist —
    and a stale key could silently re-tick a row that came back."""
    store, hub, ws, project, adapter = _setup(tmp_path, monkeypatch)
    ws.checked_rows = ["untested_lines|src/gone.ts|99", "no_test_file|src/also-gone.ts|4"]
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    assert ws.checked_rows == []


# --- covered_files: the number that licenses the clean state --------------- #

def test_the_run_records_how_many_files_coverage_spoke_about(tmp_path, monkeypatch):
    """Without this the pane says "every changed line ran" whenever the row list is empty,
    including when the coverage map never contained a single changed file."""
    store, hub, ws, project, adapter = _setup(tmp_path, monkeypatch)
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    # src/new.ts is absent from the map (that IS the no_test_file row), so nothing in this
    # diff was executed — 0, not None, because a map did exist.
    assert store.latest_test(ws.id).unchecked_covered_files == 0


def test_covered_files_is_none_when_no_coverage_provider_answered(tmp_path, monkeypatch):
    class _NoCoverage(_Adapter):
        async def coverage_lines(self, *, cwd, repo_root=None):
            return None

    store, hub, ws, project, _ = _setup(tmp_path, monkeypatch, adapter=_NoCoverage())
    asyncio.run(run_gate(store=store, hub=hub, adapter=_NoCoverage(), workspace=ws, project_path=project.path))
    run = store.latest_test(ws.id)
    assert run.unchecked_covered_files is None
    # The risk rules still ran, so this is "measured, coverage blind" — not "never ran".
    assert run.unchecked_items is not None
    assert [i.kind for i in run.unchecked_items] == ["new_dep"]
