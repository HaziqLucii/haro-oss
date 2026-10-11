"""The gate is fully deterministic: no LLM check and no lint/semgrep scanner is part of
the verdict, and the gitleaks secrets scan is advisory "code to check" only."""

from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import stat
import sys

import pytest

from haro import integrate, secrets_scan
from haro.config import load_project_settings
from haro.gate import run_gate
from haro.models import GateSummary, Project, Workspace, WorkspaceStatus
from haro.models import TestRunStatus as RunStatus

from tests.test_degraded_gate import _Green, _setup

QUIET = (
    "[workflow]\ntamper_alarm = 'off'\ncoverage_guard = 'off'\ncode_to_check = 'off'\n"
    "[gate]\nverified_hunks = false\n"
)
# Every removed knob, still present in an old project file.
LEGACY = (
    "[quality]\nenabled = true\nenforce = 'block'\nscanners = ['gitleaks', 'semgrep', 'lint']\n"
    "severity_threshold = 'low'\nplan_compliance = 'warn'\nlint_cmd = 'ruff check'\n"
    "[roles]\nenabled = true\nreview = 'opus:high'\nreview_enforce = 'warn'\nreview_max_rounds = 4\n"
    "[trust]\nrequire_quality = true\n"
)


def _changed(tmp_path, monkeypatch, name="changed.py"):
    (tmp_path / name).write_text("x = 1\n")

    async def fake_changed_files(*_a, **_k):
        return [{"path": name}]

    monkeypatch.setattr("haro.git_ops.changed_files", fake_changed_files)


def _gate(store, hub, ws, project):
    asyncio.run(run_gate(store=store, hub=hub, adapter=_Green(), workspace=ws, project_path=project.path))
    return store.latest_test(ws.id)


def _finding(**kw):
    base = dict(file="changed.py", line=3, rule="generic-api-key", message="Detected a Generic API Key")
    base.update(kw)
    return secrets_scan.SecretFinding(**base)


def _ship_ok(ws, project, monkeypatch):
    async def clean(*_a, **_k):
        return True

    async def not_merged(*_a, **_k):
        return False

    monkeypatch.setattr("haro.git_ops.is_clean", clean)
    monkeypatch.setattr("haro.git_ops.branch_merged", not_merged)
    asyncio.run(integrate.ship_preflight(
        workspace=ws, project=project, merge_mode="both", busy=None, action="merge"))


# --- no LLM, no scanners on the gate path ------------------------------------ #

def test_the_quality_module_and_scanners_are_gone():
    assert importlib.util.find_spec("haro.quality") is None
    assert importlib.util.find_spec("haro.adapters.quality") is None


def test_the_gate_never_calls_the_code_review_or_any_reviewer(tmp_path, monkeypatch):
    from haro import review

    def boom(*_a, **_k):
        raise AssertionError("the gate must not call an LLM reviewer")

    for name in ("run_code_review", "run_review"):
        monkeypatch.setattr(review, name, boom)
    store, hub, ws, project = _setup(tmp_path, QUIET + "secrets_scan = false\n" + LEGACY)
    _changed(tmp_path, monkeypatch)

    run = _gate(store, hub, ws, project)

    assert ws.status == WorkspaceStatus.gate_green
    assert run.review is None and run.plan_compliance is None
    assert run.quality_findings is None and run.quality_blocked is False
    assert run.degraded_reasons == []
    g = ws.gate
    assert (g.review_verdict, g.review_must_fix, g.review_blocking) == (None, 0, False)
    assert (g.quality_status, g.quality_count, g.quality_blocking, g.quality_note) == (None, 0, 0, None)
    assert g.degraded is False


# --- old config still loads, ignored ------------------------------------------ #

def test_old_quality_and_review_enforce_config_loads_and_is_ignored(tmp_path):
    store, hub, ws, project = _setup(tmp_path, QUIET + LEGACY)
    s = load_project_settings(str(tmp_path))
    assert s.roles_enabled is True and s.role_review.model == "opus"  # review model kept
    assert s.secrets_scan is True
    for gone in ("quality_enabled", "quality_enforce", "review_enforce", "review_max_rounds"):
        assert not hasattr(s, gone)


# --- secrets are advisory ----------------------------------------------------- #

def test_secret_findings_are_advisory_green_stays_green_and_ship_is_allowed(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, QUIET)
    _changed(tmp_path, monkeypatch)

    async def found(**_kw):
        return [_finding()]

    monkeypatch.setattr(secrets_scan, "scan", found)
    run = _gate(store, hub, ws, project)

    assert ws.status == WorkspaceStatus.gate_green
    assert run.degraded_reasons == [] and ws.gate.degraded is False
    assert run.quality_blocked is False
    (row,) = run.unchecked_items
    assert (row.kind, row.file, row.line, row.rule) == ("secret_found", "changed.py", 3, "generic-api-key")
    assert "Generic API Key" in row.detail and row.key
    assert run.unchecked_note == "1 possible secret"
    assert ws.gate.unchecked_count == 1
    _ship_ok(ws, project, monkeypatch)


