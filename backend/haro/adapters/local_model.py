"""LocalModelAdapter — run a coding agent against a LOCAL model (Ollama / llama.cpp).

The privacy/FOSS pitch: *"works with your local Ollama — no cloud."* Both Ollama
(``http://localhost:11434/v1``) and llama.cpp's ``llama-server``
(``http://localhost:8080/v1``) expose the same **OpenAI-compatible
``/v1/chat/completions`` API with function/tool-calling**, so one adapter covers
both — you just point ``base_url`` at whichever is running.

Unlike ``ClaudeCodeAdapter`` (which shells out to a CLI that already *is* an
agent), a bare local model is only a text/tool-call generator — it has no
built-in harness. So this adapter runs the agentic loop itself:

    system+user → model → (tool_calls?) → execute tools → feed results → repeat
                                        → (no tool_calls) → done

We expose a small, honest coding toolset (read/write/edit files, run bash, list a
dir), execute each call inside the worktree, and normalize everything to haro's
five event types (``token|tool_call|file_edit|done|error``) exactly like every
other adapter — nothing downstream knows a local model is behind it.

**Transport = curl.** Streaming SSE over a ``curl`` subprocess fits haro's
existing subprocess-streaming idiom (same shape as the CLI adapters: spawn, read
stdout line-by-line, normalize), needs no new Python dependency, and curl is
universally present on the Linux target. The transport is injectable
(``transport=``) so the loop is unit-testable without a running model server.

Limitations (v1, deliberate): no server-side session, so ``resume`` starts a fresh
conversation (local servers are stateless per request); context is bounded by the
loaded model's window. Follow-ups lose prior turns — acceptable for the first cut.
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Any, AsyncIterator, Awaitable, Callable

from .. import files
from .base import AgentAdapter, NormalizedEvent

# A transport turns a request payload into a stream of raw SSE lines (as a curl /
# HTTP client would emit them). Injectable so tests can script turns without a model.
Transport = Callable[[dict[str, Any]], AsyncIterator[str]]

_MAX_ITERS = 40          # hard cap on tool-loop rounds — a stuck model can't spin forever
_BASH_TIMEOUT = 120      # seconds before a run_bash call is killed
_OUT_CAP = 16_000        # chars: cap tool output fed back to the model (context hygiene)
_DIFF_CAP = 400          # cap streamed diff lines (mirrors ClaudeCodeAdapter)


# --------------------------------------------------------------------------- #
# Tool schema (OpenAI function-calling format)
# --------------------------------------------------------------------------- #
def tool_schemas() -> list[dict[str, Any]]:
    """The coding toolset advertised to the model. Small on purpose: enough to be a
    real coding agent (read/write/edit/list/bash) without a sprawling surface a
    smaller local model would fumble."""

    def fn(name: str, desc: str, props: dict, required: list[str]) -> dict:
        return {
            "type": "function",
            "function": {
                "name": name,
                "description": desc,
                "parameters": {"type": "object", "properties": props, "required": required},
            },
        }

    s = {"type": "string"}
    return [
        fn("read_file", "Read a UTF-8 text file, relative to the repo root.",
           {"path": s}, ["path"]),
        fn("write_file", "Create or overwrite a file with the given content.",
           {"path": s, "content": s}, ["path", "content"]),
        fn("edit_file",
           "Replace the first exact occurrence of old_string with new_string in a file. "
           "old_string must match exactly (including whitespace) and be unique enough to "
           "target the right spot.",
           {"path": s, "old_string": s, "new_string": s}, ["path", "old_string", "new_string"]),
        fn("list_dir", "List the entries of a directory (relative to the repo root; '' = root).",
           {"path": s}, []),
        fn("run_bash", "Run a shell command in the repo root and return its combined "
           "stdout+stderr and exit code.",
           {"command": s}, ["command"]),
    ]


# --------------------------------------------------------------------------- #
# Streaming tool-call accumulation
# --------------------------------------------------------------------------- #
def apply_tool_call_deltas(acc: dict[int, dict[str, Any]], deltas: list[dict[str, Any]]) -> None:
    """Fold one streamed chunk's ``delta.tool_calls`` into the accumulator.

    OpenAI-style streaming splits a tool call across chunks: the ``index`` ties the
    fragments together, ``function.arguments`` arrives as a partial JSON string that
    must be *concatenated*, and id/name show up once. Non-streaming servers send it
    all in one delta (index 0, full arguments) — this handles both.
    """
    for d in deltas or []:
        idx = d.get("index", 0)
        slot = acc.setdefault(idx, {"id": None, "name": None, "args": ""})
        if d.get("id"):
            slot["id"] = d["id"]
        func = d.get("function") or {}
        if func.get("name"):
            slot["name"] = func["name"]
        if func.get("arguments"):
            slot["args"] += func["arguments"]


def _parse_args(raw: str) -> dict[str, Any]:
    """Tool-call arguments, tolerant of a model that emits ``""`` or slightly-off JSON."""
    raw = (raw or "").strip()
    if not raw:
        return {}
    try:
        val = json.loads(raw)
        return val if isinstance(val, dict) else {}
    except json.JSONDecodeError:
        return {}


# --------------------------------------------------------------------------- #
# Tool execution — pure(ish), bounded to the worktree, unit-testable
# --------------------------------------------------------------------------- #
async def execute_tool(
    name: str, args: dict[str, Any], cwd: str
) -> tuple[str, NormalizedEvent | None]:
    """Run one tool call inside ``cwd``. Returns ``(result_text, event)`` where
    ``result_text`` is fed back to the model as the tool result and ``event`` is the
    normalized event to stream to the UI (``file_edit`` for edits, ``tool_call``
    otherwise, ``None`` when nothing worth showing)."""
    try:
        if name == "read_file":
            res = files.read_file(cwd, args.get("path", ""))
            if res.get("error"):
                return f"error: {res['error']}", _tool_event(name, args.get("path", ""))
            return res.get("content", ""), _tool_event(name, args.get("path", ""))

        if name == "list_dir":
            rel = args.get("path", "") or ""
            base = files.safe_path(cwd, rel)
            if not base.is_dir():
                return f"error: not a directory: {rel or '.'}", _tool_event(name, rel or ".")
            names = sorted(
                (e.name + ("/" if e.is_dir() else "")) for e in base.iterdir()
            )
            return "\n".join(names) or "(empty)", _tool_event(name, rel or ".")

        if name == "write_file":
            path = args.get("path", "")
            content = args.get("content", "")
            files.write_file(cwd, path, content)
            added = _count_lines(content)
            diff, trunc = _diff([("+", content)])
            return (
                f"wrote {path} ({added} lines)",
                NormalizedEvent("file_edit", {
                    "tool": "write_file", "path": path, "added": added, "removed": 0,
                    "diff": diff, "diff_truncated": trunc,
                }),
            )

        if name == "edit_file":
            path = args.get("path", "")
            old = args.get("old_string", "")
            new = args.get("new_string", "")
            res = files.read_file(cwd, path)
            if res.get("error"):
                return f"error: {res['error']}", _tool_event("edit_file", path)
            body = res.get("content", "")
            if old and old not in body:
                return (
                    "error: old_string not found in file (it must match exactly)",
                    _tool_event("edit_file", path),
                )
            updated = body.replace(old, new, 1) if old else body + new
            files.write_file(cwd, path, updated)
            diff, trunc = _diff([("-", old), ("+", new)])
            return (
                f"edited {path}",
                NormalizedEvent("file_edit", {
                    "tool": "edit_file", "path": path,
                    "added": _count_lines(new), "removed": _count_lines(old),
                    "diff": diff, "diff_truncated": trunc,
                }),
            )

        if name == "run_bash":
            command = args.get("command", "")
            out = await _run_bash(command, cwd)
            return out, NormalizedEvent("tool_call", {"tool": "run_bash", "summary": command})

        return f"error: unknown tool {name!r}", None
    except ValueError as exc:  # path traversal guard from files.safe_path
        return f"error: {exc}", None
    except OSError as exc:
        return f"error: {exc}", None


def _tool_event(name: str, summary: str) -> NormalizedEvent:
    return NormalizedEvent("tool_call", {"tool": name, "summary": summary})


def _count_lines(s: str) -> int:
    return len(s.splitlines()) if s else 0


def _diff(parts: list[tuple[str, str]]) -> tuple[list[dict[str, str]], bool]:
    """Signed diff lines for the stream row (mirrors ClaudeCodeAdapter's ``_edit_diff``)."""
    lines: list[dict[str, str]] = []
    for sign, text in parts:
        for ln in text.splitlines():
            lines.append({"sign": sign, "text": ln})
    return lines[:_DIFF_CAP], len(lines) > _DIFF_CAP


async def _run_bash(command: str, cwd: str) -> str:
    if not command.strip():
        return "error: empty command"
    proc = await asyncio.create_subprocess_shell(
        command, cwd=cwd,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=_BASH_TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        return f"error: command timed out after {_BASH_TIMEOUT}s"
    text = out.decode(errors="replace")
    if len(text) > _OUT_CAP:
        text = text[:_OUT_CAP] + "\n… (output truncated)"
    return f"[exit {proc.returncode}]\n{text}".rstrip()


# --------------------------------------------------------------------------- #
# Adapter
# --------------------------------------------------------------------------- #
_SYSTEM = (
    "You are a coding agent working inside a git worktree. Complete the user's task by "
    "using the provided tools to read, write, and edit files and run shell commands. "
    "Paths are relative to the repository root. Make the change directly — don't just "
    "describe it. When the task is fully done, reply with a short summary and STOP "
    "calling tools."
)


class LocalModelAdapter(AgentAdapter):
    name = "local-model"

    def __init__(
        self,
        *,
        base_url: str = "http://localhost:11434/v1",
        model: str = "qwen2.5-coder",
        transport: Transport | None = None,
    ):
        # Normalize: accept a bare host ("http://localhost:11434") or a full "/v1".
        self.base_url = base_url.rstrip("/")
        if not self.base_url.endswith("/v1"):
            self.base_url += "/v1"
        self.model = model
        self._transport = transport or self._curl_transport

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
        plan: bool = False,  # no plan mode for a bare local model — accepted + ignored
    ) -> AsyncIterator[NormalizedEvent]:
        model = model or self.model
        system = _SYSTEM
        if instructions and instructions.strip():
            system += "\n\n# Project instructions\n" + instructions.strip()
        messages: list[dict[str, Any]] = [
            {"role": "system", "content": system},
            {"role": "user", "content": task},
        ]

        yield NormalizedEvent("token", {
            "system": True, "model": model, "effort": None,
            "text": f"◆ local model session (model: {model} · {self.base_url})\n",
        })

        tokens_out = 0
        for _ in range(_MAX_ITERS):
            content_buf: list[str] = []
            tool_acc: dict[int, dict[str, Any]] = {}
            errored: str | None = None

            payload = {
                "model": model,
                "messages": messages,
                "tools": tool_schemas(),
                "stream": True,
            }
            try:
                async for obj in self._read_stream(payload):
                    if obj.get("__error__"):
                        errored = obj["__error__"]
                        break
                    choice = (obj.get("choices") or [{}])[0]
                    delta = choice.get("delta") or {}
                    text = delta.get("content")
                    if text:
                        content_buf.append(text)
                        tokens_out += 1
                        yield NormalizedEvent("token", {"text": text})
                    if delta.get("tool_calls"):
                        apply_tool_call_deltas(tool_acc, delta["tool_calls"])
            except FileNotFoundError:
                yield NormalizedEvent("error", {
                    "message": "`curl` not found on PATH: needed to reach the local model server.",
                })
                return

            if errored:
                yield NormalizedEvent("error", {"message": errored, "tokens_out": tokens_out})
                return

            content = "".join(content_buf)
            calls = [tool_acc[i] for i in sorted(tool_acc)]

            # No tool calls → the model is done talking; this turn is the final answer.
            if not calls:
                yield NormalizedEvent("done", {
                    "result": content, "tokens_out": tokens_out, "session_id": None,
                })
                return

            # Record the assistant turn (content + the tool calls it requested), then
            # execute each call and append its result so the model can continue.
            messages.append({
                "role": "assistant",
                "content": content or None,
                "tool_calls": [
                    {"id": c["id"] or f"call_{i}", "type": "function",
                     "function": {"name": c["name"] or "", "arguments": c["args"] or "{}"}}
                    for i, c in enumerate(calls)
                ],
            })
            for i, c in enumerate(calls):
                name = c["name"] or ""
                args = _parse_args(c["args"])
                result, event = await execute_tool(name, args, cwd)
                if event is not None:
                    if event.type == "file_edit":
                        _relativize(event, cwd)
                    yield event
                messages.append({
                    "role": "tool",
                    "tool_call_id": c["id"] or f"call_{i}",
                    "content": result,
                })

        yield NormalizedEvent("error", {
            "message": f"reached the {_MAX_ITERS}-round tool-call cap without finishing.",
            "tokens_out": tokens_out, "session_id": None,
        })

    # ------------------------------------------------------------------ #
    async def _read_stream(self, payload: dict[str, Any]) -> AsyncIterator[dict[str, Any]]:
        """Drive the transport, unwrap SSE ``data:`` framing, yield parsed JSON chunks.

        A transport-level failure is surfaced as a single ``{"__error__": msg}`` object
        so the caller can turn it into a normalized ``error`` event."""
        async for line in self._transport(payload):
            line = line.strip()
            if not line or not line.startswith("data:"):
                continue
            data = line[len("data:"):].strip()
            if data == "[DONE]":
                return
            try:
                yield json.loads(data)
            except json.JSONDecodeError:
                continue

    async def _curl_transport(self, payload: dict[str, Any]) -> AsyncIterator[str]:
        """Default transport: stream ``POST {base_url}/chat/completions`` via curl.

        ``-N`` disables curl's output buffering so SSE lines arrive as the model emits
        them (live tokens). ``--fail-with-body`` makes an HTTP error a non-zero exit
        while still printing the server's error JSON, which we surface to the UI."""
        url = f"{self.base_url}/chat/completions"
        cmd = [
            "curl", "-sS", "-N", "--fail-with-body",
            "-H", "Content-Type: application/json",
            "-H", "Accept: text/event-stream",
            "-d", json.dumps(payload),
            url,
        ]
        api_key = os.environ.get("HARO_LOCAL_API_KEY") or os.environ.get("OPENAI_API_KEY")
        if api_key:
            cmd[1:1] = ["-H", f"Authorization: Bearer {api_key}"]

        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            limit=16 * 1024 * 1024,
        )
        assert proc.stdout is not None
        saw_data = False
        async for raw in proc.stdout:
            saw_data = True
            yield raw.decode(errors="replace")
        code = await proc.wait()
        if code != 0:
            err = (await proc.stderr.read()).decode(errors="replace").strip() if proc.stderr else ""
            hint = (
                f"couldn't reach the local model server at {self.base_url} "
                f"(curl exit {code}). Is Ollama / llama-server running?"
            )
            yield f'data: {json.dumps({"__error__": (err or hint)})}'
        elif not saw_data:
            yield f'data: {json.dumps({"__error__": f"empty response from {self.base_url}"})}'


def _relativize(event: NormalizedEvent, cwd: str) -> None:
    """Show a file_edit path relative to the worktree (CLI-style), like ClaudeCodeAdapter."""
    p = event.payload.get("path")
    if p and os.path.isabs(p):
        try:
            rel = os.path.relpath(p, cwd)
            if not rel.startswith(".."):
                event.payload["path"] = rel
        except ValueError:
            pass
