"""The language-server bridge (``lsp.py`` + ``/ws/workspaces/{id}/lsp``).

No node needed: a tiny fake server written to tmp_path speaks real ``Content-Length`` framing.
The route is called directly with a fake WebSocket (the suite has no httpx, so no TestClient),
like the other handler tests. "Reaped" is asserted with ``os.kill(pid, 0)`` raising: a zombie
still answers signal 0, so this only passes once the child has actually been waited on.
"""

from __future__ import annotations

import asyncio
import json
import os
import stat
import sys
import textwrap
import time

import pytest
from fastapi import WebSocketDisconnect

from haro import lsp
from haro import main as main_mod
from haro.lifecycle import quiesce_workspace
from haro.models import Project, Workspace
from haro.store import Store

FAKE_SERVER = textwrap.dedent(
    f"""\
    #!{sys.executable}
    import json, os, sys

    inp, out = sys.stdin.buffer, sys.stdout.buffer

    def read():
        n = None
        while True:
            line = inp.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                break
            k, _, v = line.partition(b":")
            if k.lower() == b"content-length":
                n = int(v)
        return json.loads(inp.read(n).decode("utf-8"))

    def frame(obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        return b"Content-Length: %d\\r\\n\\r\\n" % len(body) + body

    def send(*objs):
        out.write(b"".join(frame(o) for o in objs))
        out.flush()

    while True:
        msg = read()
        if msg is None:
            break
        m = msg.get("method")
        if m == "initialize":
            send({{"jsonrpc": "2.0", "id": msg["id"], "result": {{"pid": os.getpid(), "args": sys.argv[1:]}}}})
        elif m == "burst":
            send({{"jsonrpc": "2.0", "id": msg["id"], "result": "a"}},
                 {{"jsonrpc": "2.0", "id": msg["id"] + 1, "result": "b"}})
        elif m == "die":
            sys.exit(7)
        elif "id" in msg:
            send({{"jsonrpc": "2.0", "id": msg["id"], "result": msg.get("params")}})
    """
)


def run(coro):
    return asyncio.run(coro)


def _install_fake(worktree):
    binp = worktree / "node_modules" / ".bin" / "typescript-language-server"
    binp.parent.mkdir(parents=True)
    binp.write_text(FAKE_SERVER)
    binp.chmod(binp.stat().st_mode | stat.S_IXUSR)
    return binp


def _gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


async def _wait_gone(pid: int, timeout: float = 5.0) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if _gone(pid):
            return True
        await asyncio.sleep(0.02)
    return False


def _req(id_, method, params=None):
    return json.dumps({"jsonrpc": "2.0", "id": id_, "method": method, "params": params}, ensure_ascii=False)


class FakeWS:
    def __init__(self):
        self.inbox: asyncio.Queue = asyncio.Queue()
        self.sent: asyncio.Queue = asyncio.Queue()
        self.closed = False

    async def accept(self):
        pass

    async def receive_text(self):
        item = await self.inbox.get()
        if item is None:
            raise WebSocketDisconnect()
        return item

    async def send_text(self, text):
        await self.sent.put(text)

    async def close(self, code=1000):
        self.closed = True

    def push(self, text):
        self.inbox.put_nowait(text)

    def hang_up(self):
        self.inbox.put_nowait(None)

    async def next(self, timeout=5.0):
        return await asyncio.wait_for(self.sent.get(), timeout)


@pytest.fixture
def env(tmp_path, monkeypatch):
    store = Store()
    monkeypatch.setattr(main_mod, "store", store)
    worktree = tmp_path / "wt"
    worktree.mkdir()
    proj = store.add_project(Project(name="p", path=str(tmp_path), default_branch="main"))
    ws = store.add_workspace(
        Workspace(project_id=proj.id, name="w", branch="b", worktree_path=str(worktree), base_ref="main")
    )
    return store, ws, worktree


