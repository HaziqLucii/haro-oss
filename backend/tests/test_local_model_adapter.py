"""LocalModelAdapter — the local-model (Ollama / llama.cpp) agent backend.

We can't hit a real model server in the gate, so the adapter takes an injectable
``transport``: a callable that turns a request payload into a stream of raw SSE
lines. These tests script turns as an Ollama/llama.cpp OpenAI-compatible endpoint
would emit them, then assert:

  * the agentic loop drives tool calls → executes them in the worktree → feeds
    results back → finishes on a no-tool-call turn,
  * streamed content becomes ``token`` events, edits become ``file_edit`` events,
  * the tool executors are bounded to the worktree (traversal guard), and
  * transport/curl failures surface as a single normalized ``error`` event.
"""

import asyncio
import json

import pytest

from haro.adapters.local_model import (
    LocalModelAdapter,
    apply_tool_call_deltas,
    execute_tool,
    tool_schemas,
)


# --------------------------------------------------------------------------- #
# Transport scripting helpers
# --------------------------------------------------------------------------- #
def _sse(obj: dict) -> str:
    return f"data: {json.dumps(obj)}"


def _content_chunk(text: str) -> dict:
    return {"choices": [{"delta": {"content": text}}]}


def _tool_chunk(name: str, args: dict, call_id: str = "call_1") -> dict:
    return {"choices": [{"delta": {"tool_calls": [
        {"index": 0, "id": call_id, "type": "function",
         "function": {"name": name, "arguments": json.dumps(args)}}
    ]}}]}


def scripted_transport(turns: list[list[dict]]):
    """Return a transport that replays ``turns`` — one turn's SSE chunks per call.

    Each call to the transport (one per agent-loop round) pops the next turn and
    streams its chunks followed by ``[DONE]``.
    """
    remaining = list(turns)

    async def transport(payload):
        chunks = remaining.pop(0) if remaining else []
        for c in chunks:
            yield _sse(c)
        yield "data: [DONE]"

    return transport


def _drive(adapter: LocalModelAdapter, *, task: str, cwd: str) -> list:
    async def collect():
        return [ev async for ev in adapter.run(task=task, cwd=cwd)]

    return asyncio.run(collect())


# --------------------------------------------------------------------------- #
# Tool schema
# --------------------------------------------------------------------------- #
def test_tool_schema_shape():
    names = {t["function"]["name"] for t in tool_schemas()}
    assert names == {"read_file", "write_file", "edit_file", "list_dir", "run_bash"}
    for t in tool_schemas():
        assert t["type"] == "function"
        assert "parameters" in t["function"]


# --------------------------------------------------------------------------- #
# Streaming tool-call accumulation
# --------------------------------------------------------------------------- #
def test_tool_call_deltas_concatenate_across_chunks():
    acc: dict = {}
    # arguments split across chunks, name/id only on the first — the streaming case.
    apply_tool_call_deltas(acc, [{"index": 0, "id": "c1", "function": {"name": "write_file", "arguments": '{"path":"a.txt",'}}])
    apply_tool_call_deltas(acc, [{"index": 0, "function": {"arguments": '"content":"hi"}'}}])
    assert acc[0]["name"] == "write_file"
    assert acc[0]["id"] == "c1"
    assert json.loads(acc[0]["args"]) == {"path": "a.txt", "content": "hi"}


# --------------------------------------------------------------------------- #
# Tool execution (bounded to the worktree)
# --------------------------------------------------------------------------- #
def test_write_then_read_roundtrip(tmp_path):
    res, ev = asyncio.run(execute_tool("write_file", {"path": "hello.py", "content": "print(1)\n"}, str(tmp_path)))
    assert (tmp_path / "hello.py").read_text() == "print(1)\n"
    assert ev.type == "file_edit" and ev.payload["path"] == "hello.py" and ev.payload["added"] == 1

    res, ev = asyncio.run(execute_tool("read_file", {"path": "hello.py"}, str(tmp_path)))
    assert res == "print(1)\n"
    assert ev.type == "tool_call"


