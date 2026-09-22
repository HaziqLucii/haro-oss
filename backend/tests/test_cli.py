"""`haro gate` — the headless CLI (usp-critique-plan.md idea 2). Uses the
`command` runner (`true`/`false`) so these tests need no real vitest/node
install, just a real git repo."""

from __future__ import annotations

import subprocess
from pathlib import Path

from haro import cli


def _run(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path: Path, *, command: str = "true", extra_settings: str = "") -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("init", "-b", "main", cwd=repo)
    _run("config", "user.email", "t@t", cwd=repo)
    _run("config", "user.name", "t", cwd=repo)
    haro_dir = repo / ".haro"
    haro_dir.mkdir()
    (haro_dir / "settings.toml").write_text(
        f"[gate]\nrunner = 'command'\ncommand = '{command}'\n{extra_settings}"
    )
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "init", cwd=repo)
    return repo


def test_gate_green_exits_0_and_prints_the_receipt(tmp_path, capsys):
    repo = _repo(tmp_path, command="true")
    code = cli.main(["gate", str(repo)])
    out = capsys.readouterr().out
    assert code == 0
    assert "# haro gate receipt — GREEN" in out
    assert "`main` → `main`" in out


def test_gate_red_exits_2(tmp_path, capsys):
    repo = _repo(tmp_path, command="false")
    code = cli.main(["gate", str(repo)])
    out = capsys.readouterr().out
    assert code == 2
    assert "# haro gate receipt — RED" in out


def test_not_a_git_repo_exits_1(tmp_path, capsys):
    plain = tmp_path / "not-a-repo"
    plain.mkdir()
    code = cli.main(["gate", str(plain)])
    err = capsys.readouterr().err
    assert code == 1
    assert "not inside a git repository" in err


def test_default_path_is_cwd(tmp_path, capsys, monkeypatch):
    repo = _repo(tmp_path, command="true")
    monkeypatch.chdir(repo)
    code = cli.main(["gate"])
    assert code == 0


def test_base_flag_overrides_detected_default_branch(tmp_path, capsys):
    repo = _repo(tmp_path, command="true")
    _run("checkout", "-b", "feat", cwd=repo)
    (repo / "f.txt").write_text("x\n")
    _run("add", "-A", cwd=repo)
    _run("commit", "-m", "work", cwd=repo)

    code = cli.main(["gate", str(repo), "--base", "main"])
    out = capsys.readouterr().out
    assert code == 0
    assert "`feat` → `main`" in out


def test_command_runner_error_kind_still_exits_nonzero(tmp_path, capsys):
    # An unlaunchable command (nonexistent binary) is a setup problem, not a red
    # test — the receipt records it as `error`, which is not "green" either.
    repo = _repo(tmp_path, command="this-binary-does-not-exist-anywhere")
    code = cli.main(["gate", str(repo)])
    assert code == 2


def test_usage_error_exits_1_not_2(capsys):
    # The round-10 regression: argparse's own default exit code for a malformed
    # invocation is 2, colliding with this CLI's own "the gate measured this and
    # it's not green" meaning. A Stop hook that treats exit 2 as "keep retrying"
    # would loop forever on a typo, which will never resolve by trying again.
    code = cli.main(["gate", "--this-flag-does-not-exist"])
    err = capsys.readouterr().err
    assert code == 1
    assert "error" in err.lower()


def test_unknown_subcommand_exits_1(capsys):
    code = cli.main(["not-a-real-subcommand"])
    assert code == 1


# --------------------------------------------------------------------------- #
# --json / --attest / verify (usp-critique-round3.md Move A)
# --------------------------------------------------------------------------- #
def test_gate_json_prints_receipt_json_not_markdown(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, command="true")
    code = cli.main(["gate", str(repo), "--json"])
    out = capsys.readouterr().out
    assert code == 0
    assert "# haro gate receipt" not in out
    import json
    payload = json.loads(out)
    assert payload["verdict"] == "green"
    assert payload["branch"] == "main"


def test_gate_attest_saves_and_prints_a_signed_envelope(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, command="true")
    code = cli.main(["gate", str(repo), "--attest"])
    result = capsys.readouterr()
    assert code == 0
    assert "attestation saved:" in result.err
    import json
    envelope = json.loads(result.out)
    assert envelope["payloadType"] == "application/vnd.in-toto+json"
    assert envelope["signatures"][0]["keyid"].startswith("ed25519:")
    saved = list((repo / ".haro" / "attestations").glob("*.json"))
    assert len(saved) == 1


def test_verify_succeeds_right_after_attest(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, command="true")
    cli.main(["gate", str(repo), "--attest"])
    capsys.readouterr()
    sha = next((repo / ".haro" / "attestations").glob("*.json")).stem

    code = cli.main(["verify", sha, str(repo)])
    out = capsys.readouterr().out
    assert code == 0
    assert "signature OK" in out
    assert "tree: matches" in out
    assert "GREEN" in out


def test_verify_fails_when_the_saved_file_is_tampered_with(tmp_path, capsys, monkeypatch):
    # The plan's own verification bar: "haro gate verify fails after a one-line
    # edit to the receipt file" — ANY byte changed in the signed payload breaks it.
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, command="true")
    cli.main(["gate", str(repo), "--attest"])
    capsys.readouterr()
    path = next((repo / ".haro" / "attestations").glob("*.json"))
    sha = path.stem

    import base64
    import json

    envelope = json.loads(path.read_text())
    payload = json.loads(base64.b64decode(envelope["payload"]))
    payload["predicate"]["verdict"] = "red"  # flip green -> red post-hoc
    envelope["payload"] = base64.b64encode(json.dumps(payload).encode()).decode()
    path.write_text(json.dumps(envelope))

    code = cli.main(["verify", sha, str(repo)])
    err = capsys.readouterr().err
    assert code == 2
    assert "VERIFY FAILED" in err


def test_verify_with_no_attestation_exits_1(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, command="true")
    code = cli.main(["verify", "deadbeef0000", str(repo)])
    err = capsys.readouterr().err
    assert code == 1
    assert "no saved attestation" in err


def test_attest_and_json_together_prefers_attest_output(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, command="true")
    code = cli.main(["gate", str(repo), "--json", "--attest"])
    out = capsys.readouterr().out
    assert code == 0
    import json
    envelope = json.loads(out)
    assert "signatures" in envelope  # the DSSE envelope, not the bare receipt


def test_verify_reports_the_verified_key_not_the_envelopes_own_claim(tmp_path, capsys, monkeypatch):
    # refuter round-3: `signatures[0].keyid` is unauthenticated, so the CLI used to
    # print whatever it said even if rewritten to a lie. It must report the key it
    # actually verified against instead.
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    repo = _repo(tmp_path, command="true")
    cli.main(["gate", str(repo), "--attest"])
    capsys.readouterr()
    path = next((repo / ".haro" / "attestations").glob("*.json"))
    sha = path.stem

    import json

    envelope = json.loads(path.read_text())
    real_keyid = envelope["signatures"][0]["keyid"]
    envelope["signatures"][0]["keyid"] = "ed25519:0000000000000000"
    path.write_text(json.dumps(envelope))

    code = cli.main(["verify", sha, str(repo)])
    out = capsys.readouterr().out
    assert code == 0
    assert real_keyid in out
    assert "0000000000000000" not in out