# --- framing -----------------------------------------------------------------
def test_frame_counts_bytes_not_characters():
    out = lsp.frame('{"t":"héllo 日本"}')
    header, _, body = out.partition(b"\r\n\r\n")
    assert int(header.split(b":")[1]) == len(body) == len('{"t":"héllo 日本"}'.encode())


def test_parser_handles_partial_reads_and_multiple_messages():
    a, b = '{"a":"日本語"}', '{"b":1}'
    stream = lsp.frame(a) + lsp.frame(b)
    p = lsp.FrameParser()
    got: list[str] = []
    for i in range(0, len(stream), 3):  # 3-byte slices split multibyte chars and headers
        got += p.feed(stream[i : i + 3])
    assert got == [a, b]
    assert lsp.FrameParser().feed(stream) == [a, b]


def test_parser_ignores_extra_headers():
    p = lsp.FrameParser()
    assert p.feed(b"Content-Type: x\r\nContent-Length: 2\r\n\r\n{}") == ["{}"]
    assert not p.corrupt


def test_parser_marks_stream_corrupt_instead_of_gluing_body_to_next_header():
    p = lsp.FrameParser()
    assert p.feed(b"oops\n" + lsp.frame('{"a":1}')) == []
    assert p.corrupt
    assert p.feed(lsp.frame('{"b":2}')) == []


def test_parser_marks_oversized_length_corrupt():
    p = lsp.FrameParser()
    assert p.feed(b"Content-Length: 99999999999\r\n\r\n" + lsp.frame("{}")) == []
    assert p.corrupt


def test_parser_marks_unterminated_header_flood_corrupt():
    p = lsp.FrameParser()
    assert p.feed(b"x" * (64 * 1024 + 1)) == []
    assert p.corrupt


# --- resolve_server ----------------------------------------------------------
def test_resolve_prefers_project_bin_then_path(tmp_path):
    wt = tmp_path / "wt"
    wt.mkdir()
    assert lsp.resolve_server(str(wt), {"PATH": str(tmp_path / "nope")}) is None
    pathdir = tmp_path / "pathbin"
    pathdir.mkdir()
    exe = pathdir / "typescript-language-server"
    exe.write_text("#!/bin/sh\n")
    exe.chmod(0o755)
    assert lsp.resolve_server(str(wt), {"PATH": str(pathdir)}) == [str(exe), "--stdio"]
    local = _install_fake(wt)
    assert lsp.resolve_server(str(wt), {"PATH": str(pathdir)}) == [str(local), "--stdio"]


def test_resolve_skips_empty_and_relative_path_entries(tmp_path, monkeypatch):
    wt = tmp_path / "wt"
    wt.mkdir()
    exe = wt / "typescript-language-server"
    exe.write_text("#!/bin/sh\n")
    exe.chmod(0o755)
    monkeypatch.chdir(wt)
    assert lsp.resolve_server(str(wt), {"PATH": os.pathsep.join(["", ".", "rel"])}) is None


def test_resolve_ignores_non_executable_project_bin(tmp_path):
    wt = tmp_path / "wt"
    local = _install_fake(wt)
    local.chmod(0o644)
    assert lsp.resolve_server(str(wt), {"PATH": ""}) is None


# --- route -------------------------------------------------------------------
def test_round_trip_multibyte_and_double_message_chunk(env):
    store, ws, wt = env
    _install_fake(wt)

    async def body():
        sock = FakeWS()
        task = asyncio.create_task(main_mod.lsp_ws(sock, ws.id))
        sock.push(_req(1, "initialize"))
        init = json.loads(await sock.next())
        assert init["id"] == 1 and init["result"]["args"] == ["--stdio"]
        assert any(k.startswith(f"{ws.id}:lsp:") for k in store.term_procs)

        text = "héllo 日本語 \U0001f600"
        sock.push(_req(2, "textDocument/hover", {"text": text}))
        echoed = json.loads(await sock.next())
        assert echoed == {"jsonrpc": "2.0", "id": 2, "result": {"text": text}}

        sock.push(_req(10, "burst"))
        first, second = json.loads(await sock.next()), json.loads(await sock.next())
        assert (first["id"], first["result"], second["id"], second["result"]) == (10, "a", 11, "b")

        sock.hang_up()
        await asyncio.wait_for(task, 5)
        assert not store.term_procs

    run(body())


