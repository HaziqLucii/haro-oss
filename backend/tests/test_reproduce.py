"""``haro verify --rerun`` (reproduce.py) and the PR text line (receipt.pr_line).
The integration tests use a real temp git repo and the `command` runner
(`true`/`test -e ...`), so no vitest install is needed. HARO_HOME is always a
temp dir: nothing touches ~/.haro."""

from __future__ import annotations

import base64
import json
import subprocess
from pathlib import Path

from haro import attest, cli, receipt as receipt_svc, reproduce
from haro.models import Receipt, ReceiptSuite


def _git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def _repo(tmp_path: Path, command: str) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git("init", "-b", "main", cwd=repo)
    _git("config", "user.email", "t@t", cwd=repo)
    _git("config", "user.name", "t", cwd=repo)
    (repo / ".haro").mkdir()
    (repo / ".haro" / "settings.toml").write_text(
        f"[gate]\nrunner = 'command'\ncommand = '{command}'\n"
    )
    (repo / ".gitignore").write_text(".haro/attestations/\n")
    _git("add", "-A", cwd=repo)
    _git("commit", "-m", "init", cwd=repo)
    return repo


def _attest(repo: Path, capsys) -> str:
    assert cli.main(["gate", str(repo), "--attest"]) == 0
    capsys.readouterr()
    return next((repo / ".haro" / "attestations").glob("*.json")).stem


def _receipt(verdict="green", passed=42, failed=0, skipped=0) -> Receipt:
    return Receipt(
        workspace_id="w", branch="b", base_ref="main", verdict=verdict,
        suite=ReceiptSuite(
            runner="vitest", scope="all", total=passed + failed + skipped,
            passed=passed, failed=failed, skipped=skipped,
        ),
    )


def _worktrees(repo: Path) -> int:
    return len([ln for ln in _git("worktree", "list", cwd=repo).splitlines() if ln.strip()])


# -- pr_line --------------------------------------------------------------


def test_pr_line_with_attestation():
    line = receipt_svc.pr_line(_receipt(), "a1b2c3d4e5f6aaaa")
    assert line == (
        "Gate: green, 42 passed, 0 failed · attested a1b2c3d4e5f6 "
        "· reproduce: haro verify a1b2c3d4e5f6 --rerun"
    )


def test_pr_line_without_attestation_is_verdict_only():
    assert receipt_svc.pr_line(_receipt("red", 3, 2), None) == "Gate: red, 3 passed, 2 failed"


def test_pr_line_reports_skipped_and_not_gated():
    assert receipt_svc.pr_line(_receipt(skipped=4), None) == "Gate: green, 42 passed, 0 failed, 4 skipped"
    assert receipt_svc.pr_line(_receipt("none", 0, 0), "abc") == "Gate: not gated"


def test_pr_line_has_no_em_dash_or_image():
    line = receipt_svc.pr_line(_receipt(), "abcdef123456")
    assert "—" not in line and "![" not in line and "http" not in line


def test_render_markdown_has_no_em_dash():
    md = receipt_svc.render_markdown(_receipt())
    assert "—" not in md


# -- compare --------------------------------------------------------------


def _predicate(**over) -> dict:
    p = {
        "verdict": "green",
        "suite": {"runner": "vitest", "scope": "all", "total": 42, "passed": 42, "failed": 0, "skipped": 0},
    }
    p.update(over)
    return p


def test_compare_identical_is_empty():
    assert reproduce.compare(_predicate(), _receipt(), []) == []


def test_compare_reports_verdict_and_counts():
    diffs = reproduce.compare(_predicate(), _receipt("red", 40, 2), ["a.test.ts::x"])
    fields = {d["field"]: d for d in diffs}
    assert fields["verdict"]["attested"] == "green" and fields["verdict"]["rerun"] == "red"
    assert fields["passed"]["rerun"] == 40
    assert fields["failed"]["rerun"] == 2
    assert "failed_ids" not in fields  # old statements carry no ids to compare


