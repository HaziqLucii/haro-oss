"""AI code review — the "quality" half of the verify step's Double Gate.

Once the *test* gate is green (or on demand), a reviewer agent reads the
worktree diff and returns structured findings: correctness bugs, security
issues, missing error handling, plan-compliance — the things tests can't catch.
It's the on-strategy extension of the merge-gate (see
notes/differentiation-bets.md Bet 7), but **advisory**: findings surface beside
the test grid and round-trip to the composer as a fix; only a red *test* gate
blocks the merge. Keeping AI review non-blocking by default is deliberate — the
mechanical gate stays the hard wall, the LLM pass stays noise-tolerant.

Implementation is a single non-streaming ``claude -p ... --output-format json``
call (not the full agent loop in runner.py): the diff is embedded in the prompt
and we ask for a strict JSON object back, so parsing is deterministic. Tools are
disabled (``--tools ""``) so the reviewer stays a single text turn — with tools
enabled it could wander into file reads and burn its turns until it exits with an
empty result (the failure mode behind the "couldn't parse" errors). Parsing is
tolerant of prose/fence-wrapped JSON and surfaces a clear reason on a failed run.
This is the simplest cut that ships; a streaming / deterministic-first
(gitleaks/semgrep) layering is a later bet.
"""

from __future__ import annotations

import asyncio
import json
import time

from . import git_ops
from . import sandbox as sandbox_mod
from .models import PlanComplianceResult, PlanGap, ReviewFinding, ReviewMustFix, ReviewResult, ReviewVerdict


def _sandbox_wrap(cmd: list[str], *, worktree: str, sandbox: bool) -> tuple[list[str] | None, str | None]:
    """Shared fail-closed wrapping for review.py's two one-shot `claude` calls.

    Both are read-only, tools-disabled turns (the diff is embedded in the
    prompt), so they get the STRICTER profile: read-only worktree, no `.git`
    bind at all — a smaller surface than the main agent's, and one that fails
    visibly if a future change re-enables tools instead of silently gaining
    write access. Returns (wrapped_cmd, None) on success, or (None, error) to
    surface as the caller's normal error path — same fail-closed contract as
    ClaudeCodeAdapter (see sandbox.py's module docstring: an unsandboxed
    bypassPermissions-style run must not silently proceed once sandboxing was
    requested).
    """
    if not sandbox:
        return cmd, None
    if not sandbox_mod.bwrap_available():
        return None, "[agent] sandbox is on but bwrap is not installed"
    wrapped = sandbox_mod.wrap_agent_command(cmd, worktree=worktree, writable=False)
    if wrapped is None:
        return None, "`claude` CLI not found on PATH. Install Claude Code."
    return wrapped, None

# Cap the diff we hand the reviewer so a huge change doesn't blow the prompt (and
# cost). Truncation is flagged in the prompt so the model knows it saw a slice.
_DIFF_CAP = 60_000
#: Wall-clock cap for the plan-compliance pass. It sits on the GATE path (unlike the
#: on-demand reviewer above, which a human waits on and can cancel), so a model that hangs
#: would hang the verdict. Timing out degrades the run — honest, and bounded.
_TIMEOUT_S = 180

# Run in the worktree, the reviewer inherits the project's + the user's global
# CLAUDE.md (memory reminders and all). That can prime a conversational preamble —
# "I'll check my memory for prior context first…" — which emits no JSON object and
# fails parsing at char 0. This appended system prompt forbids the preamble; the
# retry in ``run_review`` mops up the occasional miss. We deliberately do NOT use
# ``--bare`` to isolate the run: it also skips the keychain/auth read, so every
# review comes back "Not logged in".
_REVIEW_SYSTEM = (
    "You are a code-review JSON generator. You have no tools and no memory to "
    "consult — do not attempt to read files or recall prior context, and do not "
    "announce that you will. Write no preamble, explanation, or narration. Your "
    "entire reply MUST be a single valid JSON object that begins with the "
    "character { and contains nothing else."
)


