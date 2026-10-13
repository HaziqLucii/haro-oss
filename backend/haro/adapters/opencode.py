"""OpenCodeAdapter: run a coding agent through the OpenCode CLI (``opencode run --format json``).

OpenCode (https://opencode.ai) is itself an agent harness with its own tools, providers and models
(Anthropic, OpenAI, DeepSeek, a local Ollama, its free tier...), so this adapter is shaped like
``ClaudeCodeAdapter``: spawn the CLI in the worktree, read its NDJSON events, and normalize them to
haro's five event types. Nothing downstream knows OpenCode is behind it.

What the stream looks like (verified on opencode 1.18.26)::

    {"type":"step_start","sessionID":"ses_..","part":{...}}
    {"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{...},
                       "output":"..","metadata":{"diff":"<unified diff>",...}}}}   # once, when finished
    {"type":"text","part":{"text":"..."}}
    {"type":"step_finish","part":{"reason":"tool-calls"|"stop","tokens":{"total":..,"input":..,
                       "output":..,"cache":{"read":..,"write":..}},"cost":0.0}}
    {"type":"error","error":{"name":"..","data":{"message":".."}}}                # and exit code 1

Facts the code relies on:

* OpenCode takes its working directory from the ``PWD`` environment variable, not from the
  process's real cwd (verified: a child started with ``cwd=<worktree>`` but the backend's
  ``PWD=/`` worked in ``/``, its tools and all). So the run is given ``--dir <worktree>`` and
  ``PWD`` is set to match.
* ``opencode run`` reads stdin when it is an open pipe and waits for EOF, so the process is spawned
  with stdin closed (``DEVNULL``). Otherwise it never starts: that looked like a hang for a while.
* A tool call is reported once, already finished: there is no "started" event, so a tool row never
  shows as running here.
* No steering and no sub-agent stop: ``steer`` stays the base class's ``False``.
* There are no PreToolUse hooks, but OpenCode enforces ``permission`` rules before a call (verified:
  a ``write`` to a denied path fails with "a rule prevents you", a compound shell command containing
  a denied pattern is refused, ``*`` matches across folders, the last matching rule wins). So the
  fence, protected tests and the command guard are handed to it as inline config
  (``OPENCODE_CONFIG_CONTENT``), and the shared browser as a remote MCP server in the same config.
  The runner still reverts out-of-scope edits when the run ends, so a rule that fails to bite is
  caught there. A refusal is not counted in the receipt's "blocked" list (that count comes from
  haro's own hook, which OpenCode does not call).
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import time
from pathlib import Path
from typing import Any, AsyncIterator

from ..procs import terminate_tree
from .base import AgentAdapter, NormalizedEvent

_STREAM_LIMIT = 16 * 1024 * 1024  # a tool result can be one very long line
_DIFF_CAP = 400  # cap the streamed diff, like ClaudeCodeAdapter
_STDERR_TAIL = 600
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

#: OpenCode's file-writing tools, as the stream rows name them.
_EDIT_TOOLS = {
    "edit": "Edit",
    "write": "Write",
    "multiedit": "MultiEdit",
    "patch": "Patch",
    "apply_patch": "Patch",
}

#: The other tools, named the way the Claude Code rows are, so the stream reads the same.
_TOOL_NAMES = {
    "bash": "Bash",
    "read": "Read",
    "glob": "Glob",
    "grep": "Grep",
    "list": "LS",
    "webfetch": "WebFetch",
    "websearch": "WebSearch",
    "todowrite": "TodoWrite",
    "todoread": "TodoRead",
    "task": "Agent",
    "skill": "Skill",
}


def find_opencode() -> str | None:
    """The ``opencode`` binary: on PATH, else where its installer puts it (``~/.opencode/bin``)."""
    found = shutil.which("opencode")
    if found:
        return found
    fallback = Path.home() / ".opencode" / "bin" / "opencode"
    return str(fallback) if fallback.exists() else None


def _opencode_browser_note(instructions: str) -> str:
    """The runner's note about the shared browser is written for Claude's tool names; OpenCode names an
    MCP tool ``<server>_<tool>``."""
    return (
        instructions.replace("mcp__haro_browser__", "haro_browser_")
        .replace("the Playwright plugin's own tools are disabled for this run", "use these rather than any other browser tool")
    )


def _first(d: dict[str, Any], *keys: str) -> Any:
    for k in keys:
        if d.get(k) not in (None, ""):
            return d[k]
    return None


def _rel(path: str, cwd: str) -> str:
    if path and cwd and os.path.isabs(path):
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            return path
        return path if rel.startswith("..") else rel
    return path


def _summarize(tool: str, tool_input: dict[str, Any], cwd: str) -> str:
    """A one-line gist of a tool call for the stream row."""
    if tool == "bash":
        return str(_first(tool_input, "command") or "")
    path = _first(tool_input, "filePath", "path")
    if path:
        return _rel(str(path), cwd)
    other = _first(tool_input, "pattern", "url", "query", "description", "prompt")
    if other:
        return str(other)
    blob = json.dumps(tool_input, ensure_ascii=False)
    return blob if len(blob) <= 200 else blob[:200] + "…"


def _diff_lines(unified: str) -> list[dict[str, str]]:
    """Signed lines of a unified diff, headers and hunk markers left out."""
    out: list[dict[str, str]] = []
    for ln in unified.splitlines():
        if ln.startswith(("+++", "---", "@@", "Index:", "====")):
            continue
        if ln.startswith("+"):
            out.append({"sign": "+", "text": ln[1:]})
        elif ln.startswith("-"):
            out.append({"sign": "-", "text": ln[1:]})
    return out


def _input_lines(tool: str, tool_input: dict[str, Any]) -> list[dict[str, str]]:
    """Signed lines from the call's own input, for a tool whose result carries no diff (`write`)."""
    lines: list[dict[str, str]] = []

    def add(sign: str, text: Any) -> None:
        for ln in str(text or "").splitlines():
            lines.append({"sign": sign, "text": ln})

    if tool == "write":
        add("+", tool_input.get("content"))
    elif tool == "edit":
        add("-", tool_input.get("oldString"))
        add("+", tool_input.get("newString"))
    return lines


