"""Test-tamper alarm — "did the *same* tests pass?", the sibling of ``blame.py``.

The gate's whole promise is "trust the green". The cheapest way an agent fakes a
green gate is to weaken the suite it's judged by: delete a test, slap ``.skip`` /
``.only`` on one, gut an ``expect()``, or wholesale-rewrite a snapshot. Every other
gate signal (coverage delta, impact map, autonomy rungs) stands on the suite, so a
single ``it.skip`` games them all. This module turns a suspicious green into
``green*`` by classifying *how* the suite changed vs ``base_ref``.

Pure functions only (no IO), exactly like ``blame.py`` — the caller (``gate.run_gate``)
supplies the unified diff text (from ``git_ops.diff``) and two test inventories
(base vs worktree, from ``VitestAdapter._list``). That keeps the make-or-break
matching logic unit-testable, including the legit-refactor negatives (a rename or a
file move must yield *zero* findings — the judges were unanimous that a chip that
cries wolf destroys the trust it exists to build).

The signals, from strongest to noisiest:
  * **removed** — a test in the base inventory that's gone from the worktree, *after*
    rename-aware matching pairs it against an added test (exact → same-name-in-renamed-
    file → same-name-anywhere → fuzzy same-file). Only truly-unmatched removals count.
  * **skip / only / todo** — a test modifier *added* by the diff (net of any removed),
    where ``.only`` is the quiet killer: it silently shrinks the run to itself.
  * **assertions** — a changed test file that *lost* net ``expect(`` calls.
  * **snapshot** — the share of the diff that is ``.snap`` / inline-snapshot churn.
  * **xfail**: pytest's ``xfail`` / ``expectedFailure``: the test still runs but a failure
    no longer fails the gate, so it is a skip in everything but name.
  * **weakened**: an assertion whose subject is unchanged but whose matcher went from strict
    to loose (``toBe(2)`` to ``toBeTruthy()``, ``assert x == y`` to ``assert x``). Pairing is
    one-for-one per subject within a hunk, so a legit refactor that changes the subject or
    adds a second strict assertion stays silent.
  * **timeout**: a per-test, config or ``pytest.mark.timeout`` limit added or raised (never
    lowered): the cheapest way to make a slow or hanging test stop failing.

Python suites are read from the diff alone (``def test_*`` lines), because the base/worktree
inventories come from ``vitest list``; see :func:`python_removed_tests`.

One more signal, added round 3 (usp-critique-round3.md Move C), sits outside the diff
alone. It IS a real finding, folded into ``findings`` exactly like the ones above, so it
reaches ``green*``, ``tamper_blocked`` under ``block`` mode, and
``trust.no_tamper``/the autonomy-ladder streak. It is not proof of deliberate gaming
the way an unmatched test removal is (a legitimate config edit looks identical from here),
which is why its ``detail`` text reads as "look at this", not "this was gamed" — but the
whole point of a round-3 signal is that the 2026 evidence (SpecBench, Trail of Bits) says
an agent CAN weaken the suite this way, so the finding still has to be able to stop a
merge under ``block`` mode. Do not route it through :attr:`TamperReport.rewrites` (below)
to "soften" it — that attribute exists for a specific proven-safe case, not a general
advisory lane.
  * **config** — a diff touching a file that decides *which tests run*
    (``vitest.config.*``/``vite.config.*``'s ``test:`` block/``vitest.workspace.*``,
    ``pytest.ini``, ``pyproject.toml``'s pytest section, a ``package.json`` test
    script, husky/``.githooks``, ``.claude/settings*.json``, ``.vscode/tasks.json``).
    See :func:`config_tamper`. Line-based, no AST: it catches an edit to a KEYED
    line (``exclude: […]`` rewritten in place, a ``test: {`` block added/removed)
    but not a bare array element added deep inside an existing multi-line literal
    without repeating the key — an accepted trade-off, not a silent gap (see
    ``_VITE_CONFIG_TEST_BLOCK_RE``'s comment and its own test).

**Vacuous is NOT a tamper signal** (decision 2026-09-30). A genuinely NEW test that already
passes at ``base_ref`` (computed by :func:`gate._red_first_check`, not here, since it needs to
actually run the test — this module stays pure/no-IO; see :func:`added_tests` for the
population) leaves the suite exactly as strong as it was: tampering means the suite got
WEAKER, and a legitimate negative-case test ("weekdays add nothing") passes at base by
design. So it never enters ``findings``/``note``: ``gate.run_gate`` routes each one to the
advisory "code to check" pane as a ``vacuous_test`` row (``unchecked.vacuous_items``), which
can never block a merge in any mode.

One deliberate non-signal sits beside them: :func:`rewritten_tests`. The four above answer
*"does this test still exist?"*, never *"does it still assert the same thing"*, so a base
test that is retitled **and** re-asserted in place is silent — the fuzzy tier pairs the
retitle, and rewriting one assertion into another drops no ``expect(`` count. Measured live
(``notes/e2e-gate-test-plan.md`` §8.8): an agent turned ``expect(mean([])).toBe(0)`` into
``expect(() => mean([])).toThrow(…)`` under a new title and the alarm reported zero findings,
so ``no_tamper`` read "suite intact" while the base contract was asserted nowhere. The fix is
NOT to make that a finding: a retitle-plus-re-assert is also exactly what a deliberate
contract change looks like, and promoting it would put the chip on honest work — the one
kill condition the judges were unanimous about. So it is reported as a **separate, softer
fact** on :attr:`TamperReport.rewrites`, never in ``findings`` and never in the ``note``.
It cannot reach ``green*``, ``tamper_blocked``, ``trust.no_tamper`` or the streak — by
construction, not by every consumer remembering to filter it. ``gate.run_gate`` routes it to
the advisory "code to check" pane instead (``unchecked.py``), which is the right surface for
the same reason: the tamper chip only renders when there ARE findings, and the whole point of
this gap is that there are none.

Then :func:`reconcile` folds the overlaps, because the signals are not independent
observers of independent facts — they are four views of one diff, and ``vitest list``
reports what *would run*, not what exists. One ``.skip`` therefore shows up twice
(a modifier AND a vanished test) and one ``.only`` makes every *other* test in its
file vanish; unreconciled, the chip's severity would scale with the number of
detectors rather than the amount of tampering. Reconciliation is a false-positive
defence, so it only ever *merges* findings — it can't hide a file the alarm already
decided to flag. Both rules were written from a live E2E run on the ``haro-test``
sandbox (``notes/e2e-gate-test-plan.md`` Phase 7), which is also where the whole-file
exclusion in :func:`assertion_deltas` came from.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from difflib import SequenceMatcher

from .adapters.test_runner.base import TestRef

# --- tunables -----------------------------------------------------------------
# How similar two test names must be to count as an in-place rename ("adds two
# numbers" → "adds 2 numbers"), not a deletion + a new test. High on purpose:
# fuzzy matching only exists to suppress false "removed" alarms, never to find them.
_FUZZY_THRESHOLD = 0.8

# Flag snapshot churn only when it dominates a diff that's big enough to mean
# something — a 3-line snapshot tweak isn't "the diff is all snapshot rewrites".
_SNAPSHOT_CHURN_THRESHOLD = 0.5
_SNAPSHOT_MIN_LINES = 10

# Vitest/jest test files: ``*.test.ts`` / ``*.spec.tsx`` / anything under ``__tests__/``.
_JS_TEST_FILE_RE = re.compile(r"(?:\.(?:test|spec)\.[cm]?[jt]sx?$)|(?:^|/)__tests__/")
# pytest's default collection: ``test_*.py`` / ``*_test.py``. Helpers under ``tests/`` are not
# collected, so deleting a ``def test_*`` from one is not a removed test. ``conftest.py`` is
# config (see ``_ALWAYS_CONFIG_RE``).
_PY_TEST_FILE_RE = re.compile(r"(?:(?:^|/)test_[^/]*\.py$)|(?:_test\.py$)")
_PY_NOT_TEST_RE = re.compile(r"(?:^|/)(?:conftest|__init__)\.py$")

# Config files that decide WHICH tests run — usp-critique-round3.md Move C. An agent
# can turn a gate green by editing these without touching a single test file (widen
# a vitest exclude glob, gut a pytest.ini, retarget a package.json test script). These
# are entirely test config, so ANY change to them is worth naming. `.husky`/`.githooks`
# use `.+` (not `[^/]+`) since real husky trees nest a level deeper (`.husky/_/husky.sh`).
_ALWAYS_CONFIG_RE = re.compile(
    r"(?:^|/)(?:"
    r"vitest\.config\.[cm]?[jt]s"
    r"|vitest\.workspace\.[cm]?[jt]s"
    r"|pytest\.ini"
    r"|conftest\.py"
    r"|\.husky/.+"
    r"|\.githooks/.+"
    r"|\.claude/settings[^/]*\.json"
    r"|\.vscode/tasks\.json"
    r")$"
)
# vite.config.* / pyproject.toml / package.json carry a lot of unrelated content
# (build config, deps, other tools' config) — flagging every touch would cry wolf on
# routine changes, so these three are conditional on the ADDED/REMOVED lines actually
# looking test-config-shaped. vite.config.* matters because Vitest reads its config
# from a `test:` block INSIDE vite.config.* by default — a separate vitest.config.*
# is the opt-out, not the common case — so this is not an edge case to skip.
_VITE_CONFIG_RE = re.compile(r"(?:^|/)vite\.config\.[cm]?[jt]s$")
# Matched against ADDED/REMOVED lines only (no AST, no full-file read — this module
# stays pure/no-IO), so this catches an edit that touches the KEY line itself
# (`exclude: […]` rewritten on one line, `test: {` block added/removed) but NOT one
# that only adds a bare array element deep inside an existing multi-line literal
# without repeating the key (code review round-3: confirmed gap, not silently assumed
# fixed). Widened past the bare `test:` block header to vitest's own option keys —
# `exclude`/`include` in particular are exactly the exclude-glob-widening attack
# config_tamper exists to catch, and those are usually one-line edits in practice.
_VITE_CONFIG_TEST_BLOCK_RE = re.compile(
    r"\btest\s*:"
    r"|\bexclude\s*:"
    r"|\binclude\s*:"
    r"|\bcoverage\s*:"
    r"|\bsetupFiles\s*:"
    r"|\benvironment\s*:"
    r"|\btestTimeout\s*:"
    r"|\bglobals\s*:"
    r"|\bpoolOptions\s*:"
)
_PYPROJECT_RE = re.compile(r"(?:^|/)pyproject\.toml$")
_PACKAGE_JSON_RE = re.compile(r"(?:^|/)package\.json$")
_PYPROJECT_PYTEST_RE = re.compile(
    r"\[tool\.pytest|testpaths|pythonpath|python_files|python_classes|python_functions"
    r"|addopts|norecursedirs|xfail_strict|filterwarnings",
    re.IGNORECASE,
)
# tox.ini / setup.cfg carry other tools' sections too, so only a pytest-shaped line counts.
_INI_CONFIG_RE = re.compile(r"(?:^|/)(?:tox\.ini|setup\.cfg)$")
_INI_PYTEST_RE = re.compile(
    r"\[pytest\]|\[tool:pytest\]|testpaths|python_files|addopts|norecursedirs|xfail_strict"
    r"|filterwarnings|--deselect|--ignore",
    re.IGNORECASE,
)
# Matches a `"scripts"`-shaped JSON entry whose KEY starts with test/pretest/posttest
# — checked in `_is_test_script_line` against the VALUE too, so a dependency like
# `"testcontainers": "^1.0.0"` or `"test-utils": "~2.0"` (key matches, but the value
# is a version spec, not a command) doesn't false-positive on every routine bump.
_PACKAGE_JSON_TEST_KEY_RE = re.compile(r'"((?:pre|post)?test[a-z0-9:_-]*)"\s*:\s*"([^"]*)"')
_TEST_RUNNER_PREFIXES = (
    "vitest", "jest", "mocha", "pytest", "ava", "tap", "cypress", "playwright", "node",
)


def _is_test_script_line(line: str) -> bool:
    m = _PACKAGE_JSON_TEST_KEY_RE.search(line)
    if not m:
        return False
    value = m.group(2).strip()
    if not value:
        return False
    # A shell command almost always has a space (`"vitest run"`, `"npm run lint"`);
    # a dependency's version spec never does (`"^1.0.0"`, `"workspace:*"`). A bare
    # runner name with no args (`"test": "jest"`) is still a valid script value.
    return " " in value or value.lower().startswith(_TEST_RUNNER_PREFIXES)

# A test modifier added to a test declaration: ``it.skip(`` / ``describe.only(`` / …
# The dangerous trio the spec calls out; ``.only`` shrinks the run silently.
_MODIFIER_RE = re.compile(r"\b(?:it|test|describe|bench|suite)\s*\.\s*(skip|only|todo)\b")

# The quoted title following a modifier, when there is one: ``.skip('does x'``.
_TITLE_RE = re.compile(r"\.(?:skip|only|todo)\s*\(\s*(['\"`])(.*?)\1")

_EXPECT_RE = re.compile(r"\bexpect\s*\(")
_SNAPSHOT_ASSERT_RE = re.compile(r"toMatch(?:Inline)?Snapshot")

# Any test/suite declaration with a literal title, modifiers and chained helpers included
# (``it(``, ``it.skip(``, ``describe.each(…)(`` won't match its title and is fine to miss).
# Used only to attribute assertion lines to the test they sit under, never to raise a finding.
_DECL_RE = re.compile(
    r"\b(?:it|test|describe|bench|suite)\s*(?:\.\s*\w+\s*)*\(\s*(['\"`])(.*?)\1"
)


@dataclass
class TamperFinding:
    """One suspicious change to the test suite. ``file``/``test`` locate it; ``detail``
    is the human one-liner ("``.only`` added", "3 fewer expect() calls")."""

    kind: str  # removed | skip | xfail | only | todo | weakened | assertions | timeout | snapshot | config | acceptance_changed | acceptance_missing
    file: str
    detail: str
    test: str | None = None


@dataclass
class TamperReport:
    findings: list[TamperFinding] = field(default_factory=list)
    note: str | None = None  # the compact chip line, or None when clean
    #: Retitled-and-re-asserted base tests (``kind="rewritten"``) — a separate, softer fact,
    #: NOT part of the ``green*`` verdict. Kept off ``findings`` on purpose so it cannot reach
    #: the chip, ``tamper_blocked``, ``trust.no_tamper`` or the streak through any consumer
    #: that forgot to filter. ``gate.run_gate`` routes it to the "code to check" pane.
    rewrites: list[TamperFinding] = field(default_factory=list)


@dataclass
class Hunk:
    """One ``@@`` block as its two *sides*, each in file order with context lines kept.

    The flat ``FileDiff.added``/``removed`` lists are enough to count things, but not to say
    *which test* a changed line belongs to: they drop the unchanged declaration lines between
    hunks, so a title changed in hunk 1 would silently adopt an assertion changed in hunk 3.
    Keeping the sides intact bounds that attribution to one hunk, with its context lines
    available to close a test off. Only :func:`rewritten_tests` reads this.
    """

    old: list[str] = field(default_factory=list)  # context + removed, in order
    new: list[str] = field(default_factory=list)  # context + added, in order


@dataclass
class FileDiff:
    """One file's slice of a unified diff, reduced to what the signals need."""

    old_path: str | None  # None when the file was added (``/dev/null`` old side)
    new_path: str | None  # None when the file was deleted
    added: list[str] = field(default_factory=list)  # added line bodies (no leading +)
    removed: list[str] = field(default_factory=list)  # removed line bodies (no leading -)
    is_rename: bool = False
    hunks: list[Hunk] = field(default_factory=list)

    @property
    def path(self) -> str | None:
        """The file's identity for reporting — its current path, else its old one."""
        return self.new_path or self.old_path


