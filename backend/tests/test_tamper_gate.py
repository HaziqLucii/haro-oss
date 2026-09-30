"""The tamper alarm wired into ``run_gate``: an otherwise-green gate records the
test-suite-integrity findings (the ``green*`` signal), a partial "re-run failed"
skips the check (diagnostic, not a ship verdict), and an engine crash degrades to
no findings without ever sinking the verdict. The pure signal engine has its own
fixture tests in ``test_tamper.py`` — this exercises the IO wiring only."""

import asyncio

from haro import analytics, git_ops
# TestRef/TestResult aliased: pytest would otherwise try to *collect* these Test*-named classes.
from haro.adapters.test_runner.base import TestRef as Ref
from haro.adapters.test_runner.base import TestResult as RunResult
from haro.adapters.test_runner.base import TestRunnerAdapter
from haro.gate import run_gate
from haro.hub import Hub
from haro.models import Project, Workspace, WorkspaceStatus
from haro.models import TestRunStatus as RunStatus
from haro.store import Store


class _Adapter(TestRunnerAdapter):
    name = "vitest"

    def __init__(self, result: RunResult):
        self._result = result

    async def run(self, *, cwd, emit=None, changed_since=None, only=None):
        return self._result


def _setup(tmp_path, result: RunResult):
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(
        project_id=project.id, name="w", branch="feat",
        worktree_path=str(tmp_path), base_ref="main",
    )
    store.workspaces[ws.id] = ws
    return store, hub, ws, project


def _patch_inventories(monkeypatch, base, current, diff_text=""):
    async def fake_diff(worktree_path, base_ref):
        return diff_text, 0

    async def fake_inventories(*, store, workspace, project):
        return base, current

    monkeypatch.setattr(git_ops, "diff", fake_diff)
    monkeypatch.setattr(analytics, "test_inventories", fake_inventories)


def test_green_gate_records_tamper_findings(monkeypatch, tmp_path):
    # base had a test the worktree dropped → one unmatched "removed" finding. Warn
    # behaviour: the finding is recorded but the gate stays green (not blocked).
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _patch_inventories(
        monkeypatch,
        base=[Ref(file="a.test.ts", name="guards the edge case")],
        current=[],
    )

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert ws.status == WorkspaceStatus.gate_green  # warn records, never blocks
    assert [f.kind for f in test.tamper_findings] == ["removed"]
    assert test.tamper_note == "1 removed"
    assert test.tamper_blocked is False
    assert test.tamper_measured is True


def test_missing_base_inventory_reads_as_unmeasured(monkeypatch, tmp_path):
    # The regression review round 5 found: `base_inv is None` (vitest list couldn't run
    # at base_ref) degrades to `tamper_findings == []`, and `[]` alone reads as "clean" —
    # gate.py's own comment on this branch says so explicitly ("unmeasured is not
    # clean"). `tamper_measured` must stay False here even though findings/note were
    # still set from the diff-text-only signals, or a consumer reading `measured=True,
    # findings=[]` (the Gate Receipt) reports a degraded run as a clean one.
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _patch_inventories(monkeypatch, base=None, current=[])

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert ws.status == WorkspaceStatus.gate_green
    assert any("base test inventory was unavailable" in r for r in test.degraded_reasons)
    assert test.tamper_measured is False


def _write_tamper_mode(tmp_path, mode):
    haro = tmp_path / ".haro"
    haro.mkdir(exist_ok=True)
    (haro / "settings.toml").write_text(f'[workflow]\ntamper_alarm = "{mode}"\n')


def test_block_mode_turns_a_tampered_suite_red(monkeypatch, tmp_path):
    # Under tamper_alarm = "block" a finding folds into the green conjunction: the
    # tests passed but the suite was weakened, so the gate goes red (not by pretending
    # a test failed — the run status stays passed, so it won't trip the auto-fix loop).
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _write_tamper_mode(tmp_path, "block")
    _patch_inventories(
        monkeypatch,
        base=[Ref(file="a.test.ts", name="guards the edge case")],
        current=[],
    )

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert ws.status == WorkspaceStatus.gate_red
    assert test.status == RunStatus.passed  # not a test failure — the auto-fix loop stays out of it
    assert test.tamper_blocked is True
    assert [f.kind for f in test.tamper_findings] == ["removed"]


