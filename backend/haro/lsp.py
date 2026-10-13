"""Language-server bridge: one WebSocket <-> one stdio language server per editor connection.

The Flutter code editor wants completion, diagnostics, hover and go-to-definition for TS/JS,
and the only practical source is ``typescript-language-server`` (it fronts the project's own
``tsserver``). A native client cannot spawn it with the worktree's env, and LSP speaks
``Content-Length`` framed JSON-RPC over stdio, which a WebSocket does not need: the socket
already delimits messages. So this module owns the framing. The WS carries exactly ONE JSON-RPC
message per text frame; the session wraps outgoing frames into LSP framing and parses the
server's stdout back into single messages (partial reads, several messages per chunk, and
multi-byte text all handled, because ``Content-Length`` counts bytes, not characters).

The server runs in its own process group so the whole tree (the server plus the ``tsserver``
node child it forks) can be killed as a unit; terminating just the parent leaves tsserver
orphaned and holding the project's files. The session object also exposes ``returncode`` and
``terminate()`` so it can sit in ``store.term_procs`` and be reaped by
``lifecycle.quiesce_workspace`` exactly like a PTY.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import shutil
import signal
from collections import deque
from pathlib import Path
from typing import Any, AsyncIterator, Optional

_BIN = "typescript-language-server"

#: Stderr kept for diagnostics, in bytes. The drain never blocks; old output falls off.
_STDERR_LIMIT = 16 * 1024

#: A frame claiming more than this is a corrupt stream, not a real message.
_MAX_BODY = 64 * 1024 * 1024

#: A header block longer than this with no terminator is garbage, not a header.
_MAX_HEADER = 64 * 1024

#: How long a terminated server gets before the group is SIGKILLed.
_KILL_AFTER = 2.0


def resolve_server(worktree_path: str, env: Optional[dict[str, str]] = None) -> Optional[list[str]]:
    """The command to start the TS/JS language server for a worktree, or None.

    Prefers the project's own ``node_modules/.bin`` (its pinned version, and ``typescript``
    resolves beside it), then PATH. ``env`` should be the env the Shell PTY gets
    (``lifecycle.script_env``): the backend's PATH is already the user's login-shell PATH.
    """
    local = Path(worktree_path) / "node_modules" / ".bin" / _BIN
    if local.is_file() and os.access(local, os.X_OK):
        return [str(local), "--stdio"]
    # An empty or relative PATH entry would resolve against whatever cwd the spawn uses.
    path = os.pathsep.join(
        d for d in (env or os.environ).get("PATH", "").split(os.pathsep) if os.path.isabs(d)
    )
    found = shutil.which(_BIN, path=path)
    return [found, "--stdio"] if found else None


def frame(text: str) -> bytes:
    body = text.encode("utf-8")
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


class FrameParser:
    """Incremental ``Content-Length`` parser: ``feed(bytes)`` returns the complete messages."""

    def __init__(self) -> None:
        self._buf = bytearray()
        #: Set when a header has no usable length. The body that followed it cannot be told
        #: from the next header, so the stream is unrecoverable and the caller must stop.
        self.corrupt = False

    def feed(self, data: bytes) -> list[str]:
        if self.corrupt:
            return []
        self._buf += data
        out: list[str] = []
        while True:
            end = self._buf.find(b"\r\n\r\n")
            if end < 0:
                self.corrupt = len(self._buf) > _MAX_HEADER
                break
            length = _content_length(bytes(self._buf[:end]))
            if length is None:
                self.corrupt = True
                break
            start = end + 4
            if len(self._buf) < start + length:
                break
            out.append(bytes(self._buf[start : start + length]).decode("utf-8", errors="replace"))
            del self._buf[: start + length]
        return out


def _content_length(header: bytes) -> Optional[int]:
    for line in header.split(b"\r\n"):
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            try:
                n = int(value.strip())
            except ValueError:
                return None
            return n if 0 <= n <= _MAX_BODY else None
    return None


class LspSession:
    """One running language server. Create with ``LspSession.start``."""

    def __init__(self, proc: asyncio.subprocess.Process) -> None:
        self._proc = proc
        self._parser = FrameParser()
        self._stderr: deque[bytes] = deque()
        self._stderr_size = 0
        self._stderr_task = asyncio.create_task(self._drain_stderr())
        self._closed = False

    @classmethod
    async def start(cls, cmd: list[str], cwd: str, env: dict[str, str]) -> "LspSession":
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=cwd,
            env=env,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
        return cls(proc)

    @property
    def pid(self) -> int:
        return self._proc.pid

    @property
    def returncode(self) -> Optional[int]:
        return self._proc.returncode

    @property
    def stderr_tail(self) -> str:
        return b"".join(self._stderr).decode("utf-8", errors="replace")

    async def _drain_stderr(self) -> None:
        stream = self._proc.stderr
        if stream is None:
            return
        while True:
            chunk = await stream.read(4096)
            if not chunk:
                return
            self._stderr.append(chunk)
            self._stderr_size += len(chunk)
            while self._stderr_size > _STDERR_LIMIT and len(self._stderr) > 1:
                self._stderr_size -= len(self._stderr.popleft())

    async def send(self, text: str) -> None:
        stdin = self._proc.stdin
        if stdin is None or stdin.is_closing():
            return
        try:
            stdin.write(frame(text))
            await stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass  # the server died; the reader side reports it

    async def messages(self) -> AsyncIterator[str]:
        """Server -> client messages, one per item, until stdout closes."""
        stream = self._proc.stdout
        if stream is None:
            return
        while True:
            chunk = await stream.read(65536)
            if not chunk:
                return
            for msg in self._parser.feed(chunk):
                yield msg
            if self._parser.corrupt:
                return

    async def wait_exit(self, timeout: float = _KILL_AFTER) -> Optional[int]:
        """The exit code, giving a server that just closed stdout a moment to finish exiting."""
        try:
            return await asyncio.wait_for(self._proc.wait(), timeout)
        except asyncio.TimeoutError:
            return self._proc.returncode

    def _signal_group(self, sig: int) -> None:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(self._proc.pid, sig)

    def terminate(self) -> None:
        """SIGTERM the whole group. Sync, so ``quiesce_workspace`` can call it like a PTY's."""
        self._signal_group(signal.SIGTERM)

    async def close(self) -> None:
        """Stop the server and reap it. Idempotent."""
        if self._closed:
            return
        self._closed = True
        self.terminate()
        if self._proc.stdin is not None:
            with contextlib.suppress(Exception):
                self._proc.stdin.close()
        try:
            await asyncio.wait_for(self._proc.wait(), _KILL_AFTER)
        except asyncio.TimeoutError:
            self._signal_group(signal.SIGKILL)
            await self._proc.wait()
        # A parent that exits on SIGTERM can leave a child that ignored it.
        self._signal_group(signal.SIGKILL)
        self._stderr_task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await self._stderr_task


