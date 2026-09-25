"""Move 2 of the backlog redesign (backlog/backlog-v2.md): an item's `stage` is
derived from its seeded workspace's actual gate/run state instead of being a
separate signal that can drift from it, the in-progress lock excludes a merged
(but not yet archived) workspace so a shipped item doesn't stay falsely locked,
a same-file rename remaps a live workspace's `seed_key` instead of orphaning it,
and a merged todo-seeded workspace gets its source line ticked automatically.

Endpoints are called directly (not through a TestClient), matching the rest of
this suite's pattern for driving async handlers.
"""

from __future__ import annotations

import asyncio
import subprocess

import pytest
from fastapi import HTTPException

from haro import backlog, main as main_mod
from haro.config import ProjectSettings
from haro.models import (
    AgentRun,
    AgentRunStatus,
    Project,
    TodoItemAppendRequest,
    TodoWriteRequest,
    Workspace,
    WorkspaceStatus,
)


def _init_git(tmp_path) -> None:
    # _discover_todo_files shells out to `git ls-files`, so the fixture project
    # needs a real (if history-less) repo — `--others --exclude-standard` finds
    # untracked files fine without a commit.
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)


def _project(tmp_path) -> Project:
    _init_git(tmp_path)
    return Project(id="p", name="proj", path=str(tmp_path), default_branch="main")


def _workspace(project: Project, **kw) -> Workspace:
    ws = Workspace(
        project_id=project.id, name="w", branch="feat", worktree_path="/tmp/x",
        base_ref="main", **kw,
    )
    main_mod.store.workspaces[ws.id] = ws
    return ws


@pytest.fixture(autouse=True)
def _clean_store():
    yield
    main_mod.store.workspaces.clear()
    main_mod.store.projects.clear()
    main_mod.store.runs.clear()


# ── _stage_of ─────────────────────────────────────────────────────────────────
def test_stage_no_workspace_is_ready():
    assert main_mod._stage_of(None) == "ready"


def test_stage_archived_is_ready():
    # A soft-archived race loser (fanout.py) stays in the store sharing its
    # winning sibling's seed_key — its stale status must not shadow the winner.
    ws = Workspace(
        project_id="p", name="w", branch="f", worktree_path="/tmp/x", base_ref="main",
        status=WorkspaceStatus.archived,
    )
    assert main_mod._stage_of(ws) == "ready"


def test_stage_merged_wins_over_a_stale_green_gate():
    ws = Workspace(
        project_id="p", name="w", branch="f", worktree_path="/tmp/x", base_ref="main",
        status=WorkspaceStatus.merged,
    )
    assert main_mod._stage_of(ws) == "shipped"


@pytest.mark.parametrize(
    "status,expected",
    [
        (WorkspaceStatus.gate_red, "red"),
        (WorkspaceStatus.gate_green, "green"),
    ],
)
def test_stage_gate_states(status, expected):
    ws = Workspace(
        project_id="p", name="w", branch="f", worktree_path="/tmp/x", base_ref="main",
        status=status,
    )
    assert main_mod._stage_of(ws) == expected


def test_stage_queued_when_the_latest_run_is_queued():
    project = Project(id="p", name="proj", path="/tmp", default_branch="main")
    ws = _workspace(project, status=WorkspaceStatus.idle)
    run = AgentRun(workspace_id=ws.id, adapter="claude-code", status=AgentRunStatus.queued)
    main_mod.store.runs[run.id] = run
    assert main_mod._stage_of(ws) == "queued"


def test_stage_queued_wins_over_a_stale_gate_verdict():
    # A follow-up run queued behind [agent] max_parallel doesn't flip
    # Workspace.status until it acquires its slot, so a gate_green/gate_red left
    # over from the PREVIOUS run must not outrank "another run is about to
    # change this" — else a green item would wrongly deep-link to ④ ship.
    project = Project(id="p", name="proj", path="/tmp", default_branch="main")
    ws = _workspace(project, status=WorkspaceStatus.gate_green)
    run = AgentRun(workspace_id=ws.id, adapter="claude-code", status=AgentRunStatus.queued)
    main_mod.store.runs[run.id] = run
    assert main_mod._stage_of(ws) == "queued"


def test_stage_falls_back_to_running_with_no_run_and_no_gate_verdict():
    ws = Workspace(
        project_id="p", name="w", branch="f", worktree_path="/tmp/x", base_ref="main",
        status=WorkspaceStatus.agent_running,
    )
    assert main_mod._stage_of(ws) == "running"


