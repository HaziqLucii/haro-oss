"""Known-flaky retry-once (``[gate] flaky_retry``): a red full-scope run whose failures are
ALL known-flaky gets those tests re-run once; all passing makes the gate green but flagged.
Anything unknown, or a failed/incomplete retry, stays red."""

from __future__ import annotations

import asyncio

from haro import receipt as receipt_mod
from haro import trust
from haro.adapters.test_runner.base import CaseResult, TestRunnerAdapter
from haro.adapters.test_runner.base import TestResult as RunResult
from haro.config import load_project_settings
from haro.gate import retried_all_passed, run_gate
from haro.hub import Hub
from haro.models import KnownFlaky, TestRun, WorkspaceStatus
from haro.models import TestRunStatus as RunStatus
from haro.store import Store

from tests.test_degraded_gate import _setup

QUIET = (
    "[workflow]\ntamper_alarm = 'off'\ncoverage_guard = 'off'\ncode_to_check = 'off'\n"
    "[gate]\nverified_hunks = false\nsecrets_scan = false\n"
)


def _case(name, status, file="a.test.ts"):
    return CaseResult(file, name, status)


class _Scripted(TestRunnerAdapter):
    """First call (the full suite) returns ``first``; later calls return ``retry``."""

    name = "vitest"

    def __init__(self, first: RunResult, retry: RunResult | Exception):
        self.first, self.retry = first, retry
        self.calls: list[dict] = []

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        self.calls.append({"only": only, "changed_since": changed_since})
        if len(self.calls) == 1:
            return self.first
        if isinstance(self.retry, Exception):
            raise self.retry
        return self.retry


def _red(*failing, passing=("ok",)):
    cases = [_case(n, "failed") for n in failing] + [_case(n, "passed") for n in passing]
    return RunResult(ok=False, total=len(cases), passed=len(passing), failed=len(failing), cases=cases)


def _gate(tmp_path, adapter, *, known=(), toml=QUIET):
    store, hub, ws, project = _setup(tmp_path, toml)
    for name in known:
        store.add_known_flaky(project.id, "a.test.ts", name)
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    return store, ws, store.latest_test(ws.id)


def test_all_failures_known_flaky_and_retry_passes_is_green_but_flagged(tmp_path):
    retry = RunResult(ok=True, total=2, passed=2, cases=[_case("f1", "passed"), _case("f2", "passed")])
    adapter = _Scripted(_red("f1", "f2"), retry)
    store, ws, run = _gate(tmp_path, adapter, known=("f1", "f2"))

    assert run.status == RunStatus.passed
    assert ws.status == WorkspaceStatus.gate_green
    assert run.flaky_retried == ["a.test.ts::f1", "a.test.ts::f2"]
    assert run.failed == 0
    assert adapter.calls[1]["only"] == [("a.test.ts", "f1"), ("a.test.ts", "f2")]
    assert len(adapter.calls) == 2  # exactly one retry


def test_an_unknown_failure_stays_red_and_is_never_retried(tmp_path):
    adapter = _Scripted(_red("f1", "real"), RunResult(ok=True))
    _store, ws, run = _gate(tmp_path, adapter, known=("f1",))

    assert run.status == RunStatus.failed
    assert ws.status == WorkspaceStatus.gate_red
    assert run.flaky_retried == []
    assert len(adapter.calls) == 1


def test_a_failed_retry_stays_red(tmp_path):
    retry = RunResult(ok=False, total=1, failed=1, cases=[_case("f1", "failed")])
    _store, ws, run = _gate(tmp_path, _Scripted(_red("f1"), retry), known=("f1",))
    assert ws.status == WorkspaceStatus.gate_red
    assert run.flaky_retried == []


def test_a_retry_that_dropped_the_test_stays_red(tmp_path):
    # An adapter that ignores `only`, or a filter that matched nothing, must not read as a pass.
    retry = RunResult(ok=True, total=1, passed=1, cases=[_case("other", "passed")])
    _store, ws, run = _gate(tmp_path, _Scripted(_red("f1"), retry), known=("f1",))
    assert ws.status == WorkspaceStatus.gate_red


def test_a_crashed_retry_stays_red(tmp_path):
    _s, ws, _r = _gate(tmp_path, _Scripted(_red("f1"), RuntimeError("boom")), known=("f1",))
    assert ws.status == WorkspaceStatus.gate_red


def test_an_errored_retry_stays_red(tmp_path):
    retry = RunResult(ok=False, error="runner died")
    _s, ws, _r = _gate(tmp_path, _Scripted(_red("f1"), retry), known=("f1",))
    assert ws.status == WorkspaceStatus.gate_red


