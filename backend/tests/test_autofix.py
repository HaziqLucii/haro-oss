from pathlib import Path

from haro.config import load_project_settings
from haro.models import TestCaseResult as CaseModel  # aliased: pytest tries to collect Test*
from haro.models import TestRun as RunModel
from haro.models import TestRunStatus as RunStatus
from haro.runner import compose_fix_task, should_autofix


def _run(status: RunStatus, cases: list[CaseModel]) -> RunModel:
    return RunModel(workspace_id="w", runner="vitest", status=status, cases=cases)


def _case(name: str, status: str, message: str | None = None) -> CaseModel:
    return CaseModel(file=f"{name}.test.ts", name=name, status=status, message=message)


def test_should_autofix_only_on_real_test_failures():
    failed = _run(RunStatus.failed, [_case("a", "passed"), _case("b", "failed")])
    assert should_autofix(failed) is True


def test_should_not_autofix_a_green_gate():
    ok = _run(RunStatus.passed, [_case("a", "passed")])
    assert should_autofix(ok) is False


def test_should_not_autofix_a_gate_that_couldnt_run():
    # setup/crash reds land as `error` — the agent can't fix deps by editing code.
    errored = _run(RunStatus.error, [])
    assert should_autofix(errored) is False


def test_should_not_autofix_failed_status_with_no_failing_cases():
    # defensive: a "failed" run with no failing case gives the agent nothing to do.
    weird = _run(RunStatus.failed, [_case("a", "passed")])
    assert should_autofix(weird) is False


def test_compose_fix_task_lists_failing_tests_with_first_error_line():
    test = _run(
        RunStatus.failed,
        [
            _case("adds numbers", "failed", "expected 2 got 3\nstack line"),
            _case("passes", "passed"),
            _case("no message", "failed", None),
        ],
    )
    task = compose_fix_task(test, 2, 3)
    assert "auto-fix round 2/3" in task
    assert "2 failing" in task  # two failing cases
    assert "adds numbers" in task
    assert "expected 2 got 3" in task
    assert "stack line" not in task  # only the first line of the message
    assert "no message" in task
    assert "passes" not in task  # passing tests aren't included


def test_compose_fix_task_tells_agent_not_to_weaken_tests():
    test = _run(RunStatus.failed, [_case("a", "failed", "boom")])
    assert "do not weaken" in compose_fix_task(test, 1, 3).lower()


def _write_toml(base: Path, body: str) -> None:
    (base / ".haro").mkdir(parents=True, exist_ok=True)
    (base / ".haro" / "settings.toml").write_text(body)


def test_auto_fix_defaults_off(tmp_path):
    s = load_project_settings(str(tmp_path))
    assert s.auto_fix is False
    assert s.auto_fix_max_rounds == 3


def test_auto_fix_parsed_from_workflow_table(tmp_path):
    _write_toml(tmp_path, "[workflow]\nauto_fix = true\nauto_fix_max_rounds = 5\n")
    s = load_project_settings(str(tmp_path))
    assert s.auto_fix is True
    assert s.auto_fix_max_rounds == 5


def test_auto_fix_rounds_clamped_to_sane_range(tmp_path):
    _write_toml(tmp_path, "[workflow]\nauto_fix_max_rounds = 999\n")
    assert load_project_settings(str(tmp_path)).auto_fix_max_rounds == 10
    _write_toml(tmp_path, "[workflow]\nauto_fix_max_rounds = 0\n")
    assert load_project_settings(str(tmp_path)).auto_fix_max_rounds == 1
