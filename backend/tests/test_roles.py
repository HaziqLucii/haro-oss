"""`haro.roles` (Phase 2 of notes/workflow-roles-plan.md): pure helpers for the
scout sub-agent haro injects via `--agents` — no I/O, so these are plain unit
tests of the JSON shape and instructions text. Adapter argv wiring lives in
test_agents_flag.py.
"""

from __future__ import annotations

from haro.config import RoleConfig
from haro.roles import SCOUT_TOOLS, scout_agent_json, scout_instructions


def test_scout_agent_json_shape():
    out = scout_agent_json(RoleConfig(model="haiku"))
    assert set(out.keys()) == {"scout"}
    scout = out["scout"]
    assert set(scout.keys()) == {"description", "prompt", "tools", "model"}
    assert scout["tools"] == ["Read", "Grep", "Glob"]
    assert scout["model"] == "haiku"


def test_scout_is_read_only():
    # Whatever the role's model, the tool list never grows a write tool.
    out = scout_agent_json(RoleConfig(model="opus", effort="high"))
    assert out["scout"]["tools"] == SCOUT_TOOLS
    assert not ({"Edit", "Write", "Bash", "MultiEdit"} & set(out["scout"]["tools"]))


def test_scout_model_comes_from_the_role_not_a_hardcoded_default():
    assert scout_agent_json(RoleConfig(model="sonnet"))["scout"]["model"] == "sonnet"
    assert scout_agent_json(RoleConfig(model="fable", effort="xhigh"))["scout"]["model"] == "fable"


def test_scout_agent_json_is_pure_and_stable():
    role = RoleConfig(model="haiku")
    assert scout_agent_json(role) == scout_agent_json(role)


def test_scout_instructions_is_a_nonempty_stable_string():
    text = scout_instructions()
    assert isinstance(text, str) and text.strip()
    assert text == scout_instructions()
    assert "scout" in text