def _build_prompt(diff: str, task: str | None, truncated: bool) -> str:
    task_line = task.strip() if task and task.strip() else "(not recorded)"
    trunc_note = (
        "\n\n(NOTE: the diff was truncated to fit — review what you can see.)"
        if truncated
        else ""
    )
    return (
        "You are a meticulous senior code reviewer. Review ONLY the git diff below "
        "(the branch vs its base). Do NOT modify any files.\n\n"
        f"Task the author was given:\n{task_line}\n\n"
        "Focus on what automated tests can't catch: correctness bugs, security "
        "issues (hardcoded secrets, injection, unsafe eval/exec), missing error "
        "handling, and whether the diff actually implements the task above. "
        "Ignore pure formatting/style.\n\n"
        "Output ONLY a single JSON object — no prose, no markdown fences — in "
        "exactly this shape:\n"
        '{"summary": "<one sentence overall verdict>", "findings": [{"file": '
        '"<repo-relative path>", "line": <integer or null>, "severity": '
        '"high|medium|low|nit", "category": "<short slug e.g. correctness, '
        'security, error-handling, plan-compliance>", "title": "<short one-line>", '
        '"detail": "<why it matters + concrete suggested fix>"}]}\n'
        "If the diff looks good, return an empty findings array.\n\n"
        f"DIFF:\n{diff}{trunc_note}"
    )


def _strip_fences(text: str) -> str:
    """Best-effort unwrap of a ```json … ``` block the model may add despite being
    told not to — so parsing survives a fenced response."""
    s = text.strip()
    if s.startswith("```"):
        s = s.split("\n", 1)[1] if "\n" in s else s
        if s.endswith("```"):
            s = s[: -3]
    return s.strip()


def _extract_json_object(text: str) -> str:
    """Pull the JSON object out of a reviewer reply that may be wrapped in prose
    despite the prompt asking for bare JSON. We scan for the first ``{`` and walk
    to its matching ``}`` (tracking string state so braces inside strings don't
    fool the counter). Falls back to the fence-stripped text if no object is found,
    so a genuinely-JSON reply still parses and a genuinely-empty one still raises a
    clear error downstream."""
    stripped = _strip_fences(text)
    start = stripped.find("{")
    if start == -1:
        return stripped
    depth = 0
    in_str = False
    escaped = False
    for i in range(start, len(stripped)):
        ch = stripped[i]
        if in_str:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return stripped[start : i + 1]
    return stripped


def parse_findings(result_text: str) -> tuple[str, list[ReviewFinding]]:
    """Parse the reviewer's JSON payload into (summary, findings). Raises ValueError
    on anything we can't turn into findings — the caller maps that to an error
    ReviewResult so the UI shows "couldn't parse" rather than silently empty."""
    if not result_text.strip():
        raise ValueError("the reviewer returned an empty response")
    obj = json.loads(_extract_json_object(result_text))
    if not isinstance(obj, dict):
        raise ValueError("reviewer did not return a JSON object")
    summary = str(obj.get("summary", "") or "")
    findings: list[ReviewFinding] = []
    for raw in obj.get("findings", []) or []:
        if not isinstance(raw, dict):
            continue
        sev = str(raw.get("severity", "medium")).lower()
        if sev not in ("high", "medium", "low", "nit"):
            sev = "medium"
        findings.append(
            ReviewFinding(
                file=str(raw.get("file", "?")),
                line=raw.get("line") if isinstance(raw.get("line"), int) else None,
                severity=sev,  # type: ignore[arg-type]
                category=str(raw.get("category", "review") or "review"),
                title=str(raw.get("title", "") or "(untitled finding)"),
                detail=str(raw.get("detail", "") or ""),
            )
        )
    return summary, findings


