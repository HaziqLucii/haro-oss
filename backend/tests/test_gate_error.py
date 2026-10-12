from haro.gate import classify_gate_error


def test_missing_toolchain_is_setup():
    assert classify_gate_error("`vitest`/`npx` not found on PATH.", None) == "setup"


def test_unresolved_import_is_setup():
    assert classify_gate_error("Error: Cannot find module 'react'", None) == "setup"
    assert classify_gate_error("ERR_MODULE_NOT_FOUND", None) == "setup"


def test_dep_note_problem_forces_setup_even_without_error_markers():
    note = "project has no node_modules — run `npm install` in the repo first"
    assert classify_gate_error("some opaque failure", note) == "setup"


def test_successful_symlink_note_is_not_a_setup_problem():
    # ensure_deps succeeded — so an error here is about the run, not the deps.
    note = "symlinked node_modules from project root"
    assert classify_gate_error("vitest timed out after 120s", note) == "runner"


def test_command_gate_non_launch_is_setup():
    # A `command` gate that never ran must read as setup ("your gate command never
    # ran"), not a scary red — covers every CommandAdapter non-launch phrasing.
    assert classify_gate_error("gate command not found on PATH (exit 127): make test", None) == "setup"
    assert classify_gate_error("could not launch gate command: [Errno 13] Permission denied", None) == "setup"
    assert (
        classify_gate_error(
            "no gate command configured — set `[gate] command` in .haro/settings.toml", None
        )
        == "setup"
    )


def test_no_tests_found():
    assert classify_gate_error("no tests found", None) == "no_tests"
    assert classify_gate_error("No test files found, exiting", None) == "no_tests"


def test_timeout_and_unknown_are_runner():
    assert classify_gate_error("vitest timed out after 120s", None) == "runner"
    assert classify_gate_error("RuntimeError: kaboom", None) == "runner"


def test_empty_error_defaults_to_runner():
    assert classify_gate_error(None, None) == "runner"