def _strip_ab(path: str) -> str:
    """Drop git's ``a/`` / ``b/`` diff prefix."""
    if path.startswith(("a/", "b/")):
        return path[2:]
    return path


def is_python_test_file(path: str | None) -> bool:
    if not path:
        return False
    p = path.replace("\\", "/")
    return bool(_PY_TEST_FILE_RE.search(p)) and not _PY_NOT_TEST_RE.search(p)


def is_test_file(path: str | None) -> bool:
    if not path:
        return False
    return bool(_JS_TEST_FILE_RE.search(path.replace("\\", "/"))) or is_python_test_file(path)


def parse_file_diffs(diff_text: str) -> list[FileDiff]:
    """Split a unified diff into per-file slices.

    Reads the reliable headers (``rename from``/``rename to`` for renames,
    ``---``/``+++`` for content changes) rather than the ambiguous ``diff --git``
    line, which can't be parsed unambiguously when a path contains spaces.

    Path headers are only read *before* the file's first ``@@``: inside a hunk, a removed
    source line that happens to start with ``--- `` is content, not a header, and letting it
    through would blank the file's path and take every path-keyed signal down with it.
    """
    files: list[FileDiff] = []
    cur: FileDiff | None = None
    hunk: Hunk | None = None
    for line in diff_text.splitlines():
        if line.startswith("diff --git "):
            cur = FileDiff(old_path=None, new_path=None)
            files.append(cur)
            hunk = None
        elif cur is None:
            continue
        elif line.startswith("rename from ") and hunk is None:
            cur.old_path = line[len("rename from "):].strip()
            cur.is_rename = True
        elif line.startswith("rename to ") and hunk is None:
            cur.new_path = line[len("rename to "):].strip()
            cur.is_rename = True
        elif line.startswith("--- ") and hunk is None:
            p = line[4:].strip()
            cur.old_path = None if p == "/dev/null" else _strip_ab(p)
        elif line.startswith("+++ ") and hunk is None:
            p = line[4:].strip()
            cur.new_path = None if p == "/dev/null" else _strip_ab(p)
        elif line.startswith("@@"):
            hunk = Hunk()
            cur.hunks.append(hunk)
        elif line.startswith("+"):
            cur.added.append(line[1:])
            if hunk is not None:
                hunk.new.append(line[1:])
        elif line.startswith("-"):
            cur.removed.append(line[1:])
            if hunk is not None:
                hunk.old.append(line[1:])
        elif hunk is not None and not line.startswith("\\"):
            # A context line — unchanged, so it belongs to both sides ("\ No newline at end
            # of file" is diff bookkeeping and belongs to neither).
            hunk.old.append(line[1:] if line.startswith(" ") else line)
            hunk.new.append(line[1:] if line.startswith(" ") else line)
    return files


