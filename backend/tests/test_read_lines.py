"""A long line of process output must not end the run's reader.

``async for line in stream`` raises ValueError past the stream limit (64 KiB). The dev server
of a real project logs whole response payloads, so the reader task died, haro marked the run
stopped and forgot its process while it kept running with nobody draining its pipe.
"""

from __future__ import annotations

import asyncio
import sys

import pytest

from haro import config, lifecycle, procs
from haro.hub import Hub
from haro.models import Project, Workspace
from haro.store import Store


def run(coro):
    return asyncio.run(coro)


def stream_with(*chunks: bytes) -> asyncio.StreamReader:
    reader = asyncio.StreamReader()  # the default 64 KiB limit, as a subprocess pipe has
    for c in chunks:
        reader.feed_data(c)
    reader.feed_eof()
    return reader


async def collect(*chunks: bytes, **kw) -> list[bytes]:
    return [line async for line in procs.read_lines(stream_with(*chunks), **kw)]


def test_the_plain_stream_iterator_raises_on_a_long_line():
    """What the readers did before: the whole reader died on one 70 KB line."""

    async def go():
        return [line async for line in stream_with(b"x" * 70_000 + b"\nafter\n")]

    with pytest.raises(ValueError):
        run(go())


def test_short_lines_come_through_whole_with_their_newline():
    assert run(collect(b"one\ntwo\n")) == [b"one\n", b"two\n"]


def test_a_line_split_across_chunks_is_joined():
    assert run(collect(b"hel", b"lo\nwor", b"ld\n")) == [b"hello\n", b"world\n"]


def test_a_last_line_without_a_newline_is_still_yielded():
    assert run(collect(b"a\nb")) == [b"a\n", b"b"]


def test_a_long_line_is_cut_into_pieces_and_nothing_is_lost():
    body = b"y" * 200_000
    got = run(collect(body + b"\nafter\n", max_line=8000))
    assert got[-1] == b"after\n"
    pieces = got[:-1]
    assert all(len(p) <= 8000 for p in pieces)
    assert b"".join(pieces) == body + b"\n"


def test_a_long_line_with_no_newline_until_the_end_does_not_pile_up():
    chunks = [b"z" * 50_000 for _ in range(40)]  # 2 MB, never a newline
    got = run(collect(*chunks, max_line=8192))
    assert all(len(p) <= 8192 for p in got)
    assert sum(len(p) for p in got) == 2_000_000


@pytest.fixture(autouse=True)
def log_root(tmp_path, monkeypatch):
    monkeypatch.setattr(config.settings, "run_log_root", str(tmp_path / "logs"))
    return tmp_path / "logs"


def test_a_run_that_prints_a_huge_line_is_still_watched_to_its_exit(tmp_path, monkeypatch):
    """End to end through start_run: the 300 KB line used to end the reader, so the run was
    reported stopped (no exit code) while its process went on."""
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(ws)
    project = Project(name="demo", path=str(tmp_path), default_branch="main")
    psettings = config.ProjectSettings()
    code = "import sys; sys.stdout.write('q' * 300000 + '\\n' + 'after the long line\\n'); sys.stdout.flush()"
    psettings.runs = [config.RunScript(id="web", command=f'{sys.executable} -c "{code}"', default=True)]
    published: list[dict] = []

    async def publish(ws_id, env):
        published.append(env)

    monkeypatch.setattr(hub, "publish", publish)

    async def go():
        await lifecycle.start_run(store=store, hub=hub, workspace=ws, project=project, psettings=psettings)
        await asyncio.wait_for(store.run_tasks[(ws.id, "web")], 20)

    run(go())
    lines = [e["line"] for e in published if e.get("line") is not None]
    # An exact output line: the "$ command" header also contains the words.
    assert any(l.strip() == "after the long line" for l in lines), "the reader kept going past the long line"
    assert sum(len(l) for l in lines if set(l.strip()) == {"q"}) == 300_000
    ended = [e for e in published if e.get("running") is False]
    assert ended and ended[-1]["exit"] == 0, "its real exit code, not a bare 'stopped'"
    assert (ws.id, "web") not in store.run_procs


def test_a_reader_that_fails_does_not_orphan_the_process(tmp_path, monkeypatch):
    """Whatever breaks the reader, the run is not reported stopped while it still runs: haro says
    it cannot read the output, keeps the pipe drained and reports the real exit."""
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="haro/w", worktree_path=str(tmp_path), base_ref="main")
    store.add_workspace(ws)
    project = Project(name="demo", path=str(tmp_path), default_branch="main")
    psettings = config.ProjectSettings()
    psettings.runs = [config.RunScript(id="web", command="printf 'one\\ntwo\\n'; sleep 0.3; exit 3", default=True)]
    published: list[dict] = []

    async def publish(ws_id, env):
        published.append(env)

    monkeypatch.setattr(hub, "publish", publish)

    async def breaks(stream, **kw):
        yield await stream.readline()
        raise ValueError("boom")

    monkeypatch.setattr(lifecycle, "read_lines", breaks)

    async def go():
        await lifecycle.start_run(store=store, hub=hub, workspace=ws, project=project, psettings=psettings)
        await asyncio.wait_for(store.run_tasks[(ws.id, "web")], 20)

    run(go())
    lines = [e["line"] for e in published if e.get("line") is not None]
    assert any("could not read the output any more (ValueError)" in l for l in lines)
    ended = [e for e in published if e.get("running") is False]
    assert ended[-1]["exit"] == 3, "the real exit code, after waiting for the process"
    assert (ws.id, "web") not in store.run_procs