# ── _tick_item_text / tick_backlog_item (haro.backlog; main.tick_backlog_item is
# an alias onto the same function, checked separately below) ────────────────────
def test_tick_item_text_flips_only_the_matching_line():
    md = "- [ ] first\n- [ ] second\n- [x] third\n"
    new_text, ticked = backlog._tick_item_text(md, "second")
    assert ticked is True
    assert new_text == "- [ ] first\n- [x] second\n- [x] third\n"


def test_tick_item_text_no_match_is_a_noop():
    md = "- [ ] only item\n"
    new_text, ticked = backlog._tick_item_text(md, "renamed item")
    assert ticked is False
    assert new_text == md


def test_tick_item_text_already_done_is_not_re_matched():
    md = "- [x] done already\n"
    new_text, ticked = backlog._tick_item_text(md, "done already")
    assert ticked is False
    assert new_text is md


def test_tick_item_text_ignores_checkbox_lines_inside_a_fenced_example():
    # A backlog file explaining the checklist syntax can contain a `- [ ]` line
    # INSIDE a fenced code example (parse_todo_doc already skips these when
    # counting real items) — the raw re-scan must skip them too, or its item
    # index drifts out of sync with parse_todo_doc's and the wrong line gets
    # ticked. Move 1 widened `[backlog] files` discovery to plan-style docs,
    # which are exactly where such examples live.
    md = (
        "# Plan\n\n"
        "Example:\n\n"
        "```markdown\n"
        "- [ ] Untested: `src/pricing.ts:41-58` never executed (ws: foo)\n"
        "```\n\n"
        "- [ ] real item one\n"
        "- [ ] real item two\n"
    )
    new_text, ticked = backlog._tick_item_text(md, "real item one")
    assert ticked is True
    assert "- [x] real item one\n" in new_text
    assert "- [x] real item two" not in new_text
    # the fenced example must be untouched
    assert "```markdown\n- [ ] Untested:" in new_text


def test_tick_backlog_item_writes_the_file(tmp_path):
    (tmp_path / "backlog").mkdir()
    f = tmp_path / "backlog" / "TODO.md"
    f.write_text("- [ ] ship it\n")
    settings = ProjectSettings()
    ok = main_mod.tick_backlog_item(
        str(tmp_path), "backlog/TODO.md::ship it", settings.backlog_dir, settings.backlog_files
    )
    assert ok is True
    assert f.read_text() == "- [x] ship it\n"


def test_tick_backlog_item_ignores_issue_seed_keys(tmp_path):
    assert main_mod.tick_backlog_item(str(tmp_path), "issue:42") is False


def test_tick_backlog_item_never_raises_on_a_missing_file(tmp_path):
    assert main_mod.tick_backlog_item(str(tmp_path), "backlog/gone.md::x") is False


def test_tick_backlog_item_is_the_same_function_backlog_exposes():
    # main.py aliases onto haro.backlog rather than keeping its own copy — pinned so
    # a future refactor can't quietly fork the two and let a merge path (rungs.py's
    # auto-merge calls haro.backlog directly) drift from the manual merge endpoint's.
    assert main_mod.tick_backlog_item is backlog.tick_backlog_item


# ── get_todo: stage + lock-excludes-merged + orphaned ───────────────────────────
def test_get_todo_reports_stage_and_excludes_merged_from_the_lock(tmp_path):
    (tmp_path / "backlog").mkdir()
    (tmp_path / "backlog" / "TODO.md").write_text("- [ ] ship it\n")
    project = _project(tmp_path)
    main_mod.store.projects[project.id] = project
    ws = _workspace(project, seed_key="backlog/TODO.md::ship it", status=WorkspaceStatus.merged)

    out = asyncio.run(main_mod.get_todo(project.id))
    (item,) = out["files"][0]["items"]
    assert item["stage"] == "shipped"
    # merged is excluded from the lock — the item reads unseeded even though a
    # workspace still exists, so the UI stops treating it as "in progress".
    assert item["seeded_workspace"] is None


def test_get_todo_orphans_a_workspace_whose_item_text_changed(tmp_path):
    (tmp_path / "backlog").mkdir()
    (tmp_path / "backlog" / "TODO.md").write_text("- [ ] a totally different task\n")
    project = _project(tmp_path)
    main_mod.store.projects[project.id] = project
    ws = _workspace(project, seed_key="backlog/TODO.md::the old task text")

    out = asyncio.run(main_mod.get_todo(project.id))
    assert out["orphaned"] == [{"workspace_id": ws.id, "seed_key": ws.seed_key}]