def rename_map(file_diffs: list[FileDiff]) -> dict[str, str]:
    """``{old_path: new_path}`` for every file the diff moved or renamed."""
    out: dict[str, str] = {}
    for fd in file_diffs:
        if fd.old_path and fd.new_path and fd.old_path != fd.new_path:
            out[fd.old_path] = fd.new_path
    return out


def _extract_title(line: str) -> str | None:
    m = _TITLE_RE.search(line)
    return m.group(2) if m else None


def _similar(a: str, b: str) -> bool:
    return SequenceMatcher(None, a, b).ratio() >= _FUZZY_THRESHOLD


def _find_match(
    r: TestRef, added: list[TestRef], used: list[bool], renames: dict[str, str]
) -> tuple[int, int] | None:
    """``(index, tier)`` of the first unused added test that ``r`` could be, tightest first.

    Tiers, in order (a looser tier only fires when every tighter one missed):
      1. same name, in the file ``r``'s file was renamed *to*   (git-detected move)
      2. same name, in *any* file          (consolidation / a move git didn't flag)
      3. fuzzy name, in ``r``'s file or its rename target       (in-place retitle)

    The tier is returned, not just the index, because tier 3 is the only one that changed a
    test's *title* — and a changed title beside a changed assertion is the pair
    :func:`rewritten_tests` reports. Tiers 1 and 2 kept the name verbatim, so a body edit
    there is an ordinary test fix and stays out of it.
    """
    target = renames.get(r.file)
    for i, a in enumerate(added):  # tier 1
        if not used[i] and a.name == r.name and target is not None and a.file == target:
            return i, 1
    for i, a in enumerate(added):  # tier 2
        if not used[i] and a.name == r.name:
            return i, 2
    for i, a in enumerate(added):  # tier 3
        if used[i]:
            continue
        same_file = a.file == r.file or (target is not None and a.file == target)
        if same_file and _similar(a.name, r.name):
            return i, 3
    return None


def pair_removals(
    base_inventory: list[TestRef],
    worktree_inventory: list[TestRef],
    renames: dict[str, str],
) -> tuple[list[TestRef], list[tuple[TestRef, TestRef]]]:
    """Run the rename-aware matching once and return both halves of its answer:
    ``(unmatched, retitled)`` — the base tests nothing explains, and the base→worktree pairs
    that matched only by fuzzy title (tier 3).

    One pass, two readers: matching consumes each added test at most once, so ``removed_tests``
    and ``rewritten_tests`` have to agree about who paired with whom or the same edit could be
    counted as both a removal and a retitle.
    """
    wt_keys = {(t.file, t.name) for t in worktree_inventory}
    base_keys = {(t.file, t.name) for t in base_inventory}
    removed = [t for t in base_inventory if (t.file, t.name) not in wt_keys]
    added = [t for t in worktree_inventory if (t.file, t.name) not in base_keys]
    used = [False] * len(added)
    unmatched: list[TestRef] = []
    retitled: list[tuple[TestRef, TestRef]] = []
    for r in removed:
        m = _find_match(r, added, used, renames)
        if m is None:
            unmatched.append(r)
            continue
        idx, tier = m
        used[idx] = True
        if tier == 3:
            retitled.append((r, added[idx]))
    return unmatched, retitled


def removed_tests(
    base_inventory: list[TestRef],
    worktree_inventory: list[TestRef],
    renames: dict[str, str],
) -> list[TamperFinding]:
    """Tests present at ``base_ref`` but gone from the worktree, after rename-aware
    matching consumes every removal explainable as a move/rename/retitle."""
    unmatched, _ = pair_removals(base_inventory, worktree_inventory, renames)
    return [
        TamperFinding(kind="removed", file=r.file, test=r.name, detail="test removed")
        for r in unmatched
    ]


def _assertion_text(line: str) -> str | None:
    """The assertion part of a line — from ``expect`` to the end, whitespace collapsed.

    Starting at ``expect`` and not at the line start is what makes a one-liner test
    comparable: ``it("adds 2", () => expect(add(1,1)).toBe(2))`` retitled to ``"adds two"``
    changes the line but not this, so a pure retitle stays silent.
    """
    m = _EXPECT_RE.search(line)
    return " ".join(line[m.start():].split()) if m else None


def _assertions_by_title(lines: list[str]) -> dict[str, list[str]]:
    """``{test title: [its assertion texts]}`` for one side of one hunk.

    Attribution is positional (an assertion belongs to the nearest declaration above it),
    which is why context lines are kept: an unchanged ``it(…)`` between two changed ones has
    to be able to close the previous test off. Assertions with no declaration above them in
    the hunk are dropped rather than guessed at — unattributable evidence stays silent.
    """
    out: dict[str, list[str]] = {}
    title: str | None = None
    for line in lines:
        d = _DECL_RE.search(line)
        if d is not None:
            title = d.group(2)
            out.setdefault(title, [])
        a = _assertion_text(line)
        if a is not None and title is not None:
            out[title].append(a)
    return out


def _leaf(name: str) -> str:
    """A ``TestRef`` name's own title, without its describe path."""
    return _segments(name)[-1]