def _dump(obj: dict[str, Any]) -> str:
    return json.dumps(obj, separators=(",", ":"))


UNAVAILABLE = _dump({"haro": "lsp_unavailable", "reason": "not_installed"})


def exited(code: Optional[int]) -> str:
    return _dump({"haro": "lsp_exited", "code": code})


def spawn_failed() -> str:
    return _dump({"haro": "lsp_unavailable", "reason": "spawn_failed"})


async def bridge(websocket: Any, session: LspSession) -> None:
    """Pump an accepted WebSocket <-> a session until either side ends, then reap the server.

    If the server ends first the client gets ``lsp_exited`` and a normal close; if the
    socket ends first the server is terminated. Either way ``close()`` has run on return.
    """

    async def to_client() -> bool:
        async for msg in session.messages():
            await websocket.send_text(msg)
        return True

    async def to_server() -> bool:
        while True:
            text = await websocket.receive_text()
            await session.send(text)

    server_task = asyncio.create_task(to_client())
    client_task = asyncio.create_task(to_server())
    try:
        await asyncio.wait({server_task, client_task}, return_when=asyncio.FIRST_COMPLETED)
        if server_task.done() and not server_task.cancelled() and server_task.exception() is None:
            code = await session.wait_exit()
            with contextlib.suppress(Exception):
                await websocket.send_text(exited(code))
                await websocket.close()
    finally:
        for t in (server_task, client_task):
            t.cancel()
        for t in (server_task, client_task):
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await t
        await session.close()
