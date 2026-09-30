"""``attest.py`` — the DSSE-signed in-toto statement over a Gate Receipt
(usp-critique-round3.md Move A). Unit-level: key management, sign/verify
round-trip, and what breaks a signature. CLI-level wiring (`--attest`, `verify`,
staleness) is covered in test_cli.py."""

from __future__ import annotations

from haro import attest
from haro.models import Receipt, ReceiptAgent, ReceiptMutation, ReceiptQuality, ReceiptSuite, ReceiptTamper, ReceiptVerifiedHunks


def _receipt(verdict: str = "green") -> Receipt:
    return Receipt(
        workspace_id="w1", branch="feat", base_ref="main", verdict=verdict,
        gate_sha="abc123",
        suite=ReceiptSuite(runner="vitest", scope="all", total=10, passed=10, failed=0, skipped=0),
        tamper=ReceiptTamper(measured=True, clean=True, findings_count=0),
        quality=ReceiptQuality(measured=False, blocked=False, findings_count=0, blocking_count=0),
        verified_hunks=ReceiptVerifiedHunks(),
        mutation=ReceiptMutation(ran=False),
        agent=ReceiptAgent(),
    )


def test_ensure_key_generates_once_and_reuses(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    k1 = attest.ensure_key()
    k2 = attest.ensure_key()
    assert attest.key_id(k1.public_key()) == attest.key_id(k2.public_key())
    priv_path, pub_path = attest._key_paths()
    assert priv_path.exists() and pub_path.exists()
    # 0o600 on the private key — not world/group readable
    assert oct(priv_path.stat().st_mode)[-3:] == "600"


def test_sign_and_verify_round_trips(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    key = attest.ensure_key()
    subject = {"name": "feat@abc123", "digest": {"sha256": "deadbeef"}}
    statement = attest.build_statement(_receipt(), subject)
    envelope = attest.sign_statement(statement, key)

    decoded = attest.verify_envelope(envelope, key.public_key())
    assert decoded == statement
    assert decoded["predicate"]["verdict"] == "green"


def test_verify_rejects_a_tampered_payload(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    key = attest.ensure_key()
    subject = {"name": "feat@abc123", "digest": {"sha256": "deadbeef"}}
    envelope = attest.sign_statement(attest.build_statement(_receipt(), subject), key)

    import base64
    import json

    payload = json.loads(base64.b64decode(envelope["payload"]))
    payload["predicate"]["verdict"] = "red"
    envelope["payload"] = base64.b64encode(json.dumps(payload).encode()).decode()

    assert attest.verify_envelope(envelope, key.public_key()) is None


def test_verify_rejects_a_different_signer(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    key = attest.ensure_key()
    subject = {"name": "feat@abc123", "digest": {"sha256": "deadbeef"}}
    envelope = attest.sign_statement(attest.build_statement(_receipt(), subject), key)

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    other = Ed25519PrivateKey.generate()
    assert attest.verify_envelope(envelope, other.public_key()) is None


def test_verify_envelope_never_raises_on_garbage():
    assert attest.verify_envelope({}, None) is None
    assert attest.verify_envelope({"payload": "not-base64!!", "signatures": []}, None) is None


def test_save_and_load_envelope_round_trips(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    key = attest.ensure_key()
    subject = {"name": "feat@abc123def456", "digest": {"sha256": "deadbeef"}}
    envelope = attest.sign_statement(attest.build_statement(_receipt(), subject), key)

    repo = str(tmp_path / "repo")
    path = attest.save_envelope(repo, envelope, subject)
    assert path.name == "abc123def456.json"

    loaded = attest.load_envelope(repo, "abc123def456")
    assert loaded == envelope
    assert attest.load_envelope(repo, "0" * 12) is None


def test_pae_binds_type_and_length_not_just_content():
    # Two payloads that concatenate to the same bytes under a naive scheme must
    # still produce different PAE encodings — this is the whole point of DSSE's
    # length-prefixed encoding over "type + payload".
    a = attest._pae("ab", b"c")
    b = attest._pae("a", b"bc")
    assert a != b


def test_verify_rejects_a_stripped_payload_type(tmp_path, monkeypatch):
    # refuter round-3: `.get("payloadType", PAYLOAD_TYPE)` let a STRIPPED field
    # silently fall back to the exact default it was signed with, so removing it
    # changed nothing verify_envelope checked — the field wasn't load-bearing.
    # Now required outright: missing it must fail to verify, not silently pass.
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    key = attest.ensure_key()
    subject = {"name": "feat@abc123", "digest": {"sha256": "deadbeef"}}
    envelope = attest.sign_statement(attest.build_statement(_receipt(), subject), key)
    del envelope["payloadType"]
    assert attest.verify_envelope(envelope, key.public_key()) is None


def test_verify_ignores_a_rewritten_keyid_the_caller_must_not_trust_it(tmp_path, monkeypatch):
    # `keyid` is NOT part of the signed PAE, so rewriting it to a lie still
    # verifies — this is expected (see verify_envelope's docstring): the caller's
    # job is to report the key it verified against, never echo this field as fact.
    monkeypatch.setenv("HARO_HOME", str(tmp_path / "home"))
    key = attest.ensure_key()
    subject = {"name": "feat@abc123", "digest": {"sha256": "deadbeef"}}
    envelope = attest.sign_statement(attest.build_statement(_receipt(), subject), key)
    envelope["signatures"][0]["keyid"] = "ed25519:not-actually-this-key"
    assert attest.verify_envelope(envelope, key.public_key()) is not None


def test_build_subject_uses_the_given_digest_verbatim(tmp_path):
    import asyncio
    import subprocess

    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "t@t"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "t"], cwd=repo, check=True, capture_output=True)
    (repo / "f.txt").write_text("x\n")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=repo, check=True, capture_output=True)

    subject = asyncio.run(attest.build_subject(
        repo_path=str(repo), branch="main", base_ref="main", digest="given-digest-not-recomputed",
    ))
    assert subject["digest"]["sha256"] == "given-digest-not-recomputed"
