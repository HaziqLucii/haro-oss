"""`vitest list` reports resolved paths; a cwd under a symlink (macOS /var -> /private/var,
where baseline inventory worktrees live) must still yield worktree-relative test files."""

import asyncio
import json
import os

from haro.adapters.test_runner.vitest import VitestAdapter


class _Proc:
    def __init__(self, out: bytes):
        self._out = out

    async def communicate(self):
        return self._out, b""


def test_list_relativises_through_a_symlinked_cwd(tmp_path, monkeypatch):
    real = tmp_path / "real"
    (real / "lib").mkdir(parents=True)
    (real / "lib" / "a.test.ts").write_text("")
    link = tmp_path / "link"
    os.symlink(real, link)

    payload = json.dumps([{"file": str((real / "lib" / "a.test.ts").resolve()), "name": "a > works"}])

    async def fake_exec(*_a, **_kw):
        return _Proc(payload.encode())

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(VitestAdapter, "_resolve_base", lambda self, cwd: ["vitest"])

    refs = asyncio.run(VitestAdapter()._list(cwd=str(link)))
    assert [r.file for r in refs] == ["lib/a.test.ts"]