def test_off_mode_skips_the_tamper_check(monkeypatch, tmp_path):
    # tamper_alarm = "off" opts out entirely: no findings recorded even when the
    # inventories would have flagged one, and the gate stays plain green.
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _write_tamper_mode(tmp_path, "off")
    _patch_inventories(
        monkeypatch,
        base=[Ref(file="a.test.ts", name="guards the edge case")],
        current=[],
    )

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert ws.status == WorkspaceStatus.gate_green
    assert test.tamper_findings == []
    assert test.tamper_note is None
    assert test.tamper_blocked is False
    # The whole point: `tamper_findings == []` here is indistinguishable from a clean
    # measured run unless something else says so — this is that something else. `None`
    # (not `False`): the tamper block never ran at all for an "off" alarm, so nothing
    # explicitly stamped a value — unlike a genuinely degraded run, which does.
    assert test.tamper_measured is None


def test_partial_rerun_still_measures_tamper(monkeypatch, tmp_path):
    # A "re-run failed only" used to skip the alarm, which let a failed-scope re-run wash a
    # tamper block into green. The analysis is diff/inventory based, so it runs on partials.
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _patch_inventories(
        monkeypatch,
        base=[Ref(file="a.test.ts", name="guards the edge case")],
        current=[],
    )

    test = asyncio.run(
        run_gate(
            store=store, hub=hub, adapter=_Adapter(result), workspace=ws,
            project_path=project.path, only=[("a.test.ts", "c")],
        )
    )

    assert [f.kind for f in test.tamper_findings] == ["removed"]
    assert test.tamper_measured is True


def test_engine_crash_degrades_to_no_findings(monkeypatch, tmp_path):
    # A git/list hiccup inside the tamper engine must never sink a verdict the tests
    # already earned — it degrades to zero findings and the gate stays green.
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)

    async def boom(worktree_path, base_ref):
        raise RuntimeError("git exploded")

    monkeypatch.setattr(git_ops, "diff", boom)

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert ws.status == WorkspaceStatus.gate_green
    assert test.status == RunStatus.passed
    assert test.tamper_findings == []
    assert test.tamper_note is None
    # A crashed engine has NOT verified anything, same as "off" — must not read "clean".
    assert test.tamper_measured is False


def test_gate_summary_carries_the_tamper_star(monkeypatch, tmp_path):
    # The dashboard's glance view has to render green* off the COARSE status feed alone
    # (no fetch-per-card), so the denormalized GateSummary carries the finding count +
    # the compact note — and the same pair rides the status envelope. The findings
    # themselves stay on the TestRun, where the drill-down reads them.
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    q = hub.subscribe(ws.id)
    _patch_inventories(
        monkeypatch,
        base=[Ref(file="a.test.ts", name="guards the edge case")],
        current=[],
    )

    asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert ws.status == WorkspaceStatus.gate_green  # green* is still a green
    assert ws.gate is not None
    assert ws.gate.tamper_count == 1
    assert ws.gate.tamper_note == "1 removed"

    envelopes = []
    while not q.empty():
        envelopes.append(q.get_nowait())
    gate_status = [e for e in envelopes if e.get("channel") == "status" and "gate" in e]
    assert gate_status, "the gate verdict must ride the status channel"
    assert gate_status[-1]["gate"]["tamper_count"] == 1
    assert gate_status[-1]["gate"]["tamper_note"] == "1 removed"


def test_clean_green_gate_summary_is_unstarred(monkeypatch, tmp_path):
    # The star must be earned: an untouched suite leaves the summary at zero findings
    # and no note, so a plain green card never renders as green*.
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    ref = Ref(file="a.test.ts", name="guards the edge case")
    _patch_inventories(monkeypatch, base=[ref], current=[ref])

    asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert ws.status == WorkspaceStatus.gate_green
    assert ws.gate.tamper_count == 0
    assert ws.gate.tamper_note is None


