"""Unit tests for ``gate.ensure_deps`` — the node_modules symlink stopgap.

The guarantee under test (backlog/merge-firewall.md §2, "respect the foreign
tool's own install"): ``ensure_deps`` NEVER clobbers an existing ``node_modules``
*install* with the project-root symlink. A real install dir, a live symlink, or
even a *dangling* symlink a foreign tool left behind is treated as "already
provisioned, hands off" and returns a silent no-op (None).

The second half (backlog/gate.md) is the counterweight: "exists" is not
"provisioned". An agent running ``npx vitest`` makes vitest write
``node_modules/.vite/…``, which creates ``node_modules`` as a real directory with
no packages in it — and being read as provisioned, that quietly cancelled the
symlink for the rest of the worktree's life, which is how the coverage guard ended
up measuring nothing on a green gate. A package-less directory is a build cache,
so it gets cleared and symlinked.
"""

from __future__ import annotations

import os
from pathlib import Path

from haro.gate import ensure_deps


def _project_with_node_modules(tmp_path: Path) -> Path:
    proj = tmp_path / "project"
    (proj / "node_modules" / "vitest").mkdir(parents=True)
    return proj


def test_noop_when_worktree_has_real_node_modules(tmp_path):
    """A foreign tool's genuine install is left untouched — no symlink, no note."""
    proj = _project_with_node_modules(tmp_path)
    wt = tmp_path / "worktree"
    own = wt / "node_modules" / "left-pad"
    own.mkdir(parents=True)

    assert ensure_deps(str(wt), str(proj)) is None
    # The foreign install is intact and NOT a symlink to the project root.
    assert not (wt / "node_modules").is_symlink()
    assert own.exists()


def test_noop_when_worktree_has_dangling_symlink(tmp_path):
    """A foreign node_modules *symlink* whose target moved must still be respected.

    ``Path.exists()`` follows the link and reports False, so an ``exists()``-only
    guard would try to re-symlink and hit ``FileExistsError`` — a cry-wolf
    ``setup`` failure on a worktree that was, in fact, already provisioned.
    """
    proj = _project_with_node_modules(tmp_path)
    wt = tmp_path / "worktree"
    wt.mkdir()
    link = wt / "node_modules"
    os.symlink(tmp_path / "gone", link, target_is_directory=True)
    assert link.is_symlink() and not link.exists()  # dangling, as set up

    assert ensure_deps(str(wt), str(proj)) is None
    # Untouched: still the foreign tool's own (dangling) link, not our project link.
    assert os.readlink(link) == str(tmp_path / "gone")


def test_symlinks_when_worktree_is_dependency_less(tmp_path):
    """The stopgap still fires for a genuinely empty worktree (managed create path)."""
    proj = _project_with_node_modules(tmp_path)
    wt = tmp_path / "worktree"
    wt.mkdir()

    note = ensure_deps(str(wt), str(proj))
    assert note == "symlinked node_modules from project root"
    assert (wt / "node_modules").is_symlink()
    assert (wt / "node_modules" / "vitest").exists()


def test_reports_when_project_has_no_node_modules(tmp_path):
    """Nothing to symlink and nothing in the worktree → the diagnosable hint."""
    proj = tmp_path / "project"
    proj.mkdir()
    wt = tmp_path / "worktree"
    wt.mkdir()

    note = ensure_deps(str(wt), str(proj))
    assert note is not None and note.startswith("project has no node_modules")


# --- "exists" is not "provisioned" (backlog/gate.md) ------------------------ #


def test_a_package_less_node_modules_still_gets_the_symlink(tmp_path):
    """THE hole: ``npx vitest`` creates node_modules just by writing its build cache, and
    that was enough to read as provisioned — after which nothing in the worktree could
    resolve ``@vitest/coverage-v8`` and the coverage guard measured nothing, forever."""
    proj = _project_with_node_modules(tmp_path)
    wt = tmp_path / "worktree"
    (wt / "node_modules" / ".vite" / "vitest").mkdir(parents=True)  # what npx vitest leaves

    note = ensure_deps(str(wt), str(proj))
    assert note is not None and note.startswith("symlinked node_modules from project root")
    assert "cache" in note  # the note says the cache dir was cleared, not silently removed
    assert (wt / "node_modules").is_symlink()
    assert (wt / "node_modules" / "vitest").exists()  # deps resolve again


def test_a_dot_bin_only_node_modules_counts_as_a_real_install(tmp_path):
    """``.bin`` is written by every real install, so it's the cheap "this is provisioned"
    signal even when the package dirs live somewhere unusual (pnpm's store, a partial tree)."""
    proj = _project_with_node_modules(tmp_path)
    wt = tmp_path / "worktree"
    (wt / "node_modules" / ".bin").mkdir(parents=True)

    assert ensure_deps(str(wt), str(proj)) is None
    assert not (wt / "node_modules").is_symlink()


def test_a_cache_dir_is_never_cleared_without_something_better_to_offer(tmp_path):
    """The destructive step only happens when the project actually has packages to link.
    Otherwise we report the hint and leave the worktree exactly as we found it."""
    proj = tmp_path / "project"
    (proj / "node_modules" / ".vite").mkdir(parents=True)  # the project root has a cache too
    wt = tmp_path / "worktree"
    (wt / "node_modules" / ".vite").mkdir(parents=True)

    note = ensure_deps(str(wt), str(proj))
    assert note is not None and note.startswith("project has no node_modules")
    assert (wt / "node_modules" / ".vite").exists()  # untouched
    assert not (wt / "node_modules").is_symlink()
