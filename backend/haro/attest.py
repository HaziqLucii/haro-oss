"""Portable proof, v1 (usp-critique-round3.md Move A): an in-toto-shaped,
ed25519-signed statement over a Gate Receipt — TAMPER-EVIDENT, not yet
cross-machine verifiable. What v1 actually proves: the saved statement has not
been altered since it was signed on THIS machine (any byte changed anywhere in
the signed payload, including inside the receipt, breaks the signature —
``verify_envelope``). What it does NOT yet prove: that a stranger with no access
to this machine's key can independently check it — there is no key-export or
Sigstore-transparency-log path (deferred per the plan; local ed25519 first), and
``.haro/attestations/`` is gitignored, so a statement never travels anywhere on
its own. "Someone who doesn't trust the machine it ran on" is the eventual target
this is built toward, not what v1 ships.

The statement's subject anchors on ``git merge-base`` between HEAD and ``base_ref``
(stable regardless of which side moves next) plus a diff fingerprint
(``receipt.diff_fingerprint``) — not ``Receipt.gate_sha``, which is only ever set on
a green run with Verified Hunks on (see ``receipt.build_receipt``). A red or degraded
gate still deserves a checkable attestation of WHAT it measured, so the subject never
depends on the verdict.

Signed as a DSSE envelope (https://github.com/secure-systems-lab/dsse) over the
statement's Pre-Authentication Encoding — the same envelope shape in-toto/Sigstore
use, so a later Sigstore upgrade (deferred per the plan; local ed25519 first) can read
what this already writes without a format migration. The key is a local ed25519
keypair generated on first use, mirroring ``db.py``'s ``$HARO_DB`` convention:
``$HARO_HOME`` (default ``~/.haro``) holds ``attest_ed25519``/``attest_ed25519.pub``.
One identity signs every attestation this machine produces, the same way one
``~/.gitconfig`` identity signs every commit — this is NOT a per-project key.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

from . import git_ops
from .models import Receipt

STATEMENT_TYPE = "https://in-toto.io/Statement/v1"
PREDICATE_TYPE = "https://haro.dev/attestation/gate/v1"
PAYLOAD_TYPE = "application/vnd.in-toto+json"


def _haro_home() -> Path:
    return Path(os.environ.get("HARO_HOME") or "~/.haro").expanduser()


def _key_paths() -> tuple[Path, Path]:
    home = _haro_home()
    return home / "attest_ed25519", home / "attest_ed25519.pub"


def ensure_key() -> Ed25519PrivateKey:
    """The local signing key, generated on first use and reused after. ``0o600`` on
    the private key — same "single local user, trust the filesystem" model the rest
    of haro already assumes (see ``gate.ensure_deps``'s docstring)."""
    priv_path, pub_path = _key_paths()
    if priv_path.exists():
        return serialization.load_pem_private_key(priv_path.read_bytes(), password=None)
    priv_path.parent.mkdir(parents=True, exist_ok=True)
    key = Ed25519PrivateKey.generate()
    priv_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    pub_pem = key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    priv_path.write_bytes(priv_pem)
    priv_path.chmod(0o600)
    pub_path.write_bytes(pub_pem)
    return key


def key_id(pub_key: Ed25519PublicKey) -> str:
    """A short, stable identifier for a public key — the DSSE envelope's ``keyid``
    and the ``Verified-by:`` trailer's fingerprint. Not a secret; safe to publish."""
    raw = pub_key.public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
    )
    return "ed25519:" + hashlib.sha256(raw).hexdigest()[:16]


async def build_subject(*, repo_path: str, branch: str, base_ref: str, digest: str) -> dict:
    """The statement's one subject: the merge-base both sides share.

    ``digest`` must be a ``receipt.diff_fingerprint`` the CALLER already computed
    (ideally the gate-time one frozen on ``Receipt.digest`` — see its docstring),
    never a fresh diff read here: this function doesn't know when the gate actually
    ran, so it cannot tell a live tree from a drifted one. ``save_envelope`` keys
    the saved file by merge-base sha ALONE, so attesting the same merge-base twice
    (e.g. iterating before the branch rebases) overwrites the previous statement —
    latest-wins, the same idiom ``git_ops.add_note``'s ``-f`` already uses ("a
    retried merge can't leave two receipts fighting"). It is not a namespacing
    guarantee across different diffs sharing a merge-base."""
    try:
        base_sha = await git_ops.merge_base(repo_path, "HEAD", base_ref)
    except git_ops.GitError:
        base_sha = await git_ops.head_sha(repo_path)  # unborn/diverged base: fall back to HEAD
    return {
        "name": f"{branch}@{base_sha[:12]}",
        "digest": {"sha256": digest},
    }