def test_secret_rows_join_the_other_code_to_check_rows(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(
        tmp_path, "[workflow]\ntamper_alarm = 'off'\ncoverage_guard = 'off'\n[gate]\nverified_hunks = false\n"
    )
    _changed(tmp_path, monkeypatch)

    async def found(**_kw):
        return [_finding()]

    monkeypatch.setattr(secrets_scan, "scan", found)
    monkeypatch.setattr("haro.git_ops.diff", lambda *_a, **_k: _async_diff())
    run = _gate(store, hub, ws, project)

    assert run.unchecked_items is not None
    assert run.unchecked_items[0].kind == "secret_found"  # read first


async def _async_diff():
    return "", None


def test_gitleaks_missing_is_silent_not_degraded(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, QUIET)
    _changed(tmp_path, monkeypatch)
    monkeypatch.setattr(secrets_scan.shutil, "which", lambda _b: None)

    run = _gate(store, hub, ws, project)

    assert ws.status == WorkspaceStatus.gate_green
    assert run.degraded_reasons == [] and ws.gate.degraded is False
    assert run.unchecked_items is None
    _ship_ok(ws, project, monkeypatch)


def test_a_scan_crash_never_sinks_the_gate(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, QUIET)
    _changed(tmp_path, monkeypatch)

    async def crash(**_kw):
        raise RuntimeError("gitleaks exploded")

    monkeypatch.setattr(secrets_scan, "scan", crash)
    run = _gate(store, hub, ws, project)
    assert ws.status == WorkspaceStatus.gate_green and run.degraded_reasons == []


def test_secrets_scan_can_be_opted_out(tmp_path, monkeypatch):
    # QUIET ends inside [gate], so the key lands there.
    store, hub, ws, project = _setup(tmp_path, QUIET + "secrets_scan = false\n")
    assert load_project_settings(str(tmp_path)).secrets_scan is False
    _changed(tmp_path, monkeypatch)

    async def boom(**_kw):
        raise AssertionError("opted out")

    monkeypatch.setattr(secrets_scan, "scan", boom)
    run = _gate(store, hub, ws, project)
    assert ws.status == WorkspaceStatus.gate_green and run.unchecked_items is None


def test_a_red_or_partial_run_does_not_scan(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, QUIET)
    _changed(tmp_path, monkeypatch)
    calls = []

    async def found(**_kw):
        calls.append(1)
        return [_finding()]

    monkeypatch.setattr(secrets_scan, "scan", found)
    asyncio.run(run_gate(
        store=store, hub=hub, adapter=_Green(), workspace=ws, project_path=project.path,
        only=[("a.test.ts", "adds")],
    ))
    assert calls == []


def test_a_ticked_secret_row_survives_a_re_gate(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(
        tmp_path, "[workflow]\ntamper_alarm = 'off'\ncoverage_guard = 'off'\n[gate]\nverified_hunks = false\n"
    )
    _changed(tmp_path, monkeypatch)

    async def found(**_kw):
        return [_finding()]

    async def no_diff(*_a, **_k):
        return "", None

    monkeypatch.setattr(secrets_scan, "scan", found)
    monkeypatch.setattr("haro.git_ops.diff", no_diff)
    run = _gate(store, hub, ws, project)
    (row,) = [r for r in run.unchecked_items if r.kind == "secret_found"]
    ws.checked_rows = [row.key, "stale|gone|1"]
    assert ws.gate.unchecked_count == 1

    (tmp_path / "changed.py").write_text("x = 2\n")  # an edit, then re-gate
    run = _gate(store, hub, ws, project)
    assert ws.checked_rows == [row.key]  # the tick survives, the stale one is pruned
    assert ws.gate.unchecked_count == 0


def test_an_impacted_scope_gate_does_not_scan(tmp_path, monkeypatch):
    store, hub, ws, project = _setup(tmp_path, QUIET)
    _changed(tmp_path, monkeypatch)
    calls = []

    async def found(**_kw):
        calls.append(1)
        return [_finding()]

    monkeypatch.setattr(secrets_scan, "scan", found)
    asyncio.run(run_gate(
        store=store, hub=hub, adapter=_Green(), workspace=ws, project_path=project.path,
        changed_since="main",
    ))
    assert store.latest_test(ws.id).scope == "impacted"
    assert calls == []


def test_gate_update_from_a_legacy_client_keeps_the_opt_out(tmp_path):
    from haro import main
    from haro.config import write_project_gate

    store, hub, ws, project = _setup(tmp_path, QUIET + "secrets_scan = false\n")
    body = dict(runner="vitest", command="", gate_format="", gate_dir="", default_scope="all",
                merge_result=False, flaky_rerun=False, coverage_guard="off", coverage_tolerance=0.0)
    write_project_gate(str(tmp_path), **body, secrets_scan=None)
    assert load_project_settings(str(tmp_path)).secrets_scan is False
    write_project_gate(str(tmp_path), **body, secrets_scan=True)
    assert load_project_settings(str(tmp_path)).secrets_scan is True
    assert main.GateUpdateRequest().secrets_scan is None


def test_ship_preflight_no_longer_refuses_on_legacy_quality_or_code_review_fields(tmp_path, monkeypatch):
    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path=str(tmp_path), base_ref="main")
    ws.status = WorkspaceStatus.gate_green
    ws.gate = GateSummary(
        status=RunStatus.passed, quality_blocking=3, quality_note="3 secrets",
        review_blocking=True, review_must_fix=2,
    )
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    _ship_ok(ws, project, monkeypatch)


# --- the gitleaks wrapper ------------------------------------------------------ #

def _fake_gitleaks(tmp_path, *, report=None, exit_code=0, sleep=0, pidfile=None):
    """A stand-in binary. `report` rows may use the placeholder SRC for the scanned dir.
    It records the `--source` listing to tmp_path/listing.json."""
    script = tmp_path / "fake-gitleaks"
    script.write_text(
        f"#!{sys.executable}\n"
        "import json, os, sys, time\n"
        "a = sys.argv\n"
        "assert '--redact' in a and '--no-git' in a\n"
        "src = a[a.index('--source') + 1]\n"
        "listing = sorted(os.path.relpath(os.path.join(d, f), src)\n"
        "                 for d, _, fs in os.walk(src) for f in fs)\n"
        f"json.dump(listing, open({str(tmp_path / 'listing.json')!r}, 'w'))\n"
        f"open({str(pidfile) if pidfile else os.devnull!r}, 'w').write(str(os.getpid()))\n"
        f"time.sleep({sleep})\n"
        "path = a[a.index('--report-path') + 1]\n"
        f"json.dump(json.loads({json.dumps(json.dumps(report or []))}), open(path, 'w'))\n"
        f"sys.exit({exit_code})\n"
    )
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return str(script)


def test_scan_reports_only_changed_files_and_never_the_secret(tmp_path):
    (tmp_path / "changed.py").write_text("k = 1\n")
    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "huge.js").write_text("x\n")
    report = [
        {"File": "changed.py", "StartLine": 7, "RuleID": "aws-key",
         "Description": "AWS key", "Secret": "REDACTED", "Match": "AKIA-real-looking"},
        {"File": "legacy.py", "StartLine": 1, "RuleID": "old", "Description": "pre-existing"},
    ]
    binary = _fake_gitleaks(tmp_path, report=report, exit_code=1)  # 1 = leaks found
    found = asyncio.run(secrets_scan.scan(cwd=str(tmp_path), changed_files=["changed.py"], binary=binary))
    assert [(f.file, f.line, f.rule, f.message) for f in found] == [("changed.py", 7, "aws-key", "AWS key")]
    assert not any("AKIA" in str(vars(f)) for f in found)
    # gitleaks only ever saw the changed file, never node_modules.
    assert json.loads((tmp_path / "listing.json").read_text()) == ["changed.py"]


