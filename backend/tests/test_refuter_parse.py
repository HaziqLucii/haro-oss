"""The refuter's parse guardrail (Phase 3 of notes/workflow-roles-plan.md) — plan
compliance's sibling, same two structural defenses (test_plan_compliance.py pins
those for `parse_plan_verdict`; this pins the identical shape for
`parse_refuter_verdict`):

  1. **Cite or it didn't happen.** A must-fix with no quoted diff line is dropped.
  2. **A guess must not block.** A "fail" verdict whose must-fix list was entirely
     dropped downgrades to "pass" rather than refusing a merge on nothing.
"""

from __future__ import annotations

import json

import pytest

from haro import review
from haro.review import parse_refuter_verdict


def _verdict(**kw) -> str:
    base = {"verdict": "pass", "summary": "looks right", "must_fix": [], "notes": []}
    base.update(kw)
    return json.dumps(base)


# --- guardrail 1: cite or it didn't happen --------------------------------- #

def test_an_uncited_must_fix_is_dropped():
    _, _, must_fix, _ = parse_refuter_verdict(_verdict(
        verdict="fail",
        must_fix=[{"file": "a.py", "title": "off-by-one", "detail": "", "cited": ""}],
    ))
    assert must_fix == []


def test_a_cited_must_fix_survives():
    _, _, must_fix, _ = parse_refuter_verdict(_verdict(
        verdict="fail",
        must_fix=[{"file": "a.py", "line": 12, "title": "off-by-one",
                   "detail": "loop excludes the last element",
                   "cited": "for i in range(len(xs) - 1):"}],
    ))
    assert len(must_fix) == 1
    assert must_fix[0].file == "a.py" and must_fix[0].line == 12
    assert "range" in must_fix[0].cited


def test_a_must_fix_with_no_title_is_dropped():
    _, _, must_fix, _ = parse_refuter_verdict(_verdict(
        verdict="fail",
        must_fix=[{"file": "a.py", "title": "", "cited": "+ x = 1"}],
    ))
    assert must_fix == []


def test_a_malformed_must_fix_entry_is_skipped_not_fatal():
    _, _, must_fix, _ = parse_refuter_verdict(_verdict(
        verdict="fail",
        must_fix=["not an object", {"title": "", "cited": "x"}, {"title": "real", "cited": "+ line"}],
    ))
    assert [m.title for m in must_fix] == ["real"]


def test_fail_with_every_must_fix_dropped_downgrades_to_pass():
    """It claimed fail but could not ground a single must-fix. That is not evidence,
    so it downgrades — a guess must not refuse a merge."""
    verdict, summary, must_fix, notes = parse_refuter_verdict(_verdict(
        verdict="fail",
        must_fix=[{"file": "a.py", "title": "x", "cited": ""}],
    ))
    assert verdict == "pass"
    assert must_fix == []
    assert any("cited no diff lines" in n for n in notes)
    assert "cited no diff lines" in summary


def test_fail_with_a_surviving_must_fix_stays_fail():
    verdict, _, must_fix, _ = parse_refuter_verdict(_verdict(
        verdict="fail",
        must_fix=[{"file": "a.py", "title": "x", "cited": "+ y"}],
    ))
    assert verdict == "fail"
    assert len(must_fix) == 1


def test_pass_with_notes_is_not_downgraded_or_altered():
    verdict, _, must_fix, notes = parse_refuter_verdict(_verdict(
        verdict="pass", notes=["consider extracting this into a helper"],
    ))
    assert verdict == "pass"
    assert must_fix == []
    assert notes == ["consider extracting this into a helper"]


# --- parsing robustness ------------------------------------------------------ #

def test_an_unknown_verdict_value_falls_back_to_pass():
    verdict, _, _, _ = parse_refuter_verdict(_verdict(verdict="maybe"))
    assert verdict == "pass"


def test_verdict_is_case_insensitive():
    verdict, _, _, _ = parse_refuter_verdict(_verdict(
        verdict="FAIL", must_fix=[{"file": "a.py", "title": "x", "cited": "+ y"}],
    ))
    assert verdict == "fail"


