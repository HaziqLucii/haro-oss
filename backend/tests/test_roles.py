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


def test_code_review_agent_json_is_read_only_plus_bash_on_the_review_model():
    from haro.config import RoleConfig
    from haro.roles import CODE_REVIEW_TOOLS, code_review_agent_json

    spec = code_review_agent_json(RoleConfig(model="opus", effort="medium"))["code-review"]
    assert spec["model"] == "opus"
    assert spec["tools"] == CODE_REVIEW_TOOLS == ["Read", "Grep", "Glob", "Bash"]
    assert "Do NOT edit code" in spec["prompt"]
    assert "VERDICT" in spec["prompt"]


def test_bundled_agents_and_instructions_follow_the_configured_roles():
    from haro.config import RoleConfig
    from haro.roles import bundled_agents, bundled_instructions

    scout, review = RoleConfig(model="haiku"), RoleConfig(model="opus")
    both = bundled_agents(scout, review)
    assert set(both) == {"scout", "code-review"}
    text = bundled_instructions(both)
    assert "`scout`" in text and "`code-review`" in text
    assert set(bundled_agents(scout, None)) == {"scout"}
    assert set(bundled_agents(None, review)) == {"code-review"}
    assert bundled_agents(None, None) is None
    assert bundled_instructions(None) == ""
