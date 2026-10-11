"""ClaudeCodeAdapter — run the ``claude`` CLI and normalize its stream-json.

We invoke Claude Code in non-interactive "print" mode:

    claude -p "<task>" --output-format stream-json --verbose \\
           --permission-mode bypassPermissions [--model <model>]

``--output-format stream-json`` emits newline-delimited JSON objects, one per
line. The shapes we care about (see notes/claude-code-stream-json.md, verified
against v2.1.204):

  {"type":"system","subtype":"init", ...}              # session bootstrap
  {"type":"system","subtype":"hook_started"|...}       # hook noise — ignored
  {"type":"system","subtype":"task_notification", ...} # a delegation's TRUE completion (§8A)
  {"type":"assistant","message":{"content":[...]}}     # one event PER content block
  {"type":"user","message":{"content":[...]}}          # tool_result blocks — ignored (see below)
  {"type":"result","subtype":"success", ...}           # final summary + cost/usage

We flatten those into the five normalized event types, switching on ``subtype``
and dropping anything we don't recognize (hook events pollute the stream by
default; ``stream_event``/``rate_limit_event``/``thinking`` blocks are noise for
v0). ``--verbose`` is required for stream-json in print mode.

A sub-agent delegation (the model's own Task/Agent tool) is tracked across
several of these lines at once — see notes/claude-code-stream-json.md §8A for
the full verified protocol. Two facts drove real bugs here: every block
belonging to a delegated sub-agent's OWN turn carries a top-level
``parent_tool_use_id`` (surfaced tagged, `_nested`, for the sub-agent panel); and the tool_result that
closes the delegating tool_use is NOT its true completion when it ran
``run_in_background`` — that tool_result is just "Async agent launched
successfully", arriving almost instantly regardless of how long the sub-agent
actually runs. The authoritative completion is the ``task_notification``
system event instead, which fires at the real finish time either way.
``--permission-mode bypassPermissions`` lets the agent edit without prompting —
safe here *because* it's boxed in a throwaway git worktree: the blast radius is
one disposable branch.

A per-run mode toggle rides on top of that base invocation (feature-detected by the
caller, so a future adapter that lacks it degrades gracefully): ``plan`` swaps in
``--permission-mode plan`` (propose a plan, edit nothing).

**Teardown.** The CLI leads its own process group and ``run``'s ``finally`` kills that
group (``procs.terminate_tree``). Cancelling a run used to unwind this generator and
leave `claude` — plus every tool it had shelled out to — alive and detached, so ⏹ stop,
archive-mid-run and shutdown all leaked a live agent. Every other subprocess owner in
haro already tore down its tree; this was the one that didn't.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import uuid
from typing import Any, AsyncIterator

from .. import sandbox as sandbox_mod
from ..procs import terminate_tree
from .base import AgentAdapter, NormalizedEvent

# Tools whose use means "a file changed" — promoted from tool_call to file_edit
# so the UI (and, later, the Impact Map) can react to edits specifically.
FILE_EDIT_TOOLS = {"Edit", "MultiEdit", "Write", "NotebookEdit", "Update"}

# 16 MB line buffer: a single tool_use input or tool_result (e.g. a big file
# write or a large grep result) can blow past asyncio's 64 KB default.
_STREAM_LIMIT = 16 * 1024 * 1024


def _edit_path(tool_input: dict[str, Any]) -> str | None:
    for key in ("file_path", "notebook_path", "path"):
        if key in tool_input:
            return tool_input[key]
    return None


def _count_lines(s: str) -> int:
    return len(s.splitlines()) if s else 0


def _edit_stats(tool: str, tool_input: dict[str, Any]) -> tuple[int | None, int | None]:
    """Best-effort (added, removed) line counts from an edit tool's input — so the
    stream can show CLI-style `+64 / -3` next to a file edit without needing the
    tool_result. Returns (None, None) when we can't tell (e.g. NotebookEdit)."""
    if tool == "Write":
        return _count_lines(tool_input.get("content", "")), 0
    if tool in ("Edit", "Update"):
        return (
            _count_lines(tool_input.get("new_string", "")),
            _count_lines(tool_input.get("old_string", "")),
        )
    if tool == "MultiEdit":
        added = removed = 0
        for e in tool_input.get("edits", []) or []:
            added += _count_lines(e.get("new_string", ""))
            removed += _count_lines(e.get("old_string", ""))
        return added, removed
    return None, None


_DIFF_CAP = 400  # cap the streamed diff so a huge write doesn't bloat the transcript


def _edit_diff(tool: str, tool_input: dict[str, Any]) -> tuple[list[dict[str, str]], bool]:
    """Signed diff lines for an edit tool — so the stream row can EXPAND to show the
    actual red (removed) / green (added) code, not just the +/- counts. Returns
    ([{sign: "+"|"-", text}], truncated). Empty when we can't derive it."""
    lines: list[dict[str, str]] = []

    def add(sign: str, text: str) -> None:
        for ln in text.splitlines():
            lines.append({"sign": sign, "text": ln})

    if tool == "Write":
        add("+", tool_input.get("content", ""))
    elif tool in ("Edit", "Update"):
        add("-", tool_input.get("old_string", ""))
        add("+", tool_input.get("new_string", ""))
    elif tool == "MultiEdit":
        for e in tool_input.get("edits", []) or []:
            add("-", e.get("old_string", ""))
            add("+", e.get("new_string", ""))
    truncated = len(lines) > _DIFF_CAP
    return lines[:_DIFF_CAP], truncated


