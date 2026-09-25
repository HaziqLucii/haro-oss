"""Autonomy-ladder rung evaluator: the deterministic conjunction of gate facts.

Pure, no repo — every case builds a ``TestRun`` + ``ProjectSettings`` in memory and
asserts the report, exactly as ``backlog/autonomy-ladder.md`` requires."""

from types import SimpleNamespace

from haro.config import ProjectSettings
from haro.models import TamperFinding, TestRun, Workspace
from haro.trust import admission_reason, evaluate, policy_armed


def _ws():
    return Workspace(
        project_id="p", name="w", branch="feat/w",
        worktree_path="/tmp/w", base_ref="main",
    )


def _run(**kw):
    # `quality_findings=[]` is "measured and clean", NOT the default `None` ("nobody
    # looked") — a clean run here has to satisfy the Double Gate's rung too, or the
    # helper's promise below (a clean run fully clears) quietly stops being true.
    # `quality_measured=True` pairs with it for the same reason: `findings == []` alone
    # is also what every-scanner-unavailable produces (see test_quality_measured_*
    # below), so a genuinely clean, fully-measured run has to say so explicitly.
    base = dict(workspace_id="w", runner="vitest", scope="all", status="passed",
                quality_findings=[], quality_measured=True)
    base.update(kw)
    return TestRun(**base)


def _settings(**kw):
    # A policy where every condition's prerequisite is ON, so a clean run can fully clear.
    base = dict(
        trust_enabled=True, trust_streak_required=2, trust_auto_action="auto_pr",
        gate_merge_result=True, coverage_guard="block", flaky_rerun=True,
        quality_enabled=True,
    )
    base.update(kw)
    return ProjectSettings(**base)


def _tampered(**kw):
    """A green run the tamper alarm flagged — the ``green*`` the ladder must refuse."""
    return _run(
        coverage_delta=0.0,
        tamper_findings=[TamperFinding(kind="removed", file="a.test.ts", test="adds")],
        tamper_note="1 removed",
        **kw,
    )


def _cond(report, key):
    return next(c for c in report.conditions if c.key == key)


def test_every_condition_appears():
    report = evaluate(_ws(), _run(coverage_delta=0.0), [], _settings())
    keys = {c.key for c in report.conditions}
    # `quality` joined the set when the Double Gate shipped (backlog/double-gate.md §1);
    # before that it was deliberately omitted for want of anything to read.
    assert keys == {
        "merge_result", "coverage", "full_scope", "no_flaky", "no_tamper", "quality", "streak",
    }


def test_no_gate_run_nothing_met():
    report = evaluate(_ws(), None, [], _settings())
    assert report.met is False
    assert not _cond(report, "merge_result").met
    assert _cond(report, "full_scope").detail == "no gate run yet"


def test_disabled_prerequisites_are_unmet_with_reason():
    settings = _settings(gate_merge_result=False, coverage_guard="off", flaky_rerun=False)
    report = evaluate(_ws(), _run(coverage_delta=1.0), [], settings)
    assert "merge-result gate off" in _cond(report, "merge_result").detail
    assert "coverage guard off" in _cond(report, "coverage").detail
    assert "flaky detector off" in _cond(report, "no_flaky").detail


def test_merge_conflict_blocks_merge_result():
    report = evaluate(_ws(), _run(merge_conflict=True, coverage_delta=0.0), [], _settings())
    assert _cond(report, "merge_result").met is False


def test_impacted_scope_never_climbs():
    report = evaluate(_ws(), _run(scope="impacted", coverage_delta=0.0), [], _settings())
    fs = _cond(report, "full_scope")
    assert fs.met is False
    assert "run the full suite" in fs.detail


def test_coverage_regression_unmet():
    report = evaluate(_ws(), _run(coverage_delta=-0.5), [], _settings())
    assert _cond(report, "coverage").met is False