async def run_review(
    *,
    worktree_path: str,
    base_ref: str,
    task: str | None = None,
    model: str = "sonnet",
    sandbox: bool = False,
) -> ReviewResult:
    """Run one AI review pass over the worktree diff and return structured findings.

    Never raises: a missing CLI, empty diff, non-zero exit, or unparseable output
    all come back as a ReviewResult with ``error`` set (findings empty) so the
    endpoint can return 200 and the UI renders the reason inline.
    """
    ran_at = time.time()
    try:
        diff_text, count = await git_ops.diff(worktree_path, base_ref)
    except git_ops.GitError as exc:
        return ReviewResult(ran_at=ran_at, model=model, error=f"git diff failed: {exc.stderr}")

    if count == 0 or not diff_text.strip():
        return ReviewResult(
            ran_at=ran_at, model=model, error="No changes to review yet: the diff vs base is empty."
        )

    truncated = len(diff_text) > _DIFF_CAP
    prompt = _build_prompt(diff_text[:_DIFF_CAP], task, truncated)

    cmd = [
        "claude",
        "-p",
        prompt,
        "--output-format",
        "json",
        # The whole diff is embedded in the prompt, so the reviewer needs no
        # tools. Disabling them keeps this a single text turn — it can't wander
        # into file reads and burn turns until it exits with an empty result
        # (the failure mode behind the "couldn't parse" errors).
        "--tools",
        "",
        "--permission-mode",
        "bypassPermissions",
        "--model",
        model,
        # Forbid the CLAUDE.md/memory-induced preamble (see _REVIEW_SYSTEM).
        "--append-system-prompt",
        _REVIEW_SYSTEM,
    ]
    cmd, wrap_err = _sandbox_wrap(cmd, worktree=worktree_path, sandbox=sandbox)
    if wrap_err:
        return ReviewResult(ran_at=ran_at, model=model, error=wrap_err)

    # Even with the system prompt, the reviewer occasionally opens with prose
    # instead of the JSON object (non-deterministic). One retry takes the failure
    # rate from ~1-in-4 to negligible. Hard failures — no CLI, non-zero exit, an
    # ``is_error`` envelope — return immediately; retrying those just wastes a run.
    last_error = "the reviewer produced no output."
    for _attempt in range(2):
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=worktree_path,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                limit=16 * 1024 * 1024,
            )
        except FileNotFoundError:
            return ReviewResult(
                ran_at=ran_at, model=model, error="`claude` CLI not found on PATH. Install Claude Code."
            )

        out, err = await proc.communicate()
        if proc.returncode != 0:
            msg = err.decode(errors="replace").strip() or f"claude exited with code {proc.returncode}"
            return ReviewResult(ran_at=ran_at, model=model, error=msg)

        raw_out = out.decode(errors="replace").strip()
        if not raw_out:
            last_error = "the reviewer produced no output (claude exited 0 with empty stdout)."
            continue
        try:
            envelope = json.loads(raw_out)
        except json.JSONDecodeError as exc:
            last_error = f"couldn't parse the reviewer's output: {exc}"
            continue

        # The CLI signals a failed run (max turns, API/credit error, refusal) via
        # ``is_error``; its ``result`` is then an error string, not our JSON —
        # surface that reason instead of a misleading "couldn't parse", and don't
        # retry (the run itself failed, not just the shape).
        if isinstance(envelope, dict) and envelope.get("is_error"):
            reason = str(envelope.get("result") or envelope.get("subtype") or "unknown error").strip()
            return ReviewResult(ran_at=ran_at, model=model, error=f"the reviewer run failed: {reason}")

        result_text = envelope.get("result", "") if isinstance(envelope, dict) else str(envelope)
        try:
            summary, findings = parse_findings(result_text)
        except (json.JSONDecodeError, ValueError) as exc:
            last_error = f"couldn't parse the reviewer's output: {exc}"
            continue

        return ReviewResult(ran_at=ran_at, model=model, summary=summary, findings=findings)

    return ReviewResult(ran_at=ran_at, model=model, error=last_error)


