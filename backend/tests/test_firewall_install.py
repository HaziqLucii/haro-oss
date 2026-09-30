"""Merge Firewall install path (backlog/merge-firewall.md §3): the ``[trust]``
firewall config keys, the ``config.write_project_firewall`` writer, the
``firewall.install_hooks``/``uninstall_hooks`` git-side installer, and the
``POST /projects/{id}/firewall`` endpoint that ties them together.

The config-parse + writer tests need only a scratch dir; the installer + endpoint
tests init a real git repo (the hook goes in ``$GIT_COMMON_DIR/hooks`` and we set
real ``git config`` keys), driving the async handler with ``asyncio.run`` against
the module-level ``store`` singleton — the pattern the other route tests use.
"""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

import pytest
from fastapi import HTTPException

from haro import config, firewall, git_ops, main
from haro.models import FirewallInstallRequest, Project


def run(coro):
    return asyncio.run(coro)


def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _git_get(repo, key):
    out = subprocess.run(
        ["git", "config", "--get", key], cwd=repo, capture_output=True, text=True
    )
    return out.stdout.strip() if out.returncode == 0 else None


@pytest.fixture
def repo(tmp_path):
    """A real (remote-less) git repo, registered as a project."""
    path = tmp_path / "repo"
    path.mkdir()
    _run("init", "-b", "main", cwd=path)
    _run("config", "user.email", "t@t", cwd=path)
    _run("config", "user.name", "t", cwd=path)
    proj = Project(name="demo", path=str(path), default_branch="main")
    main.store.add_project(proj)
    yield proj
    main.store.remove_project(proj.id)


# --- config parse -----------------------------------------------------------

def test_firewall_defaults_off(tmp_path):
    ps = config.load_project_settings(str(tmp_path))
    assert ps.firewall == "off"
    assert ps.firewall_strict is False


def test_firewall_parsed_from_trust_table(tmp_path):
    base = tmp_path / ".haro"
    base.mkdir()
    (base / "settings.toml").write_text(
        '[trust]\nfirewall = "block"\nstrict = true\n'
    )
    ps = config.load_project_settings(str(tmp_path))
    assert ps.firewall == "block"
    assert ps.firewall_strict is True


def test_firewall_unknown_posture_falls_back_to_off(tmp_path):
    base = tmp_path / ".haro"
    base.mkdir()
    (base / "settings.toml").write_text('[trust]\nfirewall = "nonsense"\n')
    assert config.load_project_settings(str(tmp_path)).firewall == "off"


# --- writer -----------------------------------------------------------------

def test_write_firewall_roundtrips_and_omits_defaults(tmp_path):
    p = str(tmp_path)
    config.write_project_firewall(p, firewall="warn", strict=False)
    ps = config.load_project_settings(p)
    assert ps.firewall == "warn" and ps.firewall_strict is False
    # off/false are the defaults → the keys are omitted, not written as literals.
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert 'firewall = "warn"' in text
    assert "strict" not in text


def test_write_firewall_preserves_autonomy_ladder_keys(tmp_path):
    """The firewall shares the ``[trust]`` table with the autonomy ladder — the
    targeted upsert must not clobber the ladder's own keys."""
    base = tmp_path / ".haro"
    base.mkdir()
    (base / "settings.toml").write_text(
        "[trust]\nenabled = true\nstreak_required = 5\n"
    )
    config.write_project_firewall(str(tmp_path), firewall="block", strict=True)
    ps = config.load_project_settings(str(tmp_path))
    assert ps.trust_enabled is True and ps.trust_streak_required == 5
    assert ps.firewall == "block" and ps.firewall_strict is True


# --- installer --------------------------------------------------------------