# The delegating tool's name for a sub-agent call — "Task" in older CLIs, "Agent" as
# of 2.1.x (notes/claude-code-stream-json.md); matching both keeps this working
# across the rename either direction.
_DELEGATE_TOOLS = {"Agent", "Task"}


def _delegate_info(tool: str, tool_input: dict[str, Any]) -> dict[str, str] | None:
    """Parsed (subagent_type, description) for a sub-agent delegation call, or
    ``None`` for anything else — including an Agent/Task call with no
    `subagent_type`, which ``_summarize_input`` still handles."""
    if tool not in _DELEGATE_TOOLS:
        return None
    subagent = tool_input.get("subagent_type")
    if not subagent:
        return None
    return {"subagent_type": subagent, "description": tool_input.get("description", "")}


def _delegate_summary(info: dict[str, str] | None) -> str | None:
    """"↳ <subagent_type>: <description>" for a sub-agent delegation (e.g. haro's own
    scout, Phase 2 — notes/workflow-roles-plan.md), so it reads as a distinct kind of
    tool call in the stream rather than being summarized by its (long) `prompt`
    field like an ordinary tool_use."""
    if not info:
        return None
    subagent, description = info["subagent_type"], info["description"]
    return f"↳ {subagent}: {description}" if description else f"↳ {subagent}"


# A background `Bash` and a `Monitor` both become a CLI task (`system/task_started`,
# `task_type: "local_bash"`); only the tool that started them tells them apart.
_SHELL_CMD_CAP = 300


def _task_status(raw: Any) -> str:
    """The CLI's ``task_notification`` status as haro's row status."""
    return "done" if raw == "completed" else "stopped" if raw == "stopped" else "error"


def _shell_info(tool: str, tool_input: dict[str, Any]) -> dict[str, str] | None:
    """``{"kind", "command", "description"}`` for a call that starts a background shell
    (``Bash`` with ``run_in_background``) or a monitor, else ``None``."""
    if tool == "Bash" and tool_input.get("run_in_background"):
        kind = "shell"
    elif tool == "Monitor":
        kind = "monitor"
    else:
        return None
    return {
        "kind": kind,
        "command": str(tool_input.get("command") or "")[:_SHELL_CMD_CAP],
        "description": str(tool_input.get("description") or "")[:_SHELL_CMD_CAP],
    }


def _shell_event(shell_id: str, info: dict[str, str], status: str) -> NormalizedEvent:
    """A background shell as a delegation row (``payload.delegate``), so the rail's AGENTS
    list, its status squares and its stop button treat it like a sub-agent with no steps.
    The ``↳`` prefix is what makes the stream draw it as a delegation row."""
    kind = info["kind"]
    label = info["description"] or info["command"] or kind
    summary = f"↳ {kind}: {label}" if status == "running" else f"↳ {kind} {status}: {label}"
    return NormalizedEvent(
        "tool_call",
        {
            "tool": "Monitor" if kind == "monitor" else "Bash",
            "summary": summary,
            "delegate": {
                "id": shell_id,
                "subagent_type": kind,
                "kind": kind,
                "description": label,
                "status": status,
            },
        },
    )


def _summarize_input(tool: str, tool_input: dict[str, Any]) -> str:
    """A one-line, human-readable gist of a tool call for the stream view."""
    if tool == "Bash":
        return tool_input.get("command", "")
    for key in ("file_path", "path", "pattern", "url", "query", "prompt"):
        if key in tool_input:
            return str(tool_input[key])
    blob = json.dumps(tool_input, ensure_ascii=False)
    return blob if len(blob) <= 200 else blob[:200] + "…"


#: After the last sub-agent settles with a run result held back, how long to wait for the CLI to
#: start a follow-up turn (it answers a finished background agent) before the held result stands.
_SETTLE_GRACE_S = 10.0

# After the run's result, stdin is closed and the CLI normally exits within a second. It does NOT
# while a background shell or monitor is alive (verified live: it waits for them, a monitor can
# last 30 minutes), so the run would never finish and the UI would stay on "working". This long
# after the result, the process group is ended.
_EXIT_GRACE_S = 3.0

_DENY_EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
_DENIED_MARK = "denied by your permission settings"


#: What a failed run's `result` subtype means, for when the CLI sends no text with it.
_ERROR_SUBTYPES = {
    "error_max_turns": "The agent stopped because it reached its turn limit.",
    "error_max_budget_usd": "The agent stopped because it reached the run's budget cap.",
    "error_during_execution": "The agent hit an error while running.",
}

#: Safeguard refusal categories (`stop_details.category`), each with what to do about it.
_REFUSAL_HINTS = {
    "cyber": "The request could enable cyber harm. Finding vulnerabilities in source code is "
    "allowed; high-risk dual-use security work is not.",
    "bio": "The request touched biological harm. Everyday health and educational questions are "
    "not affected.",
    "frontier_llm": "The request could help develop competing AI models.",
    "reasoning_extraction": "Something in the task or the project's instructions asks the model "
    "to write out its reasoning in the reply. Remove that instruction.",
    "general_harms": "The request fell under another usage-policy area. Benign work can trigger "
    "this category too.",
}