# ── put_todo: C5 rename-remap ────────────────────────────────────────────────────
def test_put_todo_remaps_a_single_rename(tmp_path, monkeypatch):
    (tmp_path / "backlog").mkdir()
    (tmp_path / "backlog" / "TODO.md").write_text("- [ ] old title\n- [ ] untouched\n")
    project = _project(tmp_path)
    main_mod.store.projects[project.id] = project
    ws = _workspace(project, seed_key="backlog/TODO.md::old title")
    saves = []
    monkeypatch.setattr(main_mod.db, "save_snapshot", lambda s: saves.append(s) or asyncio.sleep(0))

    asyncio.run(
        main_mod.put_todo(
            project.id,
            TodoWriteRequest(
                path="backlog/TODO.md",
                content="- [ ] new title\n- [ ] untouched\n",
            ),
        )
    )
    assert ws.seed_key == "backlog/TODO.md::new title"
    # The remap mutates a Workspace field, not the markdown file — it must be
    # persisted, or a restart before the next snapshot silently reverts it.
    assert len(saves) == 1


def test_put_todo_leaves_a_multi_change_edit_unremapped(tmp_path, monkeypatch):
    (tmp_path / "backlog").mkdir()
    (tmp_path / "backlog" / "TODO.md").write_text("- [ ] a\n- [ ] b\n")
    project = _project(tmp_path)
    main_mod.store.projects[project.id] = project
    ws = _workspace(project, seed_key="backlog/TODO.md::a")
    saves = []
    monkeypatch.setattr(main_mod.db, "save_snapshot", lambda s: saves.append(s) or asyncio.sleep(0))

    asyncio.run(
        main_mod.put_todo(
            project.id,
            TodoWriteRequest(path="backlog/TODO.md", content="- [ ] a2\n- [ ] b2\n"),
        )
    )
    assert ws.seed_key == "backlog/TODO.md::a"  # ambiguous (2 renames) — left alone
    assert saves == []  # nothing changed server-side, no snapshot needed


# ── POST /projects/{id}/todo/items: "send to backlog" (Move 3) ─────────────────
def test_add_todo_item_writes_to_the_default_follow_ups_file(tmp_path):
    project = _project(tmp_path)
    main_mod.store.projects[project.id] = project

    out = asyncio.run(
        main_mod.add_todo_item(project.id, TodoItemAppendRequest(title="Untested hunk", evidence="ws: x"))
    )
    assert out == {"ok": True, "path": "backlog/follow-ups.md"}
    text = (tmp_path / "backlog" / "follow-ups.md").read_text()
    assert "- [ ] Untested hunk (ws: x)" in text


def test_add_todo_item_rejects_a_blank_title(tmp_path):
    project = _project(tmp_path)
    main_mod.store.projects[project.id] = project
    with pytest.raises(HTTPException) as exc:
        asyncio.run(main_mod.add_todo_item(project.id, TodoItemAppendRequest(title="   ")))
    assert exc.value.status_code == 400


def test_add_todo_item_404s_on_an_unknown_project():
    with pytest.raises(HTTPException) as exc:
        asyncio.run(main_mod.add_todo_item("does-not-exist", TodoItemAppendRequest(title="x")))
    assert exc.value.status_code == 404


def test_add_todo_item_default_file_respects_a_custom_backlog_dir(tmp_path, monkeypatch):
    # The bug a review caught: the default "backlog/follow-ups.md" was frozen into
    # the request model itself, so a project with `[backlog] dir = "tasks"` 400'd on
    # every "send to backlog" button (nothing under `backlog/` is eligible there).
    project = _project(tmp_path)
    main_mod.store.projects[project.id] = project
    monkeypatch.setattr(main_mod, "load_project_settings", lambda _p: ProjectSettings(backlog_dir="tasks"))

    out = asyncio.run(main_mod.add_todo_item(project.id, TodoItemAppendRequest(title="x")))
    assert out == {"ok": True, "path": "tasks/follow-ups.md"}
    assert (tmp_path / "tasks" / "follow-ups.md").exists()


def test_add_todo_item_explicit_file_still_overrides_the_default(tmp_path):
    project = _project(tmp_path)
    main_mod.store.projects[project.id] = project

    out = asyncio.run(
        main_mod.add_todo_item(project.id, TodoItemAppendRequest(title="x", file="backlog/custom.md"))
    )
    assert out == {"ok": True, "path": "backlog/custom.md"}