def test_flaky_tests_unmet():
    report = evaluate(_ws(), _run(coverage_delta=0.0, flaky_tests=["a.test.ts"]), [], _settings())
    nf = _cond(report, "no_flaky")
    assert nf.met is False
    assert "1 suspected-flaky" in nf.detail


def test_clean_suite_meets_no_tamper():
    # The alarm is on by default (warn) and the run recorded no findings → the rung
    # condition holds, with no deep-link (nothing to fix).
    report = evaluate(_ws(), _run(coverage_delta=0.0), [], _settings())
    nt = _cond(report, "no_tamper")
    assert nt.met is True
    assert nt.fix is None
    assert "intact" in nt.detail


def test_tamper_findings_unmet_and_deep_link():
    report = evaluate(_ws(), _tampered(), [], _settings())
    nt = _cond(report, "no_tamper")
    assert nt.met is False
    assert "1 tamper finding(s)" in nt.detail
    assert "1 removed" in nt.detail   # the alarm's own compact note carries the reason
    assert nt.fix == "tamper"         # → the green* findings chip + its restore action


def test_tamper_alarm_off_is_unmet_not_clean():
    # An UNMEASURED suite is not a clean suite: silence must never satisfy the condition
    # every other condition stands on (one it.skip games coverage, flaky and merge-result).
    report = evaluate(_ws(), _run(coverage_delta=0.0), [], _settings(tamper_alarm="off"))
    nt = _cond(report, "no_tamper")
    assert nt.met is False
    assert "tamper alarm off" in nt.detail
    assert nt.fix == "gate_settings"


def test_no_tamper_not_measured_when_the_engine_did_not_complete():
    # The round-6 regression: an otherwise-normal full-scope passed run whose tamper
    # engine still didn't complete (base inventory unavailable, a crash) looks
    # IDENTICAL to a clean measured run by `tamper_findings` alone — this is the
    # `TestRun.tamper_measured` signal gate.py stamps for exactly that case.
    degraded = evaluate(
        _ws(), _run(coverage_delta=0.0, tamper_measured=False), [], _settings()
    )
    nt = _cond(degraded, "no_tamper")
    assert nt.met is False
    assert "not measured" in nt.detail


def test_no_tamper_falls_back_to_findings_for_a_run_predating_the_field():
    # `tamper_measured=None` (the default — a row persisted before the field existed,
    # or that never entered the tamper block for some other reason not covered above)
    # must fall through to the ordinary findings-based check rather than newly failing
    # every such row with an invented "engine didn't complete" cause.
    old_row = evaluate(_ws(), _run(coverage_delta=0.0), [], _settings())
    assert _cond(old_row, "no_tamper").met is True


def test_no_tamper_not_measured_on_red_or_partial_run():
    # gate.run_gate only runs the alarm on an otherwise-green, non-partial gate — so zero
    # findings on a red / "re-run failed" loop means not measured, not clean.
    red = evaluate(_ws(), _run(status="failed"), [], _settings())
    assert "not measured" in _cond(red, "no_tamper").detail
    partial = evaluate(_ws(), _run(scope="failed"), [], _settings())
    assert "not measured" in _cond(partial, "no_tamper").detail
    none_yet = evaluate(_ws(), None, [], _settings())
    assert _cond(none_yet, "no_tamper").detail == "no gate run yet"


def _quality_settings(enabled=True, **kw):
    """Real settings now that the Double Gate has shipped (backlog/double-gate.md §1).

    These used to be a `SimpleNamespace` simulating "a future build where `[quality]
    enabled` exists", because `ProjectSettings` had no such field and its *absence* was
    what kept the rung dormant. §1 added the field, so the simulation is retired and these
    tests exercise the real type."""
    kw.setdefault("quality_enabled", enabled)
    return _settings(**kw)


def _quality_run(findings=None, note=None, **kw):
    """A gate run carrying the quality gate's verdict: `None` = not measured, `[]` = clean,
    non-empty = quality-red. A real `TestRun` now — the duck-typed stand-in is retired."""
    return _run(quality_findings=findings, quality_note=note, coverage_delta=0.0, **kw)