def test_edit_file_replaces_first_occurrence(tmp_path):
    (tmp_path / "f.txt").write_text("foo bar foo\n")
    res, ev = asyncio.run(execute_tool(
        "edit_file", {"path": "f.txt", "old_string": "foo", "new_string": "baz"}, str(tmp_path)))
    assert (tmp_path / "f.txt").read_text() == "baz bar foo\n"
    assert ev.type == "file_edit"


def test_edit_file_missing_old_string_errors(tmp_path):
    (tmp_path / "f.txt").write_text("hello\n")
    res, _ = asyncio.run(execute_tool(
        "edit_file", {"path": "f.txt", "old_string": "nope", "new_string": "x"}, str(tmp_path)))
    assert "not found" in res
    assert (tmp_path / "f.txt").read_text() == "hello\n"  # untouched


def test_path_traversal_is_refused(tmp_path):
    res, _ = asyncio.run(execute_tool("read_file", {"path": "../../etc/passwd"}, str(tmp_path)))
    assert res.startswith("error:")


def test_run_bash_returns_exit_and_output(tmp_path):
    res, ev = asyncio.run(execute_tool("run_bash", {"command": "echo hi"}, str(tmp_path)))
    assert "hi" in res and "[exit 0]" in res
    assert ev.type == "tool_call" and ev.payload["tool"] == "run_bash"


def test_list_dir(tmp_path):
    (tmp_path / "a.txt").write_text("")
    (tmp_path / "sub").mkdir()
    res, _ = asyncio.run(execute_tool("list_dir", {"path": ""}, str(tmp_path)))
    assert "a.txt" in res and "sub/" in res


# --------------------------------------------------------------------------- #
# Full agentic loop over a scripted transport
# --------------------------------------------------------------------------- #
def test_loop_executes_tool_then_finishes(tmp_path):
    # Turn 1: model asks to write a file. Turn 2: model just talks → done.
    turns = [
        [_tool_chunk("write_file", {"path": "out.txt", "content": "done\n"})],
        [_content_chunk("Created out.txt. All set.")],
    ]
    adapter = LocalModelAdapter(transport=scripted_transport(turns))
    events = _drive(adapter, task="make out.txt", cwd=str(tmp_path))

    assert (tmp_path / "out.txt").read_text() == "done\n"
    types = [e.type for e in events]
    assert "file_edit" in types
    assert types[-1] == "done"
    done = events[-1]
    assert "All set" in done.payload["result"]
    # local server is stateless → no resumable session id
    assert done.payload["session_id"] is None


def test_content_streams_as_tokens(tmp_path):
    turns = [[_content_chunk("hello "), _content_chunk("world")]]
    adapter = LocalModelAdapter(transport=scripted_transport(turns))
    events = _drive(adapter, task="say hi", cwd=str(tmp_path))
    tokens = [e.payload.get("text") for e in events if e.type == "token"]
    assert "hello " in tokens and "world" in tokens


def test_transport_error_becomes_error_event(tmp_path):
    async def failing(payload):
        yield _sse({"__error__": "connection refused"})
        yield "data: [DONE]"

    adapter = LocalModelAdapter(transport=failing)
    events = _drive(adapter, task="x", cwd=str(tmp_path))
    assert events[-1].type == "error"
    assert "connection refused" in events[-1].payload["message"]


def test_iteration_cap_stops_the_loop(tmp_path):
    # A model that keeps calling a tool forever must hit the cap, not spin.
    async def always_tool(payload):
        for c in [_tool_chunk("run_bash", {"command": "true"})]:
            yield _sse(c)
        yield "data: [DONE]"

    adapter = LocalModelAdapter(transport=always_tool)
    events = _drive(adapter, task="loop", cwd=str(tmp_path))
    assert events[-1].type == "error"
    assert "cap" in events[-1].payload["message"]


def test_base_url_normalization():
    assert LocalModelAdapter(base_url="http://localhost:11434").base_url == "http://localhost:11434/v1"
    assert LocalModelAdapter(base_url="http://localhost:8080/v1/").base_url == "http://localhost:8080/v1"
