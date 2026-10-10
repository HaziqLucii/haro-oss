"""The language-server bridge against the REAL ``typescript-language-server`` (no fake server).

Skipped unless ``HARO_LSP_SANDBOX`` points at a project with ``src/App.tsx`` (containing an
unfinished ``useSt``) and ``react`` + ``typescript`` installed, and the server resolves. Drives
``LspSession`` with real JSON-RPC: initialize, didOpen, completion, completionItem/resolve,
shutdown/exit. Run with ``-s`` to see the raw ``useState`` item and its resolve response.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any, Optional

import pytest

from haro import lsp

SANDBOX = Path(os.environ["HARO_LSP_SANDBOX"]) if os.environ.get("HARO_LSP_SANDBOX") else None
CMD = lsp.resolve_server(str(SANDBOX)) if SANDBOX else None
pytestmark = pytest.mark.skipif(
    not (SANDBOX and (SANDBOX / "src" / "App.tsx").is_file() and CMD),
    reason="HARO_LSP_SANDBOX unset or typescript-language-server not resolvable",
)

PREFERENCES = {
    "includeCompletionsForModuleExports": True,
    "includeCompletionsWithInsertText": True,
    "allowIncompleteCompletions": True,
}


class Client:
    """Minimal JSON-RPC client over ``LspSession``; answers server-to-client requests with null."""

    def __init__(self, session: lsp.LspSession) -> None:
        self.session = session
        self._next = 0
        self._pending: dict[int, asyncio.Future] = {}
        self.notifications: asyncio.Queue = asyncio.Queue()
        self._pump = asyncio.create_task(self._read())

    async def _read(self) -> None:
        async for raw in self.session.messages():
            msg = json.loads(raw)
            if "method" in msg and "id" in msg:
                await self.session.send(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": None}))
            elif "method" in msg:
                self.notifications.put_nowait(msg)
            elif "id" in msg and msg["id"] in self._pending:
                fut = self._pending.pop(msg["id"])
                if not fut.done():
                    fut.set_result(msg)

    async def request(self, method: str, params: Any, timeout: float = 60.0) -> dict:
        self._next += 1
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[self._next] = fut
        await self.session.send(
            json.dumps({"jsonrpc": "2.0", "id": self._next, "method": method, "params": params})
        )
        return await asyncio.wait_for(fut, timeout)

    async def notify(self, method: str, params: Any = None) -> None:
        msg: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        await self.session.send(json.dumps(msg))


def _items(result: Any) -> list[dict]:
    if isinstance(result, dict):
        return result.get("items", [])
    return result or []


async def _scenario(preferences: Optional[dict]) -> dict:
    assert SANDBOX and CMD
    root = SANDBOX.resolve()
    uri = root.as_uri()
    doc = root / "src" / "App.tsx"
    text = doc.read_text()
    line = text.split("\n").index(next(l for l in text.split("\n") if l.rstrip().endswith("useSt")))
    col = len(text.split("\n")[line].rstrip())

    session = await lsp.LspSession.start(CMD, str(root), dict(os.environ))
    client = Client(session)
    out: dict[str, Any] = {}
    try:
        init_opts: dict[str, Any] = {"preferences": preferences} if preferences else {}
        init = await client.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": uri,
                "workspaceFolders": [{"uri": uri, "name": "sandbox"}],
                "capabilities": {
                    "workspace": {"configuration": False},
                    "textDocument": {
                        "completion": {
                            "completionItem": {
                                "snippetSupport": False,
                            }
                        }
                    },
                },
                "initializationOptions": init_opts,
            },
        )
        assert "error" not in init, (init, session.stderr_tail)
        assert "completionProvider" in init["result"]["capabilities"]
        out["resolveProvider"] = init["result"]["capabilities"]["completionProvider"].get("resolveProvider")
        await client.notify("initialized", {})
        await client.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": doc.as_uri(), "languageId": "typescriptreact", "version": 1, "text": text}},
        )
        # The module-export (auto-import) entries are built asynchronously by tsserver: the first
        # replies hold only locals and globals (isIncomplete is False anyway), so poll until they land.
        t0 = asyncio.get_running_loop().time()
        out["attempts"] = 0
        while True:
            out["attempts"] += 1
            comp = await client.request(
                "textDocument/completion",
                {
                    "textDocument": {"uri": doc.as_uri()},
                    "position": {"line": line, "character": col},
                    "context": {"triggerKind": 1},
                },
            )
            assert "error" not in comp, comp
            items = _items(comp["result"])
            out["item"] = next((i for i in items if i.get("label") == "useState"), None)
            if out["item"] is not None or asyncio.get_running_loop().time() - t0 > 30:
                break
            await asyncio.sleep(0.25)
        out["count"] = len(items)
        out["seconds"] = round(asyncio.get_running_loop().time() - t0, 2)
        out["incomplete"] = isinstance(comp["result"], dict) and comp["result"].get("isIncomplete")
        if out["item"] is not None:
            res = await client.request("completionItem/resolve", out["item"])
            assert "error" not in res, res
            out["resolved"] = res["result"]

        await client.request("shutdown", None)
        await client.notify("exit")
        out["code"] = await session.wait_exit(10)
    finally:
        pid = session.pid
        await session.close()
        client._pump.cancel()
    out["pid"] = pid
    return out


def _gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


def _imports_use_state(item: Optional[dict]) -> bool:
    edits = (item or {}).get("additionalTextEdits") or []
    return any("import" in e.get("newText", "") and "useState" in e["newText"] and "react" in e["newText"] for e in edits)


def test_real_server_completes_use_state_with_auto_import():
    bare = asyncio.run(_scenario(None))
    withprefs = asyncio.run(_scenario(PREFERENCES))
    for name, r in (("NO PREFERENCES", bare), ("WITH PREFERENCES", withprefs)):
        print(f"\n=== {name}: {r['count']} items, isIncomplete={r['incomplete']}, resolveProvider={r['resolveProvider']}, attempts={r['attempts']}, {r['seconds']}s to first useState")
        print("completion item:", json.dumps(r["item"], indent=1)[:1800])
        print("resolved:", json.dumps(r.get("resolved"), indent=1)[:1800])
        print("auto-import in completion item:", _imports_use_state(r["item"]))
        print("auto-import after resolve:", _imports_use_state(r.get("resolved")))

    assert withprefs["item"] is not None, "no `useState` completion even with preferences set"
    assert _imports_use_state(withprefs["resolved"]) or _imports_use_state(withprefs["item"])
    assert _gone(withprefs["pid"]) and _gone(bare["pid"])


ACCEPTED = "export function App() {\n  const [n] = useState\n}"


async def _resolve_order(mode: str) -> dict:
    """Completion, then the accepted word synced via didChange, then resolve with the ORIGINAL item.

    ``mode``: ``immediate`` (resolve right after didChange), ``delayed`` (0.3s gap), ``shifted``
    (a second, unrelated didChange inserting a line above the cursor first), ``before`` (resolve
    on selection, then apply the word: the alternative order).
    """
    assert SANDBOX and CMD
    root = SANDBOX.resolve()
    uri = root.as_uri()
    doc = root / "src" / "App.tsx"
    text = doc.read_text()
    lines = text.split("\n")
    line = lines.index(next(l for l in lines if l.rstrip().endswith("useSt")))
    col = len(lines[line].rstrip())
    doc_uri = doc.as_uri()

    session = await lsp.LspSession.start(CMD, str(root), dict(os.environ))
    client = Client(session)
    out: dict[str, Any] = {"mode": mode}
    version = 1

    async def change(new_text: str) -> None:
        nonlocal version
        version += 1
        await client.notify(
            "textDocument/didChange",
            {"textDocument": {"uri": doc_uri, "version": version}, "contentChanges": [{"text": new_text}]},
        )

    try:
        init = await client.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": uri,
                "workspaceFolders": [{"uri": uri, "name": "sandbox"}],
                "capabilities": {
                    "workspace": {"configuration": False},
                    "textDocument": {"completion": {"completionItem": {"snippetSupport": False}}},
                },
                "initializationOptions": {"preferences": PREFERENCES},
            },
        )
        assert "error" not in init, (init, session.stderr_tail)
        await client.notify("initialized", {})
        await client.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": doc_uri, "languageId": "typescriptreact", "version": 1, "text": text}},
        )
        loop = asyncio.get_running_loop()
        t0 = loop.time()
        item = None
        while item is None and loop.time() - t0 < 30:
            comp = await client.request(
                "textDocument/completion",
                {
                    "textDocument": {"uri": doc_uri},
                    "position": {"line": line, "character": col},
                    "context": {"triggerKind": 1},
                },
            )
            assert "error" not in comp, comp
            item = next((i for i in _items(comp["result"]) if i.get("label") == "useState"), None)
            if item is None:
                await asyncio.sleep(0.25)
        assert item is not None, "no `useState` completion"
        out["item_data"] = item.get("data")

        if mode == "before":
            res = await client.request("completionItem/resolve", item)
            await change(ACCEPTED)
        else:
            await change(ACCEPTED)
            if mode == "delayed":
                await asyncio.sleep(0.3)
            elif mode == "shifted":
                await change("// unrelated\n" + ACCEPTED)
            res = await client.request("completionItem/resolve", item)
        out["response"] = res
        out["has_import_edit"] = "error" not in res and _imports_use_state(res.get("result"))

        await client.request("shutdown", None)
        await client.notify("exit")
        await session.wait_exit(10)
    finally:
        out["pid"] = session.pid
        await session.close()
        client._pump.cancel()
    return out


@pytest.mark.parametrize("mode", ["immediate", "delayed", "shifted", "before"])
def test_real_server_resolve_after_accepted_word_applied(mode):
    r = asyncio.run(_resolve_order(mode))
    print(f"\n=== resolve order: {mode}: import edit present = {r['has_import_edit']}")
    print("item data:", json.dumps(r["item_data"])[:400])
    print("response:", json.dumps(r["response"], indent=1)[:1500])
    assert r["has_import_edit"], r["response"]
    assert _gone(r["pid"])


_TAIL = 'export function App() {\n  const [n] = useSt\n}\n'
EXISTING_VARIANTS = {
    "a_plain_default_import": ('import React from "react";\n\n' + _TAIL, "Existing.tsx"),
    "b_two_imports_blank_line": ('import React from "react";\nimport { x } from "./x";\n\n' + _TAIL, "ExistingB.tsx"),
    "c_type_only_import": ('import type { FC } from "react";\n\n' + _TAIL, "ExistingC.tsx"),
}


async def _existing_import_scenario(name: str) -> dict:
    """Client order against a doc that ALREADY imports from "react": completion until `useState`
    appears, didChange applying the accepted word, resolve with the original item."""
    assert SANDBOX and CMD
    text, fname = EXISTING_VARIANTS[name]
    root = SANDBOX.resolve()
    uri = root.as_uri()
    src = root / "src"
    doc = src / fname
    (src / "x.ts").write_text("export const x = 1;\n")
    doc.write_text(text)
    doc_uri = doc.as_uri()
    lines = text.split("\n")
    line = lines.index(next(l for l in lines if l.rstrip().endswith("useSt")))
    col = len(lines[line].rstrip())
    accepted = "\n".join(l + "ate" if i == line else l for i, l in enumerate(lines))

    session = await lsp.LspSession.start(CMD, str(root), dict(os.environ))
    client = Client(session)
    out: dict[str, Any] = {"name": name}
    try:
        init = await client.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": uri,
                "workspaceFolders": [{"uri": uri, "name": "sandbox"}],
                "capabilities": {
                    "workspace": {"configuration": False},
                    "textDocument": {"completion": {"completionItem": {"snippetSupport": False}}},
                },
                "initializationOptions": {"preferences": PREFERENCES},
            },
        )
        assert "error" not in init, (init, session.stderr_tail)
        await client.notify("initialized", {})
        await client.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": doc_uri, "languageId": "typescriptreact", "version": 1, "text": text}},
        )
        loop = asyncio.get_running_loop()
        t0 = loop.time()
        item = None
        while item is None and loop.time() - t0 < 30:
            comp = await client.request(
                "textDocument/completion",
                {
                    "textDocument": {"uri": doc_uri},
                    "position": {"line": line, "character": col},
                    "context": {"triggerKind": 1},
                },
            )
            assert "error" not in comp, comp
            item = next((i for i in _items(comp["result"]) if i.get("label") == "useState"), None)
            if item is None:
                await asyncio.sleep(0.25)
        assert item is not None, "no `useState` completion"
        await client.notify(
            "textDocument/didChange",
            {"textDocument": {"uri": doc_uri, "version": 2}, "contentChanges": [{"text": accepted}]},
        )
        res = await client.request("completionItem/resolve", item)
        assert "error" not in res, res
        out["resolved"] = res["result"]
        out["text_edit"] = item.get("textEdit")
        await client.request("shutdown", None)
        await client.notify("exit")
        await session.wait_exit(10)
    finally:
        out["pid"] = session.pid
        await session.close()
        client._pump.cancel()
        for p in (doc, src / "x.ts"):
            p.unlink(missing_ok=True)
    return out


@pytest.mark.parametrize("name", list(EXISTING_VARIANTS))
def test_real_server_existing_react_import_edits(name):
    r = asyncio.run(_existing_import_scenario(name))
    edits = r["resolved"].get("additionalTextEdits") or []
    print(f"\n=== existing import: {name}")
    print("completion textEdit:", json.dumps(r["text_edit"]))
    print("additionalTextEdits:", json.dumps(edits))
    assert edits, r["resolved"]
    assert any("useState" in e.get("newText", "") for e in edits), edits
    assert _gone(r["pid"])


async def _diagnostics_scenario() -> dict:
    """didOpen ``const x: number = "a";`` and wait for the server's publishDiagnostics."""
    assert SANDBOX and CMD
    root = SANDBOX.resolve()
    uri = root.as_uri()
    doc = root / "src" / "diag.ts"
    session = await lsp.LspSession.start(CMD, str(root), dict(os.environ))
    client = Client(session)
    out: dict[str, Any] = {}
    try:
        init = await client.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": uri,
                "workspaceFolders": [{"uri": uri, "name": "sandbox"}],
                "capabilities": {"workspace": {"configuration": False}, "textDocument": {"publishDiagnostics": {"versionSupport": True}}},
            },
        )
        assert "error" not in init, (init, session.stderr_tail)
        await client.notify("initialized", {})
        await client.notify(
            "textDocument/didOpen",
            {
                "textDocument": {
                    "uri": doc.as_uri(),
                    "languageId": "typescript",
                    "version": 1,
                    "text": 'const x: number = "a";\n',
                }
            },
        )
        deadline = asyncio.get_running_loop().time() + 30
        while asyncio.get_running_loop().time() < deadline:
            msg = await asyncio.wait_for(client.notifications.get(), 30)
            if msg["method"] == "textDocument/publishDiagnostics" and msg["params"]["diagnostics"]:
                out["publish"] = msg
                break
        await client.request("shutdown", None)
        await client.notify("exit")
        await session.wait_exit(10)
    finally:
        await session.close()
        client._pump.cancel()
    out["uri"] = doc.as_uri()
    return out


