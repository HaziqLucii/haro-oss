"""Autonomy-ladder rung evaluator — earned auto-PR as a deterministic conjunction.

Bet 9 (`backlog/autonomy-ladder.md`): every orchestrator ships *binary* autonomy —
review-everything or YOLO — because computing *earned* trust needs a deterministic
local gate history as substrate, and no incumbent has one. haro does. This module
turns accumulated gate facts into a **graduated merge policy**: a list of individually
displayable ``{key, met, detail}`` conditions ANDed together, plus a project-level
green streak. No scores, no ML — 96% of devs don't fully trust agent code, so the
legible checklist IS the product and the auto-PR switch is the reward at the top.
(Auto-*merging* a green verdict onto the user's own ``main`` unattended was cut
2026-09-17 — a local verdict alone isn't something a stranger's `main` should act
on without a human looking at the PR first.)

Pure of IO, exactly like ``merge_queue.py``: it reads only facts already in the store
(the latest ``TestRun``, the project's run history, the parsed ``ProjectSettings``) and
returns a report. No git, no db, no filesystem — so the ladder logic is unit-testable
by constructing a ``TestRun`` in memory, without a real repo. The IO shell lives elsewhere:
``gate.build_trust_report`` (fetch the facts), the ``GET /workspaces/{id}/trust`` endpoint +
the ``status`` re-broadcast (show them), ``rungs.py`` (**act** on them — the ``auto_pr``
rung fired from the gate-green handoff), and the merge queue's admission
(``policy_armed`` + ``admission_reason`` below, applied in ``main.run_merge_queue``: an armed
project's batch merge inherits the same bar a rung clears). This module decides; nothing here
does anything.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Optional, Sequence

if TYPE_CHECKING:  # imported for annotations only — the body is pure duck-typed reads
    from .config import ProjectSettings
    from .models import TestRun, Workspace


@dataclass
class Condition:
    """One rung condition, individually displayable. ``met`` is the *actual* fact;
    ``required`` is whether it counts toward the overall conjunction (a
    ``require_<key> = false`` in ``[trust]`` shows the condition but drops it from the
    AND). ``detail`` always explains the state — including *why* a condition is unmet
    (guard off, no gate run yet, feature not shipped) so the checklist deep-links a fix."""

    key: str
    met: bool
    detail: str
    required: bool = True
    #: Machine-readable deep-link target for an unmet row's *fix*, set only on the
    #: branch that knows the reason (so the UI needn't parse ``detail``):
    #: ``"gate_settings"`` (a guard is off — toggle it in the Gate settings tab),
    #: ``"run_full"`` (a fast impacted gate ran — re-run the full suite),
    #: ``"ribbon"`` (streak short — see the regression ribbon),
    #: ``"tamper"`` (the suite was weakened — see the ``green*`` findings chip, whose
    #: "restore weakened tests → agent" action is the actual fix). ``None`` ⇒ no link
    #: (the fix is code, not config: write tests, de-flake, ship an unshipped feature).
    fix: Optional[str] = None

    def to_dict(self) -> dict:
        return {
            "key": self.key, "met": self.met, "detail": self.detail,
            "required": self.required, "fix": self.fix,
        }


@dataclass
class TrustReport:
    """The evaluated ladder for one workspace. Denormalized for the dashboard glance
    view + the merge-blocked 409 path (same one-language rule as ``GateSummary``)."""

    enabled: bool
    conditions: list[Condition] = field(default_factory=list)
    streak: int = 0
    streak_required: int = 3
    auto_action: str = "off"
    #: All REQUIRED conditions (incl. streak) hold — the conjunction the ladder gates on.
    met: bool = False
    #: The configured auto action is actually cleared to fire: ``met`` + ``enabled`` +
    #: ``auto_action != "off"``.
    armed: bool = False

    def to_dict(self) -> dict:
        return {
            "enabled": self.enabled,
            "conditions": [c.to_dict() for c in self.conditions],
            "streak": self.streak,
            "streak_required": self.streak_required,
            "auto_action": self.auto_action,
            "met": self.met,
            "armed": self.armed,
        }


def _status(run) -> str:
    """Normalize a run's status to a plain string (``TestRunStatus`` is a str-enum, but
    duck-typed test stand-ins may pass a bare string)."""
    status = getattr(run, "status", None)
    return getattr(status, "value", status)


def _break_reason(run) -> Optional[str]:
    """Why ``run`` doesn't count as a clean green — ``None`` when it does. One source of
    truth for both ``_is_clean_green`` and the streak row's *explanation*: a 0/3 streak
    sitting next to a green gate is a mystery unless we say what reset it.

    A run stops being clean when it didn't pass; when it only passed via the fix loop
    (``autofix`` — needing the loop isn't a *green-first-try*, so fail→autofix→green churn
    can't inflate trust) or via the Live Gate's advisory ``watch`` loop
    (backlog/live-gate.md — impacted-only, so ``scope`` already rejects it; this is the
    explicit second lock so a future full-scope watch mode can never feed the streak); or
    when the tamper alarm flagged it (a ``green*`` — the tests passed, but the suite they
    passed against got weaker). The tamper case matters most: without it the streak is
    exactly the metric an agent games by deleting tests (backlog/tamper-alarm.md §3)."""
    if _status(run) != "passed":
        return "a red gate"
    if list(getattr(run, "degraded_reasons", []) or []):
        # backlog/double-gate.md §0: a run where an enabled check could not run is not a
        # green we can bank. Placed here rather than as a separate condition on purpose —
        # `streak` is required, so breaking the streak already drops `met` to False, and the
        # streak row names the reason. One edit, both effects.
        return "a degraded run (a check could not run)"
    if getattr(run, "trigger", "manual") in ("autofix", "watch"):
        return "an auto-fixed green"
    if list(getattr(run, "tamper_findings", []) or []):
        return "a green* run (tamper findings)"
    return None


def _is_clean_green(run) -> bool:
    """A full-scope run that passed on its own merit — the streak's unit."""
    if getattr(run, "scope", "all") != "all":
        return False
    return _break_reason(run) is None


def _streak(history: Sequence) -> tuple[int, Optional[str]]:
    """Trailing consecutive clean full-scope greens across the project's runs, plus *what
    stopped the count* (``None`` when nothing did). ``history`` is chronological
    (oldest→newest); we walk newest→oldest and stop at the first run that isn't a clean
    green. Impacted fast-gate runs aren't part of the trust substrate, so they're skipped
    (neither counted nor streak-breaking); any *full-scope* red, autofix green, or
    ``green*`` resets it."""
    streak = 0
    for run in reversed(list(history)):
        if getattr(run, "scope", "all") != "all":
            continue  # fast impacted gate — not a full-scope run, doesn't touch the streak
        if _is_clean_green(run):
            streak += 1
        else:
            return streak, _break_reason(run)
    return streak, None


def evaluate(
    workspace: "Workspace",
    latest_test: Optional["TestRun"],
    project_history: Sequence["TestRun"],
    settings: "ProjectSettings",
) -> TrustReport:
    """Evaluate the autonomy ladder for ``workspace`` from facts already in the store.

    ``latest_test`` is the workspace's most recent gate run (``None`` until one runs);
    ``project_history`` is the project's chronological ``TestRun`` list (for the streak);
    ``settings`` is the parsed ``[trust]`` + ``[gate]`` + ``[workflow]`` policy. Returns a
    ``TrustReport`` — the checklist ANDed over its *required* conditions plus the streak.
    """
    require: dict = dict(getattr(settings, "trust_require", {}) or {})
    conditions: list[Condition] = []

    def add(key: str, met: bool, detail: str, fix: Optional[str] = None) -> None:
        conditions.append(
            Condition(key=key, met=met, detail=detail,
                      required=bool(require.get(key, True)), fix=fix)
        )

    lt = latest_test

    # merge-result green: the gate must run against the tree merged onto base_ref, and
    # that merged tree must be green (an "against the worktree alone" green can go stale
    # under a moving base). Off ⇒ unmet-with-reason, never silently satisfied.
    if not getattr(settings, "gate_merge_result", False):
        add("merge_result", False,
            "merge-result gate off: enable [gate] merge_result to gate the tree merged onto base",
            fix="gate_settings")
    elif lt is None:
        add("merge_result", False, "no gate run yet")
    elif getattr(lt, "merge_conflict", False):
        add("merge_result", False, "base won't merge cleanly: rebase onto base and re-gate")
    else:
        met = _status(lt) == "passed"
        add("merge_result", met,
            "merged tree is green" if met else "gate on the merged tree is not green")

    # coverage delta ≥ 0: no line-coverage regression vs the base_ref baseline. Off ⇒
    # unmet-with-reason (the guard measures the fact this condition needs).
    guard = getattr(settings, "coverage_guard", "off")
    if guard == "off":
        add("coverage", False,
            "coverage guard off: enable [gate] coverage_guard to require no coverage regression",
            fix="gate_settings")
    elif lt is None:
        add("coverage", False, "no gate run yet")
    elif getattr(lt, "coverage_delta", None) is None:
        add("coverage", False, "coverage not measured on the last run")
    else:
        delta = lt.coverage_delta
        met = delta >= 0
        add("coverage", met, f"coverage delta {delta:+.2f} pts vs base")

    # impacted scope fully run: an "impacted" fast-gate green never climbs — only a full
    # suite pass is trustworthy enough for auto-anything.
    if lt is None:
        add("full_scope", False, "no gate run yet")
    else:
        scope = getattr(lt, "scope", "all")
        met = scope == "all"
        add("full_scope", met,
            "full suite ran" if met else f"only the {scope} scope ran: run the full suite",
            fix=None if met else "run_full")

    # zero flaky in the run: the flaky screen must be on (so nondeterminism is even
    # detected) and the last run must have surfaced no suspected-flaky tests.
    if not getattr(settings, "flaky_rerun", False):
        add("no_flaky", False,
            "flaky detector off: enable [workflow] flaky_rerun to screen nondeterminism",
            fix="gate_settings")
    elif lt is None:
        add("no_flaky", False, "no gate run yet")
    else:
        flaky = getattr(lt, "flaky_tests", []) or []
        met = not flaky
        add("no_flaky", met, "no flaky tests" if met else f"{len(flaky)} suspected-flaky test(s)")

    # no tamper findings: the suite the green stands on wasn't weakened — the rung
    # condition that keeps earned auto-merge from being a Goodhart machine
    # (backlog/tamper-alarm.md §3). Off ⇒ unmet-with-reason, like the other guards: an
    # *unmeasured* suite is not a clean suite, and this is the one condition every other
    # one depends on (one `it.skip` moves coverage, flaky and the merge-result green at once).
    #
    # The alarm only measures an otherwise-green, non-partial run (see gate.run_gate), so
    # "zero findings" on a red or on a "re-run failed" loop means *not measured* — say so
    # rather than crediting silence as clean. Within that window the engine can also
    # degrade a crash (or a missing base inventory) to zero findings while otherwise
    # looking like a normal full-scope pass; `TestRun.tamper_measured` (models.py, a
    # genuine tri-state) is what distinguishes that case — checked for `False`
    # specifically, not falsiness, so a row persisted before this field existed (`None`)
    # falls through to the ordinary findings-based check instead of newly failing.
    alarm = getattr(settings, "tamper_alarm", "warn")
    if alarm == "off":
        add("no_tamper", False,
            "tamper alarm off: enable [workflow] tamper_alarm to check test-suite integrity",
            fix="gate_settings")
    elif lt is None:
        add("no_tamper", False, "no gate run yet")
    elif _status(lt) != "passed" or getattr(lt, "scope", "all") == "failed":
        add("no_tamper", False, "not measured: the alarm only reads a whole green gate")
    elif getattr(lt, "tamper_measured", None) is False:
        add("no_tamper", False,
            "not measured: the alarm's engine didn't complete for this run", fix="tamper")
    else:
        findings = list(getattr(lt, "tamper_findings", []) or [])
        note = getattr(lt, "tamper_note", None)
        met = not findings
        add("no_tamper", met,
            "test suite intact vs base" if met
            else f"{len(findings)} tamper finding(s): {note or 'the suite was weakened'}",
            fix=None if met else "tamper")

    # quality gate green: the Double Gate's *other* half — the diff is secrets-, security-
    # and lint-clean, not just test-green (backlog/double-gate.md §1). The key is
    # registered NOW (in `config.TRUST_CONDITIONS`, so `require_quality` parses and the
    # writer round-trips it) so the day `quality.py` records a verdict this condition joins
    # the conjunction with no redesign here — backlog/autonomy-ladder.md §3, "add the key,
    # don't redesign".
    #
    # Until it ships there is no fact to read and no switch to flip, so the row is
    # **omitted** rather than shown-unmet — the one deviation from "off ⇒
    # unmet-with-reason", and it's deliberate: an unsatisfiable condition would disarm
    # every rung on a build that has no quality gate at all, which is worse than a missing
    # row (there'd be no fix to deep-link to either). `quality_enabled` is the shipped-ness
    # signal (the `[quality] enabled` toggle); the moment it exists the row behaves like
    # every other guard — off ⇒ unmet-with-reason, never silently satisfied.
    #
    # The fact it reads, mirroring `tamper_findings` so the ladder still needs no new
    # input: `TestRun.quality_findings` — `None` = not measured on that run, `[]` = measured
    # clean, non-empty = quality-red (plus an optional `quality_note` summary). Findings get
    # no `fix` link because the fix is code, not config (same as a coverage drop or a flaky
    # test); the findings-panel deep-link belongs to backlog/double-gate.md §2.
    quality_enabled = getattr(settings, "quality_enabled", None)
    if quality_enabled is not None:
        findings = getattr(lt, "quality_findings", None) if lt is not None else None
        if not quality_enabled:
            add("quality", False,
                "quality gate off: enable [quality] to require secrets/security/lint clean",
                fix="gate_settings")
        elif lt is None:
            add("quality", False, "no gate run yet")
        elif findings is None:
            add("quality", False, "not measured: no quality verdict on the last gate run")
        elif getattr(lt, "quality_measured", None) is False:
            # A tri-state edge `findings` alone can't see: `quality_findings == []` from
            # EVERY configured scanner being unavailable (missing binary, crash, timeout)
            # looks identical to a real clean scan. Backed by `TestRun.quality_measured`
            # (models.py) — a GENUINE tri-state (`None`/`True`/`False`), checked for the
            # exact value `False` rather than falsiness: `quality_measured` is `None`
            # (not `False`) for a row persisted before this field existed, so old data
            # falls through to the ordinary findings-based check below instead of newly
            # failing every rung with an invented cause. Same fix as receipt.py's quality
            # section, same bug.
            add("quality", False, "not measured: every configured scanner was unavailable this run")
        else:
            findings = list(findings)
            met = not findings
            note = getattr(lt, "quality_note", None)
            add("quality", met,
                "diff is quality-clean (secrets · security · lint)" if met
                else f"{len(findings)} quality finding(s): {note or 'the diff is not quality-green'}")

    # project-level streak: always required (governed by streak_required, not a require_ flag).
    streak, breaker = _streak(project_history or [])
    streak_required = int(getattr(settings, "trust_streak_required", 3))
    streak_met = streak >= streak_required
    streak_detail = f"{streak}/{streak_required} consecutive clean full-scope greens"
    if not streak_met and breaker:
        # Name the reset: "0/3" beside a green gate otherwise reads as a bug, especially
        # when a green* (not a red) is what broke the count.
        streak_detail += f" · {breaker} reset it"
    conditions.append(Condition(
        key="streak", met=streak_met, required=True,
        detail=streak_detail,
        fix=None if streak_met else "ribbon",
    ))

    met = all(c.met for c in conditions if c.required)

    enabled = bool(getattr(settings, "trust_enabled", False))
    auto_action = getattr(settings, "trust_auto_action", "off")
    armed = enabled and met and auto_action != "off"

    return TrustReport(
        enabled=enabled,
        conditions=conditions,
        streak=streak,
        streak_required=streak_required,
        auto_action=auto_action,
        met=met,
        armed=armed,
    )


def policy_armed(settings: "ProjectSettings") -> bool:
    """Has this *project* armed the ladder at all? (``[trust] enabled`` + an
    ``auto_action`` other than ``"off"``.)

    The project-level half of the merge queue's admission rule — a policy fact, read
    straight from config, with no workspace in sight. ``TrustReport.armed`` is the
    per-workspace half. Both must hold for the queue to inherit the ladder, and when
    this is false the queue keeps its original rule (green + committed + idle), because
    a project that never asked for the ladder must not have its merges gated by it.
    """
    return bool(getattr(settings, "trust_enabled", False)) and (
        getattr(settings, "trust_auto_action", "off") != "off"
    )


def admission_reason(report: TrustReport) -> Optional[str]:
    """Why the merge queue won't admit a rung-incomplete workspace — ``None`` when the
    rung is complete and the queue may land it (backlog/autonomy-ladder.md §3).

    Once a project arms ``[trust] auto_action``, being *green* stops being the whole
    admission ticket to the queue: the queue inherits the same bar the auto rungs clear,
    so a batch "merge all green" can't quietly ship work the ladder itself would have
    refused. Rung-incomplete workspaces are **skipped, never refused** — the ④ ship
    button still merges them by hand, which is the honest split: unattended shipping is
    earned, a human clicking merge is not.

    The message names the *unmet condition keys* rather than a count, because the keys
    are what the checklist rows are called — "coverage, streak unmet" points straight at
    the two rows to go read.

    Only meaningful behind ``policy_armed(settings)``: these messages read as ladder
    verdicts, which is only truthful for a project that actually armed the ladder.
    """
    if report.armed:
        return None
    unmet = [c.key for c in report.conditions if c.required and not c.met]
    if not unmet:
        # Every *required* condition holds yet the rung still isn't armed — the ladder
        # itself is off, or auto_action is "off".
        return (
            "trust ladder: not enabled, or auto_action is off — merge by hand instead"
        )
    return (
        f"trust ladder incomplete: {', '.join(unmet)} unmet — merge by hand instead"
    )