# --------------------------------------------------------------------------- #
# Plan compliance — the Double Gate's LLM third (backlog/double-gate.md §3)
# --------------------------------------------------------------------------- #
#
# The one question tests structurally cannot answer: a suite can be green, secret-free and
# lint-clean over code that solves a *different problem* than the one asked for. That is
# also the most expensive question to ask, which is why this runs last and only on an
# otherwise-green gate — the cheap deterministic checks earn the right to spend a model
# call, never the other way round.
#
# THE ANTI-RATIONALIZATION GUARDRAIL is the whole design. An LLM asked "does this diff
# implement the task?" will always produce a confident-sounding answer, and the failure
# mode the kill conditions name is a reviewer that rationalizes any diff as compliant (or,
# worse, invents a gap and blocks a good merge). Two structural defences, neither of which
# relies on the model behaving:
#
#   1. **Cite or it didn't happen.** Every judgement must quote the diff hunk backing it.
#      A gap with no citation is an opinion, and `_parse_plan` drops it.
#   2. **Confidence gates blocking, not the verdict.** Only a HIGH-confidence
#      non-compliance blocks a merge; low confidence warns. A model that can't ground its
#      claim is telling you it is guessing, and a guess must not refuse a merge.
#
# Both are enforced HERE, in parsing, rather than by asking the prompt nicely — a
# guardrail a model can talk its way past is not a guardrail.

_PLAN_CAP = 8_000


def _build_plan_prompt(diff: str, task: str, plan: str | None, truncated: bool) -> str:
    plan_block = (
        f"\n\nAdditional plan / handoff notes the author was working from:\n{plan.strip()[:_PLAN_CAP]}"
        if plan and plan.strip()
        else ""
    )
    trunc = "\n\n(NOTE: the diff was truncated to fit — judge only what you can see.)" if truncated else ""
    return (
        "You are auditing whether a code change does what it was asked to do. "
        "Do NOT review style, and do NOT modify files.\n\n"
        f"THE TASK THE AUTHOR WAS GIVEN:\n{task.strip()}{plan_block}\n\n"
        "Break the task into its concrete requirements. For EACH requirement, decide "
        "whether the diff below implements it, and QUOTE the line(s) from the diff that "
        "prove your answer.\n\n"
        "Rules that matter more than being helpful:\n"
        "- If you cannot quote a specific line from the diff to support a claim, you MUST "
        "NOT make that claim. Say you are unsure instead.\n"
        "- Do not credit a requirement as done because it 'looks handled' or because the "
        "tests pass. Only the diff counts.\n"
        "- Do not invent requirements the task did not state.\n"
        "- Set confidence to \"high\" ONLY if the task was specific enough to audit and "
        "you could quote the diff for every requirement. Otherwise \"low\".\n\n"
        "Output ONLY a single JSON object — no prose, no markdown fences:\n"
        '{"compliant": <true|false>, "confidence": "high|low", '
        '"summary": "<one sentence>", "gaps": [{"item": "<the requirement>", '
        '"why": "<what is missing or wrong>", "cited": "<the diff line(s) you are '
        'relying on, verbatim; empty string if you could not find any>"}]}\n'
        "An empty gaps array means every requirement is implemented.\n\n"
        f"DIFF:\n{diff}{trunc}"
    )