def rewritten_tests(
    file_diffs: list[FileDiff], retitled: list[tuple[TestRef, TestRef]]
) -> list[TamperFinding]:
    """Base tests that were retitled **and** re-asserted in place — the ``rewrites`` list.

    Deliberately NOT a tamper finding (see the module docstring): this is the shape both a
    quietly-dropped contract and an honest contract change take, so it is reported as a fact
    to read, never as a verdict. Advisory status is what lets it be reported at all.

    Both halves are required. A retitle whose assertions the diff never touched yields nothing
    (the legit rename refactor the alarm promises to stay quiet on), and a body edit under an
    unchanged title never reaches here because it isn't in ``retitled``. Comparison is on the
    multiset of assertion texts, so reordering two ``expect(`` calls is not a change.
    """
    sides: dict[str, list[tuple[dict[str, list[str]], dict[str, list[str]]]]] = {}
    for fd in file_diffs:
        if not is_test_file(fd.path) or fd.old_path is None or fd.new_path is None:
            continue
        per_hunk = [(_assertions_by_title(h.old), _assertions_by_title(h.new)) for h in fd.hunks]
        for key in {fd.old_path, fd.new_path}:  # findable from either side of a rename
            sides[key] = per_hunk

    findings: list[TamperFinding] = []
    for old, new in retitled:
        for was_by_title, now_by_title in sides.get(new.file) or sides.get(old.file) or []:
            was = was_by_title.get(_leaf(old.name))
            now = now_by_title.get(_leaf(new.name))
            if was is None or now is None:
                continue  # this hunk doesn't hold both sides of the retitle
            if sorted(was) == sorted(now):
                continue  # title-only change, or the assertions came back identical
            findings.append(
                TamperFinding(
                    kind="rewritten",
                    file=new.file,
                    test=new.name,
                    detail=f'retitled and re-asserted (was "{_leaf(old.name)}")',
                )
            )
            break  # one finding per retitled test, whichever hunk carried it
    return findings


def added_modifiers(file_diffs: list[FileDiff]) -> list[TamperFinding]:
    """``.skip`` / ``.only`` / ``.todo`` added to test files, net of any removed.

    Netting per file+modifier means re-indenting or moving a pre-existing ``.skip``
    (which shows as one removed + one added line) nets to zero — no false alarm.
    """
    findings: list[TamperFinding] = []
    for fd in file_diffs:
        if not is_test_file(fd.path):
            continue
        if is_python_test_file(fd.path):
            findings.extend(_python_modifiers(fd))
            continue
        added_titles: dict[str, list[str | None]] = {}
        removed_counts: dict[str, int] = {}
        for line in fd.added:
            for m in _MODIFIER_RE.finditer(line):
                added_titles.setdefault(m.group(1), []).append(_extract_title(line))
        for line in fd.removed:
            for m in _MODIFIER_RE.finditer(line):
                removed_counts[m.group(1)] = removed_counts.get(m.group(1), 0) + 1
        for mod, titles in added_titles.items():
            net = len(titles) - removed_counts.get(mod, 0)
            for title in titles[:net]:  # net<=0 slices to empty → nothing emitted
                findings.append(
                    TamperFinding(kind=mod, file=fd.path or "", test=title, detail=f".{mod} added")
                )
    return findings


def _python_modifiers(fd: FileDiff) -> list[TamperFinding]:
    """pytest/unittest skip and xfail added to a Python test file, netted per kind like the
    JS path so a re-indented or moved decorator is not a new one."""
    added: dict[str, list[str]] = {}
    removed: dict[str, int] = {}
    for line in fd.added:
        if _is_py_comment(line):
            continue
        for m in _PY_MODIFIER_RE.finditer(line):
            added.setdefault(_modifier_kind(m.group(0)), []).append(_modifier_label(m.group(0)))
    for line in fd.removed:
        if _is_py_comment(line):
            continue
        for m in _PY_MODIFIER_RE.finditer(line):
            k = _modifier_kind(m.group(0))
            removed[k] = removed.get(k, 0) + 1
    out: list[TamperFinding] = []
    for kind, labels in added.items():
        net = len(labels) - removed.get(kind, 0)
        for label in labels[:net]:
            out.append(TamperFinding(kind=kind, file=fd.path or "", detail=f"{label} added"))
    return out


def assertion_deltas(file_diffs: list[FileDiff]) -> list[TamperFinding]:
    """Test files that lost net ``expect(`` calls — assertions gutted while the
    test still reads as green. Text heuristic (no AST); reports net-negative only.

    Only files present on *both* sides of the diff are measured. A whole-file add or
    delete has no meaningful "delta": every line of a deleted test file counts as
    removed, so a legitimate consolidation (two test files merged into one, tests
    verbatim) would report the vanished file as mass assertion-gutting while
    :func:`removed_tests` correctly pairs every test to its new home — a false
    positive on a clean refactor, observed live on the ``haro-test`` sandbox. Nothing
    is lost by skipping them: a test file genuinely deleted is exactly what the
    rename-aware ``removed`` signal exists to catch.
    """
    findings: list[TamperFinding] = []
    _, folds = _python_analysis(file_diffs, rename_map(file_diffs))
    for fd in file_diffs:
        if not is_test_file(fd.path):
            continue
        if fd.old_path is None or fd.new_path is None:
            continue
        added = _count_assertions(fd.path, fd.added)
        removed = _count_assertions(fd.path, fd.removed)
        net = removed - added
        if net > 0 and is_python_test_file(fd.path):
            net -= _fold_explained(fd, folds)
        if net > 0:
            findings.append(
                TamperFinding(
                    kind="assertions",
                    file=fd.path or "",
                    detail=f"{net} fewer {'assertion' if is_python_test_file(fd.path) else 'expect() call'}{'s' if net != 1 else ''}",
                )
            )
    return findings


def snapshot_churn(file_diffs: list[FileDiff]) -> TamperFinding | None:
    """Flag when snapshot rewrites dominate the diff — ``.snap`` files plus inline
    ``toMatchSnapshot`` lines — a green that's mostly "accept whatever came out"."""
    total = 0
    snap = 0
    for fd in file_diffs:
        lines = fd.added + fd.removed
        total += len(lines)
        is_snap_file = bool(fd.path) and fd.path.endswith(".snap")
        if is_snap_file:
            snap += len(lines)
        else:
            snap += sum(1 for l in lines if _SNAPSHOT_ASSERT_RE.search(l))
    if total < _SNAPSHOT_MIN_LINES or snap == 0:
        return None
    ratio = snap / total
    if ratio < _SNAPSHOT_CHURN_THRESHOLD:
        return None
    return TamperFinding(kind="snapshot", file="", detail=f"snapshots {round(ratio * 100)}% of diff")


def config_tamper(file_diffs: list[FileDiff]) -> list[TamperFinding]:
    """Config files that decide *which tests run* — the gap the four signals above
    don't cover, since they all read the suite's own content, not what selects it.
    A real finding (see the module docstring): it flips ``green`` to ``green*``,
    counts toward ``tamper_blocked`` under ``block`` mode and against
    ``trust.no_tamper``, exactly like a removed test — a legitimate config edit and
    an agent quietly widening an exclude glob look identical from a diff alone, so
    the signal cannot tell them apart, but it can still make sure a human does."""
    findings: list[TamperFinding] = []
    for fd in file_diffs:
        path = fd.path
        if not path:
            continue
        if _ALWAYS_CONFIG_RE.search(path):
            findings.append(TamperFinding(kind="config", file=path, detail="test-config file changed"))
        elif _VITE_CONFIG_RE.search(path):
            lines = fd.added + fd.removed
            if any(_VITE_CONFIG_TEST_BLOCK_RE.search(l) for l in lines):
                findings.append(TamperFinding(kind="config", file=path, detail="vitest config (in vite.config) changed"))
        elif _PYPROJECT_RE.search(path):
            lines = fd.added + fd.removed
            if any(_PYPROJECT_PYTEST_RE.search(l) for l in lines):
                findings.append(TamperFinding(kind="config", file=path, detail="pytest config changed"))
        elif _INI_CONFIG_RE.search(path):
            lines = fd.added + fd.removed
            if any(_INI_PYTEST_RE.search(l) for l in lines):
                findings.append(TamperFinding(kind="config", file=path, detail="pytest config changed"))
        elif _PACKAGE_JSON_RE.search(path):
            lines = fd.added + fd.removed
            if any(_is_test_script_line(l) for l in lines):
                findings.append(TamperFinding(kind="config", file=path, detail="test script changed"))
    return findings


# --- pytest parity ------------------------------------------------------------

_PY_DEF_RE = re.compile(r"^\s*(?:async\s+)?def\s+(test\w*)\s*\(")

