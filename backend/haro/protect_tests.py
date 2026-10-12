"""Protected tests, the honest version: deny rules for the agent's edit tools.

``[agent] protect_tests = "existing"`` (or the per-run toggle) hands the agent CLI deny
rules for every test file tracked at ``base_ref``. Verified against the installed CLI
(notes/claude-code-stream-json.md section 12): deny rules still apply under
``--permission-mode bypassPermissions``, so an Edit/Write on a protected file is refused.

This is a speed bump, never a guarantee. The agent has a shell, and ``sed -i`` or
``echo >>`` writes any file. The tamper alarm on the diff (``tamper.py``) is what actually
catches a weakened suite; the protection only removes the easy path so a bypass has to be
deliberate. Nothing here or in the UI may call the tests "read-only".

Rule shapes (all verified against the real CLI):
  * Explicit paths are anchored with a leading ``/``. Unanchored, a slash-less root path
    like ``a.test.ts`` matches at any depth and would also refuse a NEW ``sub/a.test.ts``.
    Anchored, new test files stay writable.
  * Past ``MAX_EXPLICIT_PATHS`` files (2000 rules ran fine through the CLI) the list
    collapses to FILENAME-pattern globs (``**/*.test.ts``, ``**/test_*.py``...), which also
    refuse new files of that shape. Never directory globs: ``pkg/**`` would deny source edits.
    A glob is only used if it matches no tracked non-test file; leftovers stay explicit.
"""

from __future__ import annotations

import fnmatch
import re
from typing import Callable, Iterable

from . import git_ops
from .tamper import is_test_file

MAX_EXPLICIT_PATHS = 500

_META_RE = re.compile(r"([\\*?\[\]()])")
_JS_RE = re.compile(r"\.(test|spec)(\.[cm]?[jt]sx?)$")
_PY_PREFIX_RE = re.compile(r"^test_.*\.py$")
_PY_SUFFIX_RE = re.compile(r"_test\.py$")
_TESTS_DIR_GLOB = "**/__tests__/**"


def escape_glob(path: str) -> str:
    """Backslash-escape glob metacharacters and parens (a Next.js ``(group)`` or
    ``[id]`` directory would otherwise be read as a pattern / break the rule syntax).
    A leading ``!`` (negation) is escaped too; the anchor makes that moot for explicit
    paths, but the function stands alone."""
    out = _META_RE.sub(r"\\\1", path)
    return "\\" + out if out.startswith("!") else out


def _anchored(path: str) -> str:
    return "/" + escape_glob(path)


def _shape(path: str) -> str | None:
    """The filename-pattern glob this test file's shape fits, or None."""
    if "/__tests__/" in f"/{path}":
        return _TESTS_DIR_GLOB
    base = path.rpartition("/")[2]
    m = _JS_RE.search(base)
    if m:
        return f"**/*.{m.group(1)}{m.group(2)}"
    if _PY_PREFIX_RE.match(base):
        return "**/test_*.py"
    if _PY_SUFFIX_RE.search(base):
        return "**/*_test.py"
    return None


def _glob_matches(glob: str, path: str) -> bool:
    if glob == _TESTS_DIR_GLOB:
        return "/__tests__/" in f"/{path}"
    return fnmatch.fnmatchcase(path.rpartition("/")[2], glob.rpartition("/")[2])


def protected_patterns(
    tracked: Iterable[str],
    is_test: Callable[[str], bool] = is_test_file,
    max_explicit: int | None = None,
) -> list[str]:
    """Deny-rule path patterns for the test files among ``tracked`` (repo-relative,
    forward slashes): anchored explicit paths while there are few enough, else
    filename-pattern globs plus anchored explicit leftovers."""
    files = sorted(set(tracked))
    tests = [p for p in files if is_test(p)]
    limit = MAX_EXPLICIT_PATHS if max_explicit is None else max_explicit
    if len(tests) <= limit:
        return [_anchored(p) for p in tests]
    non_tests = [p for p in files if not is_test(p)]
    candidates = {g for p in tests if (g := _shape(p))}
    globs = {g for g in candidates if not any(_glob_matches(g, n) for n in non_tests)}
    leftovers = [p for p in tests if not any(_glob_matches(g, p) for g in globs)]
    return sorted(globs) + [_anchored(p) for p in leftovers]


async def deny_patterns_at(worktree_path: str, base_ref: str) -> list[str]:
    """The protected patterns for the tests that exist at ``base_ref``. Raises
    ``git_ops.GitError`` when the ref can't be read (the caller refuses the run rather
    than claiming protection it doesn't have)."""
    return protected_patterns(await git_ops.list_files_at(worktree_path, base_ref))


def runs_protected(runs: Iterable) -> bool:
    """True when every editing (non-plan) run carried protection and there was at least
    one. A single unprotected run means the claim would be false for the diff."""
    editing = [r for r in runs if not getattr(r, "plan", False)]
    return bool(editing) and all(getattr(r, "protect_tests", False) for r in editing)