def parse_plan_verdict(result_text: str) -> tuple[bool, str, str, list[PlanGap]]:
    """Parse the reviewer's JSON into ``(compliant, confidence, summary, gaps)``.

    Enforces the guardrail rather than trusting the prompt: an **uncited** gap is dropped,
    and a verdict whose gaps were all dropped is downgraded to compliant-but-low-confidence.
    Raises on unparseable input so the caller can report an honest error.
    """
    data = json.loads(_extract_json_object(_strip_fences(result_text)))
    if not isinstance(data, dict):
        raise ValueError("plan verdict was not a JSON object")

    gaps: list[PlanGap] = []
    for raw in data.get("gaps") or []:
        if not isinstance(raw, dict):
            continue
        item = str(raw.get("item") or "").strip()
        cited = str(raw.get("cited") or "").strip()
        # Cite or it didn't happen. An unsupported gap is exactly the hallucinated
        # blocker this feature cannot afford, so it never becomes one.
        if not item or not cited:
            continue
        gaps.append(PlanGap(item=item[:300], why=str(raw.get("why") or "").strip()[:500], cited=cited[:500]))

    compliant = bool(data.get("compliant", True))
    confidence = "high" if str(data.get("confidence", "")).strip().lower() == "high" else "low"
    summary = str(data.get("summary") or "").strip()[:500]
    if not compliant and not gaps:
        # It claimed non-compliance but could not ground a single gap. Downgrade rather
        # than block on an unevidenced verdict — and SAY so alongside whatever it claimed,
        # rather than quietly keeping its confident sentence over an empty gap list. A
        # reader seeing "non-compliant" with nothing listed would otherwise have no idea
        # whether haro found nothing or hid something.
        confidence = "low"
        note = "the reviewer reported non-compliance but cited no diff lines"
        summary = f"{summary} — {note}" if summary else note
    return compliant, confidence, summary, gaps


async def run_plan_compliance(
    *,
    worktree_path: str,
    base_ref: str,
    task: str | None,
    plan: str | None = None,
    model: str = "sonnet",
    sandbox: bool = False,
) -> PlanComplianceResult:
    """Audit the diff against the task it was given. Never raises: every failure comes
    back with ``error`` set so the gate can degrade honestly instead of guessing."""
    ran_at = time.time()
    if not task or not task.strip():
        # No task recorded ⇒ nothing to audit against. This is NOT compliance; it's an
        # unanswerable question, and pretending otherwise would let the rung arm on a
        # check that never happened.
        return PlanComplianceResult(
            ran_at=ran_at, model=model,
            error="no task was recorded for this workspace, so there is nothing to audit the diff against",
        )
    try:
        diff_text, count = await git_ops.diff(worktree_path, base_ref)
    except git_ops.GitError as exc:
        return PlanComplianceResult(ran_at=ran_at, model=model, error=f"git diff failed: {exc.stderr}")
    if count == 0 or not diff_text.strip():
        return PlanComplianceResult(ran_at=ran_at, model=model, error="the diff vs base is empty")

    truncated = len(diff_text) > _DIFF_CAP
    prompt = _build_plan_prompt(diff_text[:_DIFF_CAP], task, plan, truncated)
    cmd = [
        "claude", "-p", prompt, "--output-format", "json",
        "--tools", "",  # the diff is in the prompt; tools would only let it wander
        "--permission-mode", "plan",
        "--model", model,
    ]
    cmd, wrap_err = _sandbox_wrap(cmd, worktree=worktree_path, sandbox=sandbox)
    if wrap_err:
        return PlanComplianceResult(ran_at=ran_at, model=model, error=wrap_err)
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, cwd=worktree_path,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_S)
    except FileNotFoundError:
        return PlanComplianceResult(ran_at=ran_at, model=model, error="the `claude` CLI was not found on PATH")
    except asyncio.TimeoutError:
        return PlanComplianceResult(ran_at=ran_at, model=model, error=f"the reviewer timed out after {_TIMEOUT_S}s")

    if proc.returncode != 0:
        msg = err.decode(errors="replace").strip() or f"claude exited with code {proc.returncode}"
        return PlanComplianceResult(ran_at=ran_at, model=model, error=msg)
    raw_out = out.decode(errors="replace").strip()
    if not raw_out:
        return PlanComplianceResult(ran_at=ran_at, model=model, error="the reviewer produced no output")
    try:
        envelope = json.loads(raw_out)
    except json.JSONDecodeError as exc:
        return PlanComplianceResult(ran_at=ran_at, model=model, error=f"couldn't parse the reviewer's output: {exc}")
    if isinstance(envelope, dict) and envelope.get("is_error"):
        reason = str(envelope.get("result") or envelope.get("subtype") or "unknown error").strip()
        return PlanComplianceResult(ran_at=ran_at, model=model, error=f"the reviewer run failed: {reason}")

    result_text = envelope.get("result", "") if isinstance(envelope, dict) else str(envelope)
    try:
        compliant, confidence, summary, gaps = parse_plan_verdict(result_text)
    except (json.JSONDecodeError, ValueError) as exc:
        return PlanComplianceResult(ran_at=ran_at, model=model, error=f"couldn't parse the plan verdict: {exc}")
    return PlanComplianceResult(
        ran_at=ran_at, model=model, compliant=compliant,
        confidence=confidence, summary=summary, gaps=gaps,
    )


