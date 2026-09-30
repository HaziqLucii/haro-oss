"""Gate runner dispatch (``main._test_adapter``).

The gate picks its ``TestRunnerAdapter`` from ``[gate] runner`` in the project's
``.haro/settings.toml``: default/unset → Vitest (so existing projects behave
exactly as before), ``"pytest"`` → pytest, ``"command"`` → the generic command
gate — wired with the configured ``[gate] command``.
"""

from haro.adapters.test_runner import (
    CommandAdapter,
    OffenseAdapter,
    PytestAdapter,
    VitestAdapter,
)
from haro.main import _test_adapter


def _write_gate(tmp_path, body: str) -> str:
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text(body)
    return str(tmp_path)


def test_default_dispatches_to_vitest(tmp_path):
    # No [gate] table → Vitest, the historical default.
    assert isinstance(_test_adapter(str(tmp_path)), VitestAdapter)


def test_no_project_path_dispatches_to_vitest():
    assert isinstance(_test_adapter(None), VitestAdapter)


def test_pytest_runner_dispatches_to_pytest(tmp_path):
    path = _write_gate(tmp_path, '[gate]\nrunner = "pytest"\n')
    assert isinstance(_test_adapter(path), PytestAdapter)


def test_command_runner_dispatches_to_command_adapter(tmp_path):
    path = _write_gate(tmp_path, '[gate]\nrunner = "command"\ncommand = "make test"\n')
    adapter = _test_adapter(path)
    assert isinstance(adapter, CommandAdapter)
    # The configured command is threaded through to the adapter.
    assert adapter.command == "make test"


def test_command_runner_honors_login_shell(tmp_path):
    path = _write_gate(
        tmp_path,
        '[scripts]\nlogin_shell = true\n[gate]\nrunner = "command"\ncommand = "shopify theme check"\n',
    )
    adapter = _test_adapter(path)
    assert isinstance(adapter, CommandAdapter)
    assert adapter.login_shell is True


def test_offense_runner_dispatches_with_command_and_format(tmp_path):
    path = _write_gate(
        tmp_path,
        '[gate]\nrunner = "offense"\ncommand = "shopify theme check --output json"\nformat = "theme-check"\n',
    )
    adapter = _test_adapter(path)
    assert isinstance(adapter, OffenseAdapter)
    assert adapter.command == "shopify theme check --output json"
    assert adapter.format == "theme-check"


def test_unknown_runner_falls_back_to_vitest(tmp_path):
    path = _write_gate(tmp_path, '[gate]\nrunner = "mocha"\n')
    assert isinstance(_test_adapter(path), VitestAdapter)


def test_applied_preset_end_to_end_dispatches_correctly(tmp_path):
    # The propose-and-confirm write path: applying a preset via write_project_scripts
    # must produce a settings.toml the gate then dispatches on. Ties preset → write →
    # dispatch so a preset can never silently write config the gate ignores.
    from haro.config import write_project_scripts
    from haro.presets import get_preset

    preset = get_preset("shopify-theme")
    write_project_scripts(
        str(tmp_path),
        setup=preset.setup,
        run=preset.run,
        archive=None,
        run_mode="concurrent",
        login_shell=preset.login_shell,
        port_range=(4100, 4200),
        gate=dict(preset.gate),
        target="shared",
    )
    adapter = _test_adapter(str(tmp_path))
    assert isinstance(adapter, OffenseAdapter)
    assert adapter.command == "npx shopify theme check --output json"
    assert adapter.login_shell is True
    assert adapter.format == "theme-check"
