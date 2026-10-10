"""The watch must not register ``node_modules`` and friends with inotify.

A recursive watch on a 48,000-directory bun monorepo took 45s while holding the GIL, so the
backend could not answer ``/health`` at boot and the app gave up waiting for it. The watch
now covers the project's own directories, non-recursively, and re-walks when one appears.
"""

from __future__ import annotations

import asyncio

from watchfiles import Change

from haro import watcher
from haro.models import Project
from haro.store import store

from test_quiescence import FakeHub, clean_store  # noqa: F401


def test_watch_dirs_prunes_ignored_trees(tmp_path):
    for d in ("src/deep", "node_modules/pkg/node_modules/x", "packages/a/node_modules/y",
              ".git/objects", ".venv/lib", "src/__pycache__"):
        (tmp_path / d).mkdir(parents=True)
    got = {p.removeprefix(str(tmp_path)) or "/" for p in watcher._watch_dirs([str(tmp_path)])}
    assert got == {"/", "/src", "/src/deep", "/packages", "/packages/a"}


def test_watch_dirs_covers_every_root(tmp_path):
    (tmp_path / "a" / "x").mkdir(parents=True)
    (tmp_path / "b").mkdir()
    got = watcher._watch_dirs([str(tmp_path / "a"), str(tmp_path / "b")])
    assert got == [str(tmp_path / "a"), str(tmp_path / "a" / "x"), str(tmp_path / "b")]


def test_new_dirs_only_for_new_watchable_directories(tmp_path):
    new = tmp_path / "new"
    new.mkdir()
    (tmp_path / "f.txt").write_text("x")
    ignored = tmp_path / "node_modules" / "p"
    ignored.mkdir(parents=True)
    assert watcher._new_dirs({(Change.added, str(new))}) == [str(new)]
    assert not watcher._new_dirs({(Change.added, str(tmp_path / "f.txt"))})
    assert not watcher._new_dirs({(Change.modified, str(new))})
    assert not watcher._new_dirs({(Change.added, str(ignored))})


def test_files_in_new_dirs_skips_ignored_trees_and_noise(tmp_path):
    new = tmp_path / "new"
    (new / "sub").mkdir(parents=True)
    (new / "node_modules" / "p").mkdir(parents=True)
    (new / "a.md").write_text("a")
    (new / "sub" / "b.md").write_text("b")
    (new / "node_modules" / "p" / "c.js").write_text("c")
    (new / "mod.pyc").write_text("x")
    got = watcher._files_in([str(new)])
    assert got == {(Change.added, str(new / "a.md")), (Change.added, str(new / "sub" / "b.md"))}


def test_a_directory_made_after_start_is_watched(clean_store, tmp_path, monkeypatch):  # noqa: F811
    """A directory and its file created in one burst, while running: the file raises no event
    of its own (it existed before the watch on its directory did), so it is reported from the
    walk of the new directory."""
    monkeypatch.setattr(watcher.settings, "worktree_root", str(tmp_path / "wt"))
    repo = tmp_path / "repo"
    (repo / "node_modules" / "pkg").mkdir(parents=True)
    proj = Project(name="demo", path=str(repo), default_branch="main")
    store.add_project(proj)

    async def go():
        hub = FakeHub()
        task = asyncio.create_task(watcher.watch_forever(hub))
        try:
            await asyncio.sleep(0.7)
            (repo / "docs").mkdir()
            (repo / "docs" / "todo-ideas.md").write_text("seen")
            for _ in range(40):
                if hub.broadcast:
                    break
                await asyncio.sleep(0.25)
            return hub.broadcast
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    got = asyncio.run(go())
    assert {"channel": "notify", "kind": "backlog_changed", "project_id": proj.id} in got


def test_recursive_watch_never_walks_the_tree(clean_store, tmp_path, monkeypatch):  # noqa: F811
    """On FSEvents the roots are armed as they are: walking and arming every directory
    froze the backend on a few thousand of them."""
    monkeypatch.setattr(watcher.settings, "worktree_root", str(tmp_path / "wt"))
    monkeypatch.setattr(watcher, "_RECURSIVE_WATCH", True)

    def no_walk(_roots):
        raise AssertionError("the tree was walked")

    monkeypatch.setattr(watcher, "_watch_dirs", no_walk)
    repo = tmp_path / "repo"
    repo.mkdir()
    proj = Project(name="demo", path=str(repo), default_branch="main")
    store.add_project(proj)

    async def go():
        hub = FakeHub()
        task = asyncio.create_task(watcher.watch_forever(hub))
        try:
            await asyncio.sleep(0.7)
            (repo / "docs").mkdir()
            (repo / "docs" / "todo-ideas.md").write_text("seen")
            for _ in range(40):
                if hub.broadcast:
                    break
                await asyncio.sleep(0.25)
            return hub.broadcast, task.done()
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    got, died = asyncio.run(go())
    assert not died
    assert {"channel": "notify", "kind": "backlog_changed", "project_id": proj.id} in got