def test_quality_row_appears_unmet_once_the_double_gate_ships():
    """The deviation this row used to make ("omit rather than show unmet") existed only
    while there was no switch to flip. §1 shipped the switch, so it now behaves like every
    other guard: off ⇒ unmet-with-reason, never silently satisfied.

    ⚠ This is a real upgrade consequence, which is why it gets its own test: a project that
    had a rung armed before §1 sees a NEW unmet row and disarms until it either enables
    `[quality]` or waives it with `require_quality = false`. That's the same bargain the
    coverage guard and flaky detector already make, and it is the honest one — silently
    satisfying a check nobody ran is what §0 exists to prevent."""
    report = evaluate(_ws(), _run(coverage_delta=0.0), [], _settings(quality_enabled=False))
    q = _cond(report, "quality")
    assert q is not None and q.met is False
    assert "quality gate off" in q.detail
    assert q.fix == "gate_settings"                      # and it deep-links to the fix
    assert "quality" in ProjectSettings().trust_require  # the policy key still parses


def test_quality_clean_diff_meets_the_condition():
    report = evaluate(_ws(), _quality_run(findings=[]), [], _quality_settings())
    q = _cond(report, "quality")
    assert q.met is True
    assert q.required is True     # required by default, like every other condition
    assert q.fix is None
    assert "quality-clean" in q.detail


def test_quality_findings_are_unmet():
    report = evaluate(
        _ws(),
        _quality_run(findings=[{"tool": "gitleaks"}, {"tool": "semgrep"}],
                     note="1 secret, 1 security"),
        [], _quality_settings(),
    )
    q = _cond(report, "quality")
    assert q.met is False
    assert "2 quality finding(s)" in q.detail
    assert "1 secret, 1 security" in q.detail  # the gate's own note carries the reason
    assert q.fix is None  # the fix is code, not config (the findings panel is §2's job)


def test_quality_gate_off_is_unmet_not_clean():
    # Once the feature exists it behaves like the other guards: an unmeasured diff is not
    # a clean diff, so "off" reads as unmet-with-reason and deep-links to the settings.
    report = evaluate(_ws(), _quality_run(findings=[]), [], _quality_settings(enabled=False))
    q = _cond(report, "quality")
    assert q.met is False
    assert "quality gate off" in q.detail
    assert q.fix == "gate_settings"


def test_quality_every_scanner_unavailable_reads_as_not_measured_not_clean():
    # The same tri-state ambiguity `TestRun.quality_findings` has by itself: every
    # configured scanner unavailable still leaves `findings == []`, indistinguishable
    # from a real clean scan unless `quality_measured` says otherwise (models.py,
    # gate.py). Without this check the rung would arm on a quality gate that never
    # actually looked at anything.
    unmeasured = evaluate(
        _ws(), _quality_run(findings=[], quality_measured=False), [], _quality_settings()
    )
    q = _cond(unmeasured, "quality")
    assert q.met is False
    assert "not measured" in q.detail
    assert "unavailable" in q.detail


def test_quality_falls_back_to_findings_for_a_run_predating_the_field():
    # `quality_measured=None` (the default — a row persisted before the field existed)
    # must fall through to the ordinary findings-based check rather than newly failing
    # every such row with an invented "every scanner unavailable" cause.
    old_row = evaluate(
        _ws(), _quality_run(findings=[], quality_measured=None), [], _quality_settings()
    )
    assert _cond(old_row, "quality").met is True


def test_quality_not_measured_on_the_last_run():
    unmeasured = evaluate(_ws(), _quality_run(findings=None), [], _quality_settings())
    assert "not measured" in _cond(unmeasured, "quality").detail
    none_yet = evaluate(_ws(), None, [], _quality_settings())
    assert _cond(none_yet, "quality").detail == "no gate run yet"