# --------------------------------------------------------------------------- #
# The refuter (Phase 3 of notes/workflow-roles-plan.md)
# --------------------------------------------------------------------------- #
#
# Consumes the GATE's verdict as evidence instead of re-deriving it: the suite already
# ran (deterministically, via gate.run_gate — tamper alarm and code-to-check included),
# so the refuter spends its budget on what tests structurally cannot answer: correctness
# vs the plan, missed edge cases, silent scope drift, cheating a suite too thin to catch.
# The one structural difference from plan compliance: it carries READ-ONLY tools
# (Read/Grep/Glob) rather than judging the diff text alone, because "is this actually
# correct" often needs to see a function's other call sites or the file it's editing in
# full — that's what makes it a refuter rather than a diff-reader. Same two guardrails as
# plan compliance, enforced in parsing rather than trusted to the prompt: cite-or-drop,
# and only a verdict with a surviving must-fix can fail.
_REFUTER_TIMEOUT_S = 420  # larger than plan compliance's _TIMEOUT_S: it has tools to use

_REFUTER_SYSTEM = (
    "You are a refuter: an independent reviewer verifying a green test gate actually "
    "proves the task is done. You may use Read/Grep/Glob to open files around the diff "
    "for context, but you write no files and run no commands. Write no preamble, "
    "explanation, or narration. Your entire reply MUST be a single valid JSON object "
    "that begins with the character { and contains nothing else."
)


def _build_refuter_prompt(task: str, plan: str | None, gate_facts: str, diff: str, truncated: bool) -> str:
    plan_block = (
        f"\n\nApproved plan / handoff notes the author was working from:\n{plan.strip()[:_PLAN_CAP]}"
        if plan and plan.strip()
        else ""
    )
    trunc = "\n\n(NOTE: the diff was truncated to fit — judge only what you can see.)" if truncated else ""
    return (
        "The test gate for this change already ran. Take these facts as given — do NOT "
        f"re-run the tests yourself, you have no Bash tool:\n{gate_facts}\n\n"
        f"THE TASK THE AUTHOR WAS GIVEN:\n{task.strip()}{plan_block}\n\n"
        "Re-read the changed code against that task (open files around the diff with "
        "Read/Grep/Glob if you need more context than the diff alone shows) and hunt for "
        "what a PASSING suite would not catch: correctness bugs, missed edge cases, "
        "silent scope drift from the task/plan, and a suite that tests the wrong thing or "
        "nothing at all. Do NOT flag style or things the tests already demonstrably cover.\n\n"
        "Rules that matter more than being helpful:\n"
        "- Every must-fix MUST quote the exact diff line(s) or code it is grounded in. If "
        "you cannot cite it, do not raise it.\n"
        "- Do not credit correctness because the tests pass — that is the gate's job, not "
        "yours. You are asking whether the tests SHOULD have caught something and didn't.\n"
        "- Do not invent scope the task did not state.\n"
        "- verdict is \"fail\" ONLY when at least one must-fix has a citation. A hunch you "
        "cannot ground in the diff is a note, not a must-fix.\n\n"
        "Output ONLY a single JSON object — no prose, no markdown fences:\n"
        '{"verdict": "pass|fail", "summary": "<one sentence>", "must_fix": '
        '[{"file": "<repo-relative path>", "line": <integer or null>, "title": '
        '"<short one-line>", "detail": "<why it matters>", "cited": "<the diff line(s) '
        'or code you are relying on, verbatim>"}], "notes": ["<a non-blocking '
        'observation>"]}\n'
        "An empty must_fix array with verdict \"pass\" means nothing correctness-shaped "
        "was found.\n\n"
        f"DIFF:\n{diff}{trunc}"
    )