def test_install_writes_both_hooks_executable_and_config(repo):
    written = run(
        firewall.install_hooks(repo.path, backend_url="http://127.0.0.1:9100", strict=True)
    )
    assert len(written) == len(firewall.HOOK_NAMES)
    for path in written:
        import os
        assert path.endswith(tuple(firewall.HOOK_NAMES))
        assert firewall._HOOK_MARKER in open(path).read()
        assert os.access(path, os.X_OK)
    assert _git_get(repo.path, "haro.url") == "http://127.0.0.1:9100"
    assert _git_get(repo.path, "haro.strict") == "true"


def test_default_backend_url_leaves_haro_url_unset(repo):
    run(firewall.install_hooks(repo.path, strict=False))
    # A stock install stays config-free for haro.url; strict is still written.
    assert _git_get(repo.path, "haro.url") is None
    assert _git_get(repo.path, "haro.strict") == "false"


def test_install_chains_onto_foreign_hook(repo):
    """A pre-existing foreign hook is chained onto (fenced block appended), never
    clobbered — its own body survives verbatim."""
    hooks = run(firewall._hooks_dir(repo.path))
    hooks.mkdir(parents=True, exist_ok=True)
    (hooks / "pre-push").write_text("#!/bin/sh\necho not ours\n")
    run(firewall.install_hooks(repo.path))
    text = (hooks / "pre-push").read_text()
    assert "echo not ours" in text  # foreign body preserved
    assert firewall._FENCE_START in text and firewall._FENCE_END in text
    assert firewall._HOOK_MARKER in text  # our logic is present inside the fence


def test_chain_is_idempotent(repo):
    """Reinstalling over an already-chained hook refreshes the block in place — no
    duplicate fence, foreign body still intact."""
    hooks = run(firewall._hooks_dir(repo.path))
    hooks.mkdir(parents=True, exist_ok=True)
    (hooks / "pre-push").write_text("#!/bin/sh\necho not ours\n")
    run(firewall.install_hooks(repo.path))
    run(firewall.install_hooks(repo.path))
    text = (hooks / "pre-push").read_text()
    assert text.count(firewall._FENCE_START) == 1
    assert text.count("echo not ours") == 1


def test_install_respects_core_hooks_path(repo):
    """When ``core.hooksPath`` redirects hooks (husky et al.), we install there — not
    into the default dir git would ignore — and chain onto husky's existing hook."""
    husky = Path(repo.path) / ".husky"
    husky.mkdir()
    (husky / "pre-push").write_text("#!/bin/sh\nnpm test\n")
    _run("config", "core.hooksPath", ".husky", cwd=repo.path)
    assert run(firewall._hooks_dir(repo.path)) == husky.resolve()
    written = run(firewall.install_hooks(repo.path))
    assert str(husky / "pre-push") in written
    text = (husky / "pre-push").read_text()
    assert "npm test" in text  # husky's hook preserved
    assert firewall._FENCE_START in text


def test_uninstall_strips_only_fenced_block(repo):
    """Disarm removes exactly our fenced block from a chained foreign hook, leaving
    the foreign hook byte-identical to before we chained."""
    hooks = run(firewall._hooks_dir(repo.path))
    hooks.mkdir(parents=True, exist_ok=True)
    original = "#!/bin/sh\necho not ours\n"
    (hooks / "pre-push").write_text(original)
    run(firewall.install_hooks(repo.path))
    run(firewall.uninstall_hooks(repo.path))
    assert (hooks / "pre-push").read_text() == original  # foreign hook restored
    assert _git_get(repo.path, "haro.strict") is None


def test_uninstall_removes_only_our_hooks(repo):
    run(firewall.install_hooks(repo.path, strict=True))
    hooks = run(firewall._hooks_dir(repo.path))
    (hooks / "pre-commit").write_text("#!/bin/sh\necho foreign\n")  # someone else's
    removed = run(firewall.uninstall_hooks(repo.path))
    assert {p.rsplit("/", 1)[-1] for p in removed} == set(firewall.HOOK_NAMES)
    assert (hooks / "pre-commit").exists()  # untouched
    assert _git_get(repo.path, "haro.strict") is None