def test_quality_joins_the_conjunction_and_can_be_waived():
    # The whole point of the key: once shipped, quality-red blocks the rung with no
    # redesign — and `require_quality = false` waives it exactly like any other condition.
    history = [_run(coverage_delta=0.0), _run(coverage_delta=0.0)]  # streak 2 == required
    red = _quality_run(findings=[{"tool": "gitleaks"}])
    settings = _quality_settings(trust_auto_action="auto_pr")
    report = evaluate(_ws(), red, history, settings)
    assert report.met is False
    assert report.armed is False
    assert "quality" in admission_reason(report)

    settings.trust_require["quality"] = False
    waived = evaluate(_ws(), red, history, settings)
    assert waived.met is True
    assert waived.armed is True
    assert _cond(waived, "quality").met is False  # still shown, just not required


def test_require_flag_drops_condition_from_conjunction():
    # A require_ flag shows a condition but drops it from the AND: with tamper findings
    # present but require_no_tamper off, the (unsafe) ladder clears anyway.
    settings = _settings()
    settings.trust_require["no_tamper"] = False
    history = [_run(coverage_delta=0.0), _run(coverage_delta=0.0)]  # streak 2 == required
    report = evaluate(_ws(), _tampered(), history, settings)
    assert report.met is True                       # required conditions all hold
    assert _cond(report, "no_tamper").met is False  # still shown, just not required


def test_streak_counts_trailing_clean_greens():
    history = [_run(coverage_delta=0.0) for _ in range(3)]
    report = evaluate(_ws(), _run(coverage_delta=0.0), history, _settings(trust_streak_required=3))
    assert report.streak == 3
    assert _cond(report, "streak").met is True


def test_red_run_resets_streak():
    history = [_run(coverage_delta=0.0), _run(status="failed"), _run(coverage_delta=0.0)]
    report = evaluate(_ws(), _run(coverage_delta=0.0), history, _settings())
    assert report.streak == 1  # only the trailing green after the red counts


def test_impacted_runs_skipped_in_streak():
    # An interleaved impacted fast-gate green neither counts nor breaks the streak.
    history = [_run(coverage_delta=0.0), _run(scope="impacted"), _run(coverage_delta=0.0)]
    report = evaluate(_ws(), _run(coverage_delta=0.0), history, _settings())
    assert report.streak == 2


def test_autofix_green_resets_streak():
    # A green reached via the auto-fix loop (``trigger="autofix"``) isn't a
    # green-first-try, so it breaks the trailing clean-green streak.
    history = [_run(coverage_delta=0.0), _run(coverage_delta=0.0, trigger="autofix"), _run(coverage_delta=0.0)]
    report = evaluate(_ws(), _run(coverage_delta=0.0), history, _settings())
    assert report.streak == 1  # the autofix green isn't a green-first-try


def test_trigger_defaults_to_manual():
    # The evaluator's getattr default and the model default agree: an un-stamped run
    # reads as "manual" and counts toward the streak.
    assert _run().trigger == "manual"
    duck = SimpleNamespace(scope="all", status="passed")  # no trigger attr at all
    history = [duck, _run(coverage_delta=0.0)]
    report = evaluate(_ws(), _run(coverage_delta=0.0), history, _settings())
    assert report.streak == 2  # both history greens count; a missing trigger reads as manual


def test_auto_pr_arms_when_fully_met():
    settings = _settings(trust_auto_action="auto_pr")
    history = [_run(coverage_delta=0.0), _run(coverage_delta=0.0)]
    report = evaluate(_ws(), _run(coverage_delta=0.0), history, settings)
    assert report.met is True
    assert report.armed is True


def test_tamper_findings_reset_the_streak():
    # A green* is not a clean green: without this the streak is exactly the metric an
    # agent games by weakening the suite, then cleaning up on the last run.
    history = [_run(coverage_delta=0.0), _tampered(), _run(coverage_delta=0.0)]
    report = evaluate(_ws(), _run(coverage_delta=0.0), history, _settings())
    assert report.streak == 1  # only the trailing clean green after the green* counts