def parse_refuter_verdict(result_text: str) -> tuple[str, str, list[ReviewMustFix], list[str]]:
    """Parse the refuter's JSON into ``(verdict, summary, must_fix, notes)``.

    Same two guardrails as ``parse_plan_verdict``: an **uncited** must-fix is dropped,
    and a "fail" verdict whose must-fix list was entirely dropped downgrades to "pass"
    (with a note explaining why, appended to both ``notes`` and ``summary`` so a reader
    never sees a bare "fail" with nothing under it). Raises on unparseable input so the
    caller can report an honest error.
    """
    data = json.loads(_extract_json_object(_strip_fences(result_text)))
    if not isinstance(data, dict):
        raise ValueError("refuter verdict was not a JSON object")

    must_fix: list[ReviewMustFix] = []
    for raw in data.get("must_fix") or []:
        if not isinstance(raw, dict):
            continue
        title = str(raw.get("title") or "").strip()
        cited = str(raw.get("cited") or "").strip()
        # Cite or it didn't happen — same guardrail as parse_plan_verdict's gaps.
        if not title or not cited:
            continue
        must_fix.append(
            ReviewMustFix(
                file=str(raw.get("file") or "?"),
                line=raw.get("line") if isinstance(raw.get("line"), int) else None,
                title=title[:200],
                detail=str(raw.get("detail") or "").strip()[:500],
                cited=cited[:500],
            )
        )

    notes = [str(n).strip()[:500] for n in (data.get("notes") or []) if str(n).strip()]
    verdict = "fail" if str(data.get("verdict", "")).strip().lower() == "fail" else "pass"
    summary = str(data.get("summary") or "").strip()[:500]
    if verdict == "fail" and not must_fix:
        # It claimed fail but could not ground a single must-fix. Downgrade rather than
        # block on an unevidenced verdict — and SAY so, rather than quietly keeping its
        # confident sentence over an empty must-fix list.
        verdict = "pass"
        note = "the refuter reported fail but cited no diff lines for any must-fix"
        notes.append(note)
        summary = f"{summary} — {note}" if summary else note
    return verdict, summary, must_fix, notes


