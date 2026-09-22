"""The Double Gate's orchestrator + its wiring into the verdict (backlog/double-gate.md §1).

`test_quality_adapters.py` pins the scanners; this pins the *policy* built on top of them,
which is where the load-bearing decisions live:

* the **tri-state** the autonomy ladder reads (`None` ≠ `[]`), because "nobody looked" and
  "looked and found nothing" must never collapse into one answer;
* **severity threshold** — only findings at/above it block, so a project can keep advisory
  rows visible without them refusing merges;
* **enforce = warn|block** — warn records without downgrading the verdict, block folds into
  the green conjunction;
* **unavailable ⇒ degraded** — a scanner that couldn't run makes the green unverified rather
  than silently clean.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field

import pytest

from haro import quality
from haro.adapters.quality.base import QualityFinding, QualityResult


@dataclass
class _Settings:
    """Only the fields `quality.analyze` reads (duck-typed, like the real ProjectSettings)."""

    quality_scanners: list[str] = field(default_factory=lambda: ["gitleaks"])
    quality_severity_threshold: str = "medium"
    quality_enforce: str = "block"
    quality_lint_cmd: str = ""
    quality_lint_severity: str = "medium"
    quality_semgrep_config: str = ""


def _run(settings, changed=("a.js",), **kw):
    return asyncio.run(quality.analyze(
        cwd="/tmp", changed_files=list(changed), base_ref="main", settings=settings, **kw
    ))


def _stub(monkeypatch, name: str, result: QualityResult):
    class _Stub:
        async def scan(self, **_):
            return result
    monkeypatch.setitem(quality.ADAPTERS, name, _Stub)


def _finding(sev="high", tool="gitleaks", line=1, rule="r", file="a.js"):
    return QualityFinding(tool=tool, severity=sev, file=file, rule=rule, message="m", line=line)


# --- the tri-state the ladder depends on ----------------------------------- #

def test_no_scanners_configured_returns_an_empty_report():
    r = _run(_Settings(quality_scanners=[]))
    assert r.findings == [] and r.degraded == [] and r.ran == []


def test_no_changed_files_scans_nothing():
    """An empty diff has nothing to say — and must not be reported as a clean scan of
    something, nor spend three subprocesses proving it."""
    r = _run(_Settings(), changed=())
    assert r.findings == [] and r.ran == []


def test_a_clean_scan_is_clean(monkeypatch):
    _stub(monkeypatch, "gitleaks", QualityResult(tool="gitleaks"))
    r = _run(_Settings())
    assert r.clean and r.ran == ["gitleaks"] and r.degraded == [] and r.note is None


# --- unavailable is never clean -------------------------------------------- #

def test_an_unavailable_scanner_degrades_the_run(monkeypatch):
    _stub(monkeypatch, "gitleaks", QualityResult.unavailable("gitleaks", "not installed"))
    r = _run(_Settings())
    assert r.findings == []
    assert r.ran == []                      # it did NOT run
    assert len(r.degraded) == 1 and "not installed" in r.degraded[0]


def test_an_unknown_scanner_name_degrades_rather_than_being_ignored():
    """A typo'd scanner must not read as 'scanning for secrets' while nothing scans."""
    r = _run(_Settings(quality_scanners=["gitleeks"]))
    assert r.degraded and "unknown scanner" in r.degraded[0]
    assert r.ran == []


def test_a_crashing_scanner_degrades_and_never_raises(monkeypatch):
    class _Boom:
        async def scan(self, **_):
            raise RuntimeError("kaboom")
    monkeypatch.setitem(quality.ADAPTERS, "gitleaks", _Boom)
    r = _run(_Settings())
    assert r.degraded and "crashed" in r.degraded[0] and r.findings == []


# --- severity policy -------------------------------------------------------- #

def test_only_findings_at_or_above_the_threshold_block(monkeypatch):
    _stub(monkeypatch, "gitleaks", QualityResult(
        tool="gitleaks",
        findings=[_finding("high", line=1), _finding("low", line=2), _finding("medium", line=3)],
    ))
    r = _run(_Settings(quality_severity_threshold="medium"))
    assert len(r.findings) == 3
    assert sorted(f.severity for f in r.blocking) == ["high", "medium"]


def test_a_lower_threshold_widens_what_blocks(monkeypatch):
    _stub(monkeypatch, "gitleaks", QualityResult(
        tool="gitleaks", findings=[_finding("low", line=2)],
    ))
    assert _run(_Settings(quality_severity_threshold="medium")).blocking == []
    assert len(_run(_Settings(quality_severity_threshold="low")).blocking) == 1


def test_duplicate_findings_from_two_scanners_collapse(monkeypatch):
    same = dict(file="a.js", line=7, rule="eval", message="eval is dangerous")
    _stub(monkeypatch, "gitleaks", QualityResult(
        tool="gitleaks", findings=[QualityFinding(tool="gitleaks", severity="high", **same)]))
    _stub(monkeypatch, "semgrep", QualityResult(
        tool="semgrep", findings=[QualityFinding(tool="semgrep", severity="high", **same)]))
    r = _run(_Settings(quality_scanners=["gitleaks", "semgrep"]))
    assert len(r.findings) == 1 and r.findings[0].tool == "gitleaks"


# --- the chip line ---------------------------------------------------------- #