def test_streak_row_names_what_reset_it():
    # "0/2" next to a green gate reads as a bug unless the row says a green* broke it.
    report = evaluate(_ws(), _run(coverage_delta=0.0), [_tampered()], _settings())
    detail = _cond(report, "streak").detail
    assert detail.startswith("0/2")
    assert "green*" in detail

    red = evaluate(_ws(), _run(coverage_delta=0.0), [_run(status="failed")], _settings())
    assert "a red gate reset it" in _cond(red, "streak").detail


def test_disabled_ladder_never_arms():
    settings = _settings(trust_enabled=False, trust_auto_action="auto_pr")
    history = [_run(coverage_delta=0.0), _run(coverage_delta=0.0)]
    report = evaluate(_ws(), _run(coverage_delta=0.0), history, settings)
    assert report.armed is False


def test_off_guards_deep_link_to_gate_settings():
    # A guard being off is a config fix, not a code fix → deep-link the Gate settings tab.
    settings = _settings(gate_merge_result=False, coverage_guard="off", flaky_rerun=False)
    report = evaluate(_ws(), _run(coverage_delta=1.0), [], settings)
    assert _cond(report, "merge_result").fix == "gate_settings"
    assert _cond(report, "coverage").fix == "gate_settings"
    assert _cond(report, "no_flaky").fix == "gate_settings"


def test_impacted_scope_deep_links_run_full():
    report = evaluate(_ws(), _run(scope="impacted", coverage_delta=0.0), [], _settings())
    assert _cond(report, "full_scope").fix == "run_full"


def test_short_streak_deep_links_ribbon():
    report = evaluate(_ws(), _run(coverage_delta=0.0), [], _settings(trust_streak_required=3))
    assert _cond(report, "streak").met is False
    assert _cond(report, "streak").fix == "ribbon"


def test_code_fixes_carry_no_deep_link():
    # A real coverage regression / flaky finding / met condition has no config deep-link —
    # the fix is code (write tests, de-flake), not a toggle.
    report = evaluate(_ws(), _run(coverage_delta=-0.5, flaky_tests=["a.test.ts"]), [], _settings())
    assert _cond(report, "coverage").fix is None      # guard on, genuine regression
    assert _cond(report, "no_flaky").fix is None       # detector on, genuine flake
    assert _cond(report, "full_scope").fix is None     # full scope ran → met, no fix
    assert "fix" in _cond(report, "streak").to_dict()  # field always serialized


# ---- merge-queue admission: the queue inherits the ladder (§3) ----
def test_policy_armed_needs_both_the_switch_and_an_action():
    # A project has armed the ladder only when it's enabled AND pointed at an action.
    # Either half missing ⇒ the merge queue keeps its original green-is-enough rule.
    assert policy_armed(_settings(trust_auto_action="auto_pr")) is True
    assert policy_armed(_settings(trust_auto_action="off")) is False
    assert policy_armed(_settings(trust_enabled=False, trust_auto_action="auto_pr")) is False


def test_admission_admits_a_rung_complete_workspace():
    history = [_run(coverage_delta=0.0), _run(coverage_delta=0.0)]
    report = evaluate(_ws(), _run(coverage_delta=0.0), history, _settings())
    assert report.armed is True
    assert admission_reason(report) is None  # None ⇒ the queue may land it


def test_admission_names_the_unmet_conditions():
    # Rung-incomplete: no streak yet and a coverage regression. The skip reason has to
    # name the rows, not a score — "4/6" tells you nothing about what to go fix.
    report = evaluate(_ws(), _run(coverage_delta=-1.0), [], _settings())
    reason = admission_reason(report)
    assert reason is not None
    assert "coverage" in reason and "streak" in reason
    assert "merge by hand" in reason  # the manual path stays open