def test_a_rewritten_assertion_reaches_the_pane_and_not_the_verdict(monkeypatch, tmp_path):
    """The §8.8 gap, end to end. A base test retitled AND re-asserted must leave the verdict
    exactly as the tests earned it — clean green, no chip, no star, streak intact — while still
    being visible as an advisory row in the code-to-check pane. Both halves matter: the first is
    why this isn't a tamper finding, the second is why it isn't nothing."""
    diff = (
        "diff --git a/a.test.ts b/a.test.ts\n"
        "--- a/a.test.ts\n"
        "+++ b/a.test.ts\n"
        "@@ -1,5 +1,5 @@\n"
        " describe('mean', () => {\n"
        "-  it('returns 0 for an empty list', () => {\n"
        "-    expect(mean([])).toBe(0);\n"
        "+  it('throws on an empty list', () => {\n"
        "+    expect(() => mean([])).toThrow();\n"
        "   });\n"
        " });\n"
    )
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _patch_inventories(
        monkeypatch,
        base=[Ref(file="a.test.ts", name="mean > returns 0 for an empty list")],
        current=[Ref(file="a.test.ts", name="mean > throws on an empty list")],
        diff_text=diff,
    )

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    # The verdict half — untouched, which is the whole reason this isn't a finding.
    assert ws.status == WorkspaceStatus.gate_green
    assert test.tamper_findings == []
    assert test.tamper_note is None
    assert test.tamper_blocked is False
    assert ws.gate.tamper_count == 0  # no star on the dashboard card either

    # The visible half — one advisory row, naming the test and the title it used to carry.
    rows = [i for i in test.unchecked_items if i.kind == "assertion_rewritten"]
    assert len(rows) == 1
    assert rows[0].file == "a.test.ts"
    assert "throws on an empty list" in rows[0].detail
    assert "returns 0 for an empty list" in rows[0].detail


def test_rewrites_are_not_collected_when_the_alarm_is_off(monkeypatch, tmp_path):
    # The rewrite pass rides the alarm's inventories, so "off" means no suite measurement at
    # all — consistent with every other tamper signal rather than a pass that leaks past it.
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _write_tamper_mode(tmp_path, "off")
    _patch_inventories(
        monkeypatch,
        base=[Ref(file="a.test.ts", name="mean > returns 0 for an empty list")],
        current=[Ref(file="a.test.ts", name="mean > throws on an empty list")],
        diff_text=(
            "diff --git a/a.test.ts b/a.test.ts\n"
            "--- a/a.test.ts\n"
            "+++ b/a.test.ts\n"
            "@@ -1,3 +1,3 @@\n"
            "-  it('returns 0 for an empty list', () => expect(mean([])).toBe(0));\n"
            "+  it('throws on an empty list', () => expect(() => mean([])).toThrow());\n"
        ),
    )

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert [i for i in test.unchecked_items if i.kind == "assertion_rewritten"] == []


def test_red_gate_is_never_tamper_checked(monkeypatch, tmp_path):
    # A red gate is already blocked; tamper is an extra pass kept off the red path.
    result = RunResult(
        ok=False, total=1, passed=0, failed=1,
        cases=[],
    )
    store, hub, ws, project = _setup(tmp_path, result)
    _patch_inventories(
        monkeypatch,
        base=[Ref(file="a.test.ts", name="guards the edge case")],
        current=[],
    )

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert ws.status == WorkspaceStatus.gate_red
    assert test.tamper_findings == []
    assert test.tamper_note is None
    assert test.tamper_measured is None  # the block never ran for a red gate


