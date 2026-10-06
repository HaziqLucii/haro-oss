"""On-demand AI code review ("Review with AI").

Deterministic gate: the merge verdict never waits on an LLM. This module is a library for
``POST /workspaces/{id}/review``, which a human triggers. Two reviewers live here:

* ``run_review``: a single tools-disabled ``claude -p`` text turn over the embedded diff,
  returning structured findings (correctness, security, error handling).
* ``run_code_review``: the same idea with read-only Read/Grep/Glob tools, judging the diff
  against the task/plan when one is recorded and on its own merits when not.

Both run one non-streaming ``claude -p ... --output-format json`` call (not the agent loop
in runner.py) and ask for a strict JSON object back. Parsing tolerates prose/fence-wrapped
JSON and surfaces a clear reason on a failed run. Neither result ever touches a gate
verdict or a TestRun.
"""

from __future__ import annotations

import asyncio
import json
import time

from . import git_ops
from . import sandbox as sandbox_mod
from .models import ReviewFinding, ReviewMustFix, ReviewResult, ReviewVerdict


def _sandbox_wrap(cmd: list[str], *, worktree: str, sandbox: bool) -> tuple[list[str] | None, str | None]:
    """Shared fail-closed wrapping for review.py's one-shot `claude` calls.

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

NOTHING_TO_REVIEW = "Nothing to review: the diff vs base is empty."
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
        return ReviewResult(ran_at=ran_at, model=model, summary=NOTHING_TO_REVIEW, nothing_to_review=True)

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


_PLAN_CAP = 8_000


# --------------------------------------------------------------------------- #
# The code reviewer (on demand)
# --------------------------------------------------------------------------- #
# On demand only: a human triggers it, the gate never does. When a gate run exists its facts
# are handed over as evidence so the code reviewer spends its budget on what tests structurally
# cannot answer: correctness vs the task, missed edge cases, silent scope drift, cheating a
# suite too thin to catch. Unlike run_review it carries READ-ONLY tools (Read/Grep/Glob)
# rather than judging the diff text alone, because "is this actually correct" often needs a
# function's other call sites or the file in full. Two guardrails, enforced in parsing rather
# than trusted to the prompt: cite-or-drop, and only a verdict with a surviving must-fix can
# fail.
_CODE_REVIEW_TIMEOUT_S = 420  # it has tools to use, so it gets a generous wall-clock cap

_CODE_REVIEW_SYSTEM = (
    "You are a code reviewer: an independent reviewer verifying a green test gate actually "
    "proves the task is done. You may use Read/Grep/Glob to open files around the diff "
    "for context, but you write no files and run no commands. Write no preamble, "
    "explanation, or narration. Your entire reply MUST be a single valid JSON object "
    "that begins with the character { and contains nothing else."
)


def _build_code_review_prompt(task: str | None, plan: str | None, gate_facts: str, diff: str, truncated: bool) -> str:
    plan_block = (
        f"\n\nApproved plan / handoff notes the author was working from:\n{plan.strip()[:_PLAN_CAP]}"
        if plan and plan.strip()
        else ""
    )
    trunc = "\n\n(NOTE: the diff was truncated to fit: judge only what you can see.)" if truncated else ""
    task_block = (
        f"THE TASK THE AUTHOR WAS GIVEN:\n{task.strip()}"
        if task and task.strip()
        else "NO TASK WAS RECORDED for this change: judge the diff on its own merits (what it "
        "evidently sets out to do), and do not flag missing scope you cannot infer from the code."
    )
    return (
        "Latest test-gate facts for this change (they may say no gate has run). Take them "
        f"as given and do NOT re-run the tests yourself, you have no Bash tool:\n{gate_facts}\n\n"
        f"{task_block}{plan_block}\n\n"
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


def parse_code_review_verdict(result_text: str) -> tuple[str, str, list[ReviewMustFix], list[str]]:
    """Parse the code reviewer's JSON into ``(verdict, summary, must_fix, notes)``.

    Same two guardrails as ``parse_plan_verdict``: an **uncited** must-fix is dropped,
    and a "fail" verdict whose must-fix list was entirely dropped downgrades to "pass"
    (with a note explaining why, appended to both ``notes`` and ``summary`` so a reader
    never sees a bare "fail" with nothing under it). Raises on unparseable input so the
    caller can report an honest error.
    """
    data = json.loads(_extract_json_object(_strip_fences(result_text)))
    if not isinstance(data, dict):
        raise ValueError("code review verdict was not a JSON object")

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
        note = "the code reviewer reported fail but cited no diff lines for any must-fix"
        notes.append(note)
        summary = f"{summary} — {note}" if summary else note
    return verdict, summary, must_fix, notes


async def run_code_review(
    *,
    worktree_path: str,
    base_ref: str,
    task: str | None = None,
    plan: str | None = None,
    gate_facts: str = "",
    model: str = "sonnet",
    effort: str = "",
    sandbox: bool = False,
    max_budget_usd: float | None = None,
) -> ReviewVerdict:
    """Re-check a green gate's diff against the task/plan, with read-only tools to open
    files around the diff. Never raises: every failure comes back with ``error`` set, and
    an empty diff comes back as ``nothing_to_review`` (not an error).
    """
    ran_at = time.time()
    try:
        diff_text, count = await git_ops.diff(worktree_path, base_ref)
    except git_ops.GitError as exc:
        return ReviewVerdict(ran_at=ran_at, model=model, error=f"git diff failed: {exc.stderr}")
    if count == 0 or not diff_text.strip():
        return ReviewVerdict(ran_at=ran_at, model=model, summary=NOTHING_TO_REVIEW, nothing_to_review=True)

    truncated = len(diff_text) > _DIFF_CAP
    prompt = _build_code_review_prompt(task, plan, gate_facts, diff_text[:_DIFF_CAP], truncated)
    cmd = [
        "claude", "-p", prompt, "--output-format", "json",
        # Unlike run_review's `--tools ""`: the code reviewer may open files around the diff
        # for context, which is what makes it a code reviewer rather than a diff-reader. Read-only, so it cannot edit anything it opens. This
        # multi-value argv form (not a comma-joined string) is verified against the
        # installed CLI (2.1.273): the `system:init` event's own `tools` list comes
        # back as exactly `["Glob","Grep","Read"]`, confirming it's parsed as three
        # tool names, not silently ignored/falling back to the full default set.
        "--tools", "Read", "Grep", "Glob",
        "--permission-mode", "plan",
        "--model", model,
        "--append-system-prompt", _CODE_REVIEW_SYSTEM,
    ]
    if effort:
        cmd += ["--effort", effort]
    if max_budget_usd and max_budget_usd > 0:
        cmd += ["--max-budget-usd", str(max_budget_usd)]
    # Same STRICTER read-only profile as run_review (no `.git` bind
    # at all): a real tool means a real filesystem surface, so this is where a missing
    # `writable=False` would matter most.
    cmd, wrap_err = _sandbox_wrap(cmd, worktree=worktree_path, sandbox=sandbox)
    if wrap_err:
        return ReviewVerdict(ran_at=ran_at, model=model, error=wrap_err)

    # Same retry-once shape as run_review: an occasional prose preamble despite the
    # system prompt. Hard failures (no CLI, non-zero exit, timeout, an `is_error`
    # envelope) return immediately — retrying those just wastes a run.
    last_error = "the code reviewer produced no output."
    for _attempt in range(2):
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, cwd=worktree_path,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            out, err = await asyncio.wait_for(proc.communicate(), timeout=_CODE_REVIEW_TIMEOUT_S)
        except FileNotFoundError:
            return ReviewVerdict(ran_at=ran_at, model=model, error="the `claude` CLI was not found on PATH")
        except asyncio.TimeoutError:
            return ReviewVerdict(
                ran_at=ran_at, model=model, error=f"the code reviewer timed out after {_CODE_REVIEW_TIMEOUT_S}s"
            )

        if proc.returncode != 0:
            msg = err.decode(errors="replace").strip() or f"claude exited with code {proc.returncode}"
            return ReviewVerdict(ran_at=ran_at, model=model, error=msg)
        raw_out = out.decode(errors="replace").strip()
        if not raw_out:
            last_error = "the code reviewer produced no output (claude exited 0 with empty stdout)."
            continue
        try:
            envelope = json.loads(raw_out)
        except json.JSONDecodeError as exc:
            last_error = f"couldn't parse the code reviewer's output: {exc}"
            continue

        if isinstance(envelope, dict) and envelope.get("is_error"):
            reason = str(envelope.get("result") or envelope.get("subtype") or "unknown error").strip()
            return ReviewVerdict(ran_at=ran_at, model=model, error=f"the code reviewer run failed: {reason}")

        result_text = envelope.get("result", "") if isinstance(envelope, dict) else str(envelope)
        try:
            verdict, summary, must_fix, notes = parse_code_review_verdict(result_text)
        except (json.JSONDecodeError, ValueError, TypeError) as exc:
            # TypeError too: a syntactically-valid JSON object whose `must_fix`/`notes`
            # parsed to a non-iterable (e.g. `"must_fix": 5`) raises TypeError inside
            # parse_code_review_verdict's own iteration, not ValueError. Uncaught, it would
            # be a 500 from POST /workspaces/{id}/review.
            last_error = f"couldn't parse the code reviewer's verdict: {exc}"
            continue

        return ReviewVerdict(
            ran_at=ran_at, model=model, verdict=verdict, summary=summary,
            must_fix=must_fix, notes=notes,
        )

    return ReviewVerdict(ran_at=ran_at, model=model, error=last_error)


def gate_facts_brief(test) -> str:
    """The latest gate run's own facts as a short brief for the code reviewer, so it skips
    re-running the tests and spends its budget on what tests can't answer. A missing run
    is stated plainly rather than refusing to review."""
    if test is None:
        return "no gate has run for this workspace yet."
    parts = [f"{test.passed} passed, {test.failed} failed, {test.total} total (runner: {test.runner})."]
    if test.wall_ms:
        parts.append(f"wall time: {test.wall_ms / 1000:.1f}s.")
    if test.tamper_note:
        parts.append(f"tamper alarm: {test.tamper_note}.")
    if test.unchecked_items is not None:
        parts.append(f"code-to-check: {len(test.unchecked_items)} unchecked row(s).")
    return " ".join(parts)