def build_statement(receipt: Receipt, subject: dict) -> dict:
    """The in-toto Statement: WHAT was measured (``subject``) and the full Gate
    Receipt as the predicate — every field the markdown receipt renders, so a
    verifier who only has the statement loses nothing the human-readable form had."""
    return {
        "_type": STATEMENT_TYPE,
        "subject": [subject],
        "predicateType": PREDICATE_TYPE,
        "predicate": receipt.model_dump(mode="json"),
    }


def _pae(payload_type: str, payload: bytes) -> bytes:
    """DSSE's Pre-Authentication Encoding — what actually gets signed, not the raw
    payload, so a signature can't be replayed against a differently-typed payload
    (see the DSSE spec's rationale for binding the type into the signed bytes)."""
    type_b = payload_type.encode()
    return (
        b"DSSEv1 " + str(len(type_b)).encode() + b" " + type_b
        + b" " + str(len(payload)).encode() + b" " + payload
    )


def sign_statement(statement: dict, key: Ed25519PrivateKey) -> dict:
    """Wrap ``statement`` in a signed DSSE envelope. Canonical JSON (sorted keys, no
    incidental whitespace) so the same statement always signs to the same bytes —
    a verifier re-encoding the payload for display must not accidentally change
    what the signature covers."""
    payload = json.dumps(statement, sort_keys=True, separators=(",", ":")).encode()
    sig = key.sign(_pae(PAYLOAD_TYPE, payload))
    return {
        "payloadType": PAYLOAD_TYPE,
        "payload": base64.b64encode(payload).decode(),
        "signatures": [
            {"keyid": key_id(key.public_key()), "sig": base64.b64encode(sig).decode()}
        ],
    }


def verify_envelope(envelope: dict, pub_key: Ed25519PublicKey) -> dict | None:
    """The decoded statement if the signature checks out against ``pub_key``, else
    ``None`` — never raises, so a malformed or tampered envelope just reads as "does
    not verify" rather than crashing the caller. This is the whole check: ANY byte
    changed in the signed fields (the payload — including everything inside the
    receipt predicate — and ``payloadType``) breaks the signature.

    ``envelope["payloadType"]`` is required, not defaulted: refuter round-3 found
    that ``.get(..., PAYLOAD_TYPE)`` let a STRIPPED ``payloadType`` field silently
    reconstruct the exact value it was signed with, so removing it changed nothing
    — the field wasn't actually protecting anything. Requiring it present (a
    missing key now fails to verify, via the ``KeyError`` below) makes the field
    load-bearing instead of decorative.

    Only ``payload``/``payloadType``/``signatures[0].sig`` feed the crypto check.
    Every OTHER field — ``signatures[0].keyid`` in particular — is unauthenticated:
    it rides along in the envelope but nothing here confirms it names the key that
    actually signed. Callers must report the key THEY verified against (``pub_key``),
    never echo a field out of the envelope as if it were proven (see ``cli.py``'s
    ``_run_verify_cli``, which used to make exactly that mistake)."""
    try:
        payload = base64.b64decode(envelope["payload"])
        sig = base64.b64decode(envelope["signatures"][0]["sig"])
        pub_key.verify(sig, _pae(envelope["payloadType"], payload))
        return json.loads(payload)
    except (KeyError, IndexError, ValueError, TypeError, InvalidSignature):
        return None


def _attestations_dir(repo_path: str) -> Path:
    return Path(repo_path) / ".haro" / "attestations"


def save_envelope(repo_path: str, envelope: dict, subject: dict) -> Path:
    """Persist the envelope keyed by its subject's merge-base sha, so ``haro
    verify <sha>`` can find it later without re-signing anything."""
    sha = subject["name"].rsplit("@", 1)[-1]
    out_dir = _attestations_dir(repo_path)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{sha}.json"
    path.write_text(json.dumps(envelope, indent=2) + "\n")
    return path


def load_envelope(repo_path: str, sha: str) -> dict | None:
    """The saved envelope for ``sha`` (a 12-char merge-base prefix), or ``None`` if
    nothing was ever attested for it."""
    path = _attestations_dir(repo_path) / f"{sha[:12]}.json"
    if not path.exists():
        return None
    return json.loads(path.read_text())