def test_real_server_publishes_ts2322_diagnostics():
    out = asyncio.run(_diagnostics_scenario())
    msg = out.get("publish")
    assert msg is not None, "no publishDiagnostics with entries"
    print("\nRAW publishDiagnostics:", json.dumps(msg, indent=1))
    params = msg["params"]
    assert params["uri"] == out["uri"]
    d = next(x for x in params["diagnostics"] if x.get("code") == 2322)
    assert d["severity"] == 1
    assert d["source"] == "typescript"
    # typescript-language-server 6.0.1 omits `version` even with versionSupport advertised.
    assert params.get("version") in (None, 1)
    assert d["message"] == "Type 'string' is not assignable to type 'number'."
    assert d["range"]["start"] == {"line": 0, "character": 6}


async def _definition_scenario(root: Path) -> dict:
    """didOpen a file importing ``useState`` from react and a local helper, ask for both definitions."""
    assert SANDBOX and CMD
    uri = root.as_uri()
    doc = root / "src" / "def.tsx"
    text = doc.read_text()
    lines = text.split("\n")
    line = next(i for i, l in enumerate(lines) if "= useState(" in l)
    use_col = lines[line].index("useState(") + 2
    local_line = next(i for i, l in enumerate(lines) if "return local(" in l)
    local_col = lines[local_line].index("local(") + 1

    session = await lsp.LspSession.start(CMD, str(root), dict(os.environ))
    client = Client(session)
    out: dict[str, Any] = {}
    try:
        init = await client.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": uri,
                "workspaceFolders": [{"uri": uri, "name": "wt"}],
                "capabilities": {
                    "workspace": {"configuration": False},
                    "textDocument": {
                        "definition": {"dynamicRegistration": False, "linkSupport": False},
                        "hover": {"contentFormat": ["markdown", "plaintext"]},
                    },
                },
            },
        )
        assert "error" not in init, (init, session.stderr_tail)
        await client.notify("initialized", {})
        await client.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": doc.as_uri(), "languageId": "typescriptreact", "version": 1, "text": text}},
        )
        loop = asyncio.get_running_loop()
        for name, (ln, col) in (("react", (line, use_col)), ("local", (local_line, local_col))):
            t0 = loop.time()
            result = None
            tries = 0
            # Right after didOpen tsserver can still answer with the import specifier itself (module
            # resolution is async): poll until the answer leaves this file, as the completion tests do.
            while loop.time() - t0 < 30:
                tries += 1
                res = await client.request(
                    "textDocument/definition",
                    {"textDocument": {"uri": doc.as_uri()}, "position": {"line": ln, "character": col}},
                )
                assert "error" not in res, res
                result = res["result"]
                if result and result[0]["uri"] != doc.as_uri():
                    break
                await asyncio.sleep(0.25)
            out[name] = result
            out[name + "_tries"] = tries
        hov = await client.request(
            "textDocument/hover",
            {"textDocument": {"uri": doc.as_uri()}, "position": {"line": line, "character": use_col}},
        )
        assert "error" not in hov, hov
        out["hover"] = hov["result"]
        await client.request("shutdown", None)
        await client.notify("exit")
        await session.wait_exit(10)
    finally:
        await session.close()
        client._pump.cancel()
    return out


