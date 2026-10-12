from __future__ import annotations

import asyncio
import subprocess

from haro import git_panel


def test_a_failed_count_is_flagged_not_reported_as_zero(tmp_path):
    subprocess.run(["git", "init", "-q", "-b", "main", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "-c", "user.email=a@b", "-c", "user.name=a",
                    "commit", "-q", "--allow-empty", "-m", "x"], check=True)
    out = asyncio.run(git_panel.status(str(tmp_path), "main", "no-such-base"))
    assert out["counts_unknown"] is True
    ok = asyncio.run(git_panel.status(str(tmp_path), "main", "main"))
    assert ok["counts_unknown"] is False and ok["ahead"] == 0
