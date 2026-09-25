"""Preset registry: detection ranks the right stack per fixture layout, ambiguous
repos surface candidates, and each preset renders a valid ``settings.toml``
fragment (round-trips back through ``tomllib``)."""

import tomllib

from haro.presets import (
    PRESETS,
    detect_stack,
    detect_stack_response,
    get_preset,
    is_ambiguous,
    to_toml_fragment,
)


def _write(root, rel: str, body: str = "{}") -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)


# --- detection -------------------------------------------------------------


def test_detect_vitest_from_dependency(tmp_path):
    _write(tmp_path, "package.json", '{"devDependencies": {"vitest": "^2.0.0"}}')
    top = detect_stack(tmp_path)[0]
    assert top.preset.id == "vitest"
    assert top.confidence >= 0.9


def test_detect_vitest_from_script(tmp_path):
    _write(tmp_path, "package.json", '{"scripts": {"test": "vitest run"}}')
    assert detect_stack(tmp_path)[0].preset.id == "vitest"


def test_detect_pytest_from_pyproject_tool_table(tmp_path):
    _write(tmp_path, "pyproject.toml", "[tool.pytest.ini_options]\naddopts = '-q'\n")
    top = detect_stack(tmp_path)[0]
    assert top.preset.id == "pytest"
    assert top.confidence >= 0.9


def test_detect_pytest_from_pytest_ini(tmp_path):
    _write(tmp_path, "pytest.ini", "[pytest]\n")
    assert detect_stack(tmp_path)[0].preset.id == "pytest"


def test_detect_shopify_theme_from_layout(tmp_path):
    _write(tmp_path, "config/settings_schema.json", "[]")
    _write(tmp_path, "sections/header.liquid", "<header></header>")
    _write(tmp_path, "templates/index.liquid", "{{ content_for_layout }}")
    top = detect_stack(tmp_path)[0]
    assert top.preset.id == "shopify-theme"
    assert top.confidence >= 0.9


def test_detect_shopify_theme_from_theme_check_config(tmp_path):
    _write(tmp_path, ".theme-check.yml", "extends: theme-check:recommended\n")
    assert detect_stack(tmp_path)[0].preset.id == "shopify-theme"


def test_empty_repo_falls_back_to_custom(tmp_path):
    ranked = detect_stack(tmp_path)
    assert ranked[0].preset.id == "custom"
    # custom is always present and never crashes on a bare directory.
    assert not is_ambiguous(ranked)


def test_detection_always_lists_every_preset(tmp_path):
    ranked = detect_stack(tmp_path)
    assert {r.preset.id for r in ranked} == {p.id for p in PRESETS}


# --- ambiguity -------------------------------------------------------------


def test_clear_winner_is_not_ambiguous(tmp_path):
    _write(tmp_path, "pytest.ini", "[pytest]\n")
    assert not is_ambiguous(detect_stack(tmp_path))


def test_two_close_stacks_are_ambiguous(tmp_path):
    # A repo that reads as both a weak Node project and a weak pytest project:
    # neither dominates, so the UI should ask rather than auto-pick.
    _write(tmp_path, "package.json", '{"name": "x"}')  # Node, no vitest → weak
    _write(tmp_path, "pyproject.toml", "[project]\nname = 'x'\n")  # weak pytest
    ranked = detect_stack(tmp_path)
    assert is_ambiguous(ranked)


# --- fragment rendering ----------------------------------------------------


def test_shopify_fragment_round_trips_and_uses_offense_grid(tmp_path):
    frag = to_toml_fragment(get_preset("shopify-theme"))
    parsed = tomllib.loads(frag)
    # Local install + npx (not `npm i -g`, which EACCESes as the unprivileged
    # setup user); runs through a login shell so npx reaches node_modules/.bin.
    assert parsed["scripts"]["setup"].startswith("npm install @shopify/cli")
    assert parsed["scripts"]["run"].startswith("npx shopify")
    assert parsed["scripts"]["login_shell"] is True
    assert "$HARO_PORT" in parsed["scripts"]["run"]
    assert parsed["gate"] == {
        "runner": "offense",
        "command": "npx shopify theme check --output json",
        "format": "theme-check",
    }


def test_pytest_fragment_has_no_run_key(tmp_path):
    parsed = tomllib.loads(to_toml_fragment(get_preset("pytest")))
    assert parsed["gate"]["runner"] == "pytest"
    assert "run" not in parsed.get("scripts", {})


def test_vitest_fragment_round_trips(tmp_path):
    parsed = tomllib.loads(to_toml_fragment(get_preset("vitest")))
    assert parsed["scripts"]["setup"] == "npm install"
    assert parsed["gate"]["runner"] == "vitest"


def test_custom_fragment_is_headers_only(tmp_path):
    frag = to_toml_fragment(get_preset("custom"))
    # No scripts/gate to write — just the marker comment, still valid TOML.
    assert tomllib.loads(frag) == {}
    assert "custom" in frag


def test_every_preset_fragment_is_valid_toml():
    for preset in PRESETS:
        tomllib.loads(to_toml_fragment(preset))  # must not raise


# --- detect-stack API payload ----------------------------------------------


def test_detect_response_proposes_clear_winner(tmp_path):
    _write(tmp_path, "pytest.ini", "[pytest]\n")
    resp = detect_stack_response(tmp_path)
    assert resp.ambiguous is False
    assert resp.proposal is not None
    assert resp.proposal.preset.id == "pytest"
    assert resp.proposal.confidence >= 0.9
    # Full ranked candidate list, custom always available for "configure manually".
    assert {c.preset.id for c in resp.candidates} == {p.id for p in PRESETS}
    assert resp.candidates[0].preset.id == "pytest"


def test_detect_response_carries_inspectable_toml_per_candidate(tmp_path):
    resp = detect_stack_response(tmp_path)
    for cand in resp.candidates:
        # Each candidate ships the settings.toml it would write, valid + matching.
        assert tomllib.loads(cand.preset.toml) == tomllib.loads(
            to_toml_fragment(get_preset(cand.preset.id))
        )


def test_detect_response_withholds_proposal_when_ambiguous(tmp_path):
    _write(tmp_path, "package.json", '{"name": "x"}')  # weak Node
    _write(tmp_path, "pyproject.toml", "[project]\nname = 'x'\n")  # weak pytest
    resp = detect_stack_response(tmp_path)
    assert resp.ambiguous is True
    # No auto-pick on a tie — the UI must ask.
    assert resp.proposal is None
    assert len(resp.candidates) == len(PRESETS)


def test_detect_response_never_proposes_custom_on_empty_repo(tmp_path):
    resp = detect_stack_response(tmp_path)
    # custom tops the ranking (its floor), but it isn't a *detected* stack, so
    # there's nothing to propose — the dev picks manually.
    assert resp.ambiguous is False
    assert resp.proposal is None
    assert resp.candidates[0].preset.id == "custom"