def test_compare_failing_ids_when_attested_has_them():
    pred = _predicate(verdict="red", reproduce={"failed_ids": ["a::x"]})
    pred["suite"].update(passed=41, failed=1)
    same = reproduce.compare(pred, _receipt("red", 41, 1), ["a::x"])
    assert same == []
    moved = reproduce.compare(pred, _receipt("red", 41, 1), ["a::y"])
    assert [d["field"] for d in moved] == ["failed_ids"]


# -- attest helpers -------------------------------------------------------


def test_find_attestation_matches_signed_digest_only(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = tmp_path / "r"
    repo.mkdir()
    assert attest.find_attestation(str(repo), "d1") is None  # no key yet: nothing minted
    assert not (tmp_path / "home").exists()

    key = attest.ensure_key()
    subject = {"name": "b@abcdef123456", "digest": {"sha256": "d1"}}
    env = attest.sign_statement(attest.build_statement(_receipt(), subject), key)
    attest.save_envelope(str(repo), env, subject)
    assert attest.find_attestation(str(repo), "d1") == "abcdef123456"
    assert attest.find_attestation(str(repo), "other") is None


def test_build_statement_reproduce_block_is_optional():
    subject = {"name": "b@x", "digest": {"sha256": "d"}}
    assert "reproduce" not in attest.build_statement(_receipt(), subject)["predicate"]
    with_block = attest.build_statement(_receipt(), subject, {"tree": "t"})
    assert with_block["predicate"]["reproduce"] == {"tree": "t"}


# -- integration: haro verify --rerun ------------------------------------


def test_rerun_reproduces_a_green_attestation(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, "true")
    (repo / "new.txt").write_text("uncommitted work\n")
    sha = _attest(repo, capsys)
    before = _worktrees(repo)

    code = cli.main(["verify", sha, str(repo), "--rerun"])
    out = capsys.readouterr().out
    assert code == 0
    assert "REPRODUCED" in out
    assert _worktrees(repo) == before  # throwaway worktree cleaned up


def test_rerun_uses_the_pinned_tree_after_the_worktree_moves(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, "true")
    (repo / "new.txt").write_text("attested content\n")
    sha = _attest(repo, capsys)
    (repo / "new.txt").write_text("edited after attesting\n")

    assert cli.main(["verify", sha, str(repo), "--rerun"]) == 0


def test_rerun_mismatch_when_the_verdict_changes(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    flag = tmp_path / "flag"
    repo = _repo(tmp_path, f"test ! -e {flag}")
    sha = _attest(repo, capsys)
    flag.write_text("x")  # the environment now makes the same tree fail

    code = cli.main(["verify", sha, str(repo), "--rerun", "--json"])
    captured = capsys.readouterr()
    assert code == 2
    result = json.loads(captured.out)  # human lines went to stderr, stdout is pure JSON
    assert result["reproduced"] is False
    assert result["attested_verdict"] == "green" and result["rerun_verdict"] == "red"
    assert "verdict" in {d["field"] for d in result["differences"]}


def test_rerun_json_on_success(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, "true")
    sha = _attest(repo, capsys)
    code = cli.main(["verify", sha, str(repo), "--rerun", "--json"])
    result = json.loads(capsys.readouterr().out)
    assert code == 0 and result["reproduced"] is True and result["differences"] == []


def _resign(repo: Path, sha: str, mutate) -> None:
    path = repo / ".haro" / "attestations" / f"{sha}.json"
    env = json.loads(path.read_text())
    statement = json.loads(base64.b64decode(env["payload"]))
    mutate(statement)
    path.write_text(json.dumps(attest.sign_statement(statement, attest.ensure_key())))


def test_rerun_tree_mismatch_exits_2(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, "true")
    sha = _attest(repo, capsys)
    _resign(repo, sha, lambda s: s["subject"][0]["digest"].update(sha256="0" * 16))

    code = cli.main(["verify", sha, str(repo), "--rerun"])
    out = capsys.readouterr().out
    assert code == 2
    assert "tree does not match the attestation" in out


def test_rerun_supports_statements_without_the_reproduce_block(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, "true")
    sha = _attest(repo, capsys)
    _resign(repo, sha, lambda s: s["predicate"].pop("reproduce"))

    assert cli.main(["verify", sha, str(repo), "--rerun"]) == 0


def test_rerun_missing_pinned_tree_exits_1(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, "true")
    sha = _attest(repo, capsys)
    _resign(repo, sha, lambda s: s["predicate"]["reproduce"].update(tree="1" * 40))

    code = cli.main(["verify", sha, str(repo), "--rerun"])
    assert code == 1
    assert "no longer in this repository" in capsys.readouterr().err


def test_rerun_not_attempted_when_the_signature_fails(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, "true")
    sha = _attest(repo, capsys)
    path = repo / ".haro" / "attestations" / f"{sha}.json"
    env = json.loads(path.read_text())
    statement = json.loads(base64.b64decode(env["payload"]))
    statement["predicate"]["verdict"] = "red"
    env["payload"] = base64.b64encode(json.dumps(statement).encode()).decode()
    path.write_text(json.dumps(env))

    assert cli.main(["verify", sha, str(repo), "--rerun"]) == 2
    assert "VERIFY FAILED" in capsys.readouterr().err


def test_attest_pins_the_tree_under_refs(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, "true")
    sha = _attest(repo, capsys)
    refs = _git("for-each-ref", "--format=%(refname)", cwd=repo)
    assert f"{reproduce.ATTESTED_REF_PREFIX}{sha}" in refs


def _feat_repo(tmp_path: Path) -> Path:
    repo = _repo(tmp_path, "true")
    _git("checkout", "-b", "feat", cwd=repo)
    (repo / "f.txt").write_text("work\n")
    _git("add", "-A", cwd=repo)
    _git("commit", "-m", "work", cwd=repo)
    return repo


def _attest_on_main_base(repo: Path, capsys) -> str:
    assert cli.main(["gate", str(repo), "--base", "main", "--attest"]) == 0
    capsys.readouterr()
    return next((repo / ".haro" / "attestations").glob("*.json")).stem


def test_rerun_survives_new_commits_on_the_base_branch(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _feat_repo(tmp_path)
    sha = _attest_on_main_base(repo, capsys)

    _git("checkout", "main", cwd=repo)
    (repo / "other.txt").write_text("moves main\n")
    _git("add", "-A", cwd=repo)
    _git("commit", "-m", "main moved", cwd=repo)
    _git("checkout", "feat", cwd=repo)

    assert cli.main(["verify", sha, str(repo), "--rerun"]) == 0
    assert "REPRODUCED" in capsys.readouterr().out


def test_verify_freshness_uses_the_attested_base(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _feat_repo(tmp_path)
    sha = _attest_on_main_base(repo, capsys)
    assert cli.main(["verify", sha, str(repo)]) == 0
    assert "tree: matches" in capsys.readouterr().out


def test_old_statement_without_base_sha_notes_the_fallback(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, "true")
    sha = _attest(repo, capsys)
    _resign(repo, sha, lambda s: s["predicate"]["reproduce"].pop("base_sha"))
    code = cli.main(["verify", sha, str(repo), "--rerun", "--json"])
    result = json.loads(capsys.readouterr().out)
    assert code == 0
    assert any("predates base_sha" in n for n in result["notes"])


def test_rerun_refuses_when_gate_settings_changed(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, "true")
    sha = _attest(repo, capsys)
    (repo / ".haro" / "settings.toml").write_text("[gate]\nrunner = 'command'\ncommand = 'false'\n")

    code = cli.main(["verify", sha, str(repo), "--rerun"])
    assert code == 2
    assert "gate settings changed since attesting" in capsys.readouterr().out
