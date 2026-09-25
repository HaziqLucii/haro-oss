"""Plan compliance — the Double Gate's LLM third (backlog/double-gate.md §3).

Almost every test here is about the ANTI-RATIONALIZATION GUARDRAIL, because that is the
whole design. An LLM asked "does this diff implement the task?" always produces a
confident-sounding answer, so the parser assumes the model is sometimes wrong and enforces
two rules structurally rather than asking the prompt nicely:

  1. **Cite or it didn't happen** — a gap with no quoted diff line is an opinion, and
     opinions don't block merges.
  2. **Confidence gates blocking** — only HIGH-confidence non-compliance can refuse a ship.

A guardrail a model can talk its way past is not a guardrail, which is why these are tested
at the parse boundary and not by inspecting the prompt text.
"""

from __future__ import annotations

import json

import pytest

from haro.models import PlanComplianceResult, PlanGap
from haro.review import parse_plan_verdict


def _verdict(**kw) -> str:
    base = {"compliant": True, "confidence": "high", "summary": "ok", "gaps": []}
    base.update(kw)
    return json.dumps(base)


# --- guardrail 1: cite or it didn't happen --------------------------------- #

def test_an_uncited_gap_is_dropped():
    """The hallucinated-blocker case. A gap the model can't ground in the diff must never
    become a reason someone can't merge."""
    _, _, _, gaps = parse_plan_verdict(_verdict(
        compliant=False,
        gaps=[{"item": "add retry logic", "why": "missing", "cited": ""}],
    ))
    assert gaps == []


def test_a_cited_gap_survives():
    _, _, _, gaps = parse_plan_verdict(_verdict(
        compliant=False,
        gaps=[{"item": "add retry", "why": "no retry loop", "cited": "+ return fetch(url)"}],
    ))
    assert len(gaps) == 1
    assert gaps[0].item == "add retry" and "fetch" in gaps[0].cited


def test_non_compliance_with_every_gap_dropped_downgrades_instead_of_blocking():
    """It claimed the diff is wrong but couldn't cite one line. That is not evidence, so
    it degrades to low confidence — which, by `blocking`, cannot refuse a merge."""
    compliant, confidence, summary, gaps = parse_plan_verdict(_verdict(
        compliant=False, confidence="high",
        gaps=[{"item": "x", "why": "y", "cited": ""}],
    ))
    assert gaps == [] and confidence == "low"
    assert "cited no diff lines" in summary
    assert PlanComplianceResult(
        ran_at=0, compliant=compliant, confidence=confidence, gaps=gaps
    ).blocking is False


def test_a_malformed_gap_entry_is_skipped_not_fatal():
    _, _, _, gaps = parse_plan_verdict(_verdict(
        compliant=False,
        gaps=["not an object", {"item": "", "cited": "x"}, {"item": "real", "cited": "+ line"}],
    ))
    assert [g.item for g in gaps] == ["real"]


# --- guardrail 2: confidence gates blocking -------------------------------- #

def test_only_high_confidence_non_compliance_blocks():
    high = PlanComplianceResult(ran_at=0, compliant=False, confidence="high",
                                gaps=[PlanGap(item="i", cited="c")])
    low = PlanComplianceResult(ran_at=0, compliant=False, confidence="low",
                               gaps=[PlanGap(item="i", cited="c")])
    assert high.blocking is True
    assert low.blocking is False, "a model that is unsure must not refuse a merge"


def test_compliance_never_blocks_however_confident():
    ok = PlanComplianceResult(ran_at=0, compliant=True, confidence="high")
    assert ok.blocking is False


def test_unknown_confidence_values_fall_back_to_low():
    """Fail toward not-blocking: an unrecognised label is not evidence of certainty."""
    _, confidence, _, _ = parse_plan_verdict(_verdict(confidence="extremely"))
    assert confidence == "low"


def test_confidence_is_case_insensitive():
    _, confidence, _, _ = parse_plan_verdict(_verdict(confidence="HIGH"))
    assert confidence == "high"


# --- parsing robustness ----------------------------------------------------- #

def test_fenced_json_still_parses():
    """The model is told not to fence its output; it sometimes does anyway."""
    compliant, _, summary, _ = parse_plan_verdict("```json\n" + _verdict(summary="fine") + "\n```")
    assert compliant is True and summary == "fine"


def test_prose_wrapped_json_still_parses():
    compliant, _, _, _ = parse_plan_verdict("Sure! Here you go:\n" + _verdict() + "\nHope that helps.")
    assert compliant is True


def test_garbage_raises_so_the_caller_can_report_it():
    """Unparseable output must surface as an honest error, never as a silent pass."""
    with pytest.raises((json.JSONDecodeError, ValueError)):
        parse_plan_verdict("I could not review this.")


def test_long_fields_are_clamped():
    _, _, _, gaps = parse_plan_verdict(_verdict(
        compliant=False, gaps=[{"item": "x" * 999, "why": "y" * 999, "cited": "z" * 999}],
    ))
    assert len(gaps[0].item) <= 300 and len(gaps[0].why) <= 500 and len(gaps[0].cited) <= 500


# --- "couldn't run" is not "compliant" -------------------------------------- #

def test_no_task_recorded_is_an_error_not_a_pass():
    """Nothing to audit against is an unanswerable question. Calling it compliant would
    let a rung arm on a check that never happened."""
    import asyncio
    from haro import review

    r = asyncio.run(review.run_plan_compliance(
        worktree_path="/tmp", base_ref="main", task=None,
    ))
    assert r.error and "nothing to audit" in r.error
    assert r.blocking is False


def test_config_defaults_plan_compliance_off(tmp_path):
    """Opting into secret scanning must not silently opt you into paying for an LLM audit
    on every green gate — the two switches are deliberately separate."""
    from haro import config

    (tmp_path / ".haro").mkdir()
    (tmp_path / ".haro" / "settings.toml").write_text("[quality]\nenabled = true\n")
    s = config.load_project_settings(str(tmp_path))
    assert s.quality_enabled is True
    assert s.quality_plan_compliance == "off"


def test_config_rejects_an_unknown_plan_compliance_mode(tmp_path):
    from haro import config

    (tmp_path / ".haro").mkdir()
    (tmp_path / ".haro" / "settings.toml").write_text('[quality]\nplan_compliance = "sometimes"\n')
    assert config.load_project_settings(str(tmp_path)).quality_plan_compliance == "off"