# Skip / xfail spellings. The decorator and the ``pytestmark = pytest.mark.skip`` module
# form share the ``pytest.mark.*`` prefix; the call forms end in ``(``.
_PY_MODIFIER_RE = re.compile(
    r"\bpytest\.mark\.(?:skipif|skip|xfail)\b"
    r"|\bunittest\.(?:skipIf|skipUnless|skip|expectedFailure)\b"
    r"|\bpytest\.(?:skip|xfail)\s*\("
    r"|\bself\.skipTest\s*\("
)

_PY_ASSERT_COUNT_RE = re.compile(
    r"^\s*assert\b|\bself\.assert\w*\s*\(|\bpytest\.raises\s*\("
)


def _is_py_comment(line: str) -> bool:
    return line.lstrip().startswith("#")


def _modifier_kind(text: str) -> str:
    return "xfail" if ("xfail" in text or "expectedFailure" in text) else "skip"


def _modifier_label(text: str) -> str:
    text = text.strip()
    return text[:-1].rstrip() + "()" if text.endswith("(") else text


def _count_assertions(path: str | None, lines: list[str]) -> int:
    if is_python_test_file(path):
        return sum(
            len(_PY_ASSERT_COUNT_RE.findall(l)) for l in lines if not _is_py_comment(l)
        )
    return sum(len(_EXPECT_RE.findall(l)) for l in lines)


def _parametrize_cases(decorators: str) -> int | None:
    """Visible case count of the ``parametrize`` decorator(s) above a test, or None when it
    can't be read (a variable, a call, an unclosed literal). Stacked decorators multiply.
    An unreadable or empty list never counts as a fold, because pytest skips a test with an
    empty parameter set and a variable can hold anything."""
    total = 1
    pos = 0
    found = False
    while True:
        i = decorators.find("parametrize", pos)
        if i < 0:
            break
        found = True
        j = decorators.find("(", i)
        b = _balanced(decorators, j) if j >= 0 else None
        if b is None:
            return None
        args = _split_args(b[0])
        if len(args) < 2 or not args[1][:1] in ("[", "("):
            return None
        inner = _balanced(args[1], 0)
        if inner is None:
            return None
        n = len([e for e in _split_args(inner[0]) if e.strip()])
        total *= n
        pos = b[1]
    return total if found else None


def _python_analysis(
    file_diffs: list[FileDiff], renames: dict[str, str]
) -> tuple[list[TestRef], list[tuple[str, list[str], str]]]:
    """``(orphans, folds)``: the removed Python tests nothing explains, and the recognized
    parametrize folds as ``(file, folded test names, parametrized test name)``.

    The gate's inventories come from ``vitest list`` and know nothing about Python, so the
    two sides are rebuilt from the diff: ``def test_*`` on removed lines is the base side,
    on added lines the worktree side. A function moved within its file appears on both sides
    with the same name and cancels; a retitle, a file rename or a consolidation pairs through
    :func:`pair_removals`; a rename to a name pytest won't collect (``_test_x``) does not
    pair, which is the point.

    Two extra pairings, both same-file. A removed name that is a *prefix* of an added one
    (``test_parse`` to ``test_parse_empty``) is a retitle; the reverse (a long descriptive name
    trimmed to a short one) is not, since that is how a deletion hides. Several removed tests
    fold into one added ``@pytest.mark.parametrize``d test whose name is their common prefix.
    """
    base: list[TestRef] = []
    wt: list[TestRef] = []
    cases: dict[tuple[str, str], int | None] = {}  # parametrized test -> visible case count
    for fd in file_diffs:
        if is_python_test_file(fd.old_path):
            for line in fd.removed:
                m = _PY_DEF_RE.match(line)
                if m:
                    base.append(TestRef(file=fd.old_path or "", name=m.group(1)))
        if is_python_test_file(fd.new_path):
            for i, line in enumerate(fd.added):
                m = _PY_DEF_RE.match(line)
                if m:
                    wt.append(TestRef(file=fd.new_path or "", name=m.group(1)))
                    deco = "\n".join(fd.added[max(0, i - 8):i])
                    if "parametrize" in deco:
                        cases[(fd.new_path or "", m.group(1))] = _parametrize_cases(deco)
    unmatched, retitled = pair_removals(base, wt, renames)
    base_keys = {(t.file, t.name) for t in base}
    added = [t for t in wt if (t.file, t.name) not in base_keys]

    def bare(name: str) -> str:
        return name[len("test_"):] if name.startswith("test_") else name

    def real_fold(key: tuple[str, str], n: int) -> bool:
        c = cases.get(key)
        return c is not None and c >= n

    # (candidate key, is_shortening) -> removals claiming it
    claims: dict[tuple[tuple[str, str], bool], list[TestRef]] = {}
    orphans: list[TestRef] = []
    seeded: dict[tuple[str, str], list[str]] = {}  # removals the fuzzy tier already paired
    for r, a in retitled:
        seeded.setdefault((a.file, a.name), []).append(r.name)
    for r in unmatched:
        target = renames.get(r.file, r.file)
        same_file = [a for a in added if a.file in (r.file, target) and bare(a.name) != bare(r.name)]
        ext = next((a for a in same_file if bare(r.name) and bare(a.name).startswith(bare(r.name))), None)
        short = next(
            (
                a for a in same_file
                if (a.file, a.name) in cases and bare(a.name) and bare(r.name).startswith(bare(a.name))
            ),
            None,
        )
        if ext is not None:
            claims.setdefault(((ext.file, ext.name), False), []).append(r)
        elif short is not None:
            claims.setdefault(((short.file, short.name), True), []).append(r)
        else:
            orphans.append(r)
    folds: list[tuple[str, list[str], str]] = []
    for (key, shortening), rs in claims.items():
        n = len(rs) + len(seeded.get(key, []))
        if shortening and n < 2:
            orphans.extend(rs)
        elif n > 1 and not real_fold(key, n):
            orphans.extend(rs)
        elif n > 1:
            folds.append((key[0], [r.name for r in rs] + seeded.get(key, []), key[1]))
    return orphans, folds


def python_removed_tests(
    file_diffs: list[FileDiff], renames: dict[str, str]
) -> list[TamperFinding]:
    """The removed-test findings of :func:`_python_analysis`."""
    orphans, _ = _python_analysis(file_diffs, renames)
    return [
        TamperFinding(kind="removed", file=r.file, test=r.name, detail="test removed")
        for r in orphans
    ]


def _py_scope_counts(lines: list[str]) -> dict[str, int]:
    """Assertions per enclosing ``def`` over one flat side of a diff."""
    out: dict[str, int] = {}
    scope = ""
    for line in lines:
        d = _PY_ANY_DEF_RE.match(line)
        if d:
            scope = d.group(1)
        if not _is_py_comment(line):
            out[scope] = out.get(scope, 0) + len(_PY_ASSERT_COUNT_RE.findall(line))
    return out


def _fold_explained(fd: FileDiff, folds: list[tuple[str, list[str], str]]) -> int:
    """Assertions a recognized parametrize fold accounts for losing: the folded tests' total,
    less what the parametrized test keeps. It keeps at least the largest folded test's worth
    or nothing is explained, so folding into an emptied test is still a loss."""
    if not folds:
        return 0
    removed = _py_scope_counts(fd.removed)
    added = _py_scope_counts(fd.added)
    total = 0
    for file, names, target in folds:
        if file != fd.new_path:
            continue
        per = [removed.get(n, 0) for n in names]
        total += max(0, sum(per) - max(added.get(target, 0), max(per, default=0)))
    return total


# --- matcher weakening --------------------------------------------------------

_JS_STRICT = {
    "toBe", "toEqual", "toStrictEqual", "toMatchObject", "toHaveLength",
    "toHaveBeenCalledWith", "toHaveBeenLastCalledWith", "toHaveBeenNthCalledWith",
    "toHaveBeenCalledTimes", "toBeCloseTo", "toThrow", "toThrowError",
}
_JS_ARGS_ANYTHING = {"toEqual", "toStrictEqual", "toHaveBeenCalledWith", "toBe"}
_JS_LOOSE_PLAIN = {"toBeTruthy", "toBeDefined", "toBeFalsy", "toHaveBeenCalled", "toBeCalled"}
_JS_LOOSE_NEGATED = {"toBeNull", "toBeUndefined"}
_PY_GENERIC_EXC = {"Exception", "BaseException"}
_APPROX_RE = re.compile(r"\b(?:pytest\.)?approx\s*\(")
_TOL_RE = re.compile(r"\b(rel|abs)\s*=\s*([0-9.]+(?:[eE][-+]?\d+)?)")
_RAISES_RE = re.compile(r"\b(?:pytest\.raises|self\.assertRaises)\s*\(\s*([^,)\s][^,)]*)")
_CHAIN_RE = re.compile(r"\s*\.\s*(\w+)")