def test_green_gate_freezes_a_diff_fingerprint(monkeypatch, tmp_path):
    # usp-critique-round3.md Move A: the Verified-by: trailer and an --attest
    # statement both need what the gate ACTUALLY measured, frozen at gate time —
    # not a value integrate.py or the CLI recomputes later from a possibly-drifted
    # tree. This is the one field that makes that possible.
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _patch_inventories(monkeypatch, base=[], current=[], diff_text="diff --git a/f b/f\n")

    test = asyncio.run(run_gate(
        store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=str(tmp_path),
    ))
    from haro.receipt import diff_fingerprint
    assert test.diff_fingerprint == diff_fingerprint("diff --git a/f b/f\n")



# --- vacuous (new test already passing at base) is advisory, never tamper ------------

def _patch_red_first(monkeypatch, vacuous):
    from haro import gate

    calls = []

    async def fake_red_first(**kw):
        calls.append(kw["added"])
        return [gate.VacuousTest(file=t.file, test=t.name) for t in kw["added"] if t.name in vacuous]

    monkeypatch.setattr(gate, "_red_first_check", fake_red_first)
    return calls


def _vacuous_setup(monkeypatch, tmp_path, mode, *, base, current, vacuous):
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _write_tamper_mode(tmp_path, mode)
    _patch_inventories(monkeypatch, base=base, current=current)
    calls = _patch_red_first(monkeypatch, vacuous)
    return store, hub, ws, project, result, calls


def test_vacuous_only_run_is_green_and_not_blocked_even_in_block_mode(monkeypatch, tmp_path):
    ref = Ref(file="a.test.ts", name="adds")
    new = [
        Ref(file="a.test.ts", name="weekdays add nothing"),
        Ref(file="a.test.ts", name="empty list adds nothing"),
    ]
    store, hub, ws, project, result, calls = _vacuous_setup(
        monkeypatch, tmp_path, "block", base=[ref], current=[ref, *new],
        vacuous={"weekdays add nothing", "empty list adds nothing"},
    )

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert calls, "precondition: the red-first check ran"
    assert ws.status == WorkspaceStatus.gate_green
    assert test.tamper_findings == []
    assert test.tamper_note is None
    assert test.tamper_blocked is False
    assert test.tamper_measured is True
    assert ws.gate.tamper_count == 0  # no green* star either

    rows = [i for i in test.unchecked_items if i.kind == "vacuous_test"]
    assert len(rows) == 2
    assert {r.file for r in rows} == {"a.test.ts"}
    joined = " ".join(r.detail for r in rows)
    assert "weekdays add nothing" in joined and "empty list adds nothing" in joined
    assert all("already passes on main" in r.detail for r in rows)
    assert all("guards existing behaviour, not this change" in r.detail for r in rows)
    assert "2 new tests already pass on main" in test.unchecked_note
    assert len({r.key for r in rows}) == 2


def test_vacuous_rows_are_tickable_and_the_tick_survives_a_regate(monkeypatch, tmp_path):
    ref = Ref(file="a.test.ts", name="adds")
    new = Ref(file="a.test.ts", name="weekdays add nothing")
    store, hub, ws, project, result, _ = _vacuous_setup(
        monkeypatch, tmp_path, "block", base=[ref], current=[ref, new],
        vacuous={"weekdays add nothing"},
    )

    def gate_once():
        return asyncio.run(
            run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
        )

    test = gate_once()
    (row,) = [i for i in test.unchecked_items if i.kind == "vacuous_test"]
    open_before = ws.gate.unchecked_count

    ws.checked_rows = [row.key]
    gate_once()

    assert ws.checked_rows == [row.key]
    assert ws.gate.unchecked_count == open_before - 1
    assert ws.status == WorkspaceStatus.gate_green


def test_mixed_vacuous_and_removed_blocks_on_the_removed_one_only(monkeypatch, tmp_path):
    gone = Ref(file="a.test.ts", name="guards the edge case")
    new = Ref(file="a.test.ts", name="weekdays add nothing")
    store, hub, ws, project, result, _ = _vacuous_setup(
        monkeypatch, tmp_path, "block", base=[gone], current=[new],
        vacuous={"weekdays add nothing"},
    )

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert ws.status == WorkspaceStatus.gate_red
    assert test.tamper_blocked is True
    assert [f.kind for f in test.tamper_findings] == ["removed"]
    assert test.tamper_note == "1 removed"  # vacuous is not counted in the chip line
    assert ws.gate.tamper_count == 1
    assert [i.kind for i in test.unchecked_items if i.kind == "vacuous_test"] == ["vacuous_test"]


