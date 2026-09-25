from __future__ import annotations

"""Mutation score on the diff — an ADVISORY gate signal (the "is the suite hard to fool?" test).

A green gate proves the tests *pass*. It does not prove they would *notice if the
code were wrong*: an agent authors the tests that grade its own code, so a green
suite certifies "internally consistent with what the author imagined", not
"correct". Line coverage answers "did the line run"; this answers the next
question — "would any test fail if that line were subtly wrong?".

Mechanism: mutate each *added* source line one at a time (flip an operator, a
constant, a comparison), re-run the suite, and see whether it still passes. A
mutant the suite still passes is a **survivor**: a fault the tests cannot tell
apart, i.e. the tests are weak exactly there. The residue of survivors is the
shortlist of lines a reviewer should actually read.

Design stance — advisory by construction, like `unchecked.py` / `verified_hunks.py`:
  * There is NO `mutation_blocked`. It can never downgrade a verdict the tests
    earned, never writes `store.tests` / `workspace.status` / the trust streak.
  * But unlike those two it must actually RUN tests (N times), so it lives beside
    `analytics.py` (which already re-runs the suite for flaky detection) rather
    than inside the pure `run_gate` path — a heavy on-demand insight, kept off the
    ~1s merge-gate path.
  * Diff-scoped: only *added* lines are mutated, so a 1,200-line agent diff costs
    a bounded number of mutants, not a whole-file mutation sweep.

The engine here is pure of IO the same way `merge_queue`/`race` are: the "run the
suite against this mutated tree" step is an injected `run_suite` callable, so the
operator logic + scoring is unit-testable with no repo and no vitest. The endpoint
(`main.run_mutation`) supplies the real adapter-backed runner.
"""

import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Awaitable, Callable

# JS/TS only for the first cut — mirrors VitestAdapter being the flagship runner
# and `verified_hunks`/coverage being vitest-gated. A `.py` mutator (mutmut-style
# operators) is the obvious second adapter; the operator table is the only
# language-specific part.
SUPPORTED_RUNNERS = frozenset({"vitest"})

#: A worktree-tree runner: given the worktree path, run the suite against whatever
#: is currently on disk and report the coarse verdict. Injected so the engine stays
#: pure/testable. Returns a `SuiteVerdict`.
RunSuite = Callable[[str], Awaitable["SuiteVerdict"]]


class SuiteVerdict(str, Enum):
    """The three outcomes that matter for scoring a mutant."""

    PASSED = "passed"   # every test passed → the fault SURVIVED (bad: tests can't see it)
    FAILED = "failed"   # a test failed → the fault was KILLED (good: tests caught it)
    ERROR = "error"     # the suite could not run (compile/parse error) → mutant SKIPPED, not scored


@dataclass(frozen=True)
class MutationOperator:
    """One rewrite rule. `find` is matched against source; each *distinct* match on
    an added line becomes one mutant with `find`'s text swapped for `replace`."""

    pattern: re.Pattern[str]
    replace: str
    label: str  # human summary, e.g. "round → floor"


def _op(find: str, replace: str, label: str) -> MutationOperator:
    return MutationOperator(re.compile(find), replace, label)

# Deliberately conservative, high-signal operators: the classes that silently ship
# real bugs (rounding direction, arithmetic sign, off-by-one comparisons, dropped
# guards) rather than an exhaustive academic set (which mostly produces equivalent
# mutants and noise). Order is display order.
OPERATORS: tuple[MutationOperator, ...] = (
    _op(r"\bMath\.round\b", "Math.floor", "round → floor"),
    _op(r"\bMath\.round\b", "Math.ceil", "round → ceil"),
    _op(r"\bMath\.round\b", "Math.trunc", "round → trunc"),
    _op(r"\bMath\.floor\b", "Math.ceil", "floor → ceil"),
    _op(r"\bMath\.ceil\b", "Math.floor", "ceil → floor"),
    # arithmetic — one occurrence at a time (word-free so it hits real operators)
    _op(r" \+ ", " - ", "+ → -"),
    _op(r" - ", " + ", "- → +"),
    _op(r" \* ", " / ", "* → /"),
    _op(r" / ", " * ", "/ → *"),
    _op(r" % ", " * ", "% → *"),
    # comparisons / boundaries (off-by-one and inverted guards)
    _op(r" <= ", " < ", "<= → <"),
    _op(r" >= ", " > ", ">= → >"),
    _op(r" < ", " <= ", "< → <="),
    _op(r" > ", " >= ", "> → >="),
    _op(r" === ", " !== ", "=== → !=="),
    _op(r" !== ", " === ", "!== → ==="),
    # logical
    _op(r" && ", " || ", "&& → ||"),
    _op(r" \|\| ", " && ", "|| → &&"),
    # dropped negation (a removed guard)
    _op(r"\(!", "(", "drop ! (negation)"),
    # numeric literal tweaks (off-by-one / magnitude)
    _op(r"\b0\b", "1", "0 → 1"),
    _op(r"\b1\b", "0", "1 → 0"),
)