def test_flaky_retry_off_never_retries(tmp_path):
    adapter = _Scripted(_red("f1"), RunResult(ok=True, cases=[_case("f1", "passed")]))
    toml = QUIET.replace("[gate]\n", "[gate]\nflaky_retry = false\n")
    _s, ws, _r = _gate(tmp_path, adapter, known=("f1",), toml=toml)
    assert ws.status == WorkspaceStatus.gate_red
    assert len(adapter.calls) == 1


def test_partial_scope_run_is_never_retried(tmp_path):
    store, hub, ws, project = _setup(tmp_path, QUIET)
    store.add_known_flaky(project.id, "a.test.ts", "f1")
    adapter = _Scripted(_red("f1"), RunResult(ok=True, cases=[_case("f1", "passed")]))
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws,
                         project_path=project.path, changed_since="main"))
    assert ws.status == WorkspaceStatus.gate_red
    assert len(adapter.calls) == 1


def test_known_flaky_is_per_project(tmp_path):
    store, hub, ws, project = _setup(tmp_path, QUIET)
    store.add_known_flaky("other-project", "a.test.ts", "f1")
    adapter = _Scripted(_red("f1"), RunResult(ok=True, cases=[_case("f1", "passed")]))
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    assert ws.status == WorkspaceStatus.gate_red


