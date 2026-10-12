"""The vitest adapter's ``only`` filter (re-run failed, added-test checks) against REAL vitest.
Skipped when the sandbox repo's node_modules is absent."""

from __future__ import annotations

import asyncio
import os
from pathlib import Path

import pytest

from haro.adapters.test_runner.vitest import VitestAdapter, only_args

SANDBOX_MODULES = Path(os.environ.get("HARO_VITEST_SANDBOX", "/nonexistent")) / "node_modules"
needs_vitest = pytest.mark.skipif(
    not (SANDBOX_MODULES / ".bin" / "vitest").exists(), reason="sandbox vitest not installed"
)


def test_only_args_uses_space_joined_anchored_names():
    args = only_args([("a.test.js", "grp > nested"), ("a.test.js", "add")])
    assert args[-1] == "^grp\\ nested$|^add$"


@needs_vitest
def test_only_finds_a_test_inside_a_describe_and_does_not_run_its_prefix_sibling(tmp_path):
    body = (
        'import {describe,test,expect} from "vitest"\n'
        'describe("grp", () => { test("nested", () => {}) })\n'
        'test("add", () => {})\ntest("add many", () => { throw new Error("must not run") })\n'
    )
    root = tmp_path / "proj"
    (root / "src").mkdir(parents=True)
    (root / "package.json").write_text('{"type":"module"}')
    os.symlink(SANDBOX_MODULES, root / "node_modules")
    (root / "src" / "n.test.js").write_text(body)

    async def go():
        a = VitestAdapter()
        return (
            await a.run(cwd=str(root), only=[("src/n.test.js", "grp > nested")]),
            await a.run(cwd=str(root), only=[("src/n.test.js", "add")]),
        )

    nested, add = asyncio.run(go())
    assert [(c.name, c.status) for c in nested.cases if c.status != "skipped"] == [("grp > nested", "passed")]
    assert [c.name for c in add.cases if c.status != "skipped"] == ["add"]
