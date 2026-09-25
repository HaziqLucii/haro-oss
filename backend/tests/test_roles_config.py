"""`[roles]` config parsing + writer round-trip (Phase 1 of
notes/workflow-roles-plan.md). Same shape/philosophy as `[race]` lanes
(test_race_config.py): junk falls back rather than breaking the whole config.
"""

from __future__ import annotations

from pathlib import Path

from haro.config import (
    RoleConfig,
    _parse_role,
    load_project_settings,
    write_project_roles,
)


def write_settings(tmp_path: Path, body: str) -> str:
    haro_dir = tmp_path / ".haro"
    haro_dir.mkdir(parents=True, exist_ok=True)
    (haro_dir / "settings.toml").write_text(body)
    return str(tmp_path)


# --------------------------------------------------------------------------- #
# _parse_role
# --------------------------------------------------------------------------- #
def test_parse_role_from_a_model_effort_string():
    assert _parse_role("fable:xhigh") == RoleConfig(model="fable", effort="xhigh")


def test_parse_role_from_a_bare_model_string():
    assert _parse_role("haiku") == RoleConfig(model="haiku", effort="")


def test_parse_role_from_a_table():
    assert _parse_role({"model": "Opus", "effort": "High"}) == RoleConfig(model="opus", effort="high")


def test_parse_role_junk_returns_none():
    assert _parse_role(None) is None
    assert _parse_role(42) is None
    assert _parse_role("") is None
    assert _parse_role(":xhigh") is None  # no model
    assert _parse_role({}) is None


# --------------------------------------------------------------------------- #
# load_project_settings
# --------------------------------------------------------------------------- #
def test_a_project_with_no_roles_table_gets_safe_defaults(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, ""))
    assert ps.roles_enabled is False
    assert ps.role_plan is None
    assert ps.role_build is None
    assert ps.role_review is None
    assert ps.role_scout is None
    assert ps.review_enforce == "off"
    assert ps.review_max_rounds == 2


def test_roles_parse_from_the_toml_shape_in_the_plan(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[roles]
enabled = true
plan   = "fable:xhigh"
build  = "sonnet:high"
review = "opus:high"
scout  = "haiku"
review_enforce = "warn"
review_max_rounds = 2
"""))
    assert ps.roles_enabled is True
    assert ps.role_plan == RoleConfig(model="fable", effort="xhigh")
    assert ps.role_build == RoleConfig(model="sonnet", effort="high")
    assert ps.role_review == RoleConfig(model="opus", effort="high")
    assert ps.role_scout == RoleConfig(model="haiku", effort="")
    assert ps.review_enforce == "warn"
    assert ps.review_max_rounds == 2


def test_an_unknown_review_enforce_and_a_silly_round_count_are_clamped(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[roles]
review_enforce = "whenever"
review_max_rounds = 999
"""))
    assert ps.review_enforce == "off"
    assert ps.review_max_rounds == 10


def test_a_junk_role_entry_falls_back_to_none_instead_of_breaking_the_config(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[roles]
enabled = true
plan = 42
"""))
    assert ps.roles_enabled is True
    assert ps.role_plan is None


def test_roles_off_by_default_is_byte_identical_resolution(tmp_path, monkeypatch):
    """`enabled = false` (or an absent [roles] table) must leave every other field
    at its plain default — the whole point of an opt-in feature."""
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    ps = load_project_settings(write_settings(tmp_path, """
[roles]
enabled = false
plan = "fable:xhigh"
"""))
    assert ps.roles_enabled is False
    # The role itself still parses (a toggle flip shouldn't require re-typing it)...
    assert ps.role_plan == RoleConfig(model="fable", effort="xhigh")


# --------------------------------------------------------------------------- #
# write_project_roles round-trip
# --------------------------------------------------------------------------- #
def test_writer_round_trips_and_preserves_other_tables(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    project_path = write_settings(tmp_path, """
[scripts]
setup = "npm ci"

[gate]
runner = "vitest"
""")
    write_project_roles(
        project_path,
        enabled=True,
        role_plan="fable:xhigh",
        role_build="sonnet:high",
        role_review="opus:high",
        role_scout="haiku",
        review_enforce="warn",
        review_max_rounds=2,
        target="shared",
    )
    ps = load_project_settings(project_path)
    assert ps.roles_enabled is True
    assert ps.role_plan == RoleConfig(model="fable", effort="xhigh")
    assert ps.role_build == RoleConfig(model="sonnet", effort="high")
    assert ps.role_review == RoleConfig(model="opus", effort="high")
    assert ps.role_scout == RoleConfig(model="haiku", effort="")
    assert ps.review_enforce == "warn"
    # [scripts]/[gate] untouched by the targeted [roles] write.
    assert ps.setup == "npm ci"
    assert ps.gate_runner == "vitest"


def test_writer_omits_default_valued_keys_on_a_shared_write(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    project_path = write_settings(tmp_path, "")
    path = write_project_roles(
        project_path,
        enabled=True,
        role_plan="",
        role_build="",
        role_review="",
        role_scout="",
        review_enforce="off",
        review_max_rounds=2,
        target="shared",
    )
    text = Path(path).read_text()
    assert "review_enforce" not in text
    assert "review_max_rounds" not in text
    assert "enabled = true" in text


def test_writer_clearing_a_role_removes_its_key(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    project_path = write_settings(tmp_path, "")
    write_project_roles(
        project_path, enabled=True, role_plan="fable:xhigh", target="shared",
    )
    write_project_roles(
        project_path, enabled=True, role_plan="", target="shared",
    )
    ps = load_project_settings(project_path)
    assert ps.role_plan is None