@dataclass(frozen=True)
class Mutant:
    """A single located fault: `source` is the whole file with one occurrence swapped."""

    file: str          # repo-relative path
    line: int          # 1-based line of the mutated token
    label: str         # operator label
    source: str        # full mutated file content


@dataclass(frozen=True)
class Survivor:
    """A mutant the suite still passed — a fault the tests can't distinguish."""

    file: str
    line: int
    label: str


@dataclass
class MutationReport:
    """The advisory result. `score` is killed / scored (survivors excluded from the
    denominator only when a mutant couldn't run at all — those are `skipped`)."""

    supported: bool
    killed: int = 0
    survived: int = 0
    skipped: int = 0                       # mutants that failed to compile — not scored
    survivors: list[Survivor] = field(default_factory=list)
    total_mutants: int = 0                 # generated (may exceed killed+survived+skipped if capped)
    budget_capped: bool = False
    note: str | None = None                # why unsupported / degraded, human-readable

    @property
    def scored(self) -> int:
        return self.killed + self.survived

    @property
    def score(self) -> int | None:
        """Percent of runnable mutants the suite caught; None when nothing was scored."""
        return round(self.killed / self.scored * 100) if self.scored else None


def _added_line_set(added_lines: list[int]) -> set[int]:
    return set(added_lines)


def generate_mutants(file: str, source: str, added_lines: list[int]) -> list[Mutant]:
    """Pure: every operator × every match that lands on an *added* line → one mutant.

    Diff-scoped so we only ever question the code the agent just wrote, never the
    repo's standing test debt. One occurrence is swapped per mutant so each is a
    single, locatable fault.
    """
    added = _added_line_set(added_lines)
    # Char-offset of each line start, so a match position maps back to its 1-based line.
    offsets: list[int] = []
    total = 0
    for ln in source.splitlines(keepends=True):
        offsets.append(total)
        total += len(ln)

    def line_of(pos: int) -> int:
        # binary-search the last offset <= pos
        lo, hi = 0, len(offsets) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if offsets[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1  # 1-based

    mutants: list[Mutant] = []
    seen: set[tuple[int, str]] = set()  # (pos, replace) dedupe across overlapping ops
    for op in OPERATORS:
        for m in op.pattern.finditer(source):
            pos = m.start()
            ln = line_of(pos)
            if ln not in added:
                continue
            key = (pos, op.replace)
            if key in seen:
                continue
            seen.add(key)
            mutated = source[: m.start()] + op.replace + source[m.end():]
            if mutated == source:
                continue
            mutants.append(Mutant(file=file, line=ln, label=op.label, source=mutated))
    return mutants


async def run_mutation(
    *,
    worktree_path: str,
    changed: dict[str, tuple[str, list[int]]],   # file -> (current source, added line numbers)
    run_suite: RunSuite,
    write_file: Callable[[str, str], None],       # (repo-relative path, content) -> None (injected, sync)
    runner: str,
    max_mutants: int = 40,
) -> MutationReport:
    """Orchestrate the mutation run.

    * `changed` is the diff already fetched by the caller (file → its current source
      and the list of added line numbers), so we never parse the diff again — and the
      current source IS the baseline we mutate from and restore to.
    * `run_suite(worktree_path)` runs the suite against the on-disk tree.
    * `write_file` mutates and restores a file in the worktree; the caller owns path
      resolution so the engine never touches the filesystem itself (and stays testable).

    The file is ALWAYS restored (after each mutant AND in a final `finally`), so at
    most one file is mutated for the duration of a single suite run, and a crash
    mid-run can never leave a mutant on disk — the same crash-safety stance as the
    rest of haro.
    """
    if runner not in SUPPORTED_RUNNERS:
        return MutationReport(
            supported=False,
            note=f"mutation score is vitest-only for now (runner={runner!r})",
        )

    # Generate all diff-scoped mutants, then apply the budget cap deterministically
    # (source order) so a huge diff stays bounded and repeatable.
    all_mutants: list[Mutant] = []
    for file, (source, added) in changed.items():
        all_mutants.extend(generate_mutants(file, source, added))

    report = MutationReport(supported=True, total_mutants=len(all_mutants))
    if not all_mutants:
        report.note = "no mutable code on the added lines"
        return report

    mutants = all_mutants[:max_mutants]
    report.budget_capped = len(all_mutants) > max_mutants

    # The current source (handed to us) is the baseline we restore to.
    originals = {file: changed[file][0] for file in {m.file for m in mutants}}
    try:
        for mut in mutants:
            write_file(mut.file, mut.source)
            verdict = await run_suite(worktree_path)
            # restore this file before the next mutant (others may share the file)
            write_file(mut.file, originals[mut.file])
            if verdict is SuiteVerdict.ERROR:
                report.skipped += 1
            elif verdict is SuiteVerdict.PASSED:
                report.survived += 1
                report.survivors.append(Survivor(mut.file, mut.line, mut.label))
            else:  # FAILED
                report.killed += 1
    finally:
        for file, content in originals.items():
            write_file(file, content)  # belt-and-braces restore

    if report.budget_capped:
        report.note = f"capped at {max_mutants} of {len(all_mutants)} mutants"
    return report
