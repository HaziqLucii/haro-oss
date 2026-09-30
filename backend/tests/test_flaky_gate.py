from pathlib import Path

from haro.config import load_project_settings
from haro.gate import reconcile_flaky


def test_reconcile_splits_flaky_from_real():
    first = {("a.test.ts", "a"), ("b.test.ts", "b"), ("c.test.ts", "c")}
    rerun = {("b.test.ts", "b")}  # only b failed again
    flaky, real = reconcile_flaky(first, rerun)
    assert flaky == {("a.test.ts", "a"), ("c.test.ts", "c")}  # failed then passed
    assert real == {("b.test.ts", "b")}  # failed both times


def test_reconcile_all_reproduced_is_all_real():
    first = {("a.test.ts", "a")}
    flaky, real = reconcile_flaky(first, first)
    assert flaky == set()
    assert real == first


def test_reconcile_all_recovered_is_all_flaky():
    first = {("a.test.ts", "a")}
    flaky, real = reconcile_flaky(first, set())
    assert flaky == first
    assert real == set()


def _write_toml(base: Path, body: str) -> None:
    (base / ".haro").mkdir(parents=True, exist_ok=True)
    (base / ".haro" / "settings.toml").write_text(body)


def test_flaky_rerun_defaults_off(tmp_path):
    assert load_project_settings(str(tmp_path)).flaky_rerun is False


def test_flaky_rerun_parsed_from_workflow(tmp_path):
    _write_toml(tmp_path, "[workflow]\nflaky_rerun = true\n")
    assert load_project_settings(str(tmp_path)).flaky_rerun is True
