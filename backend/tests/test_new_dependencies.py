"""New dependency names a change adds to a manifest, and the receipt line that carries them."""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

import pytest

from haro import main, new_dependencies as nd, receipt as receipt_svc
from haro.config import ProjectSettings
from haro.models import Workspace


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
        cwd=repo, check=True, capture_output=True, text=True,
    )


@pytest.fixture
def repo(tmp_path) -> Path:
    r = tmp_path / "repo"
    (r / "web").mkdir(parents=True)
    _git(r, "init", "-q", "-b", "main")
    (r / "package.json").write_text('{"name":"app","version":"1.0.0","dependencies":{"react":"^18.0.0"},"devDependencies":{"vitest":"^1.0.0"}}')
    (r / "web/package.json").write_text('{"name":"web"}')
    (r / "requirements.txt").write_text("flask==2.0\n# comment\nRequests>=2\n")
    (r / "pyproject.toml").write_text('[project]\nname = "x"\ndependencies = ["httpx>=0.27", "pydantic"]\n')
    _git(r, "add", "-A")
    _git(r, "commit", "-q", "-m", "base")
    return r


def _run(repo: Path):
    changed = ["package.json", "web/package.json", "requirements.txt", "pyproject.toml", "src/a.ts"]
    return asyncio.run(nd.new_dependencies(str(repo), "main", changed))


def test_nothing_new_when_manifests_are_unchanged(repo):
    assert _run(repo) == []


def test_a_new_js_package_is_named_and_a_version_bump_is_not(repo):
    (repo / "package.json").write_text(
        '{"name":"app","version":"2.0.0","dependencies":{"react":"^19.0.0","left-padd":"^1.0.0"},'
        '"devDependencies":{"vitest":"^1.0.0","tinycolor3":"1.0.0"},"scripts":{"test":"vitest"}}'
    )
    got = _run(repo)
    assert [(d.path, d.names) for d in got] == [("package.json", ["left-padd", "tinycolor3"])]


def test_a_manifest_that_did_not_exist_at_the_base_counts_everything(repo):
    (repo / "web/package.json").write_text('{"name":"web","dependencies":{"zod":"^3"}}')
    got = {d.path: d.names for d in _run(repo)}
    assert got["web/package.json"] == ["zod"]
    subprocess.run(["git", "mv", "web/package.json", "web/other.json"], cwd=repo)
    assert "web/package.json" not in {d.path for d in asyncio.run(nd.new_dependencies(str(repo), "main", ["web/other.json"]))}


def test_python_manifests(repo):
    (repo / "requirements.txt").write_text("flask==2.1\nRequests>=2\n-r other.txt\nfastapi==0.100\nPy_Yaml\n")
    (repo / "pyproject.toml").write_text(
        '[project]\nname = "x"\ndependencies = ["httpx>=0.27", "pydantic", "rich[extras]>=13"]\n'
        '[project.optional-dependencies]\ndev = ["pytest"]\n'
    )
    got = {d.path: d.names for d in _run(repo)}
    assert got["requirements.txt"] == ["fastapi", "py-yaml"]
    assert got["pyproject.toml"] == ["pytest", "rich"]


def test_a_broken_manifest_is_skipped_not_fatal(repo):
    (repo / "package.json").write_text("{ not json")
    assert _run(repo) == []


def test_the_receipt_carries_the_names_and_says_no_registry_was_checked(repo):
    (repo / "package.json").write_text('{"name":"app","dependencies":{"react":"^18.0.0","left-padd":"1"}}')
    w = Workspace(project_id="p", name="w", branch="b", worktree_path=str(repo), base_ref="main")
    main.store.add_workspace(w)
    try:
        r = asyncio.run(receipt_svc.build_receipt(store=main.store, workspace=w, settings=ProjectSettings()))
        assert [(d.path, d.names) for d in r.new_dependencies] == [("package.json", ["left-padd"])]
        md = receipt_svc.render_markdown(r)
        assert "- New in package.json (named there now, not at the base; no registry was checked): `left-padd`" in md
        for word in ("malicious", "hallucinated", "safe"):
            assert word not in md.lower()
    finally:
        main.store.remove_workspace(w.id)


def test_a_name_that_could_break_the_receipt_markdown_is_left_out(repo):
    (repo / "package.json").write_text(
        '{"name":"app","dependencies":{"react":"^18.0.0","ok-pkg":"1","evil`name":"1","new\\nline":"1","@scope/fine":"1"}}'
    )
    got = {d.path: d.names for d in _run(repo)}
    assert got["package.json"] == ["@scope/fine", "ok-pkg"]


def test_markdown_strips_backticks_and_newlines_from_paths_and_labels():
    from haro.models import Receipt, ReceiptGuard, ReceiptNewDependency

    r = Receipt(
        workspace_id="w",
        new_dependencies=[ReceiptNewDependency(path="we`ird\npath/package.json", names=["a"])],
        guard=ReceiptGuard(refused=["read of we`ird\n.env"]),
    )
    md = receipt_svc.render_markdown(r)
    assert "- New in weirdpath/package.json " in md
    assert "- Refused before they ran (a text match, not a complete list): read of weird.env" in md
