from pathlib import Path

from haro.config import load_project_settings
from haro.gate import evaluate_coverage_guard


def test_off_really_means_off():
    """The escape hatch: a guard nobody asked for never has an opinion, measured or not."""
    assert evaluate_coverage_guard(-5.0, "off", 0.0) == ("ok", None)
    assert evaluate_coverage_guard(None, "off", 0.0) == ("ok", None)


def test_a_missing_number_trips_the_guard():
    """The hole this closes (backlog/gate.md): ``None`` used to return ``("ok", None)``, so
    ``block`` never blocked in exactly the case where the *measurement* broke — the easiest
    half to break, since merely running the suite by hand was enough (see ``ensure_deps``).
    No number is less information than a measured drop, so it can't be the one case that
    passes."""
    action, note = evaluate_coverage_guard(None, "block", 0.0)
    assert action == "block"
    assert "could not be measured" in note

    action, note = evaluate_coverage_guard(None, "warn", 0.0)
    assert action == "warn"
    assert "could not be measured" in note


def test_the_unmeasured_note_names_the_cause():
    """The measurement already knows WHY (missing provider · red suite · no run yet), so the
    guard repeats its diagnosis instead of leaving the dev to guess between the three."""
    _action, note = evaluate_coverage_guard(
        None, "block", 0.0, unmeasured_cause="install `@vitest/coverage-v8`"
    )
    assert "@vitest/coverage-v8" in note


def test_tolerance_does_not_absorb_a_missing_number():
    """Tolerance is a statement about how big a *measured* drop may be. An unknown delta
    isn't small, it's unknown."""
    assert evaluate_coverage_guard(None, "block", 99.0)[0] == "block"


def test_a_rise_or_flat_never_trips():
    assert evaluate_coverage_guard(2.5, "block", 0.0) == ("ok", None)
    assert evaluate_coverage_guard(0.0, "block", 0.0) == ("ok", None)


def test_a_drop_trips_the_configured_mode():
    action, note = evaluate_coverage_guard(-1.5, "warn", 0.0)
    assert action == "warn"
    assert "1.50%" in note
    assert evaluate_coverage_guard(-1.5, "block", 0.0)[0] == "block"


def test_tolerance_absorbs_small_drops():
    assert evaluate_coverage_guard(-0.4, "block", 0.5) == ("ok", None)  # within tolerance
    assert evaluate_coverage_guard(-0.6, "block", 0.5)[0] == "block"  # beyond tolerance


def _write_toml(base: Path, body: str) -> None:
    (base / ".haro").mkdir(parents=True, exist_ok=True)
    (base / ".haro" / "settings.toml").write_text(body)


def test_coverage_guard_defaults_off(tmp_path):
    s = load_project_settings(str(tmp_path))
    assert s.coverage_guard == "off"
    assert s.coverage_tolerance == 0.0


def test_coverage_guard_parsed_and_junk_falls_back_to_off(tmp_path):
    _write_toml(tmp_path, '[workflow]\ncoverage_guard = "block"\ncoverage_tolerance = 1.0\n')
    s = load_project_settings(str(tmp_path))
    assert s.coverage_guard == "block"
    assert s.coverage_tolerance == 1.0
    _write_toml(tmp_path, '[workflow]\ncoverage_guard = "nonsense"\n')
    assert load_project_settings(str(tmp_path)).coverage_guard == "off"
