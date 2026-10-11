"""The bundled skills are what haro's own agents read about the platform. A bad edit once left
the `haro` skill empty on main, which no test noticed: pin that each skill is a real document."""

from pathlib import Path

import pytest

SKILLS = Path(__file__).resolve().parents[1] / "haro" / "assets" / "skills"


@pytest.mark.parametrize("name", ["haro", "haro-dev"])
def test_a_bundled_skill_has_front_matter_and_a_body(name):
    text = (SKILLS / name / "SKILL.md").read_text()
    assert text.startswith(f"---\nname: {name}\n"), "front matter with the skill name"
    head, _, body = text[4:].partition("\n---\n")
    assert "description:" in head
    assert len(body) > 3000, "a skill is a document, not a stub"
    assert body.count("\n## ") >= 1, "sections"


def test_the_haro_skill_covers_the_scope_fence_and_the_steps():
    text = (SKILLS / "haro" / "SKILL.md").read_text()
    for needle in ("Scope fence", "Verified Hunks", "haro-app", "review"):
        assert needle in text, needle