# --- endpoint ---------------------------------------------------------------

def test_endpoint_block_installs_and_persists(repo):
    res = run(main.install_firewall(repo.id, FirewallInstallRequest(firewall="block")))
    assert res.firewall == "block"
    assert res.strict is True  # block implies strict even without an explicit flag
    assert len(res.hooks) == len(firewall.HOOK_NAMES)
    assert config.load_project_settings(repo.path).firewall == "block"
    assert _git_get(repo.path, "haro.strict") == "true"


def test_endpoint_off_disarms(repo):
    run(main.install_firewall(repo.id, FirewallInstallRequest(firewall="warn")))
    res = run(main.install_firewall(repo.id, FirewallInstallRequest(firewall="off")))
    assert res.firewall == "off"
    assert len(res.hooks) == len(firewall.HOOK_NAMES)  # every slot we own
    hooks = run(firewall._hooks_dir(repo.path))
    assert not (hooks / "pre-push").exists()
    assert config.load_project_settings(repo.path).firewall == "off"


def test_endpoint_chains_onto_foreign_hook(repo):
    """A foreign hook is chained onto rather than rejected — there is no conflict path."""
    hooks = run(firewall._hooks_dir(repo.path))
    hooks.mkdir(parents=True, exist_ok=True)
    (hooks / "pre-merge-commit").write_text("#!/bin/sh\necho husky\n")
    res = run(main.install_firewall(repo.id, FirewallInstallRequest(firewall="warn")))
    assert res.firewall == "warn"
    text = (hooks / "pre-merge-commit").read_text()
    assert "echo husky" in text and firewall._FENCE_START in text


def test_endpoint_404_for_unknown_project():
    with pytest.raises(HTTPException) as exc:
        run(main.install_firewall("nope", FirewallInstallRequest(firewall="warn")))
    assert exc.value.status_code == 404


# --- DELETE (uninstall is one command) --------------------------------------

def test_delete_disarms_and_persists_off(repo):
    """DELETE is the body-less counterpart to POST off: removes both hooks, clears the
    git config, and persists posture off."""
    run(main.install_firewall(repo.id, FirewallInstallRequest(firewall="block")))
    res = run(main.uninstall_firewall(repo.id))
    assert res.firewall == "off"
    assert res.strict is False
    assert len(res.hooks) == len(firewall.HOOK_NAMES)  # every slot we own
    hooks = run(firewall._hooks_dir(repo.path))
    assert not (hooks / "pre-push").exists()
    assert not (hooks / "pre-merge-commit").exists()
    assert config.load_project_settings(repo.path).firewall == "off"
    assert _git_get(repo.path, "haro.strict") in (None, "")


def test_delete_is_idempotent_when_nothing_installed(repo):
    """The uninstall-trust guarantee: DELETE on a repo with no firewall is a clean
    no-op (no hooks to remove), never an error."""
    res = run(main.uninstall_firewall(repo.id))
    assert res.firewall == "off"
    assert res.hooks == []
    # a second DELETE is still a no-op
    assert run(main.uninstall_firewall(repo.id)).hooks == []


def test_delete_strips_only_our_block_from_foreign_hook(repo):
    """A hook we chained onto has only our fenced block stripped; the foreign hook
    (husky et al.) is left byte-identical."""
    hooks = run(firewall._hooks_dir(repo.path))
    hooks.mkdir(parents=True, exist_ok=True)
    (hooks / "pre-push").write_text("#!/bin/sh\necho husky\n")
    run(main.install_firewall(repo.id, FirewallInstallRequest(firewall="warn")))
    run(main.uninstall_firewall(repo.id))
    text = (hooks / "pre-push").read_text()
    assert "echo husky" in text
    assert firewall._FENCE_START not in text


def test_delete_404_for_unknown_project():
    with pytest.raises(HTTPException) as exc:
        run(main.uninstall_firewall("nope"))
    assert exc.value.status_code == 404
