"""Contract tests for the quality scanners (backlog/double-gate.md §1).

The seam's one non-negotiable rule is that **unavailable is not clean**: a scanner the
project asked for that cannot run must come back `available=False` with a reason, never an
empty finding list. Those are different answers and conflating them is the silent pass §0
exists to prevent, so every adapter is pinned on it here.

Tests that need the real binary skip when it is absent rather than mocking the CLI —
a mocked scanner would pin our *assumptions* about the tool's output, which is exactly the
class of bug (guessed flags, guessed JSON shape) these adapters were written to avoid.
"""

from __future__ import annotations

import asyncio
import shutil
import subprocess
from pathlib import Path

import pytest

from haro.adapters.quality import ADAPTERS, GitleaksAdapter, LintAdapter, SemgrepAdapter
from haro.adapters.quality.base import at_or_above

# A real GitHub PAT-shaped string gitleaks recognises. Fake, but the right shape.
_FAKE_PAT = "ghp_16C7e42F292c6912E7710c838347Ae178B4a"


def _need(tool: str):
    if shutil.which(tool) is None:
        pytest.skip(f"{tool} not installed")


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    root = tmp_path / "wt"
    root.mkdir()
    subprocess.run(["git", "init", "-q", "."], cwd=root, check=True, capture_output=True)
    (root / ".gitignore").write_text("node_modules/\n")
    return root


# --- the seam's rule ------------------------------------------------------- #

def test_severity_ordering_and_unknown_labels():
    assert at_or_above("high", "medium") and at_or_above("medium", "medium")
    assert not at_or_above("low", "medium")
    # A scanner emitting a severity we don't model must NOT block a merge on a label
    # nobody chose — it degrades to advisory.
    assert not at_or_above("catastrophic", "medium")


def test_a_missing_binary_is_unavailable_not_clean(repo):
    """The whole point of the seam. `available=False` + a reason, never `findings == []`."""
    r = asyncio.run(GitleaksAdapter().scan(
        cwd=str(repo), changed_files=["a.js"], base_ref="main",
        config={"gitleaks_cmd": "definitely-not-installed-xyz"},
    ))
    assert r.available is False
    assert r.findings == []
    assert "not installed" in (r.error or "")


def test_lint_without_a_command_is_unavailable_not_clean(repo):
    r = asyncio.run(LintAdapter().scan(
        cwd=str(repo), changed_files=["a.js"], base_ref="main", config={},
    ))
    assert r.available is False and "lint_cmd" in (r.error or "")


def test_registry_exposes_the_three_named_scanners():
    assert set(ADAPTERS) == {"gitleaks", "semgrep", "lint"}


# --- gitleaks (real binary) ------------------------------------------------ #

def test_gitleaks_finds_a_planted_secret_in_a_changed_file(repo):
    _need("gitleaks")
    (repo / "conf.js").write_text(f'const token = "{_FAKE_PAT}";\n')
    r = asyncio.run(GitleaksAdapter().scan(
        cwd=str(repo), changed_files=["conf.js"], base_ref="main",
    ))
    assert r.available and len(r.findings) == 1
    f = r.findings[0]
    assert f.file == "conf.js" and f.line == 1
    # A leaked credential is never a "medium" — there is no threshold at which it's fine.
    assert f.severity == "high"
    # The credential itself must never travel into the store/feed/UI.
    assert _FAKE_PAT not in f.message


def test_gitleaks_ignores_a_secret_outside_the_change(repo):
    """Diff-scoped: pre-existing debt is somebody else's problem, or adopting haro on a
    legacy repo means a wall of findings you didn't introduce (the cry-wolf kill condition)."""
    _need("gitleaks")
    (repo / "old.js").write_text(f'const token = "{_FAKE_PAT}";\n')
    (repo / "new.js").write_text("const clean = 1;\n")
    r = asyncio.run(GitleaksAdapter().scan(
        cwd=str(repo), changed_files=["new.js"], base_ref="main",
    ))
    assert r.available and r.findings == []


def test_gitleaks_clean_change_is_clean_not_unavailable(repo):
    _need("gitleaks")
    (repo / "new.js").write_text("export const add = (a, b) => a + b;\n")
    r = asyncio.run(GitleaksAdapter().scan(
        cwd=str(repo), changed_files=["new.js"], base_ref="main",
    ))
    assert r.available is True and r.findings == []


# --- semgrep (real binary) ------------------------------------------------- #

def test_semgrep_flags_eval_with_the_bundled_offline_ruleset(repo):
    """Also pins that the bundled rules work with no network — haro is local-first."""
    _need("semgrep")
    (repo / "bad.js").write_text("const r = eval(userInput);\n")
    r = asyncio.run(SemgrepAdapter().scan(
        cwd=str(repo), changed_files=["bad.js"], base_ref="main",
    ))
    assert r.available, r.error
    assert [f.rule for f in r.findings] == ["haro-js-eval"]
    assert r.findings[0].severity == "high" and r.findings[0].line == 1


def test_semgrep_skips_files_it_cannot_parse(repo):
    _need("semgrep")
    (repo / "data.lock").write_text("not code\n")
    r = asyncio.run(SemgrepAdapter().scan(
        cwd=str(repo), changed_files=["data.lock"], base_ref="main",
    ))
    assert r.available and r.findings == []


def test_semgrep_reports_a_broken_ruleset_as_unavailable(repo):
    """A ruleset that won't load surfaces in `errors[]`, NOT the exit code. Reporting
    'clean' off a scan whose rules never loaded is the silent pass §0 forbids."""
    _need("semgrep")
    (repo / "bad.js").write_text("const r = eval(x);\n")
    r = asyncio.run(SemgrepAdapter().scan(
        cwd=str(repo), changed_files=["bad.js"], base_ref="main",
        config={"semgrep_config": str(repo / "does-not-exist.yaml")},
    ))
    assert r.available is False and r.findings == []


# --- lint (no binary needed: the command is the contract) ------------------- #

def test_lint_zero_exit_is_clean(repo):
    r = asyncio.run(LintAdapter().scan(
        cwd=str(repo), changed_files=["a.js"], base_ref="main", config={"lint_cmd": "true"},
    ))
    assert r.available and r.findings == []


def test_lint_parses_path_line_col_message(repo):
    r = asyncio.run(LintAdapter().scan(
        cwd=str(repo), changed_files=["src/a.js"], base_ref="main",
        config={"lint_cmd": "echo 'src/a.js:12:5: Unexpected console statement'; exit 1"},
    ))
    assert r.available and len(r.findings) == 1
    f = r.findings[0]
    assert (f.file, f.line) == ("src/a.js", 12)
    assert "console" in f.message


def test_lint_that_objects_unattributably_still_reports(repo):
    """A non-zero linter we can't map to a changed line must not read as green — report
    the failure itself, with the tail, rather than swallowing it."""
    r = asyncio.run(LintAdapter().scan(
        cwd=str(repo), changed_files=["a.js"], base_ref="main",
        config={"lint_cmd": "echo 'catastrophic config error'; exit 2"},
    ))
    assert r.available and len(r.findings) == 1
    assert "exited 2" in r.findings[0].message


def test_lint_ignores_complaints_about_unchanged_files(repo):
    r = asyncio.run(LintAdapter().scan(
        cwd=str(repo), changed_files=["src/new.js"], base_ref="main",
        config={"lint_cmd": "echo 'src/legacy.js:3:1: old problem'; exit 1"},
    ))
    # Attributed to a file outside the change ⇒ falls through to the one honest
    # "it objected" finding rather than blaming this diff for legacy debt.
    assert len(r.findings) == 1 and r.findings[0].file == ""