def test_note_summarizes_per_tool_and_flags_a_partial_block(monkeypatch):
    _stub(monkeypatch, "gitleaks", QualityResult(
        tool="gitleaks", findings=[_finding("high", line=1), _finding("low", line=2)],
    ))
    r = _run(_Settings(quality_severity_threshold="medium"))
    assert r.note == "2 gitleaks (1 blocking)"


def test_note_is_none_when_clean(monkeypatch):
    _stub(monkeypatch, "gitleaks", QualityResult(tool="gitleaks"))
    assert _run(_Settings()).note is None


# --- streaming -------------------------------------------------------------- #

def test_emit_streams_start_and_done_per_scanner(monkeypatch):
    _stub(monkeypatch, "gitleaks", QualityResult(tool="gitleaks", findings=[_finding()]))
    events: list[dict] = []

    async def emit(ev):
        events.append(ev)

    _run(_Settings(), emit=emit)
    kinds = [e["kind"] for e in events]
    assert kinds == ["scanner_started", "scanner_done"]
    assert events[1]["status"] == "findings" and events[1]["count"] == 1


def test_emit_reports_an_unavailable_scanner_too(monkeypatch):
    _stub(monkeypatch, "gitleaks", QualityResult.unavailable("gitleaks", "nope"))
    events: list[dict] = []

    async def emit(ev):
        events.append(ev)

    _run(_Settings(), emit=emit)
    assert events[-1]["status"] == "unavailable"


# --- the config contract the ladder waits on -------------------------------- #

def test_config_exposes_quality_enabled_as_the_shipped_ness_signal(tmp_path):
    """`trust.py` keys the dormant `quality` rung off `settings.quality_enabled`; if this
    name drifts, the rung silently never appears."""
    from haro import config

    (tmp_path / ".haro").mkdir()
    (tmp_path / ".haro" / "settings.toml").write_text(
        "[quality]\n"
        "enabled = true\n"
        'scanners = ["gitleaks", "lint"]\n'
        'severity_threshold = "high"\n'
        'enforce = "warn"\n'
        'lint_cmd = "npm run lint"\n'
    )
    s = config.load_project_settings(str(tmp_path))
    assert s.quality_enabled is True
    assert s.quality_scanners == ["gitleaks", "lint"]
    assert s.quality_severity_threshold == "high"
    assert s.quality_enforce == "warn"
    assert s.quality_lint_cmd == "npm run lint"


def test_config_defaults_are_off_and_sane(tmp_path):
    from haro import config

    s = config.load_project_settings(str(tmp_path))
    assert s.quality_enabled is False           # opt-in like every other v2.x feature
    assert s.quality_enforce == "block"         # but when you ask for it, it means it
    assert s.quality_severity_threshold == "medium"


def test_config_rejects_nonsense_values_instead_of_trusting_them(tmp_path):
    from haro import config

    (tmp_path / ".haro").mkdir()
    (tmp_path / ".haro" / "settings.toml").write_text(
        "[quality]\nenabled = true\nseverity_threshold = \"catastrophic\"\nenforce = \"maybe\"\n"
    )
    s = config.load_project_settings(str(tmp_path))
    assert s.quality_severity_threshold == "medium" and s.quality_enforce == "block"


# --- the ship choke point --------------------------------------------------- #

def _green_ws(tmp_path, **gate_kw):
    from haro.models import GateSummary, Project, Workspace, WorkspaceStatus
    from haro.models import TestRunStatus as RunStatus

    ws = Workspace(project_id="p", name="w", branch="feat",
                   worktree_path=str(tmp_path), base_ref="main")
    ws.status = WorkspaceStatus.gate_green
    ws.gate = GateSummary(status=RunStatus.passed, **gate_kw)
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    return ws, project


def _preflight(ws, project, monkeypatch):
    from haro import integrate

    async def clean(*_a, **_k):
        return True

    monkeypatch.setattr("haro.git_ops.is_clean", clean)
    return asyncio.run(integrate.ship_preflight(
        workspace=ws, project=project, merge_mode="both", busy=None, action="merge"))


def test_ship_is_refused_when_a_warn_mode_green_still_carries_blocking_findings(tmp_path, monkeypatch):
    """`enforce = "warn"` keeps the VERDICT green, but warn governs the verdict — not
    whether haro will hand you the merge button for a leaked credential."""
    from haro import integrate

    ws, project = _green_ws(tmp_path, quality_status="findings", quality_count=2,
                            quality_blocking=1, quality_note="1 gitleaks")
    with pytest.raises(integrate.ShipRefused) as e:
        _preflight(ws, project, monkeypatch)
    assert "quality gate" in str(e.value).lower()


def test_advisory_findings_below_the_threshold_do_not_refuse_a_ship(tmp_path, monkeypatch):
    """The whole point of a threshold: a project can keep low-severity rows visible
    without them refusing merges. Blocking on them would make the dial a lie."""
    ws, project = _green_ws(tmp_path, quality_status="findings", quality_count=3,
                            quality_blocking=0, quality_note="3 lint")
    _preflight(ws, project, monkeypatch)  # must not raise


def test_a_clean_quality_gate_ships(tmp_path, monkeypatch):
    ws, project = _green_ws(tmp_path, quality_status="clean")
    _preflight(ws, project, monkeypatch)


def test_a_project_without_the_quality_gate_is_unaffected(tmp_path, monkeypatch):
    """Off by default must mean *invisible* by default — no new refusal for the projects
    that never opted in."""
    ws, project = _green_ws(tmp_path)  # quality_status None
    _preflight(ws, project, monkeypatch)