@dataclass
class _Assertion:
    """One parsed assertion. ``key`` says what it is about (the ``expect(x)`` subject, the
    pytest ``assert`` left-hand side); only assertions with an equal key are ever compared."""

    key: str
    text: str  # whitespace-normalised source, used to cancel unchanged assertions
    kind: str  # js | eq | truthy | notnone | raises
    matcher: str = ""
    negated: bool = False
    args: str = ""
    rhs: str = ""

    def label(self) -> str:
        if self.kind == "js":
            return f".{'not.' if self.negated else ''}{self.matcher}({self.args})"[:48]
        if self.kind == "raises":
            return f"raises({self.args})"[:48]
        return f"assert {self.text}"[:48]


def _norm(s: str) -> str:
    return " ".join(s.split())


def _balanced(s: str, i: int) -> tuple[str, int] | None:
    """The text inside the bracket opening at ``s[i]`` and the index just past its close."""
    depth = 0
    quote: str | None = None
    j = i
    while j < len(s):
        c = s[j]
        if quote:
            if c == "\\":
                j += 2
                continue
            if c == quote:
                quote = None
        elif c in "'\"`":
            quote = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return s[i + 1:j], j + 1
        j += 1
    return None


def _parse_js_assertions(line: str) -> list[_Assertion]:
    out: list[_Assertion] = []
    for m in _EXPECT_RE.finditer(line):
        subj = _balanced(line, m.end() - 1)
        if subj is None:
            continue
        subject, pos = subj
        negated = False
        prefix = ""
        matcher = ""
        while True:
            c = _CHAIN_RE.match(line, pos)
            if c is None:
                break
            pos = c.end()
            name = c.group(1)
            if name == "not":
                negated = True
            elif name in ("resolves", "rejects"):
                prefix = name
            else:
                matcher = name
                break
        if not matcher:
            continue
        args = ""
        gap = len(line[pos:]) - len(line[pos:].lstrip())
        if line[pos + gap:pos + gap + 1] == "(":
            b = _balanced(line, pos + gap)
            if b is not None:
                args = _norm(b[0])
                pos = b[1]
        out.append(
            _Assertion(
                key=f"{_norm(subject)}|{prefix}",
                text=_norm(line[m.start():pos]),
                kind="js",
                matcher=matcher,
                negated=negated,
                args=args,
            )
        )
    return out