def _error_message(obj: dict[str, Any]) -> str:
    err = obj.get("error") or {}
    data = err.get("data") if isinstance(err, dict) else None
    msg = (data or {}).get("message") if isinstance(data, dict) else None
    return str(msg or (err.get("message") if isinstance(err, dict) else None) or (err.get("name") if isinstance(err, dict) else None) or "OpenCode reported an error.")


_MODEL_LINE = re.compile(r"^[A-Za-z0-9._-]+/\S+$")


async def list_models(cwd: str, *, binary: str | None = None, timeout: float = 20.0) -> tuple[list[str], str | None]:
    """The models OpenCode can run, as ``provider/model`` (``opencode models``): the ones of the
    providers it has credentials for, plus its free tier. ``([], reason)`` when it cannot say, so the
    Settings picker can say why instead of offering nothing. A project's own ``opencode.json`` may
    add providers, which is why it runs in the project's folder."""
    binary = binary or find_opencode()
    if not binary:
        return [], "`opencode` was not found. Install it from https://opencode.ai."
    try:
        proc = await asyncio.create_subprocess_exec(
            binary, "models",
            cwd=cwd, env={**os.environ, "PWD": cwd}, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as exc:
        return [], f"Could not start opencode: {exc}"
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        await terminate_tree(proc)
        return [], "`opencode models` did not answer in time."
    if proc.returncode != 0:
        why = _ANSI.sub("", err.decode(errors="replace")).strip()
        return [], why[-_STDERR_TAIL:] or f"`opencode models` exited with code {proc.returncode}."
    seen: dict[str, None] = {}
    for line in _ANSI.sub("", out.decode(errors="replace")).splitlines():
        line = line.strip()
        if _MODEL_LINE.match(line):
            seen.setdefault(line)
    return list(seen), None


async def session_model(binary: str, session_id: str, cwd: str, *, timeout: float = 15.0) -> str | None:
    """The ``provider/model`` a session actually ran with (``opencode export``). With no model chosen
    OpenCode picks its own default and the run's events never say which, so the stream, the rail and
    the receipt would show only "opencode"."""
    try:
        proc = await asyncio.create_subprocess_exec(
            binary, "export", session_id,
            cwd=cwd, env={**os.environ, "PWD": cwd}, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return None
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        data = json.loads(out.decode(errors="replace"))
    except asyncio.TimeoutError:
        await terminate_tree(proc)
        return None
    except ValueError:
        return None
    for message in (data.get("messages") or []) if isinstance(data, dict) else []:
        info = message.get("info") or {}
        chosen = info.get("model") if isinstance(info.get("model"), dict) else info
        provider, model = chosen.get("providerID"), chosen.get("modelID")
        if provider and model:
            return f"{provider}/{model}"
    return None


async def _settle(fut: asyncio.Future, timeout: float = 10.0) -> str | None:
    """A lookup's answer, or None if it failed or is too slow: the model name is a nicety."""
    try:
        return await asyncio.wait_for(asyncio.shield(fut), timeout)
    except (asyncio.TimeoutError, Exception):  # noqa: BLE001
        return None


#: Shell commands the command guard refuses (a short text-match list, as in command_guard.py: a speed
#: bump, never a guarantee). OpenCode matches these against the whole command, compound ones too.
_GUARDED_COMMANDS = (
    "git reset --hard*",
    "git clean -f*", "git clean -df*", "git clean -fd*", "git clean -xdf*", "git clean -xfd*",
    "git checkout .", "git checkout -- .", "git restore .",
    "git push --force*", "git push -f*", "git push * --force*", "git push * -f *",
    "rm -rf /*", "rm -rf ~*", "rm -rf $HOME*", "rm -rf .", "rm -rf ./", "rm -rf .git*", "rm -rf ..*",
    "printenv*", "env", "env | *", "cat /proc/*/environ*",
)
#: Files the command guard keeps the agent from reading (secrets), with the harmless siblings let back in.
_SECRET_READS = ("*.env", "*.env.*", "*.pem", "*.key", "*.p12", "*.pfx", "*id_rsa*", "*id_ed25519*", "*id_ecdsa*", "*id_dsa*")
_SECRET_READS_OK = ("*.env.example", "*.env.sample", "*.env.template")


def _edit_globs(paths: list[str]) -> list[str]:
    """haro's fence / protected-test paths as OpenCode permission patterns: relative, ``**`` is ``*``
    (its ``*`` already crosses folders), a folder (trailing ``/``, or a bare name) covers what is in it."""
    out: list[str] = []
    for raw in paths:
        p = raw.strip().replace("\\", "/")
        while p.startswith("./"):
            p = p[2:]
        p = p.lstrip("/")
        if not p:
            continue
        p = re.sub(r"\*{2,}", "*", p)
        if p.endswith("/"):
            out.append(p + "*")
            continue
        out.append(p)
        if not any(c in p for c in "*?[") and "." not in p.rsplit("/", 1)[-1]:
            out.append(p + "/*")  # a bare name may be a folder
    return list(dict.fromkeys(out))


def inline_config(
    *,
    scope_paths: list[str] | None,
    deny_edit_paths: list[str] | None,
    guard_commands: bool,
    browser_url: str | None,
    agents: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """The part of OpenCode's config haro owns for one run, passed as ``OPENCODE_CONFIG_CONTENT``.

    Rules are evaluated in order and the last match wins, so the broad rule comes first: the fence
    denies everything and allows its paths, then protected tests deny theirs on top (a protected
    file inside the fence stays protected)."""
    cfg: dict[str, Any] = {}
    edit: dict[str, str] = {}
    if scope_paths:
        edit["*"] = "deny"
        for g in _edit_globs(scope_paths):
            edit[g] = "allow"
    for g in _edit_globs(deny_edit_paths or []):
        edit[g] = "deny"
    perm: dict[str, Any] = {}
    if edit:
        perm["edit"] = edit
    if guard_commands:
        perm["bash"] = {"*": "allow", **{c: "deny" for c in _GUARDED_COMMANDS}}
        perm["read"] = {"*": "allow", **{c: "deny" for c in _SECRET_READS}, **{c: "allow" for c in _SECRET_READS_OK}}
    if perm:
        cfg["permission"] = perm
    if agents:
        cfg["agent"] = agents  # haro's own sub-agents (scout, code-review), already in OpenCode's shape
    if browser_url:
        cfg["mcp"] = {"haro_browser": {"type": "remote", "url": browser_url, "enabled": True}}
    return cfg


def _merge_config(mine: dict[str, Any], existing: str | None) -> str | None:
    """Layer haro's config over one the user already put in OPENCODE_CONFIG_CONTENT (rare)."""
    if not mine:
        return existing
    base: dict[str, Any] = {}
    if existing:
        try:
            parsed = json.loads(existing)
            base = parsed if isinstance(parsed, dict) else {}
        except ValueError:
            base = {}
    for key, value in mine.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            base[key] = {**base[key], **value}
        else:
            base[key] = value
    return json.dumps(base)


class OpenCodeAdapter(AgentAdapter):
    name = "opencode"

    def __init__(self, *, model: str = "", skip_permissions: bool = True, binary: str | None = None):
        #: ``provider/model`` (``deepseek/deepseek-v4-flash``); empty lets OpenCode use its own default.
        self.model = model
        # `--auto` approves the permissions OpenCode would otherwise ask about; with nobody to
        # answer in a headless run, asking would just hang. The same stance as the Claude adapter's
        # default (bypassPermissions): the worktree and the gate are the boundary.
        self.skip_permissions = skip_permissions
        self._binary = binary

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
        deny_edit_paths: list[str] | None = None,
        scope_paths: list[str] | None = None,
        guard_commands: bool = False,
        run_log_dir: str | None = None,
        app_control: dict[str, str] | None = None,
        browser_mcp: dict[str, str] | None = None,
        gh_token: str | None = None,
        agents: dict[str, Any] | None = None,
    ) -> AsyncIterator[NormalizedEvent]:
        binary = self._binary or find_opencode()
        if not binary:
            yield NormalizedEvent(
                "error",
                {"message": "`opencode` not found on PATH. Install it from https://opencode.ai."},
            )
            return

        chosen = (model or self.model or "").strip()
        cmd = [binary, "run", "--format", "json", "--dir", cwd]
        if "/" in chosen:  # OpenCode wants provider/model; anything else is not one of its models
            cmd += ["-m", chosen]
        if resume:
            cmd += ["-s", resume]
        if plan:
            cmd += ["--agent", "plan"]
        if self.skip_permissions:
            cmd += ["--auto"]
        if instructions and browser_mcp:
            instructions = _opencode_browser_note(instructions)
        if app_control:
            # OpenCode's shell rebuilds PATH from the user's profile, so haro's bin directory does not
            # survive on it (verified: `command not found: haro-app`). The environment variables do.
            where = os.path.join(app_control["bin_dir"], "haro-app")
            note = (
                f"The `haro-app` command is at `{where}` and your shell may not have it on PATH: call it by that "
                "full path. HARO_API and HARO_WORKSPACE_ID are already set for it."
            )
            instructions = f"{instructions}\n\n{note}" if instructions else note
        message = task
        if instructions and instructions.strip():
            message = (
                "Project instructions (follow them for this task):\n\n"
                f"{instructions.strip()}\n\n---\n\nTask:\n{task}"
            )
        cmd += ["--", message]

        # What haro hands every agent (the Claude adapter does the same through its own flags): the
        # `haro-app` command and the backend's address, the app's log, the pinned GitHub account.
        env = {**os.environ, "PWD": cwd}
        if run_log_dir:
            env["HARO_LOG_DIR"] = run_log_dir
            env["HARO_RUN_LOG"] = os.path.join(run_log_dir, "run.log")
        if app_control:
            env["HARO_API"] = app_control["api"]
            env["HARO_WORKSPACE_ID"] = app_control["workspace_id"]
            env["PATH"] = app_control["bin_dir"] + os.pathsep + env.get("PATH", "")
        if gh_token:
            env["GH_TOKEN"] = gh_token
        config = _merge_config(
            inline_config(
                scope_paths=scope_paths,
                deny_edit_paths=deny_edit_paths,
                guard_commands=guard_commands,
                browser_url=(browser_mcp or {}).get("url"),
                agents=agents,
            ),
            env.get("OPENCODE_CONFIG_CONTENT"),
        )
        if config:
            env["OPENCODE_CONFIG_CONTENT"] = config

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=cwd,
                env=env,  # PWD pinned (OpenCode reads it), and haro's own variables and config
                stdin=asyncio.subprocess.DEVNULL,  # an open stdin blocks it
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                limit=_STREAM_LIMIT,
                start_new_session=True,  # own process group, so Stop can end the whole tree
            )
        except FileNotFoundError:
            yield NormalizedEvent("error", {"message": "`opencode` not found on PATH. Install it from https://opencode.ai."})
            return
        assert proc.stdout is not None and proc.stderr is not None
        stderr_task = asyncio.ensure_future(proc.stderr.read())

        started = time.monotonic()
        session_id: str | None = None
        announced = False
        cost = 0.0
        tokens_in = tokens_out = 0
        last_ctx: dict[str, int] | None = None
        error: str | None = None
        saw_step = False
        step_text: list[str] = []  # the text parts of the step being read
        final_text: list[str] = []  # the last step that had any: the run's answer (a plan's text)
        over_budget = False
        resolving: asyncio.Future | None = None  # the real model, when none was chosen
        resolved_sent = False
        label = chosen or "opencode default"

        try:
            async for raw in proc.stdout:
                line = raw.decode(errors="replace").strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    yield NormalizedEvent("token", {"text": line})
                    continue
                if not isinstance(obj, dict):
                    continue
                if obj.get("sessionID"):
                    session_id = obj["sessionID"]
                kind = obj.get("type")
                part = obj.get("part") or {}

                if kind == "step_start":
                    saw_step = True
                    step_text = []
                    if not announced:
                        announced = True
                        meta = {"system": True, "model": label, "effort": None, "session_id": session_id}
                        if resume:
                            # A continuing conversation: carry the label, skip the banner.
                            yield NormalizedEvent("token", {**meta, "meta": True})
                        else:
                            yield NormalizedEvent("token", {**meta, "text": f"◆ session started (model: {label})\n"})
                        if not chosen and session_id:
                            resolving = asyncio.ensure_future(session_model(binary, session_id, cwd))
                if kind in ("text", "tool_use") and resolving is not None and not resolved_sent:
                    # The first visible row labels its turn with the model: hold it for the lookup
                    # (a few seconds at most; the agent itself keeps running meanwhile).
                    resolved_sent = True
                    found = await _settle(resolving)
                    if found:
                        label = found
                        yield NormalizedEvent(
                            "token",
                            {"system": True, "model": found, "effort": None, "meta": True, "session_id": session_id},
                        )
                if kind == "text":
                    text = part.get("text")
                    if text:
                        step_text.append(str(text))
                        yield NormalizedEvent("token", {"text": text})
                elif kind == "tool_use":
                    for ev in self._tool_events(part, cwd):
                        yield ev
                elif kind == "step_finish":
                    if step_text:
                        final_text = step_text
                    toks = part.get("tokens") or {}
                    cache = toks.get("cache") or {}
                    tokens_in += int(toks.get("input") or 0)
                    tokens_out += int(toks.get("output") or 0)
                    cost += float(part.get("cost") or 0)
                    read, write = int(cache.get("read") or 0), int(cache.get("write") or 0)
                    ctx = int(toks.get("input") or 0) + read + write
                    if ctx:
                        last_ctx = {"context_tokens": ctx, "context_cached": read}
                    if max_budget_usd and cost > max_budget_usd:
                        over_budget = True
                        break
                elif kind == "error":
                    error = error or _error_message(obj)
                if resolving is not None and not resolved_sent and resolving.done():
                    resolved_sent = True
                    found = None if resolving.cancelled() or resolving.exception() else resolving.result()
                    if found:
                        label = found
                        yield NormalizedEvent(
                            "token",
                            {"system": True, "model": found, "effort": None, "meta": True, "session_id": session_id},
                        )
            if resolving is not None and not resolved_sent and not over_budget:
                resolved_sent = True
                found = await _settle(resolving, 8)
                if found:
                    label = found
                    yield NormalizedEvent(
                        "token",
                        {"system": True, "model": found, "effort": None, "meta": True, "session_id": session_id},
                    )
            if over_budget:
                await terminate_tree(proc)
            code = await proc.wait()
            stderr = _ANSI.sub("", (await stderr_task).decode(errors="replace")).strip()
        finally:
            # Cancelled (Stop, archive, shutdown) or finished: nothing of OpenCode may outlive the run.
            await terminate_tree(proc)
            if not stderr_task.done():
                stderr_task.cancel()
            if resolving is not None and not resolving.done():
                resolving.cancel()

        if over_budget:
            yield NormalizedEvent(
                "error",
                {"message": "The agent stopped because it reached the run's budget cap.", "session_id": session_id, "cost_usd": cost},
            )
            return
        if error or (code not in (0, None) and not saw_step):
            message = error or stderr[-_STDERR_TAIL:] or f"opencode exited with code {code}"
            yield NormalizedEvent("error", {"message": message, "session_id": session_id, "exit_code": code, "cost_usd": cost or None})
            return
        if code not in (0, None):
            message = stderr[-_STDERR_TAIL:] or f"opencode exited with code {code}"
            yield NormalizedEvent("error", {"message": message, "session_id": session_id, "exit_code": code, "cost_usd": cost or None})
            return
        done: dict[str, Any] = {
            # What the runner keeps as a plan's text (`Workspace.plan_text`): the last step's words.
            "result": "\n\n".join(final_text),
            "session_id": session_id,
            "tokens_in": tokens_in,
            "tokens_out": tokens_out,
            "cost_usd": cost or None,
            "duration_ms": int((time.monotonic() - started) * 1000),
        }
        if last_ctx:
            done.update(last_ctx)
        yield NormalizedEvent("done", done)

    def _tool_events(self, part: dict[str, Any], cwd: str) -> list[NormalizedEvent]:
        tool = str(part.get("tool") or "")
        state = part.get("state") or {}
        tool_input = state.get("input") or {}
        failed = state.get("status") == "error"
        if tool in _EDIT_TOOLS and not failed:
            meta = state.get("metadata") or {}
            path = _rel(str(_first(tool_input, "filePath", "path") or meta.get("filepath") or ""), cwd)
            unified = meta.get("diff") if isinstance(meta.get("diff"), str) else ""
            lines = _diff_lines(unified) if unified else _input_lines(tool, tool_input)
            return [
                NormalizedEvent(
                    "file_edit",
                    {
                        "tool": _EDIT_TOOLS[tool],
                        "path": path,
                        "added": sum(1 for ln in lines if ln["sign"] == "+"),
                        "removed": sum(1 for ln in lines if ln["sign"] == "-"),
                        "diff": lines[:_DIFF_CAP],
                        "diff_truncated": len(lines) > _DIFF_CAP,
                    },
                )
            ]
        if tool.startswith("haro_browser_"):
            # The shared browser's calls carry Claude's name for them, so the rail's IN USE badge
            # (which looks for it) works for this backend too.
            return [NormalizedEvent("tool_call", {"tool": "mcp__" + tool.replace("haro_browser_", "haro_browser__", 1), "summary": _summarize(tool, tool_input, cwd)})]
        name = _TOOL_NAMES.get(tool) or _EDIT_TOOLS.get(tool) or (tool[:1].upper() + tool[1:] if tool else "Tool")
        summary = _summarize(tool, tool_input, cwd)
        if failed:
            why = str(state.get("error") or "").strip()
            summary = f"{summary} (failed{': ' + why[:120] if why else ''})".strip()
        return [NormalizedEvent("tool_call", {"tool": name, "summary": summary})]