def _declined(
    ev: NormalizedEvent, result: dict[str, Any], last_stop: tuple[Any, Any]
) -> NormalizedEvent | None:
    """The `error` that replaces a `done` when the model's safeguards declined the request.

    A refusal is a normal reply with ``stop_reason: "refusal"`` and a ``stop_details`` object
    naming the category, and the CLI may still end the run as a success: without this the run
    would read as done, with nothing written, and the gate would then run on an untouched tree.
    The result line is checked first, then the newest turn of the driving agent."""
    reason, details = result.get("stop_reason"), result.get("stop_details")
    if reason is None:
        reason, details = last_stop
    if reason != "refusal":
        return None
    category = details.get("category") if isinstance(details, dict) else None
    category = category if isinstance(category, str) and category else None
    hint = _REFUSAL_HINTS.get(category or "", "")
    label = f" ({category})" if category else ""
    payload = {**ev.payload, "subtype": "refusal", "refusal_category": category}
    payload["message"] = f"The model declined this request{label}. {hint}".strip()
    return NormalizedEvent("error", payload)


#: The tools whose writes the fence hook judges.
_FENCE_MATCHER = "Edit|Write|MultiEdit|NotebookEdit"


def _user_claude_md() -> str:
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "CLAUDE.md")


def _run_settings(
    fence_hook_url: str | None, exclude_user_claude_md: bool, hook_matcher: str | None = None
) -> str | None:
    """The inline ``--settings`` JSON for one run, or None when there is nothing to add.

    ``fence_hook_url``: a PreToolUse HTTP hook on the edit tools. The CLI posts each edit to haro,
    which answers allow or deny with a reason the agent reads, so an out-of-fence write is refused
    before it happens (checked on CLI 2.1.296; Bash writes bypass hooks, the revert after the run
    stays the check). ``exclude_user_claude_md``: ``claudeMdExcludes`` drops the developer's own
    ``~/.claude/CLAUDE.md`` and nothing else (the project CLAUDE.md and the login still load)."""
    settings: dict = {}
    if fence_hook_url:
        settings["hooks"] = {
            "PreToolUse": [
                {
                    "matcher": hook_matcher or _FENCE_MATCHER,
                    "hooks": [{"type": "http", "url": fence_hook_url}],
                }
            ]
        }
    if exclude_user_claude_md:
        settings["claudeMdExcludes"] = [_user_claude_md()]
    return json.dumps(settings) if settings else None


_SNAPSHOT_FLAG: bool | None = None


async def _modern_cli() -> bool:
    """True when the installed `claude` lists `--system-prompt-snapshot` (probed once from
    `claude --help`; a failed probe means no). That flag arrived in a late 2.1 release, after HTTP
    command hooks and `claudeMdExcludes`, so it stands in for "recent enough" for everything haro
    asks of the CLI through `--settings` and for the snapshot flag itself."""
    global _SNAPSHOT_FLAG
    if _SNAPSHOT_FLAG is None:
        try:
            proc = await asyncio.create_subprocess_exec(
                "claude", "--help",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            )
            out, _ = await asyncio.wait_for(proc.communicate(), 10)
            _SNAPSHOT_FLAG = b"--system-prompt-snapshot" in out
        except Exception:  # noqa: BLE001 - no probe, no flag: the run itself must not depend on it
            _SNAPSHOT_FLAG = False
    return _SNAPSHOT_FLAG


async def _snapshot_off_args() -> list[str]:
    """A resumed session replays the system prompt it recorded on its first request and ignores
    the text a later launch passes (verified on CLI 2.1.296: a changed `--append-system-prompt`
    still answered with the old one). haro re-sends its standing instructions on every turn
    expecting edits to apply, so a resume turns the snapshot off. Older CLIs reject the flag, so
    it is only passed when `_modern_cli`."""
    return ["--system-prompt-snapshot", "off"] if await _modern_cli() else []