def test_vacuous_only_run_reads_clean_on_the_receipt_and_xp_merge_facts(monkeypatch, tmp_path):
    from haro import receipt as receipt_svc
    from haro import xp_hooks
    from haro.config import load_project_settings

    ref = Ref(file="a.test.ts", name="adds")
    new = Ref(file="a.test.ts", name="weekdays add nothing")
    store, hub, ws, project, result, _ = _vacuous_setup(
        monkeypatch, tmp_path, "block", base=[ref], current=[ref, new],
        vacuous={"weekdays add nothing"},
    )
    asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    rcpt = asyncio.run(
        receipt_svc.build_receipt(store=store, workspace=ws, settings=load_project_settings(project.path))
    )
    assert rcpt.verdict == "green"
    assert rcpt.tamper.measured is True
    assert rcpt.tamper.clean is True
    assert rcpt.tamper.findings_count == 0
    assert rcpt.tamper.note is None

    assert xp_hooks.merge_facts(store, ws, ["a.js"], at=1.0).green is True


def test_no_base_inventory_means_no_red_first_run(monkeypatch, tmp_path):
    # With no base inventory every worktree test would read as "added"; running the check
    # then would flood the pane with rows for tests that were always there.
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _patch_inventories(monkeypatch, base=None, current=[Ref(file="a.test.ts", name="adds")])
    calls = _patch_red_first(monkeypatch, {"adds"})

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert calls == []
    assert [i for i in test.unchecked_items if i.kind == "vacuous_test"] == []


def test_a_failing_red_first_engine_leaves_the_run_green_undegraded_and_shippable(monkeypatch, tmp_path):
    # An advisory check must never turn a green into a degraded green: those are refused at
    # ship and by the merge train, and they break the streak.
    from haro import gate

    ref = Ref(file="a.test.ts", name="adds")
    new = Ref(file="a.test.ts", name="weekdays add nothing")
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])
    store, hub, ws, project = _setup(tmp_path, result)
    _write_tamper_mode(tmp_path, "block")
    _patch_inventories(monkeypatch, base=[ref], current=[ref, new])
    ran = []

    async def boom(**kw):
        ran.append(1)
        raise RuntimeError("base worktree exploded")

    monkeypatch.setattr(gate, "_red_first_check", boom)

    test = asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )

    assert ran, "precondition: the engine was attempted"
    assert ws.status == WorkspaceStatus.gate_green
    assert test.degraded_reasons == []
    assert ws.gate.degraded is False
    assert [i for i in test.unchecked_items if i.kind == "vacuous_test"] == []
    assert test.tamper_measured is True


def test_red_first_does_not_run_for_a_partial_run_or_with_code_to_check_off(monkeypatch, tmp_path):
    ref = Ref(file="a.test.ts", name="adds")
    new = Ref(file="a.test.ts", name="weekdays add nothing")
    result = RunResult(ok=True, total=1, passed=1, failed=0, cases=[])

    # partial (`only`) run
    store, hub, ws, project, _, calls = _vacuous_setup(
        monkeypatch, tmp_path, "warn", base=[ref], current=[ref, new], vacuous={"weekdays add nothing"},
    )
    asyncio.run(
        run_gate(
            store=store, hub=hub, adapter=_Adapter(result), workspace=ws,
            project_path=project.path, only=[("a.test.ts", "adds")],
        )
    )
    assert calls == []

    # code_to_check = "off"
    (tmp_path / ".haro" / "settings.toml").write_text(
        "[workflow]\ntamper_alarm = 'warn'\ncode_to_check = 'off'\n"
    )
    store, hub, ws, project = _setup(tmp_path, result)
    asyncio.run(
        run_gate(store=store, hub=hub, adapter=_Adapter(result), workspace=ws, project_path=project.path)
    )
    assert calls == []