def _worktree(tmp_path: Path, link: bool) -> Path:
    assert SANDBOX
    root = (tmp_path / ("linked" if link else "plain")).resolve()
    (root / "src").mkdir(parents=True)
    for name in ("tsconfig.json", "package.json"):
        if (SANDBOX / name).is_file():
            (root / name).write_text((SANDBOX / name).read_text())
    (root / "src" / "local.ts").write_text("export const local = (n: number) => n;\n")
    (root / "src" / "def.tsx").write_text(
        'import { useState } from "react";\n'
        'import { local } from "./local";\n'
        "export function D() {\n"
        "  const [n] = useState(0);\n"
        "  return local(n);\n"
        "}\n"
    )
    if link:
        (root / "node_modules").symlink_to((SANDBOX / "node_modules").resolve(), target_is_directory=True)
    return root


def test_real_server_definition_of_use_state_resolves_to_react_types(tmp_path):
    root = _worktree(tmp_path, link=True)
    out = asyncio.run(_definition_scenario(root))
    print("\nworktree root:", root.as_uri())
    print("node_modules realpath:", (root / "node_modules").resolve().as_uri())
    print("RAW definition of useState:", json.dumps(out["react"], indent=1))
    print("RAW definition of local:", json.dumps(out["local"], indent=1))
    print("requests until the answer left the import line:", out["react_tries"], out["local_tries"])
    loc = out["react"][0]
    assert "/node_modules/%40types/react/" in loc["uri"]
    assert loc["uri"].endswith(".d.ts")
    # The server reports the REAL path of a symlinked node_modules, never the worktree's own path.
    real = (root / "node_modules").resolve().as_uri()
    assert loc["uri"].startswith(real + "/")
    assert not loc["uri"].startswith(root.as_uri() + "/")
    print("RAW hover of useState:", json.dumps(out["hover"], indent=1)[:900])
    assert "useState" in json.dumps(out["hover"]["contents"])
    local = out["local"][0]
    assert local["uri"] == (root / "src" / "local.ts").as_uri()
    assert local["range"]["start"]["line"] == 0