class ClaudeCodeAdapter(AgentAdapter):
    name = "claude-code"

    def __init__(self, *, skip_permissions: bool = True, sandbox: bool = False):
        self.skip_permissions = skip_permissions
        # Move D step 2 (usp-critique-round3.md): confine the agent subprocess
        # under bwrap instead of handing bare bypassPermissions the whole host.
        # Opt-in ([agent] sandbox), off by default. See sandbox.py's docstring
        # for the full threat model / residuals.
        self.sandbox = sandbox
        # tool_use id -> subagent_type, for the delegations still awaiting a
        # tool_result. Never shared across workspaces, but the runner reuses ONE
        # instance for a run's auto-fix rounds, so `run` resets all per-run state.
        self._pending_delegates: dict[str, str] = {}
        # delegation id -> how many of its OWN steps were surfaced so far (see `_nested`).
        self._nested_counts: dict[str, int] = {}
        # tool_use id -> (tool, path) for edits awaiting a result, and whether this run
        # carries deny rules: only then is a refused edit reported as "blocked".
        self._pending_edits: dict[str, tuple[str, str, NormalizedEvent]] = {}
        self._protected = False
        self._cwd = ""
        # Streaming-input control channel (see `stop_task`): the live process, the task id the
        # CLI gave each delegation (`system/task_started`), and the delegations still working.
        self._proc: Any = None
        self._task_for: dict[str, str] = {}
        self._open_delegations: set[str] = set()
        # Background shells and monitors: tool_use id -> info while the CLI task lives. Kept
        # apart from delegations on purpose: a dev server left running must not hold `done`.
        self._shells: dict[str, dict[str, str]] = {}
        self._open_shells: set[str] = set()

    async def run(
        self,
        *,
        task: str,
        cwd: str,
        model: str | None = None,
        effort: str | None = None,
        resume: str | None = None,
        instructions: str | None = None,
        max_budget_usd: float | None = None,
        plan: bool = False,
        agents: dict | None = None,
        deny_edit_paths: list[str] | None = None,
        run_log_dir: str | None = None,
        app_control: dict[str, str] | None = None,
        fence_hook_url: str | None = None,
        exclude_user_claude_md: bool = False,
        hook_matcher: str | None = None,
    ) -> AsyncIterator[NormalizedEvent]:
        self._protected = bool(deny_edit_paths)
        self._cwd = cwd
        # A previous round that ended mid-delegation (crash, lost task_notification) would
        # otherwise leave a delegation open here and hold this round's `done` forever.
        self._pending_delegates.clear()
        self._nested_counts.clear()
        self._pending_edits.clear()
        self._task_for.clear()
        self._open_delegations.clear()
        self._shells.clear()
        self._open_shells.clear()
        # The prompt goes over stdin as a stream-json user message, not on argv: keeping
        # stdin open is what lets `stop_task` reach one sub-agent mid-run (a stop is a
        # control message). With stdin closed straight after the prompt the CLI behaves
        # exactly as it does with the prompt on argv (verified 2.1.289), so the only
        # difference is that haro decides when to close it (see `_stream`).
        cmd = [
            "claude",
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
        ]
        if instructions and instructions.strip():
            # haro's standing custom instructions for this project — layered
            # on top of the CLI's own system prompt (and any repo CLAUDE.md).
            cmd += ["--append-system-prompt", instructions]
        settings_json = (
            _run_settings(fence_hook_url, exclude_user_claude_md, hook_matcher)
            if (fence_hook_url or exclude_user_claude_md) and await _modern_cli()
            else None
        )
        if settings_json:
            cmd += ["--settings", settings_json]
        if resume:
            # Continue the prior session — the agent keeps its context and Claude
            # Code auto-compacts as it fills up.
            cmd += ["--resume", resume]
            cmd += await _snapshot_off_args()
        if plan:
            # Plan Mode: the agent produces a plan and edits nothing until the dev
            # approves it — the review surface *before* the first file edit. Takes
            # precedence over auto-edit for this run (the caller decides per-run).
            cmd += ["--permission-mode", "plan"]
        elif self.skip_permissions:
            cmd += ["--permission-mode", "bypassPermissions"]
        if model:
            cmd += ["--model", model]
        if effort:
            # Reasoning-effort budget for the session (low|medium|high|xhigh|max).
            cmd += ["--effort", effort]
        if max_budget_usd and max_budget_usd > 0:
            # Hard per-run dollar ceiling: the CLI stops the agent once this run's
            # API spend crosses it (only works with --print, which is our mode).
            # This is the platform's runaway guard — one stuck agent can't burn
            # tokens without bound. Follow-ups are separate invocations, so the cap
            # is per-run, not cumulative (cumulative spend is watched in runner.py).
            cmd += ["--max-budget-usd", str(max_budget_usd)]
        if deny_edit_paths:
            # Deny rules still apply under bypassPermissions (verified, see
            # notes/claude-code-stream-json.md section 12). One rule per edit tool per
            # pattern: the tools' rules don't cover each other.
            cmd += ["--disallowedTools"] + [
                f"{tool}({pat})" for pat in deny_edit_paths for tool in _DENY_EDIT_TOOLS
            ]
        if agents:
            # haro's own sub-agents (scout, Phase 2 — notes/workflow-roles-plan.md), on
            # the argv rather than relying on `~/.claude/agents/*.md` files: those never
            # travel with the project (a fresh machine/CI box has none) and vanish
            # outright under `[agent] sandbox` (its bwrap profile never binds
            # `~/.claude/agents` — see sandbox.py). Verified against the installed CLI
            # (2.1.273): `--agents` MERGES with any filesystem agents of the same name
            # rather than replacing the set, and an array `tools` value is accepted.
            cmd += ["--agents", json.dumps(agents)]

        if shutil.which(cmd[0]) is None:
            yield NormalizedEvent(
                "error",
                {"message": "`claude` CLI not found on PATH. Install Claude Code."},
            )
            return

        if self.sandbox:
            # Fail CLOSED, not degrade-open: an unsandboxed bypassPermissions run
            # is exactly the outcome this flag exists to prevent, so a missing
            # bwrap must stop the run rather than silently continue unwrapped
            # (contrast the test gate's sandbox, which degrades open because an
            # unsandboxed green test run still carries information).
            if not sandbox_mod.bwrap_available():
                yield NormalizedEvent(
                    "error",
                    {"message": "[agent] sandbox is on but bwrap is not installed"},
                )
                return
            wrapped = sandbox_mod.wrap_agent_command(
                cmd,
                worktree=cwd,
                git_dir=sandbox_mod.git_common_dir(cwd),
                writable=True,
                # The app's runtime log lives under ~/.haro, which the sandbox hides.
                extra_ro=tuple(
                    d for d in (run_log_dir, (app_control or {}).get("bin_dir")) if d
                ),
            )
            if wrapped is None:
                yield NormalizedEvent(
                    "error",
                    {"message": "`claude` CLI not found on PATH. Install Claude Code."},
                )
                return
            cmd = wrapped

        # Where haro keeps the running app's output (run_logs.py): the agent watches it with a
        # Monitor instead of starting a shell of its own, which would die with its turn.
        extra_env: dict[str, str] = {}
        if run_log_dir:
            extra_env["HARO_LOG_DIR"] = run_log_dir
            extra_env["HARO_RUN_LOG"] = os.path.join(run_log_dir, "run.log")
        if app_control:
            # `haro-app` (app_ctl.py): start, stop and restart the app haro runs for this workspace.
            extra_env["HARO_API"] = app_control["api"]
            extra_env["HARO_WORKSPACE_ID"] = app_control["workspace_id"]
            extra_env["PATH"] = app_control["bin_dir"] + os.pathsep + os.environ.get("PATH", "")
        env = {**os.environ, **extra_env} if extra_env else None
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=cwd,
                env=env,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                limit=_STREAM_LIMIT,
                # Lead its own process group so the whole tree — `claude` and every
                # tool it shells out to — can be killed as a unit in the teardown
                # below. Without this, stop/archive/shutdown unwound this generator
                # and left a live `claude` running detached, still burning tokens.
                start_new_session=True,
            )
        except FileNotFoundError:
            yield NormalizedEvent(
                "error",
                {"message": "`claude` CLI not found on PATH. Install Claude Code."},
            )
            return

        self._proc = proc
        stream = None
        # The prompt write is inside the try: a large prompt blocks drain() while the CLI
        # boots, and a stop landing there must still kill the (own-process-group) process.
        try:
            await self._send({"type": "user", "message": {"role": "user", "content": task}})
            stream = self._stream(proc, cwd=cwd, resume=resume, effort=effort)
            async for ev in stream:
                yield ev
        finally:
            self._close_stdin()
            self._proc = None
            # Close the inner generator first (it holds the half-read stdout), then the
            # process. The one teardown every haro-owned subprocess shares (procs.terminate_tree):
            # a no-op when `claude` already exited on its own, a SIGTERM→SIGKILL of the
            # group when this generator is closed early (a ⏹ stop, an archive mid-run,
            # shutdown). The runner closes the generator explicitly via ``aclosing`` so
            # this is deterministic rather than left to the garbage collector.
            if stream is not None:
                await stream.aclose()
            await terminate_tree(proc)

    # ---------------------------------------------------------------- control channel
    def _stdin(self):
        stdin = getattr(self._proc, "stdin", None)
        return None if stdin is None or stdin.is_closing() else stdin

    async def _send(self, message: dict[str, Any]) -> bool:
        """One NDJSON line to the CLI's stdin; False when there is no live stdin."""
        stdin = self._stdin()
        if stdin is None:
            return False
        try:
            stdin.write((json.dumps(message, ensure_ascii=False) + "\n").encode())
            await stdin.drain()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False
        return True

    def _close_stdin(self) -> None:
        """End of input: the CLI finishes whatever is outstanding and exits."""
        stdin = self._stdin()
        if stdin is not None:
            try:
                stdin.close()
            except OSError:
                pass

    def _end_shells(self) -> list[NormalizedEvent]:
        """Close out the shells and monitors still open: the run is over and the CLI kills them."""
        out = [_shell_event(sid, self._shells[sid], "stopped") for sid in sorted(self._open_shells)]
        self._open_shells.clear()
        return out

    async def stop_task(self, delegation_id: str) -> bool:
        """Stop ONE delegated sub-agent (foreground or background), or one background shell or
        monitor, without ending the run.

        Sends the CLI's ``stop_task`` control request for the task id it reported in
        ``system/task_started`` for this delegation. The CLI answers with a
        ``task_notification`` of status ``stopped`` (which the stream turns into the
        delegation's stopped row) and the main agent carries on. False when the delegation is
        unknown, already settled, or the process has no live stdin."""
        task_id = self._task_for.get(delegation_id)
        if not task_id or not (
            delegation_id in self._open_delegations or delegation_id in self._open_shells
        ):
            return False
        return await self._send(
            {
                "type": "control_request",
                "request_id": f"haro-stop-{uuid.uuid4().hex[:8]}",
                "request": {"subtype": "stop_task", "task_id": task_id},
            }
        )

    async def _stream(
        self, proc, *, cwd: str, resume: str | None, effort: str | None
    ) -> AsyncIterator[NormalizedEvent]:
        """The read loop: NDJSON lines in, normalized events out.

        Split out of ``run`` purely so the teardown ``finally`` there stays readable —
        an async generator's ``finally`` must not be buried under 60 lines of parsing."""
        got_result = False
        session_id: str | None = None
        # Context-window occupancy, snapshotted from each assistant turn's usage.
        # The final turn's snapshot IS the current occupancy; the `result` usage is
        # cumulative across turns (see `iterations[]`) so it can't gauge fullness.
        last_ctx: dict[str, int] | None = None
        # The newest `stop_reason` (and `stop_details`) the driving agent's own turns carried:
        # a safeguard refusal is a normal reply ending in "refusal", and the CLI may still
        # report the run as a success.
        last_stop: tuple[Any, Any] = (None, None)
        assert proc.stdout is not None
        # A `done` that arrives while sub-agents are still working is held back: with stdin
        # kept open for `stop_task` the CLI reports each turn's result as it ends, but haro's
        # "done" means everything finished (the old prompt-on-argv behaviour, where the CLI
        # buffered results to the very end). It is released when a later result arrives with
        # nothing outstanding, or at EOF. After _SETTLE_GRACE_S of quiet once the last sub-agent
        # settles, stdin is closed (the CLI then finishes any follow-up turn and exits) but the
        # result is STILL held: releasing it there would emit a second `done` for the follow-up.
        held: NormalizedEvent | None = None
        draining = False
        lines = proc.stdout.__aiter__()
        while True:
            grace = (
                _EXIT_GRACE_S
                if got_result and held is None
                else _SETTLE_GRACE_S
                if held is not None and not self._open_delegations and not draining
                else None
            )
            try:
                raw = await (
                    asyncio.wait_for(lines.__anext__(), grace) if grace else lines.__anext__()
                )
            except StopAsyncIteration:
                break
            except asyncio.TimeoutError:
                if got_result and held is None:
                    # The result is in and stdin is closed, yet the CLI is still alive: a
                    # background shell or monitor keeps it running. Their rows are already
                    # settled, so end the process group (stdout reaches EOF right after).
                    await terminate_tree(proc)
                    continue
                draining = True
                self._close_stdin()
                for ended in self._end_shells():
                    yield ended
                continue
            line = raw.decode(errors="replace").strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                # Not JSON — surface as a raw token so nothing is silently lost.
                yield NormalizedEvent("token", {"text": line})
                continue

            if isinstance(obj, dict) and obj.get("session_id"):
                session_id = obj["session_id"]

            # Tokens resident in the context window on this turn = fresh input +
            # cache creation + cache reads (the cache tokens are the bulk — ignoring
            # them under-reports occupancy by an order of magnitude).
            if isinstance(obj, dict) and obj.get("type") == "assistant":
                if not obj.get("parent_tool_use_id"):
                    msg = obj.get("message") or {}
                    if msg.get("stop_reason"):
                        last_stop = (msg.get("stop_reason"), msg.get("stop_details"))
                u = (obj.get("message") or {}).get("usage") or {}
                cached = int(u.get("cache_read_input_tokens") or 0)
                total = (
                    int(u.get("input_tokens") or 0)
                    + cached
                    + int(u.get("cache_creation_input_tokens") or 0)
                )
                if total:
                    last_ctx = {"context_tokens": total, "context_cached": cached}

            for ev in self._normalize(obj, resuming=bool(resume), effort=effort):
                if ev.type in ("done", "error") and obj.get("type") == "result":
                    ev = _declined(ev, obj, last_stop) or ev
                    last_stop = (None, None)  # each turn's result judges that turn only
                if ev.type == "file_edit":
                    # Show the path relative to the worktree (CLI-style), not the
                    # long absolute path the tool_use carries.
                    p = ev.payload.get("path")
                    if p and os.path.isabs(p):
                        try:
                            rel = os.path.relpath(p, cwd)
                            if not rel.startswith(".."):
                                ev.payload["path"] = rel
                        except ValueError:
                            pass
                if ev.type in ("done", "error"):
                    ev.payload["session_id"] = session_id  # so the caller can persist it
                    # The last assistant turn's snapshot is the truest occupancy;
                    # it overrides the cumulative fallback _normalize put on the result.
                    if last_ctx:
                        ev.payload.update(last_ctx)
                    if ev.type == "done" and (
                        draining or (self._open_delegations and self._stdin() is not None)
                    ):
                        held = ev
                        continue
                    held = None
                    got_result = True
                    self._close_stdin()  # nothing outstanding: let the CLI exit
                    # Closing stdin makes the CLI kill every background shell. Say so now,
                    # before the run's `done`, rather than relying on notices that arrive
                    # after it.
                    for ended in self._end_shells():
                        yield ended
                elif session_id and ev.payload.get("system"):
                    # Surface the session id on the bootstrap event too, so the caller
                    # can persist it the moment it's known. A user stop cancels the
                    # stream mid-run — before any done/error — and we must still be
                    # able to resume the conversation with full context afterwards.
                    ev.payload["session_id"] = session_id
                yield ev

        for ended in self._end_shells():  # before `done`, so the rows settle inside the run
            yield ended

        if held is not None:  # the stream ended with a result still waiting on sub-agents
            got_result = True
            yield held
            held = None

        for held_edit in self._flush_held_edits():
            yield held_edit

        # Close out any delegation that never got a matching tool_result (the
        # subprocess crashed/exited mid-delegation) — otherwise its row is stuck
        # on "running" forever in the agent-manager card, which reconstructs
        # from the persisted transcript across future turns/reloads.
        for tool_use_id, subagent in self._pending_delegates.items():
            yield NormalizedEvent(
                "tool_call",
                {
                    "tool": "Agent",
                    "summary": f"↳ {subagent}: error — no result came back (process ended)",
                    "delegate": {"id": tool_use_id, "subagent_type": subagent, "status": "error"},
                },
            )
        self._pending_delegates.clear()

        code = await proc.wait()

        # If the process ended without a proper result line, synthesize a
        # terminal event so the runner can always finalize the AgentRun.
        if not got_result:
            stderr = (await proc.stderr.read()).decode(errors="replace").strip() if proc.stderr else ""
            if code == 0:
                yield NormalizedEvent("done", {"result": "", "exit_code": 0, "session_id": session_id})
            else:
                yield NormalizedEvent(
                    "error",
                    {"message": stderr or f"claude exited with code {code}",
                     "exit_code": code, "session_id": session_id},
                )

    # ------------------------------------------------------------------ #
    def _normalize(
        self, obj: dict[str, Any], resuming: bool = False, effort: str | None = None
    ) -> list[NormalizedEvent]:
        kind = obj.get("type")

        if obj.get("parent_tool_use_id") and kind in ("assistant", "user"):
            # A sub-agent's OWN turn (nested inside a Task/Agent delegation this adapter
            # made), not the driving agent's: every block of a delegated sub-agent's own
            # conversation (its tool calls, its final text) carries this field, pointing
            # back at the delegating tool_use id. Rendered as ordinary top-level rows they
            # made a scout/Task's inner Read/Bash calls indistinguishable from the driving
            # agent's own work, so they are surfaced tagged (`payload["parent"]`) for the
            # sub-agent panel and kept out of the main stream by every consumer.
            return self._nested(obj, obj["parent_tool_use_id"])

        if kind == "system":
            # Session bootstrap. `model` here is the model the CLI *actually*
            # resolved and is running with (e.g. "claude-opus-4-8[1m]"), which may
            # differ from what we asked for — so it's the authoritative signal for
            # the stream's "running model · effort" label. `effort` isn't echoed
            # back by the CLI, so we carry through the value we invoked it with.
            if obj.get("subtype") == "init":
                meta = {"system": True, "model": obj.get("model", "?"), "effort": effort}
                # On a resumed turn the conversation is simply continuing, so the
                # visible banner would fire on every prompt and read as if a new
                # session began each time — suppress the text, but still carry the
                # meta (marked `meta`, so the UI reads it for the label without
                # rendering a row) to keep the label fresh across follow-ups.
                if resuming:
                    return [NormalizedEvent("token", {**meta, "meta": True})]
                return [
                    NormalizedEvent(
                        "token",
                        {**meta, "text": f"◆ session started (model: {meta['model']})\n"},
                    )
                ]
            if obj.get("subtype") == "task_started":
                # The CLI's id for a delegation's task: what a `stop_task` control request
                # names. Only delegations are tracked (a background Bash a dev server leaves
                # running must not hold the run open).
                tid, task = obj.get("tool_use_id"), obj.get("task_id")
                if tid and task and tid in self._pending_delegates:
                    self._task_for[tid] = task
                    self._open_delegations.add(tid)
                elif tid and task and tid in self._shells:
                    # Only calls that asked to run in the background are in `_shells`: a
                    # foreground Bash is a task too (`is_backgrounded: false`), not a shell.
                    self._task_for[tid] = task
                    self._open_shells.add(tid)
                    return [_shell_event(tid, self._shells[tid], "running")]
                return []
            if obj.get("subtype") == "task_notification":
                # The AUTHORITATIVE completion signal for a delegation — fires at the
                # TRUE finish time whether or not the sub-agent ran in the background.
                # The tool_result that closes the delegating tool_use is NOT reliable
                # for this: verified against a live capture, a `run_in_background:
                # true` delegation's tool_result is just "Async agent launched
                # successfully", arriving within ~0.1-0.2s of the start regardless
                # of how long the sub-agent actually runs — that was making the
                # agent-manager card flip to "done" almost instantly on every
                # backgrounded delegation (haro's own real transcripts showed
                # running->done gaps of ~0.15s for delegations that took 10-30s).
                # A nested task INSIDE the sub-agent (e.g. its own Bash call) gets
                # its own task_notification with a DIFFERENT tool_use_id, which
                # correctly misses this correlation.
                tool_use_id = obj.get("tool_use_id")
                if tool_use_id in self._open_shells:
                    self._open_shells.discard(tool_use_id)
                    return [
                        _shell_event(
                            tool_use_id, self._shells[tool_use_id], _task_status(obj.get("status"))
                        )
                    ]
                subagent = self._pending_delegates.pop(tool_use_id, None) if tool_use_id else None
                if tool_use_id:
                    self._open_delegations.discard(tool_use_id)
                if subagent is None:
                    return []
                status = _task_status(obj.get("status"))
                return [
                    NormalizedEvent(
                        "tool_call",
                        {
                            "tool": "Agent",
                            "summary": f"↳ {subagent}: {status} — sent back to main agent",
                            "delegate": {"id": tool_use_id, "subagent_type": subagent, "status": status},
                        },
                    )
                ]
            return []

        if kind == "assistant":
            return self._normalize_content(obj.get("message", {}).get("content", []))

        if kind == "user":
            # Tool results flowing back to the model are noise, except a refused edit on a
            # protected run, which the dev needs to see. A delegation's OWN tool_result is
            # deliberately NOT used to close it out (see the task_notification handling
            # above for why).
            return self._blocked_edits(obj.get("message", {}).get("content"))

        if kind == "result":
            # On --resume the CLI first reports the tasks the previous process left behind
            # ("didn't finish before the previous session ended") as a turn of its own: a
            # `result` with a task-notification origin and no model turn behind it. It is not
            # this run's answer. Taking it for one ended the run a second after the prompt and,
            # with the exit grace, killed the CLI mid-task. (A background sub-agent's hand-back
            # also arrives as a task-notification turn, but that one has a real turn.)
            origin = obj.get("origin")
            if (
                isinstance(origin, dict)
                and origin.get("kind") == "task-notification"
                and not obj.get("num_turns")
            ):
                return []
            usage = obj.get("usage", {}) or {}
            is_error = obj.get("is_error") or obj.get("subtype") != "success"
            # Authoritative context window for the model(s) used this run.
            model_usage = obj.get("modelUsage") or {}
            window = 0
            for m in model_usage.values():
                w = int(m.get("contextWindow") or 0)
                if w > window:
                    window = w
            # Cumulative-usage fallback for occupancy (run() overrides with the more
            # accurate last-assistant-turn snapshot when one was seen).
            fb_cached = int(usage.get("cache_read_input_tokens") or 0)
            fb_total = (
                int(usage.get("input_tokens") or 0)
                + fb_cached
                + int(usage.get("cache_creation_input_tokens") or 0)
            )
            payload = {
                "result": obj.get("result", ""),
                "tokens_in": usage.get("input_tokens", 0),
                "tokens_out": usage.get("output_tokens", 0),
                "cost_usd": obj.get("total_cost_usd"),
                "duration_ms": obj.get("duration_ms"),
                "context_window": window or None,
                "context_tokens": fb_total or None,
                "context_cached": fb_cached or None,
            }
            if is_error:
                subtype = obj.get("subtype")
                payload["subtype"] = subtype
                payload["message"] = (
                    obj.get("result") or _ERROR_SUBTYPES.get(subtype) or "agent reported an error"
                )
                return [NormalizedEvent("error", payload)]
            return [NormalizedEvent("done", payload)]

        return []

    #: Per delegation, the most inner steps surfaced: a runaway sub-agent must not flood the
    #: transcript (the store keeps a bounded list per workspace).
    _NESTED_CAP = 200

    def _nested(self, obj: dict[str, Any], parent_id: str) -> list[NormalizedEvent]:
        """A delegated sub-agent's own steps, tagged with the delegation they belong to.

        Only its assistant turns (tool calls and text) are kept; its tool results are noise.
        An edit is downgraded to an ordinary tool call: a sub-agent's work is never counted
        as the run's own file edits (that would flip the workspace's dirty/diff signals).
        The tag is ``payload["parent"]``, the delegating tool_use id."""
        if obj.get("type") != "assistant":
            return []
        out: list[NormalizedEvent] = []
        for ev in self._normalize_content(obj.get("message", {}).get("content", [])):
            n = self._nested_counts.get(parent_id, 0)
            self._nested_counts[parent_id] = n + 1
            if n >= self._NESTED_CAP:
                if n == self._NESTED_CAP:
                    out.append(
                        NormalizedEvent(
                            "tool_call",
                            {
                                "tool": "…",
                                "summary": f"more steps not shown (first {self._NESTED_CAP} kept)",
                                "parent": parent_id,
                            },
                        )
                    )
                continue
            payload = dict(ev.payload)
            kind = ev.type
            if kind == "file_edit":
                kind = "tool_call"
                tool = payload.get("tool") or "Edit"
                path = payload.get("path") or ""
                payload = {"tool": tool, "summary": f"{path}".strip() or str(tool)}
            payload["parent"] = parent_id
            out.append(NormalizedEvent(kind, payload))
        return out

    def _rel(self, path: str) -> str:
        if path and self._cwd and os.path.isabs(path):
            rel = os.path.relpath(path, self._cwd)
            return path if rel.startswith("..") else rel
        return path

    def _flush_held_edits(self) -> list[NormalizedEvent]:
        """Held file_edit rows whose result never arrived (the process ended first)."""
        held = [ev for _, _, ev in self._pending_edits.values()]
        self._pending_edits.clear()
        return held

    def _blocked_edits(self, content: Any) -> list[NormalizedEvent]:
        """On a protected run a file_edit row is held back until its tool_result says
        whether the edit landed: released as-is when it did, replaced by a "blocked" row
        when a deny rule refused it (so a refused edit never reads as a made one)."""
        if not self._pending_edits or not isinstance(content, list):
            return []
        events: list[NormalizedEvent] = []
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            pending = self._pending_edits.pop(block.get("tool_use_id"), None)
            if not pending:
                continue
            tool, path, held = pending
            body = block.get("content")
            text = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
            if not (block.get("is_error") and _DENIED_MARK in text):
                events.append(held)
                continue
            path = self._rel(path)
            events.append(
                NormalizedEvent(
                    "tool_call",
                    {
                        "tool": tool,
                        "summary": "Edit blocked: tests are protected for this run"
                        + (f" ({path})" if path else ""),
                        "blocked": True,
                    },
                )
            )
        return events

    def _normalize_content(self, content: list[dict[str, Any]]) -> list[NormalizedEvent]:
        events: list[NormalizedEvent] = []
        for block in content:
            btype = block.get("type")
            if btype == "text":
                text = block.get("text", "")
                if text:
                    events.append(NormalizedEvent("token", {"text": text}))
            elif btype == "tool_use":
                tool = block.get("name", "?")
                tool_input = block.get("input", {}) or {}
                if tool in FILE_EDIT_TOOLS:
                    added, removed = _edit_stats(tool, tool_input)
                    diff, diff_truncated = _edit_diff(tool, tool_input)
                    edit_ev = NormalizedEvent(
                        "file_edit",
                        {
                            "tool": tool,
                            "path": _edit_path(tool_input),
                            "added": added,
                            "removed": removed,
                            "diff": diff,
                            "diff_truncated": diff_truncated,
                        },
                    )
                    if self._protected and block.get("id"):
                        self._pending_edits[block["id"]] = (tool, _edit_path(tool_input) or "", edit_ev)
                    else:
                        events.append(edit_ev)
                else:
                    delegate_info = _delegate_info(tool, tool_input)
                    summary = _delegate_summary(delegate_info) or _summarize_input(tool, tool_input)
                    payload: dict[str, Any] = {"tool": tool, "summary": summary}
                    tool_use_id = block.get("id")
                    shell_info = _shell_info(tool, tool_input)
                    if shell_info is not None and tool_use_id:
                        self._shells[tool_use_id] = shell_info
                    if delegate_info is not None and tool_use_id:
                        # Tracked so the correlated tool_result (below) can close this
                        # row out for the agent-manager card (running -> done/error).
                        self._pending_delegates[tool_use_id] = delegate_info["subagent_type"]
                        payload["delegate"] = {
                            "id": tool_use_id,
                            "subagent_type": delegate_info["subagent_type"],
                            "description": delegate_info["description"],
                            "status": "running",
                        }
                    events.append(NormalizedEvent("tool_call", payload))
        return events
