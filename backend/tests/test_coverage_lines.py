"""The per-line coverage parser (backlog/code-to-check.md §2).

Pure, so it is tested without spawning vitest. Shapes come from a real
``coverage-final.json`` produced by `@vitest/coverage-v8` on haro's own frontend suite,
not invented: istanbul-shaped entries with ``path`` / ``statementMap`` / ``s``.
"""

from __future__ import annotations

from haro.adapters.test_runner.vitest import _line_hits


def entry(path: str, stmts: dict[str, tuple[int, int]], counts: dict[str, int]) -> dict:
    return {
        "path": path,
        "statementMap": {
            sid: {"start": {"line": a, "column": 0}, "end": {"line": b, "column": 0}}
            for sid, (a, b) in stmts.items()
        },
        "s": counts,
    }


ROOT = "/repo"


def test_single_line_statements_map_to_their_hit_counts():
    raw = {"/repo/src/a.ts": entry("/repo/src/a.ts", {"0": (1, 1), "1": (2, 2)}, {"0": 5, "1": 0})}
    assert _line_hits(raw, ROOT) == {"src/a.ts": {1: 5, 2: 0}}


def test_a_multi_line_statement_marks_every_line_it_spans():
    """A statement spanning 10-12 means all three lines ran, so a diff touching line 11
    must not be reported as cold."""
    raw = {"/repo/src/a.ts": entry("/repo/src/a.ts", {"0": (10, 12)}, {"0": 2})}
    assert _line_hits(raw, ROOT) == {"src/a.ts": {10: 2, 11: 2, 12: 2}}


def test_overlapping_statements_accumulate_so_a_line_is_cold_only_if_all_are():
    """The conservative reading: one hot statement on a line makes the line hot. Summing
    rather than overwriting is what prevents a false 'never ran' row."""
    raw = {"/repo/src/a.ts": entry("/repo/src/a.ts", {"0": (5, 5), "1": (5, 5)}, {"0": 0, "1": 3})}
    assert _line_hits(raw, ROOT)["src/a.ts"][5] == 3


def test_strict_mode_will_not_call_a_never_run_throw_executed():
    """The Verified Hunks honesty bar. Real shape from `@vitest/coverage-v8` on

        5  if (typeof cents !== "number" || Number.isNaN(cents)) {
        6    throw new TypeError("formatUSD: cents must be a number");
        7  }

    where every test passed a valid number: istanbul emits the `if` as 5→7 count=3 around
    the `throw` as 6→6 count=0. Accumulating says line 6 ran 3 times, which would tell a
    reviewer the green suite executed a line it never touched — and then hide it behind
    "collapse the executed". The minimum keeps it in the residue.
    """
    raw = {
        "/repo/src/c.js": entry(
            "/repo/src/c.js", {"0": (5, 7), "1": (6, 6)}, {"0": 3, "1": 0}
        )
    }
    lenient = _line_hits(raw, ROOT)["src/c.js"]
    strict = _line_hits(raw, ROOT, strict=True)["src/c.js"]

    assert lenient[6] == 3, "the lenient map keeps accumulating, for code-to-check"
    assert strict[6] == 0, "the throw never ran, so Verified Hunks must not claim it did"
    assert strict[5] == 3, "the `if` itself genuinely ran and must stay executed"


def test_strict_mode_leaves_a_plainly_executed_line_alone():
    """Strictness must not manufacture false residue where nothing overlaps."""
    raw = {"/repo/src/a.ts": entry("/repo/src/a.ts", {"0": (1, 1), "1": (2, 2)}, {"0": 5, "1": 0})}
    assert _line_hits(raw, ROOT, strict=True) == {"src/a.ts": {1: 5, 2: 0}}


def test_paths_are_made_repo_relative():
    """blame.changed_lines speaks git-relative paths, so the map must too or nothing joins."""
    raw = {"x": entry("/repo/frontend/src/gate.ts", {"0": (1, 1)}, {"0": 1})}
    assert list(_line_hits(raw, ROOT)) == ["frontend/src/gate.ts"]


def test_files_outside_the_repo_are_dropped_not_mangled():
    """Dependencies and virtual modules appear in coverage output; reporting them under a
    path the diff can never match would be noise."""
    raw = {
        "a": entry("/repo/src/a.ts", {"0": (1, 1)}, {"0": 1}),
        "b": entry("/elsewhere/node_modules/dep/index.js", {"0": (1, 1)}, {"0": 1}),
    }
    assert list(_line_hits(raw, ROOT)) == ["src/a.ts"]


def test_malformed_entries_are_skipped_rather_than_raising():
    """A broken signal must be silent, not fatal — the whole feature degrades to None/empty
    rather than sinking a green gate."""
    raw = {
        "ok": entry("/repo/src/ok.ts", {"0": (1, 1)}, {"0": 1}),
        "not_a_dict": "garbage",
        "no_map": {"path": "/repo/src/x.ts"},
        "bad_loc": {"path": "/repo/src/y.ts", "statementMap": {"0": {"start": {}}}, "s": {"0": 1}},
        "bad_count": entry("/repo/src/z.ts", {"0": (1, 1)}, {"0": "not a number"}),
    }
    out = _line_hits(raw, ROOT)
    assert out["src/ok.ts"] == {1: 1}
    assert out.get("src/z.ts") == {1: 0}  # unparseable count reads as cold, not as a crash


def test_empty_input_is_an_empty_map():
    assert _line_hits({}, ROOT) == {}
    assert _line_hits(None, ROOT) == {}


def test_reversed_line_range_is_normalized():
    raw = {"a": entry("/repo/src/a.ts", {"0": (9, 7)}, {"0": 1})}
    assert _line_hits(raw, ROOT) == {"src/a.ts": {7: 1, 8: 1, 9: 1}}