def test_fenced_json_still_parses():
    out = "```json\n" + _verdict(summary="fine") + "\n```"
    _, summary, _, _ = parse_refuter_verdict(out)
    assert summary == "fine"


def test_prose_wrapped_json_still_parses():
    verdict, _, _, _ = parse_refuter_verdict("Sure! Here you go:\n" + _verdict() + "\nHope that helps.")
    assert verdict == "pass"


def test_garbage_raises_so_the_caller_can_report_it():
    with pytest.raises((json.JSONDecodeError, ValueError)):
        parse_refuter_verdict("I could not review this.")


def test_a_non_iterable_must_fix_raises_type_error_not_silently_passing():
    # Caught by an independent refuter pass: a syntactically-valid JSON object whose
    # `must_fix` is not a list (e.g. a bare int) raises TypeError from the `for raw in
    # data.get("must_fix") or []` loop, NOT ValueError — run_refuter's caller must
    # catch this too (see review.py's parse call site), or a malformed model reply
    # crashes the on-demand refuter endpoint instead of degrading gracefully.
    with pytest.raises(TypeError):
        parse_refuter_verdict(_verdict(verdict="fail", must_fix=5))


def test_long_fields_are_clamped():
    _, _, must_fix, _ = parse_refuter_verdict(_verdict(
        verdict="fail",
        must_fix=[{"file": "a.py", "title": "x" * 999, "detail": "y" * 999, "cited": "z" * 999}],
    ))
    assert len(must_fix[0].title) <= 200
    assert len(must_fix[0].detail) <= 500
    assert len(must_fix[0].cited) <= 500


# --- "couldn't run" is not "pass" -------------------------------------------- #

def test_no_task_recorded_is_an_error_not_a_pass():
    """Nothing to refute against is an unanswerable question, not a clean verdict —
    same rule run_plan_compliance follows for the same reason."""
    import asyncio
    from haro import review

    r = asyncio.run(review.run_refuter(
        worktree_path="/tmp", base_ref="main", task=None, plan=None, gate_facts="",
    ))
    assert r.error and "nothing to refute" in r.error
    assert r.verdict == "pass"  # the default, never a confident answer either way


class _FakeProc:
    """Stands in for the `claude` subprocess: a fixed stdout, no stderr, exit 0."""

    def __init__(self, stdout: bytes) -> None:
        self._stdout = stdout
        self.returncode = 0

    async def communicate(self):
        return self._stdout, b""


def test_run_refuter_degrades_instead_of_raising_on_a_non_iterable_must_fix(monkeypatch, tmp_path):
    """End-to-end pin for the widened parse-verdict catch: a malformed model reply
    whose `must_fix` isn't a list must come back as a degraded ReviewVerdict, not an
    uncaught TypeError — the "never raises" contract the docstring promises, and the
    one thing standing between this and a 500 on the on-demand refuter endpoint
    (main.py's POST /workspaces/{id}/review has no try/except of its own)."""
    import asyncio

    async def fake_diff(*_a, **_kw):
        return "diff --git a/a.py b/a.py\n+x = 1\n", 1

    monkeypatch.setattr(review.git_ops, "diff", fake_diff)

    malformed = json.dumps({"verdict": "fail", "must_fix": 5})
    envelope = json.dumps({"result": malformed}).encode()

    async def fake_exec(*_cmd, **_kw):
        return _FakeProc(envelope)

    monkeypatch.setattr(review.asyncio, "create_subprocess_exec", fake_exec)

    result = asyncio.run(review.run_refuter(
        worktree_path=str(tmp_path), base_ref="main", task="fix the bug",
        plan=None, gate_facts="2 passed, 0 failed, 2 total (runner: vitest).",
    ))
    assert result.error is not None
    assert "couldn't parse" in result.error
    assert result.verdict == "pass"  # never a confident answer on a crashed parse
