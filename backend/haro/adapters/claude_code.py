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
``parent_tool_use_id`` (dropped outright, below); and the tool_result that
closes the delegating tool_use is NOT its true completion when it ran
``run_in_background`` — that tool_result is just "Async agent launched
successfully", arriving almost instantly regardless of how long the sub-agent
actually runs. The authoritative completion is the ``task_notification``
system event instead, which fires at the real finish time either way.
``--permission-mode bypassPermissions`` lets the agent edit without prompting —
safe here *because* it's boxed in a throwaway git worktree: the blast radius is
one disposable branch.

Two per-run mode toggles ride on top of that base invocation (both feature-detected
by the caller, so a future adapter that lacks either degrades gracefully):
``plan`` swaps in ``--permission-mode plan`` (propose a plan, edit nothing), and
``fast`` injects ``--settings '{"fastMode":true}'`` (the "speed over depth" toggle;
fast mode is a persisted *setting*, not a CLI flag — see ``run`` below).

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


def _summarize_input(tool: str, tool_input: dict[str, Any]) -> str:
    """A one-line, human-readable gist of a tool call for the stream view."""
    if tool == "Bash":
        return tool_input.get("command", "")
    for key in ("file_path", "path", "pattern", "url", "query", "prompt"):
        if key in tool_input:
            return str(tool_input[key])
    blob = json.dumps(tool_input, ensure_ascii=False)
    return blob if len(blob) <= 200 else blob[:200] + "…"


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
        # tool_result. A fresh instance is created per run (see main.py), so
        # this never crosses runs or workspaces.
        self._pending_delegates: dict[str, str] = {}

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
        fast: bool = False,
        agents: dict | None = None,
    ) -> AsyncIterator[NormalizedEvent]:
        cmd = [
            "claude",
            "-p",
            task,
            "--output-format",
            "stream-json",
            "--verbose",
        ]
        if instructions and instructions.strip():
            # haro's standing custom instructions for this project — layered
            # on top of the CLI's own system prompt (and any repo CLAUDE.md).
            cmd += ["--append-system-prompt", instructions]
        if resume:
            # Continue the prior session — the agent keeps its context and Claude
            # Code auto-compacts as it fills up.
            cmd += ["--resume", resume]
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
        if fast:
            # Fast Mode: "speed over depth" for narrow edits / quick follow-ups. There
            # is NO `--fast` CLI flag — fast mode is a persisted `fastMode` *setting*
            # (the REPL's `/fast` toggle). We inject it per-run as an inline `--settings`
            # source, which layers on top of the user's real settings without persisting
            # or clobbering them (verified against v2.1.214: this flips the session's
            # `fast_mode_state` "off"→"on" in `system:init`). The CLI rewrites the run to
            # Opus 4.8 + `speed="fast"`, so it's orthogonal to `--model`/`--effort`.
            cmd += ["--settings", '{"fastMode":true}']
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
            )
            if wrapped is None:
                yield NormalizedEvent(
                    "error",
                    {"message": "`claude` CLI not found on PATH. Install Claude Code."},
                )
                return
            cmd = wrapped

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=cwd,
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

        stream = self._stream(proc, cwd=cwd, resume=resume, effort=effort)
        try:
            async for ev in stream:
                yield ev
        finally:
            # Close the inner generator first (it holds the half-read stdout), then the
            # process. The one teardown every haro-owned subprocess shares (procs.terminate_tree):
            # a no-op when `claude` already exited on its own, a SIGTERM→SIGKILL of the
            # group when this generator is closed early (a ⏹ stop, an archive mid-run,
            # shutdown). The runner closes the generator explicitly via ``aclosing`` so
            # this is deterministic rather than left to the garbage collector.
            await stream.aclose()
            await terminate_tree(proc)

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
        assert proc.stdout is not None
        async for raw in proc.stdout:
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
                    got_result = True
                    ev.payload["session_id"] = session_id  # so the caller can persist it
                    # The last assistant turn's snapshot is the truest occupancy;
                    # it overrides the cumulative fallback _normalize put on the result.
                    if last_ctx:
                        ev.payload.update(last_ctx)
                elif session_id and ev.payload.get("system"):
                    # Surface the session id on the bootstrap event too, so the caller
                    # can persist it the moment it's known. A user stop cancels the
                    # stream mid-run — before any done/error — and we must still be
                    # able to resume the conversation with full context afterwards.
                    ev.payload["session_id"] = session_id
                yield ev

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
            # A sub-agent's OWN turn (nested inside a Task/Agent delegation this
            # adapter made), not the driving agent's — verified against a live
            # `--output-format stream-json` capture: every block belonging to a
            # delegated sub-agent's own conversation (its tool calls, their
            # results, its final text) carries this field, pointing back at the
            # delegating tool_use id. Rendering these as ordinary top-level rows
            # made a scout/Task's inner Read/Bash calls indistinguishable from
            # the driving agent's own work. The delegation's bookends — the
            # start row and the done/error handback (below) — are the only
            # signal surfaced for what happened inside it.
            return []

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
                subagent = self._pending_delegates.pop(tool_use_id, None) if tool_use_id else None
                if subagent is None:
                    return []
                status = "done" if obj.get("status") == "completed" else "error"
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
            # Tool results flowing back to the model — noise for v0. A delegation's
            # OWN tool_result is deliberately NOT used to close it out (see the
            # task_notification handling above for why).
            return []

        if kind == "result":
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
                payload["message"] = obj.get("result", "agent reported an error")
                return [NormalizedEvent("error", payload)]
            return [NormalizedEvent("done", payload)]

        return []

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
                    events.append(
                        NormalizedEvent(
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
                    )
                else:
                    delegate_info = _delegate_info(tool, tool_input)
                    summary = _delegate_summary(delegate_info) or _summarize_input(tool, tool_input)
                    payload: dict[str, Any] = {"tool": tool, "summary": summary}
                    tool_use_id = block.get("id")
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