def test_tamper_block_still_wins_over_a_retried_green(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(
        tmp_path,
        QUIET.replace("tamper_alarm = 'off'", "tamper_alarm = 'block'"),
    )
    store.add_known_flaky(project.id, "a.test.ts", "f1")

    async def fake_diff(*_a, **_k):
        return "", []

    async def fake_inv(**_k):
        return [], []

    monkeypatch.setattr("haro.git_ops.diff", fake_diff)
    monkeypatch.setattr("haro.analytics.test_inventories", fake_inv)
    from haro import tamper

    class _F:
        kind, file, detail, test = "removed", "a.test.ts", "gone", "x"

    class _Rep:
        findings = [_F()]
        rewrites: list = []

    monkeypatch.setattr(tamper, "analyze", lambda *a, **k: _Rep())
    adapter = _Scripted(_red("f1"), RunResult(ok=True, cases=[_case("f1", "passed")]))
    asyncio.run(run_gate(store=store, hub=hub, adapter=adapter, workspace=ws, project_path=project.path))
    run = store.latest_test(ws.id)
    assert run.flaky_retried == ["a.test.ts::f1"]
    assert run.tamper_blocked is True
    assert ws.status == WorkspaceStatus.gate_red


def test_retried_all_passed_helper():
    ok = RunResult(ok=True, cases=[_case("f1", "passed")])
    assert retried_all_passed({("a.test.ts", "f1")}, ok)
    assert not retried_all_passed({("a.test.ts", "f1")}, RunResult(ok=True, cases=[_case("f1", "skipped")]))
    assert not retried_all_passed({("a.test.ts", "f1")}, RunResult(ok=False, error="x", cases=ok.cases))


# --- trust: a retried green cannot bank a streak ------------------------------ #

def test_retried_green_is_not_a_clean_green():
    clean = TestRun(workspace_id="w", runner="vitest", scope="all", status="passed")
    retried = TestRun(workspace_id="w", runner="vitest", scope="all", status="passed",
                      flaky_retried=["a.test.ts::f1"])
    assert trust._is_clean_green(clean)
    assert not trust._is_clean_green(retried)
    streak, breaker = trust._streak([clean, clean, retried])
    assert streak == 0 and "known-flaky" in breaker


# --- receipt line -------------------------------------------------------------- #

def test_receipt_line_names_the_retried_tests(tmp_path):
    store, _hub, ws, project = _setup(tmp_path, QUIET)
    run = TestRun(workspace_id=ws.id, project_id=project.id, runner="vitest", scope="all",
                  status="passed", total=3, passed=3, flaky_retried=["a.test.ts::f1", "b.test.ts::f2"])
    store.add_test(run)
    rec = asyncio.run(receipt_mod.build_receipt(store=store, workspace=ws,
                                                settings=load_project_settings(project.path)))
    assert rec.suite.flaky_retried == run.flaky_retried
    assert "Green after retrying 2 known-flaky tests: f1, f2" in receipt_mod.render_markdown(rec)


# --- store + config ------------------------------------------------------------ #

def test_known_flaky_store_upsert_remove_and_project_removal():
    store = Store()
    store.add_known_flaky("p", "a.ts", "t1", passed=3, failed=2)
    store.add_known_flaky("p", "a.ts", "t1", passed=4, failed=1)  # upsert, not duplicate
    store.add_known_flaky("p", "b.ts", "t2")
    store.add_known_flaky("q", "a.ts", "t1")
    assert [(k.file, k.name) for k in store.list_known_flaky("p")] == [("a.ts", "t1"), ("b.ts", "t2")]
    assert store.list_known_flaky("p")[0].passed == 4
    assert store.remove_known_flaky("p", file="a.ts", name="t1") == 1
    assert store.known_flaky_ids("p") == {("b.ts", "t2")}
    store.remove_project("p")
    assert store.known_flaky_ids("p") == set()
    assert store.known_flaky_ids("q") == {("a.ts", "t1")}


def test_known_flaky_survives_a_restart(tmp_path, monkeypatch):
    from haro import db

    monkeypatch.setenv("HARO_DB", str(tmp_path / "h.db"))
    monkeypatch.setattr(db, "_hydrated", set())

    async def cycle():
        assert await db.init()
        store = Store()
        await db.load_into(store)
        store.add_known_flaky("p", "a.ts", "t1", passed=2, failed=1)
        await db.save_snapshot(store)
        await db.close()
        assert await db.init()
        again = Store()
        await db.load_into(again)
        await db.close()
        return again

    again = asyncio.run(cycle())
    assert isinstance(next(iter(again.known_flaky.values())), KnownFlaky)
    assert again.known_flaky_ids("p") == {("a.ts", "t1")}


def test_flaky_retry_defaults_on_and_parses(tmp_path):
    assert load_project_settings(str(tmp_path)).flaky_retry is True
    (tmp_path / ".haro").mkdir()
    (tmp_path / ".haro" / "settings.toml").write_text("[gate]\nflaky_retry = false\n")
    assert load_project_settings(str(tmp_path)).flaky_retry is False


def test_endpoints_list_and_delete(tmp_path, monkeypatch):
    from haro import main as main_mod
    from haro.models import Project

    store = Store()
    store.projects["p"] = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.add_known_flaky("p", "a.ts", "t1")
    store.add_known_flaky("p", "b.ts", "t2")
    monkeypatch.setattr(main_mod, "store", store)

    async def _save(*a, **k):
        return None

    monkeypatch.setattr(main_mod.db, "save_snapshot", _save)
    assert len(asyncio.run(main_mod.list_known_flaky("p"))) == 2
    assert asyncio.run(main_mod.remove_known_flaky("p", file="a.ts", name="t1")) == {"removed": 1}
    assert asyncio.run(main_mod.remove_known_flaky("p")) == {"removed": 1}
    assert asyncio.run(main_mod.list_known_flaky("p")) == []


def test_unattributed_failures_block_the_retry(tmp_path):
    first = _red("f1")
    first.unattributed_failures = 1  # e.g. a file that failed to import
    adapter = _Scripted(first, RunResult(ok=True, cases=[_case("f1", "passed")]))
    _s, ws, run = _gate(tmp_path, adapter, known=("f1",))
    assert ws.status == WorkspaceStatus.gate_red
    assert len(adapter.calls) == 1


def test_a_failed_case_count_that_disagrees_with_the_keys_blocks_the_retry(tmp_path):
    first = RunResult(ok=False, total=2, failed=2, cases=[_case("f1", "failed"), _case("f1", "failed")])
    adapter = _Scripted(first, RunResult(ok=True, cases=[_case("f1", "passed")]))
    _s, ws, _r = _gate(tmp_path, adapter, known=("f1",))
    assert ws.status == WorkspaceStatus.gate_red


def test_release_gate_task_only_drops_its_own_entry():
    from haro.gate import _release_gate_task

    async def go():
        store = Store()
        other = asyncio.get_running_loop().create_future()

        class _T:  # a live task that is not us
            def done(self):
                return False

        store.gate_tasks["w"] = _T()
        _release_gate_task(store, "w")
        kept = "w" in store.gate_tasks
        other.cancel()

        async def me():
            store.gate_tasks["w"] = asyncio.current_task()
            _release_gate_task(store, "w")

        await asyncio.create_task(me())
        return kept, "w" in store.gate_tasks

    kept, after = asyncio.run(go())
    assert kept is True and after is False


def test_receipt_line_strips_em_dashes_from_test_names():
    from haro.receipt import flaky_retry_line

    dash = chr(0x2014)
    assert dash not in flaky_retry_line([f"a.ts::adds {dash} twice"])
