"""Sanity check for the `haro-gate` GitHub Action (usp-critique-round3.md Move B,
action.yml at the repo root). Structural only — the composite action's actual
shell logic (receipt posted to the job summary even on a red gate, exit code
propagated) was hand-verified by running it against a real repo with a local
`haro` install during development; see the session notes for that trace.
`pyyaml` isn't a declared project dependency, so this skips rather than fails
where it's unavailable.

An earlier version interpolated `${{ inputs.path }}`/`${{ inputs.base }}`
directly into the `run:` script body — GitHub substitutes those as literal
text BEFORE bash parses anything, so a path with a space word-split into two
argv entries, and a crafted input executed arbitrary shell in the runner
(reproduced during review). Fixed by routing both through `env:` and
referencing them as real, quoted shell variables — pinned as a test below so
it can't quietly regress."""

from __future__ import annotations

from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

ACTION_YML = Path(__file__).resolve().parents[2] / "action.yml"


def _load():
    return yaml.safe_load(ACTION_YML.read_text())


def test_action_yml_is_valid_yaml_with_required_top_level_keys():
    doc = _load()
    assert doc["name"]
    assert doc["runs"]["using"] == "composite"


def test_action_has_a_python_setup_step_before_installing_haro_gate():
    steps = _load()["runs"]["steps"]
    names = [s.get("uses", s.get("name", "")) for s in steps]
    setup_idx = next(i for i, s in enumerate(steps) if "setup-python" in s.get("uses", ""))
    install_idx = next(i for i, s in enumerate(steps) if "haro-gate" in s.get("run", ""))
    assert setup_idx < install_idx, names


def test_the_gate_step_posts_to_the_job_summary_and_propagates_the_exit_code():
    steps = _load()["runs"]["steps"]
    gate_step = next(s for s in steps if "haro gate" in s.get("run", ""))
    run = gate_step["run"]
    assert "GITHUB_STEP_SUMMARY" in run
    assert "set +e" in run and "set -e" in run  # so a red gate doesn't skip posting the receipt
    assert 'exit "$rc"' in run


def test_gate_step_never_interpolates_raw_expressions_into_the_shell_body():
    # The injection bug this pins: `${{ inputs.* }}` must never appear inside a
    # `run:` string — every input has to cross through `env:` first and be
    # referenced as a real shell variable ("$INPUT_...").
    steps = _load()["runs"]["steps"]
    gate_step = next(s for s in steps if "haro gate" in s.get("run", ""))
    assert "${{" not in gate_step["run"]
    env = gate_step.get("env", {})
    assert any("inputs.path" in str(v) for v in env.values())
    assert any("inputs.base" in str(v) for v in env.values())
    assert "$INPUT_PATH" in gate_step["run"]
    assert "$INPUT_BASE" in gate_step["run"]


def test_no_run_step_interpolates_a_raw_expression():
    # Broader net: catches the same class of bug in ANY step, not just the gate
    # one, if a future edit adds another input-consuming run: block.
    for step in _load()["runs"]["steps"]:
        run = step.get("run")
        if run:
            assert "${{" not in run, step
