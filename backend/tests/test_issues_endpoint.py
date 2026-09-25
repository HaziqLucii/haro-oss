"""GET /projects/{id}/issues assignee resolution (``main.get_issues``).

Pinned after a review caught a real bug: ``mine`` used to be a plain bool
defaulting to False, so a project configured ``issue_assignee = "@me"`` (the
documented way to keep the pre-Move-1 behaviour) could never be switched to
"All assignees" from the UI — every request resolved to "@me" regardless of the
toggle. ``mine`` is now tri-state: the query param's ABSENCE (not falsiness)
means "use the project's config"; an explicit true/false always wins.
"""

from __future__ import annotations

import asyncio

import pytest

from haro import main as main_mod
from haro.models import Project


def _project(tmp_path, *, assignee: str) -> Project:
    haro = tmp_path / ".haro"
    haro.mkdir()
    haro.joinpath("settings.toml").write_text(f'[backlog]\nissue_assignee = "{assignee}"\n')
    return Project(id="p", name="proj", path=str(tmp_path), default_branch="main")


@pytest.fixture(autouse=True)
def _clean_store():
    yield
    main_mod.store.workspaces.clear()
    main_mod.store.projects.clear()


def _capture_assignee(monkeypatch):
    seen: dict = {}

    async def fake_list_issues(project_path, *, force=False, state="open", assignee="", limit=100):
        seen["assignee"] = assignee
        seen["state"] = state
        return {"available": True, "issues": []}

    monkeypatch.setattr(main_mod.issues_svc, "list_issues", fake_list_issues)
    return seen


def test_mine_omitted_falls_back_to_configured_default(tmp_path, monkeypatch):
    project = _project(tmp_path, assignee="@me")
    main_mod.store.projects[project.id] = project
    seen = _capture_assignee(monkeypatch)
    asyncio.run(main_mod.get_issues(project.id))
    assert seen["assignee"] == "@me"


def test_mine_false_overrides_an_at_me_config_default(tmp_path, monkeypatch):
    """The bug: this used to be indistinguishable from "omitted" and always
    resolved back to "@me", so the UI's "All assignees" button was inert for
    exactly the projects that opted into `issue_assignee = "@me"`."""
    project = _project(tmp_path, assignee="@me")
    main_mod.store.projects[project.id] = project
    seen = _capture_assignee(monkeypatch)
    asyncio.run(main_mod.get_issues(project.id, mine=False))
    assert seen["assignee"] == ""


def test_mine_true_overrides_an_anyone_config_default(tmp_path, monkeypatch):
    project = _project(tmp_path, assignee="")
    main_mod.store.projects[project.id] = project
    seen = _capture_assignee(monkeypatch)
    asyncio.run(main_mod.get_issues(project.id, mine=True))
    assert seen["assignee"] == "@me"