def test_unavailable_when_no_server(env, monkeypatch):
    store, ws, _ = env
    monkeypatch.setenv("PATH", "/nonexistent")

    async def body():
        sock = FakeWS()
        await main_mod.lsp_ws(sock, ws.id)
        assert json.loads(await sock.next()) == {"haro": "lsp_unavailable", "reason": "not_installed"}
        assert sock.sent.empty() and sock.closed
        assert not store.term_procs

    run(body())


def test_unknown_workspace_closes(env):
    async def body():
        sock = FakeWS()
        await main_mod.lsp_ws(sock, "ws_missing")
        assert sock.closed and sock.sent.empty()

    run(body())


def test_process_reaped_when_socket_closes(env):
    store, ws, wt = env
    _install_fake(wt)

    async def body():
        sock = FakeWS()
        task = asyncio.create_task(main_mod.lsp_ws(sock, ws.id))
        sock.push(_req(1, "initialize"))
        pid = json.loads(await sock.next())["result"]["pid"]
        assert not _gone(pid)
        sock.hang_up()
        await asyncio.wait_for(task, 5)
        assert await _wait_gone(pid)

    run(body())


def test_process_reaped_when_route_is_cancelled(env):
    store, ws, wt = env
    _install_fake(wt)

    async def body():
        sock = FakeWS()
        task = asyncio.create_task(main_mod.lsp_ws(sock, ws.id))
        sock.push(_req(1, "initialize"))
        pid = json.loads(await sock.next())["result"]["pid"]
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert await _wait_gone(pid)
        assert not store.term_procs

    run(body())


def test_reaped_by_quiesce_workspace(env):
    store, ws, wt = env
    _install_fake(wt)

    async def body():
        sock = FakeWS()
        task = asyncio.create_task(main_mod.lsp_ws(sock, ws.id))
        sock.push(_req(1, "initialize"))
        pid = json.loads(await sock.next())["result"]["pid"]
        await quiesce_workspace(store=store, workspace=ws)
        assert not store.term_procs
        msg = json.loads(await sock.next())
        assert msg["haro"] == "lsp_exited" and msg["code"] != 0
        await asyncio.wait_for(task, 5)
        assert sock.closed
        assert await _wait_gone(pid)

    run(body())


def test_server_that_exits_on_its_own(env):
    store, ws, wt = env
    _install_fake(wt)

    async def body():
        sock = FakeWS()
        task = asyncio.create_task(main_mod.lsp_ws(sock, ws.id))
        sock.push(_req(1, "initialize"))
        pid = json.loads(await sock.next())["result"]["pid"]
        sock.push(_req(2, "die"))
        assert json.loads(await sock.next()) == {"haro": "lsp_exited", "code": 7}
        await asyncio.wait_for(task, 5)
        assert sock.closed and not store.term_procs
        assert await _wait_gone(pid)

    run(body())


def test_close_is_idempotent_and_kills_a_term_ignoring_server(tmp_path):
    stubborn = tmp_path / "stubborn.py"
    stubborn.write_text(
        "import signal, sys, time\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "print('up', flush=True)\n"
        "time.sleep(60)\n"
    )

    async def body():
        s = await lsp.LspSession.start([sys.executable, str(stubborn)], str(tmp_path), dict(os.environ))
        await asyncio.sleep(0.3)  # let it install the SIGTERM handler
        t0 = time.monotonic()
        await s.close()
        await s.close()
        assert time.monotonic() - t0 < 5
        assert s.returncode is not None and _gone(s.pid)

    run(body())
