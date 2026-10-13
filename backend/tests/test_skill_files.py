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


def test_the_haro_note_skill_says_where_notes_live_and_when_it_applies():
    text = (SKILLS / "haro-note" / "SKILL.md").read_text()
    assert text.startswith("---\nname: haro-note\n")
    head, _, body = text[4:].partition("\n---\n")
    assert "description:" in head
    for phrase in ("create a haro note", "haro note"):
        assert phrase in head, phrase
    # The one fact the skill exists for, and the rules that keep notes the user's own.
    assert ".haro/notes/" in body
    assert "Never overwrite" in body
    assert "in their words" in body
    assert "Do not create a note on your own initiative" in body


def test_the_installer_ships_all_three_skills(tmp_path, monkeypatch):
    from haro import haro_skill

    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    notes = haro_skill.install_haro_skill()
    assert len(notes) == 3 and not any("failed" in n or "missing" in n for n in notes)
    for name in ("haro", "haro-dev", "haro-note"):
        assert (tmp_path / "skills" / name / "SKILL.md").is_file(), name