async def run_refuter(
    *,
    worktree_path: str,
    base_ref: str,
    task: str | None,
    plan: str | None,
    gate_facts: str,
    model: str = "sonnet",
    effort: str = "",
    sandbox: bool = False,
    max_budget_usd: float | None = None,
) -> ReviewVerdict:
    """Re-check a green gate's diff against the task/plan, with read-only tools to open
    files around the diff (Phase 3 — notes/workflow-roles-plan.md). Never raises: every
    failure comes back with ``error`` set so ``gate.run_gate`` can degrade honestly
    instead of guessing.
    """
    ran_at = time.time()
    if not task or not task.strip():
        # No task recorded ⇒ nothing to refute against — an unanswerable question, not
        # a pass, same as run_plan_compliance's identical refusal.
        return ReviewVerdict(
            ran_at=ran_at, model=model,
            error="no task was recorded for this workspace, so there is nothing to refute the diff against",
        )
    try:
        diff_text, count = await git_ops.diff(worktree_path, base_ref)
    except git_ops.GitError as exc:
        return ReviewVerdict(ran_at=ran_at, model=model, error=f"git diff failed: {exc.stderr}")
    if count == 0 or not diff_text.strip():
        return ReviewVerdict(ran_at=ran_at, model=model, error="the diff vs base is empty")

    truncated = len(diff_text) > _DIFF_CAP
    prompt = _build_refuter_prompt(task, plan, gate_facts, diff_text[:_DIFF_CAP], truncated)
    cmd = [
        "claude", "-p", prompt, "--output-format", "json",
        # Unlike run_review/run_plan_compliance's `--tools ""`: the refuter may open
        # files around the diff for context — that's what makes it a refuter rather
        # than a diff-reader. Read-only, so it cannot edit anything it opens. This
        # multi-value argv form (not a comma-joined string) is verified against the
        # installed CLI (2.1.273): the `system:init` event's own `tools` list comes
        # back as exactly `["Glob","Grep","Read"]`, confirming it's parsed as three
        # tool names, not silently ignored/falling back to the full default set.
        "--tools", "Read", "Grep", "Glob",
        "--permission-mode", "plan",
        "--model", model,
        "--append-system-prompt", _REFUTER_SYSTEM,
    ]
    if effort:
        cmd += ["--effort", effort]
    if max_budget_usd and max_budget_usd > 0:
        cmd += ["--max-budget-usd", str(max_budget_usd)]
    # Same STRICTER read-only profile as run_review/run_plan_compliance (no `.git` bind
    # at all): a real tool means a real filesystem surface, so this is where a missing
    # `writable=False` would matter most.
    cmd, wrap_err = _sandbox_wrap(cmd, worktree=worktree_path, sandbox=sandbox)
    if wrap_err:
        return ReviewVerdict(ran_at=ran_at, model=model, error=wrap_err)

    # Same retry-once shape as run_review: an occasional prose preamble despite the
    # system prompt. Hard failures (no CLI, non-zero exit, timeout, an `is_error`
    # envelope) return immediately — retrying those just wastes a run.
    last_error = "the refuter produced no output."
    for _attempt in range(2):
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, cwd=worktree_path,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            out, err = await asyncio.wait_for(proc.communicate(), timeout=_REFUTER_TIMEOUT_S)
        except FileNotFoundError:
            return ReviewVerdict(ran_at=ran_at, model=model, error="the `claude` CLI was not found on PATH")
        except asyncio.TimeoutError:
            return ReviewVerdict(
                ran_at=ran_at, model=model, error=f"the refuter timed out after {_REFUTER_TIMEOUT_S}s"
            )

        if proc.returncode != 0:
            msg = err.decode(errors="replace").strip() or f"claude exited with code {proc.returncode}"
            return ReviewVerdict(ran_at=ran_at, model=model, error=msg)
        raw_out = out.decode(errors="replace").strip()
        if not raw_out:
            last_error = "the refuter produced no output (claude exited 0 with empty stdout)."
            continue
        try:
            envelope = json.loads(raw_out)
        except json.JSONDecodeError as exc:
            last_error = f"couldn't parse the refuter's output: {exc}"
            continue

        if isinstance(envelope, dict) and envelope.get("is_error"):
            reason = str(envelope.get("result") or envelope.get("subtype") or "unknown error").strip()
            return ReviewVerdict(ran_at=ran_at, model=model, error=f"the refuter run failed: {reason}")

        result_text = envelope.get("result", "") if isinstance(envelope, dict) else str(envelope)
        try:
            verdict, summary, must_fix, notes = parse_refuter_verdict(result_text)
        except (json.JSONDecodeError, ValueError, TypeError) as exc:
            # TypeError too: a syntactically-valid JSON object whose `must_fix`/`notes`
            # parsed to a non-iterable (e.g. `"must_fix": 5`) raises TypeError inside
            # parse_refuter_verdict's own iteration, not ValueError — an independent
            # refuter pass found this exposed as an uncaught 500 via the new on-demand
            # POST /workspaces/{id}/review path (run_gate's blanket `except Exception`
            # already absorbed it into a degraded reason, so this was invisible there).
            last_error = f"couldn't parse the refuter's verdict: {exc}"
            continue

        return ReviewVerdict(
            ran_at=ran_at, model=model, verdict=verdict, summary=summary,
            must_fix=must_fix, notes=notes,
        )

    return ReviewVerdict(ran_at=ran_at, model=model, error=last_error)