def test_scan_returns_none_when_gitleaks_itself_fails(tmp_path):
    (tmp_path / "a.py").write_text("x\n")
    binary = _fake_gitleaks(tmp_path, exit_code=2)
    assert asyncio.run(secrets_scan.scan(cwd=str(tmp_path), changed_files=["a.py"], binary=binary)) is None


def test_scan_clean_run_is_an_empty_list(tmp_path):
    (tmp_path / "a.py").write_text("x\n")
    binary = _fake_gitleaks(tmp_path, exit_code=0)
    assert asyncio.run(secrets_scan.scan(cwd=str(tmp_path), changed_files=["a.py"], binary=binary)) == []


def test_a_timeout_kills_gitleaks_and_returns_none(tmp_path, monkeypatch):
    import os
    import signal

    (tmp_path / "a.py").write_text("x\n")
    pidfile = tmp_path / "pid"
    binary = _fake_gitleaks(tmp_path, sleep=30, pidfile=pidfile)
    monkeypatch.setattr(secrets_scan, "_TIMEOUT_S", 1)
    assert asyncio.run(secrets_scan.scan(cwd=str(tmp_path), changed_files=["a.py"], binary=binary)) is None
    pid = int(pidfile.read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(pid, signal.SIGCONT)  # gone, not orphaned


def test_deleted_or_missing_changed_files_are_not_staged(tmp_path):
    binary = _fake_gitleaks(tmp_path)
    assert asyncio.run(secrets_scan.scan(cwd=str(tmp_path), changed_files=["gone.py"], binary=binary)) == []