def _top_level_ops(expr: str) -> list[tuple[str, int]]:
    """Comparison / boolean operators at bracket depth 0 outside strings, as ``(op, index)``."""
    ops: list[tuple[str, int]] = []
    depth = 0
    quote: str | None = None
    i = 0
    while i < len(expr):
        c = expr[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0:
            two = expr[i:i + 2]
            if two in ("==", "!=", "<=", ">="):
                ops.append((two, i))
                i += 2
                continue
            if c in "<>":
                ops.append((c, i))
            elif c == " ":
                m = re.match(r"\s(and|or|is not|is|not in|in)\s", expr[i:])
                if m:
                    ops.append((m.group(1), i))
                    i += m.end() - 1
                    continue
        i += 1
    return ops


def _split_args(args: str) -> list[str]:
    out: list[str] = []
    depth = 0
    quote: str | None = None
    start = 0
    for i, c in enumerate(args):
        if quote:
            if c == quote:
                quote = None
        elif c in "'\"`":
            quote = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            out.append(args[start:i].strip())
            start = i + 1
    out.append(args[start:].strip())
    return out


def _parse_py_assertions(line: str) -> list[_Assertion]:
    if _is_py_comment(line):
        return []
    out: list[_Assertion] = []
    stripped = line.strip()
    if stripped.startswith("assert ") or stripped.startswith("assert("):
        body = _norm(_split_args(stripped[len("assert"):].strip())[0])
        ops = _top_level_ops(body)
        if len(ops) == 1 and ops[0][0] == "==":
            i = ops[0][1]
            out.append(
                _Assertion(key=body[:i].strip(), text=body, kind="eq", rhs=body[i + 2:].strip())
            )
        elif len(ops) == 1 and body.endswith(" is not None") and ops[0][0] == "is not":
            out.append(_Assertion(key=body[: -len(" is not None")].strip(), text=body, kind="notnone"))
        elif len(ops) == 1 and body.endswith(" != None") and ops[0][0] == "!=":
            out.append(_Assertion(key=body[: -len(" != None")].strip(), text=body, kind="notnone"))
        elif not ops and not body.startswith("not "):
            out.append(_Assertion(key=body, text=body, kind="truthy"))
    for m in _RAISES_RE.finditer(line):
        out.append(_Assertion(key="raises", text=_norm(m.group(0)), kind="raises", args=m.group(1).strip()))
    return out


def _tolerance(rhs: str) -> tuple[float, float] | None:
    """``(rel, abs)`` of a ``pytest.approx(...)``, defaulting to pytest's own (1e-6, 1e-12)."""
    if not _APPROX_RE.search(rhs):
        return None
    rel, ab = 1e-6, 1e-12
    for name, val in _TOL_RE.findall(rhs):
        try:
            v = float(val)
        except ValueError:
            continue
        if name == "rel":
            rel = v
        else:
            ab = v
    return rel, ab


def _js_is_loose(a: _Assertion) -> bool:
    if a.matcher in _JS_LOOSE_PLAIN and not a.negated:
        return True
    if a.negated and a.matcher in _JS_LOOSE_NEGATED:
        return True
    if a.matcher in ("toThrow", "toThrowError") and not a.args and not a.negated:
        return True
    if a.matcher in _JS_ARGS_ANYTHING and a.args.replace(" ", "") == "expect.anything()":
        return True
    if a.matcher == "toBeGreaterThanOrEqual" and a.args.strip() == "0":
        return True
    return a.matcher == "toBeGreaterThan" and a.args.strip() == "-1"


def _digits(a: _Assertion) -> int:
    parts = _split_args(a.args)
    try:
        return int(parts[1]) if len(parts) > 1 else 2
    except ValueError:
        return 2


def _is_weaker(r: _Assertion, b: _Assertion) -> bool:
    """Is ``b`` a strictly weaker check than ``r`` on the same subject?"""
    if r.kind == "js" and b.kind == "js":
        if r.negated or r.matcher not in _JS_STRICT:
            return False
        if r.matcher in ("toThrow", "toThrowError") and not r.args:
            return False
        if r.matcher == "toBe" and r.args in ("true", "false") and b.matcher in (
            "toBeTruthy", "toBeFalsy"
        ):
            return False  # the lint-rule refactor, not a loosened check
        if _js_is_loose(b) and not _js_is_loose(r):
            return True
        if r.matcher == "toStrictEqual" and b.matcher == "toEqual" and not b.negated:
            return True
        if r.matcher == "toBeCloseTo" and b.matcher == "toBeCloseTo":
            return _digits(b) < _digits(r)
        return False
    if r.kind == "eq":
        if b.kind in ("truthy", "notnone"):
            return True
        if b.kind == "eq":
            tr, tb = _tolerance(r.rhs), _tolerance(b.rhs)
            if tr and tb:
                return tb[0] > tr[0] or tb[1] > tr[1]
        return False
    if r.kind == "raises" and b.kind == "raises":
        return r.args not in _PY_GENERIC_EXC and b.args in _PY_GENERIC_EXC
    return False


def _hunk_sides(fd: FileDiff) -> list[tuple[list[str], list[str]]]:
    return [(h.old, h.new) for h in fd.hunks] or [(fd.removed, fd.added)]


_PY_ANY_DEF_RE = re.compile(r"^\s*(?:async\s+)?def\s+(\w+)")


def _scoped(lines: list[str], parse, is_py: bool) -> list[_Assertion]:
    """Parse one hunk side, prefixing each assertion's key with the test it sits in (the last
    ``def`` / ``it(`` seen above it). Without this, ``assert result`` added to one test would
    pair with ``assert result == 3`` loosened in another."""
    out: list[_Assertion] = []
    scope = ""
    for line in lines:
        if is_py:
            d = _PY_ANY_DEF_RE.match(line)
            if d:
                scope = d.group(1)
        else:
            d = _DECL_RE.search(line)
            if d:
                scope = d.group(2)
        for a in parse(line):
            a.key = f"{scope}\x00{a.key}"
            out.append(a)
    return out


def weakened_assertions(file_diffs: list[FileDiff]) -> list[TamperFinding]:
    """Assertions whose matcher went strict to loose on an unchanged subject.

    Per hunk: cancel assertions that appear verbatim on both sides (context, moves,
    re-indents), group what is left by subject, and only when a subject has the *same*
    number of assertions removed and added compare them pairwise in order. A refactor that
    changes the subject, or replaces one assertion with two, never pairs and so stays silent.
    """
    findings: list[TamperFinding] = []
    for fd in file_diffs:
        if not is_test_file(fd.path):
            continue
        is_py = is_python_test_file(fd.path)
        parse = _parse_py_assertions if is_py else _parse_js_assertions
        for old, new in _hunk_sides(fd):
            olds = _scoped(old, parse, is_py)
            news = _scoped(new, parse, is_py)
            for a in list(olds):
                for j, b in enumerate(news):
                    if b.text == a.text:
                        news.pop(j)
                        olds.remove(a)
                        break
            for key in sorted({a.key for a in olds} & {b.key for b in news}):
                ro = [a for a in olds if a.key == key]
                rn = [b for b in news if b.key == key]
                if len(ro) != len(rn):
                    continue
                for r, b in zip(ro, rn):
                    if _is_weaker(r, b):
                        findings.append(
                            TamperFinding(
                                kind="weakened",
                                file=fd.path or "",
                                detail=f"assertion weakened: {r.label()} to {b.label()}",
                            )
                        )
    return findings


# --- widened timeouts ---------------------------------------------------------

_JS_SOURCE_RE = re.compile(r"\.[cm]?[jt]sx?$")
# Not preceded by ``.`` or a word char: ``re.test(`` and ``latest(`` are not test declarations.
_JS_TEST_CALL_RE = re.compile(r"(?<![.\w])(?:it|test|describe|bench|suite)\s*(?:\.\s*\w+\s*)*\(")
_JS_LAST_ARG_NUM_RE = re.compile(r",\s*(\d[\d_]*)$")
_JS_LAST_ARG_OPT_RE = re.compile(r",\s*\{[^{}]*\btimeout\s*:\s*(\d[\d_]*)[^{}]*\}$")
# Lookbehind windows keep every per-bracket scan constant-size, so a 200k-char line stays linear.
_WINDOW = 256
_JS_MID_OBJ_RE = re.compile(r"\{([^{}]*)\}\s*,")
_JS_TIMEOUT_KEY_RE = re.compile(r"\btimeout\s*:\s*(\d[\d_]*)")
_JS_CONFIG_TIMEOUT_RE = re.compile(r"\b(testTimeout|hookTimeout|teardownTimeout)\s*:\s*(\d[\d_]*)")
_JEST_SET_TIMEOUT_RE = re.compile(r"\bjest\.setTimeout\s*\(\s*(\d[\d_]*)")
_PY_TIMEOUT_MARK_RE = re.compile(r"\bpytest\.mark\.timeout\s*\(\s*(?:timeout\s*=\s*)?(\d+(?:\.\d+)?)")
_INI_TIMEOUT_RE = re.compile(r"^(?:\s*timeout\s*[=:]\s*|.*--timeout[=\s]+)(\d+(?:\.\d+)?)")
_PYTEST_INI_FILE_RE = re.compile(r"(?:^|/)(?:pytest\.ini|tox\.ini|setup\.cfg|pyproject\.toml)$")
_JS_TEST_CONFIG_RE = re.compile(r"(?:^|/)(?:vitest|vite|jest)\.config\.[cm]?[jt]s$|(?:^|/)vitest\.workspace\.[cm]?[jt]s$")


def _num(s: str) -> float:
    return float(s.replace("_", ""))


def _js_call_timeouts(lines: list[str]) -> list[tuple[str, float]]:
    """Per-test timeouts in one side of a hunk, only where the call is provably a test
    declaration: the ``it(`` / ``test(`` opener is in view and the timeout is its own last
    argument (found by tracking bracket depth to the paren that closes the declaration), or a
    ``{ timeout: N }`` options argument on the opener line. A closing ``}, 2000)`` whose
    opener is out of view, or that closes a ``debounce(`` / ``waitFor(`` nested inside the
    test, is never counted."""
    out: list[tuple[str, float]] = []
    depth = 0
    stack: list[int] = []  # bracket depth at the open paren of each still-open test call
    for line in lines:
        openers = {m.end() - 1 for m in _JS_TEST_CALL_RE.finditer(line)}
        quote: str | None = None
        for i, c in enumerate(line):
            if quote:
                if c == quote and line[i - 1] != "\\":
                    quote = None
                continue
            if c in "'\"`":
                quote = c
            elif c in "([{":
                if i in openers:
                    stack.append(depth)
                elif c == "{" and stack and depth == stack[-1] + 1:
                    before = line[max(0, i - _WINDOW):i].rstrip()
                    m = _JS_MID_OBJ_RE.match(line, i, i + _WINDOW) if before.endswith(",") else None
                    t = _JS_TIMEOUT_KEY_RE.search(m.group(1)) if m else None
                    if t:
                        out.append(("test", _num(t.group(1))))
                depth += 1
            elif c in ")]}":
                depth -= 1
                if c == ")" and stack and depth == stack[-1]:
                    stack.pop()
                    pre = line[max(0, i - _WINDOW):i].rstrip()
                    m = _JS_LAST_ARG_NUM_RE.search(pre) or _JS_LAST_ARG_OPT_RE.search(pre)
                    if m:
                        out.append(("test", _num(m.group(1))))
    return out


def _timeout_tokens(path: str, lines: list[str]) -> list[tuple[str, float]]:
    out: list[tuple[str, float]] = []
    if _JS_SOURCE_RE.search(path):
        for line in lines:
            for m in _JS_CONFIG_TIMEOUT_RE.finditer(line):
                out.append((m.group(1), _num(m.group(2))))
            m = _JEST_SET_TIMEOUT_RE.search(line)
            if m:
                out.append(("testTimeout", _num(m.group(1))))
        if is_test_file(path):
            out.extend(_js_call_timeouts(lines))
    if path.endswith(".py"):
        for line in lines:
            m = None if _is_py_comment(line) else _PY_TIMEOUT_MARK_RE.search(line)
            if m:
                out.append(("pytest.mark", float(m.group(1))))
    if _PYTEST_INI_FILE_RE.search(path):
        for line in lines:
            m = None if _is_py_comment(line) else _INI_TIMEOUT_RE.match(line)
            if m:
                out.append(("ini", float(m.group(1))))
    return out


def _timeout_scope(path: str) -> bool:
    """Only files that can carry a test timeout: test modules and the known test configs.
    A ``timeout: 10`` in ``src/api.ts`` is a fetch option, not a weakened test."""
    return (
        is_test_file(path)
        or bool(_JS_TEST_CONFIG_RE.search(path))
        or bool(_PYTEST_INI_FILE_RE.search(path))
        or path.endswith("conftest.py")
    )


def _only_timeout_lines(fd: FileDiff) -> bool:
    lines = [l for l in fd.added + fd.removed if l.strip() and not _is_py_comment(l)]
    return bool(lines) and all(_timeout_tokens(fd.path or "", [l]) for l in lines)


def widened_timeouts(file_diffs: list[FileDiff]) -> list[TamperFinding]:
    """Timeouts added or raised, never lowered.

    Tokens are ``(key, value)`` per file. Identical tokens on both sides cancel (context,
    re-indents, moves); an added token then flags when the file's removed tokens for that key
    hold nothing at least as large, which covers both "added" and "raised".
    """
    findings: list[TamperFinding] = []
    for fd in file_diffs:
        path = fd.path or ""
        if not path or not _timeout_scope(path):
            continue
        if _PYTEST_INI_FILE_RE.search(path) and path.rsplit("/", 1)[-1] != "pytest.ini":
            blob = fd.added + fd.removed + [l for h in fd.hunks for l in h.old + h.new]
            if not any("pytest" in l.lower() for l in blob):
                continue
        sides = _hunk_sides(fd)
        olds: list[tuple[str, float]] = []
        news: list[tuple[str, float]] = []
        for old, new in sides:
            olds.extend(_timeout_tokens(path, old))
            news.extend(_timeout_tokens(path, new))
        for t in list(olds):
            if t in news:
                news.remove(t)
                olds.remove(t)
        for key, val in news:
            prior = [v for k, v in olds if k == key]
            if prior and val <= max(prior):
                continue
            unit = "s" if key in ("pytest.mark", "ini") else "ms"
            what = "per-test timeout" if key == "test" else key
            detail = (
                f"{what} raised from {max(prior):g}{unit} to {val:g}{unit}"
                if prior
                else f"{what} added ({val:g}{unit})"
            )
            findings.append(TamperFinding(kind="timeout", file=path, detail=detail))
    return findings


def added_tests(
    base_inventory: list[TestRef], worktree_inventory: list[TestRef]
) -> list[TestRef]:
    """Tests present in the worktree but not at ``base_ref`` — genuinely new tests,
    the population ``gate.run_gate``'s red-first check re-runs against ``base_ref``.
    A new test that already passes there guards existing behaviour rather than this
    change (usp-critique-round3.md §5c.4); advisory only, see the module docstring."""
    base_keys = {(t.file, t.name) for t in base_inventory}
    return [t for t in worktree_inventory if (t.file, t.name) not in base_keys]


def _segments(name: str) -> list[str]:
    """A test's name split into its describe path (``"add > adds 2"`` → ``["add", "adds 2"]``),
    so a removal can be matched against either an ``it.skip`` title (the leaf) or a
    ``describe.skip`` title (an ancestor)."""
    return [s.strip() for s in name.split(" > ")]


def reconcile(
    removed: list[TamperFinding],
    modifiers: list[TamperFinding],
    assertions: list[TamperFinding],
    weakened: list[TamperFinding] | None = None,
    timeouts: list[TamperFinding] | None = None,
) -> list[TamperFinding]:
    """Fold overlapping evidence so one act of tampering reads as one finding.

    ``vitest list`` lists what *would run*, so a modifier makes tests disappear from
    the worktree inventory and the ``removed`` signal double-reports them:

      * ``.skip`` / ``.todo`` — the test it names vanishes (or, for ``describe.skip``,
        every test beneath it). Those removals belong to the modifier finding.
      * ``.only`` — every *other* test in that file vanishes. The whole file's
        shrinkage is the ``.only``'s doing, so its removals fold in too and the
        modifier's detail carries the count ("6 other tests … no longer run") — the
        honest, and frankly scarier, way to say it.

    Assertion deltas are then dropped for files a stronger signal already flagged: a
    deleted or skipped test taking its ``expect(`` calls with it isn't a second
    problem. That leaves the assertion heuristic doing the job it's for — *silent*
    gutting, in a file nothing else noticed.

    Absorbing never lowers the verdict: an absorbed file still carries the modifier
    finding, so the gate still reads ``green*``.
    """
    kept_removed: list[TamperFinding] = []
    absorbed: dict[int, int] = {}  # index into ``modifiers`` → how many removals folded in
    for r in removed:
        # Attribute the removal to a SPECIFIC modifier, not just to its file: two
        # ``.skip``s in one file must not both claim the other's absorbed test.
        owner = next(
            (
                i for i, m in enumerate(modifiers)
                if m.file == r.file
                and (m.kind == "only" or (m.kind in ("skip", "todo", "xfail") and m.test in _segments(r.test or "")))
            ),
            None,
        )
        if owner is None:
            kept_removed.append(r)
        else:
            absorbed[owner] = absorbed.get(owner, 0) + 1

    for i, f in enumerate(modifiers):
        n = absorbed.get(i, 0)
        if f.kind == "only" and n:
            f.detail = f".only added — {n} other test{'s' if n != 1 else ''} in this file no longer run"
        elif f.kind in ("skip", "todo", "xfail") and n > 1:
            f.detail = f".{f.kind} added — {n} tests no longer run"

    weakened = weakened or []
    flagged = {f.file for f in kept_removed} | {f.file for f in modifiers} | {f.file for f in weakened}
    return (
        kept_removed
        + modifiers
        + weakened
        + [f for f in assertions if f.file not in flagged]
        + (timeouts or [])
    )


def summarize(findings: list[TamperFinding]) -> str | None:
    """The compact chip line: "3 removed · 2 skipped · snapshots 84% of diff"."""
    if not findings:
        return None
    counts: dict[str, int] = {}
    snapshot_detail: str | None = None
    for f in findings:
        counts[f.kind] = counts.get(f.kind, 0) + 1
        if f.kind == "snapshot":
            snapshot_detail = f.detail
    segs: list[str] = []
    if counts.get("removed"):
        segs.append(f"{counts['removed']} removed")
    if counts.get("skip"):
        segs.append(f"{counts['skip']} skipped")
    if counts.get("xfail"):
        segs.append(f"{counts['xfail']} xfail")
    if counts.get("only"):
        segs.append(f"{counts['only']} .only")
    if counts.get("todo"):
        segs.append(f"{counts['todo']} todo")
    if counts.get("weakened"):
        segs.append(f"{counts['weakened']} weakened")
    if counts.get("assertions"):
        segs.append(f"{counts['assertions']} with fewer assertions")
    if counts.get("timeout"):
        n = counts["timeout"]
        segs.append(f"{n} timeout{'s' if n != 1 else ''} widened")
    if snapshot_detail:
        segs.append(snapshot_detail)
    if counts.get("config"):
        segs.append(f"{counts['config']} test-config file{'s' if counts['config'] != 1 else ''} touched")
    if counts.get("acceptance_changed"):
        segs.append("acceptance test changed after approval")
    if counts.get("acceptance_missing"):
        segs.append(f"{counts['acceptance_missing']} acceptance test(s) missing")
    return " · ".join(segs)


def analyze(
    diff_text: str,
    base_inventory: list[TestRef],
    worktree_inventory: list[TestRef],
) -> TamperReport:
    """Run every signal and fold the findings into a ``green*`` report.

    Ordered strongest→noisiest so the chip and the drill-down lead with removals,
    after :func:`reconcile` merges the signals that describe the same act (a ``.skip``
    is not also a removal). An empty diff with matching inventories yields a clean
    (no-findings) report.

    ``rewrites`` rides along on the same matching pass but stays out of ``findings`` and out
    of ``note``: a retitled-and-re-asserted test is a fact worth reading, not a verdict worth
    downgrading. A report can be clean (``note is None``) and still carry rewrites.
    """
    file_diffs = parse_file_diffs(diff_text)
    renames = rename_map(file_diffs)
    unmatched, retitled = pair_removals(base_inventory, worktree_inventory, renames)
    findings = reconcile(
        [
            TamperFinding(kind="removed", file=r.file, test=r.name, detail="test removed")
            for r in unmatched
        ]
        + python_removed_tests(file_diffs, renames),
        added_modifiers(file_diffs),
        assertion_deltas(file_diffs),
        weakened=weakened_assertions(file_diffs),
        timeouts=widened_timeouts(file_diffs),
    )
    snap = snapshot_churn(file_diffs)
    if snap is not None:
        findings.append(snap)
    timeouts = {f.file for f in findings if f.kind == "timeout"}
    only_timeout_edits = {fd.path for fd in file_diffs if fd.path in timeouts and _only_timeout_lines(fd)}
    # A file whose every changed line is a timeout edit is reported once, as the more specific
    # kind. Any other change beside it (a widened exclude) keeps the config finding.
    findings.extend(f for f in config_tamper(file_diffs) if f.file not in only_timeout_edits)
    return TamperReport(
        findings=findings,
        note=summarize(findings),
        rewrites=rewritten_tests(file_diffs, retitled),
    )
