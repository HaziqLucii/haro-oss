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

Two more signals, added round 3 (usp-critique-round3.md Move C), sit outside the diff
alone. Both ARE real findings — folded into ``findings`` exactly like the four above,
so both reach ``green*``, ``tamper_blocked`` under ``block`` mode, and
``trust.no_tamper``/the autonomy-ladder streak. Neither is proof of deliberate gaming
the way an unmatched test removal is (a legitimate config edit or an honestly-weak new
test both look identical from here), which is why their ``detail`` text reads as
"look at this", not "this was gamed" — but the whole point of a round-3 signal is that
the 2026 evidence (SpecBench, Trail of Bits) says an agent CAN weaken the suite this
way, so the finding still has to be able to stop a merge under ``block`` mode. Do not
route either through :attr:`TamperReport.rewrites` (below) to "soften" them — that
attribute exists for a specific proven-safe case, not a general advisory lane.
  * **config** — a diff touching a file that decides *which tests run*
    (``vitest.config.*``/``vite.config.*``'s ``test:`` block/``vitest.workspace.*``,
    ``pytest.ini``, ``pyproject.toml``'s pytest section, a ``package.json`` test
    script, husky/``.githooks``, ``.claude/settings*.json``, ``.vscode/tasks.json``).
    See :func:`config_tamper`. Line-based, no AST: it catches an edit to a KEYED
    line (``exclude: […]`` rewritten in place, a ``test: {`` block added/removed)
    but not a bare array element added deep inside an existing multi-line literal
    without repeating the key — an accepted trade-off, not a silent gap (see
    ``_VITE_CONFIG_TEST_BLOCK_RE``'s comment and its own test).
  * **vacuous** — a genuinely NEW test that already passes at ``base_ref`` (computed
    by :func:`gate._red_first_check`, not here, since it needs to actually run the
    test — this module stays pure/no-IO). See :func:`added_tests`.

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
_TEST_FILE_RE = re.compile(r"(?:\.(?:test|spec)\.[cm]?[jt]sx?$)|(?:^|/)__tests__/")

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
# without repeating the key (refuter round-3: confirmed gap, not silently assumed
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
    r"\[tool\.pytest|testpaths|pythonpath|python_files|python_classes|python_functions",
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

    kind: str  # removed | skip | only | todo | assertions | snapshot | config | vacuous
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


def is_test_file(path: str | None) -> bool:
    return bool(path) and bool(_TEST_FILE_RE.search(path.replace("\\", "/")))


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
    for fd in file_diffs:
        if not is_test_file(fd.path):
            continue
        if fd.old_path is None or fd.new_path is None:
            continue
        added = sum(len(_EXPECT_RE.findall(l)) for l in fd.added)
        removed = sum(len(_EXPECT_RE.findall(l)) for l in fd.removed)
        net = removed - added
        if net > 0:
            findings.append(
                TamperFinding(
                    kind="assertions",
                    file=fd.path or "",
                    detail=f"{net} fewer expect() call{'s' if net != 1 else ''}",
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
        elif _PACKAGE_JSON_RE.search(path):
            lines = fd.added + fd.removed
            if any(_is_test_script_line(l) for l in lines):
                findings.append(TamperFinding(kind="config", file=path, detail="test script changed"))
    return findings


def added_tests(
    base_inventory: list[TestRef], worktree_inventory: list[TestRef]
) -> list[TestRef]:
    """Tests present in the worktree but not at ``base_ref`` — genuinely new tests,
    the population ``gate.run_gate``'s red-first check re-runs against ``base_ref``.
    A new test that already passes there never exercised the behaviour it claims
    to — the correlated-error gap mutation scoring alone doesn't catch, since it
    only mutates code the tests already run against (usp-critique-round3.md §5c.4)."""
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
                and (m.kind == "only" or (m.kind in ("skip", "todo") and m.test in _segments(r.test or "")))
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
        elif f.kind in ("skip", "todo") and n > 1:
            f.detail = f".{f.kind} added — {n} tests no longer run"

    flagged = {f.file for f in kept_removed} | {f.file for f in modifiers}
    return kept_removed + modifiers + [f for f in assertions if f.file not in flagged]


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
    if counts.get("only"):
        segs.append(f"{counts['only']} .only")
    if counts.get("todo"):
        segs.append(f"{counts['todo']} todo")
    if counts.get("assertions"):
        segs.append(f"{counts['assertions']} with fewer assertions")
    if snapshot_detail:
        segs.append(snapshot_detail)
    if counts.get("config"):
        segs.append(f"{counts['config']} test-config file{'s' if counts['config'] != 1 else ''} touched")
    if counts.get("vacuous"):
        segs.append(f"{counts['vacuous']} vacuous")
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
        ],
        added_modifiers(file_diffs),
        assertion_deltas(file_diffs),
    )
    snap = snapshot_churn(file_diffs)
    if snap is not None:
        findings.append(snap)
    findings.extend(config_tamper(file_diffs))
    return TamperReport(
        findings=findings,
        note=summarize(findings),
        rewrites=rewritten_tests(file_diffs, retitled),
    )