BADLY_SPACED = (
    "const  a   =  1 ;\n"
    "function  f ( x:number ,y :string ) {\n"
    "return   x+1\n"
    "}\n"
    "if(a){\n"
    "console.log( a )\n"
    "}\n"
)


def _apply_edits(text: str, edits: list[dict]) -> str:
    lines = text.split("\n")
    starts = [0]
    for line in lines[:-1]:
        starts.append(starts[-1] + len(line) + 1)

    def flat(pos: dict) -> int:
        if pos["line"] >= len(lines):
            return len(text)
        return starts[pos["line"]] + min(pos["character"], len(lines[pos["line"]]))

    for e in sorted(edits, key=lambda e: (flat(e["range"]["start"]), flat(e["range"]["end"])), reverse=True):
        text = text[: flat(e["range"]["start"])] + e["newText"] + text[flat(e["range"]["end"]) :]
    return text


async def _format_scenario(root: Path, options: dict) -> dict:
    assert SANDBOX and CMD
    uri = root.as_uri()
    doc = root / "src" / "messy.ts"
    session = await lsp.LspSession.start(CMD, str(root), dict(os.environ))
    client = Client(session)
    out: dict[str, Any] = {}
    try:
        init = await client.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": uri,
                "workspaceFolders": [{"uri": uri, "name": "wt"}],
                "capabilities": {
                    "workspace": {"configuration": False},
                    "textDocument": {"formatting": {"dynamicRegistration": False}},
                },
            },
        )
        assert "error" not in init, (init, session.stderr_tail)
        out["provider"] = init["result"]["capabilities"].get("documentFormattingProvider")
        await client.notify("initialized", {})
        await client.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": doc.as_uri(), "languageId": "typescript", "version": 1, "text": BADLY_SPACED}},
        )
        res = await client.request(
            "textDocument/formatting", {"textDocument": {"uri": doc.as_uri()}, "options": options}
        )
        assert "error" not in res, res
        out["edits"] = res["result"]
        await client.request("shutdown", None)
        await client.notify("exit")
        await session.wait_exit(10)
    finally:
        await session.close()
        client._pump.cancel()
    return out


def test_real_server_formats_a_badly_spaced_file(tmp_path):
    root = _worktree(tmp_path, link=True)
    (root / "src" / "messy.ts").write_text(BADLY_SPACED)
    out = asyncio.run(_format_scenario(root, {"tabSize": 2, "insertSpaces": True}))
    edits = out["edits"]
    print("\ndocumentFormattingProvider:", out["provider"])
    print("edit count:", len(edits))
    print("RAW first edits:", json.dumps(edits[:4], indent=1))
    assert out["provider"]
    assert edits, "the server returned no formatting edits"
    assert all(set(e) == {"range", "newText"} for e in edits)
    formatted = _apply_edits(BADLY_SPACED, edits)
    print("formatted:\n" + formatted)
    assert formatted != BADLY_SPACED
    assert "const a = 1;" in formatted
    assert "  return x + 1" in formatted
