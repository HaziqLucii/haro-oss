from __future__ import annotations

"""Unit tests for the mutation-score engine (backend/haro/mutation.py).

Pure/injectable by design: `generate_mutants` is IO-free and `run_mutation` takes
an injected `run_suite`, so the whole score can be exercised with no repo and no
vitest — the same decide/act split as merge_queue/race.
"""

import asyncio

from haro.mutation import (
    MutationReport,
    SuiteVerdict,
    generate_mutants,
    run_mutation,
)

SRC = (
    "export function applyDiscount(cents, percentOff) {\n"        # line 1
    "  if (percentOff < 0 || percentOff > 100) throw new Error();\n"  # line 2
    "  return Math.round(cents * (1 - percentOff / 100));\n"      # line 3
    "}\n"                                                          # line 4
)


def _labels_on(line: int, muts) -> set[str]:
    return {m.label for m in muts if m.line == line}


def test_generates_located_mutants_on_added_lines():
    muts = generate_mutants("lib/money.ts", SRC, added_lines=[1, 2, 3, 4])
    # the rounding line must be attacked three ways — the real-bug neighbourhood
    assert {"round → floor", "round → ceil", "round → trunc"} <= _labels_on(3, muts)
    # the guard line gets its comparison flipped
    assert "< → <=" in _labels_on(2, muts) or "> → >=" in _labels_on(2, muts)
    # every mutant is a single-token swap that actually changed the source
    assert all(m.source != SRC for m in muts)


def test_diff_scoped_skips_unchanged_lines():
    # only line 3 is "added" → no mutant may be attributed to the guard on line 2
    muts = generate_mutants("lib/money.ts", SRC, added_lines=[3])
    assert muts, "line 3 has mutable code"
    assert all(m.line == 3 for m in muts)


def _run(**kw) -> MutationReport:
    return asyncio.run(run_mutation(**kw))


def _fixed_runner(verdict: SuiteVerdict):
    async def _run_suite(_wt: str) -> SuiteVerdict:
        return verdict
    return _run_suite


def _noop_write(_f: str, _c: str) -> None:
    pass


def test_all_survive_is_zero_score():
    # a suite that always passes catches nothing → every mutant survives, score 0
    report = _run(
        worktree_path="/x",
        changed={"lib/money.ts": (SRC, [1, 2, 3, 4])},
        run_suite=_fixed_runner(SuiteVerdict.PASSED),
        write_file=_noop_write,
        runner="vitest",
    )
    assert report.supported
    assert report.killed == 0
    assert report.survived == report.total_mutants > 0
    assert report.score == 0


def test_all_killed_is_full_score():
    report = _run(
        worktree_path="/x",
        changed={"lib/money.ts": (SRC, [1, 2, 3, 4])},
        run_suite=_fixed_runner(SuiteVerdict.FAILED),
        write_file=_noop_write,
        runner="vitest",
    )
    assert report.survived == 0
    assert report.score == 100


def test_compile_error_mutants_are_skipped_not_killed():
    # a mutant that won't compile must NOT inflate the score as a "catch"
    report = _run(
        worktree_path="/x",
        changed={"lib/money.ts": (SRC, [1, 2, 3, 4])},
        run_suite=_fixed_runner(SuiteVerdict.ERROR),
        write_file=_noop_write,
        runner="vitest",
    )
    assert report.killed == 0 and report.survived == 0
    assert report.skipped == report.total_mutants
    assert report.score is None  # nothing was actually scored


def test_restores_the_file_after_every_mutant():
    writes: list[tuple[str, str]] = []

    def rec_write(f: str, c: str) -> None:
        writes.append((f, c))

    _run(
        worktree_path="/x",
        changed={"lib/money.ts": (SRC, [3])},
        run_suite=_fixed_runner(SuiteVerdict.FAILED),
        write_file=rec_write,
        runner="vitest",
    )
    # the LAST write to the file must be the original content — never leave a mutant on disk
    assert writes[-1] == ("lib/money.ts", SRC)


def test_unsupported_runner_is_advisory_noop():
    report = _run(
        worktree_path="/x",
        changed={"a.py": ("x = 1\n", [1])},
        run_suite=_fixed_runner(SuiteVerdict.PASSED),
        write_file=_noop_write,
        runner="pytest",
    )
    assert report.supported is False
    assert report.note and "vitest" in report.note


def test_budget_cap_is_deterministic():
    report = _run(
        worktree_path="/x",
        changed={"lib/money.ts": (SRC, [1, 2, 3, 4])},
        run_suite=_fixed_runner(SuiteVerdict.FAILED),
        write_file=_noop_write,
        runner="vitest",
        max_mutants=2,
    )
    assert report.budget_capped
    assert report.scored == 2
