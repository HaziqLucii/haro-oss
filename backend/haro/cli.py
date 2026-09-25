"""Headless CLI: ``haro gate`` (usp-critique-plan.md idea 2) + ``haro verify``
(usp-critique-round3.md Move A).

Runs the exact same gate + Gate Receipt machinery the UI uses, on the current
directory, from a shell with no server running. Turns platform absorption into
a distribution channel: a project using Claude Code's native worktrees (no
haro UI at all) can still gate on stop by shelling out to this. The UI is one
client of the gate, not its only host — this is the second.

No workspace registration, no store persistence, no network: an ephemeral
in-memory ``Store``/``Hub``/``Project``/``Workspace`` point straight at the
target directory (project path == worktree path, so there is nothing to
symlink or merge — ``gate.ensure_deps`` finds a real, already-installed
``node_modules`` and leaves it alone).

``haro gate`` exit codes: ``0`` green, ``2`` anything else the gate actually
measured and found wanting (red, or degraded — a check the project asked for
that could not run, which is not a green a Stop hook should trust either),
``1`` this CLI itself failed to run at all (bad path, no adapter, an
unhandled exception). ``--json`` prints the Receipt as JSON instead of
markdown; ``--attest`` signs it as a portable statement instead (see
``attest.py``) — exit codes are unchanged either way, since they answer "is
the gate green", not "did printing succeed".

``haro verify <sha>`` checks a saved ``--attest`` statement's signature (NOT
the gate itself — it never re-runs tests): ``0`` the signature is intact,
``2`` it was tampered with or signed by a different key, ``1`` this CLI
couldn't run the check at all (no such attestation, bad path). Spelled
``haro verify``, not the plan's literal ``haro gate verify``, to avoid an
argparse ambiguity: a subcommand can't share a parser with a same-arity
positional (``gate``'s own ``path``) without the two fighting over the first
token — see the module's own test for the case this would have broken.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

from . import git_ops
from . import receipt as receipt_svc
from .adapters.test_runner import (
    CommandAdapter,
    OffenseAdapter,
    PytestAdapter,
    TestRunnerAdapter,
    VitestAdapter,
)
from .config import ProjectSettings, load_project_settings
from .gate import run_gate
from .hub import Hub
from .models import Project, Workspace
from .store import Store


def _test_adapter(settings: ProjectSettings) -> TestRunnerAdapter:
    """Mirror of ``main._test_adapter`` — kept separate so this CLI never has to
    import ``main.py`` (and, with it, FastAPI) just to pick a runner."""
    runner = settings.gate_runner
    if runner == "pytest":
        return PytestAdapter()
    if runner == "command":
        return CommandAdapter(settings.gate_command, login_shell=settings.login_shell)
    if runner == "offense":
        return OffenseAdapter(settings.gate_command, settings.gate_format, login_shell=settings.login_shell)
    return VitestAdapter(sandbox=settings.gate_sandbox)


async def _run_gate_cli(
    path: str, base_ref: str | None, *, as_json: bool = False, attest: bool = False
) -> int:
    repo = str(Path(path).resolve())
    if not await git_ops.is_git_repo(repo):
        print(f"error: {repo} is not inside a git repository", file=sys.stderr)
        return 1

    try:
        branch = await git_ops.current_branch(repo)
        base = base_ref or await git_ops.default_branch(repo)
    except git_ops.GitError as exc:
        print(f"error: {exc.stderr or exc}", file=sys.stderr)
        return 1

    settings = load_project_settings(repo)
    try:
        adapter = _test_adapter(settings)
    except Exception as exc:  # noqa: BLE001 — an unpickable gate command etc.
        print(f"error: could not set up the {settings.gate_runner or 'vitest'} adapter: {exc}", file=sys.stderr)
        return 1

    store, hub = Store(), Hub()
    project = Project(id="cli", name=Path(repo).name, path=repo, default_branch=base)
    store.projects[project.id] = project
    workspace = Workspace(
        project_id=project.id, name="cli", branch=branch, worktree_path=repo, base_ref=base,
    )
    store.workspaces[workspace.id] = workspace

    await run_gate(
        store=store, hub=hub, adapter=adapter, workspace=workspace,
        project_path=repo, settings=settings,
    )

    rcpt = await receipt_svc.build_receipt(store=store, workspace=workspace, settings=settings)

    if attest:
        from . import attest as attest_svc

        try:
            # The gate-time digest (frozen on the receipt) — see Receipt.digest and
            # TestRun.diff_fingerprint's docstrings for why this must not be a fresh
            # re-diff. Falls back to one only if the gate's own fingerprint step
            # somehow didn't run (best-effort there too); no drift risk in this
            # single synchronous CLI invocation either way.
            digest = rcpt.digest
            if digest is None:
                diff_text, _ = await git_ops.diff(repo, base)
                digest = receipt_svc.diff_fingerprint(diff_text)
            subject = await attest_svc.build_subject(
                repo_path=repo, branch=branch, base_ref=base, digest=digest
            )
            statement = attest_svc.build_statement(rcpt, subject)
            key = attest_svc.ensure_key()
            envelope = attest_svc.sign_statement(statement, key)
            out_path = attest_svc.save_envelope(repo, envelope, subject)
        except Exception as exc:  # noqa: BLE001 — the gate's own verdict must stay reportable
            print(f"error: could not build the attestation: {exc}", file=sys.stderr)
            return 1
        print(f"attestation saved: {out_path}", file=sys.stderr)
        print(json.dumps(envelope, indent=2))
    elif as_json:
        print(json.dumps(rcpt.model_dump(mode="json"), indent=2))
    else:
        print(receipt_svc.render_markdown(rcpt))
    return 0 if rcpt.verdict == "green" else 2


async def _run_verify_cli(sha: str, path: str) -> int:
    repo = str(Path(path).resolve())
    if not await git_ops.is_git_repo(repo):
        print(f"error: {repo} is not inside a git repository", file=sys.stderr)
        return 1

    from . import attest as attest_svc

    envelope = attest_svc.load_envelope(repo, sha)
    if envelope is None:
        print(
            f"error: no saved attestation for {sha[:12]} under .haro/attestations/ "
            "(run `haro gate --attest` first)",
            file=sys.stderr,
        )
        return 1

    key = attest_svc.ensure_key()
    statement = attest_svc.verify_envelope(envelope, key.public_key())
    if statement is None:
        print(
            "VERIFY FAILED: signature does not match — the attestation file was "
            "tampered with, or was not signed by this machine's key",
            file=sys.stderr,
        )
        return 2

    # The verified key's OWN id — never the envelope's `signatures[0].keyid`, which
    # is unauthenticated (verify_envelope's docstring: nothing confirms it names the
    # key that actually signed; a rewritten `keyid` still verifies). This machine
    # only ever verifies against its own `ensure_key()`, so that's what's reported.
    print(f"signature OK — signed by {attest_svc.key_id(key.public_key())}")
    subject = (statement.get("subject") or [{}])[0]
    print(f"subject: {subject.get('name', '?')}")

    # Best-effort freshness check on top of the (load-bearing) signature check above:
    # does the CURRENT working tree still match what was attested?
    try:
        base = await git_ops.default_branch(repo)
        diff_text, _ = await git_ops.diff(repo, base)
        from .receipt import diff_fingerprint

        current = diff_fingerprint(diff_text)
        attested = (subject.get("digest") or {}).get("sha256")
        if current == attested:
            print("tree: matches — the working tree is unchanged since this was attested")
        else:
            print("tree: STALE — the working tree has changed since this was attested")
    except Exception:  # noqa: BLE001 — the signature check above is the load-bearing verdict
        pass

    predicate = statement.get("predicate") or {}
    print(f"receipt verdict at attest time: {str(predicate.get('verdict', '?')).upper()}")
    return 0


class _ArgParser(argparse.ArgumentParser):
    """Exits 1 on a malformed invocation, not argparse's default 2 — this CLI's own
    exit code 2 means "the gate measured this and it isn't green", and a caller
    checking `$?` (a Stop hook script, in particular) must be able to tell a typo'd
    flag apart from an actual red gate. A usage error will never resolve by
    "trying again", so it must not read the same as one that might."""

    def error(self, message: str) -> None:  # noqa: D102 — argparse's own signature
        self.print_usage(sys.stderr)
        self.exit(1, f"{self.prog}: error: {message}\n")


def main(argv: list[str] | None = None) -> int:
    """Always returns an int (0/1/2) — never raises ``SystemExit`` itself, even for
    a malformed invocation, so callers embedding this (and this file's own tests)
    get one consistent contract rather than "usually returns, sometimes exits"."""
    parser = _ArgParser(prog="haro", description="haro's merge gate, headless.")
    sub = parser.add_subparsers(dest="command", required=True)

    gate_p = sub.add_parser("gate", help="run the gate on a directory and print the receipt")
    gate_p.add_argument("path", nargs="?", default=".", help="git repo to gate (default: cwd)")
    gate_p.add_argument(
        "--base", default=None,
        help="base ref to diff/test against (default: the repo's own detected default branch)",
    )
    gate_p.add_argument(
        "--json", action="store_true", help="print the receipt as JSON instead of markdown",
    )
    gate_p.add_argument(
        "--attest", action="store_true",
        help=(
            "sign the receipt as a portable, ed25519-signed statement (in-toto "
            "shaped) and save it under .haro/attestations/ — implies machine "
            "output, overrides --json"
        ),
    )

    verify_p = sub.add_parser(
        "verify", help="verify a `haro gate --attest` statement's signature against this repo",
    )
    verify_p.add_argument(
        "sha", help="the attested merge-base sha (or its 12-char prefix), from the statement's subject",
    )
    verify_p.add_argument("path", nargs="?", default=".", help="git repo to verify against (default: cwd)")

    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        # `--help`/`-h` also raises SystemExit(0) — that's a real, intentional exit
        # (nothing left to run), so it's let through as-is rather than normalized.
        return exc.code if isinstance(exc.code, int) else 1

    if args.command == "gate":
        try:
            return asyncio.run(_run_gate_cli(args.path, args.base, as_json=args.json, attest=args.attest))
        except KeyboardInterrupt:
            return 1
    if args.command == "verify":
        try:
            return asyncio.run(_run_verify_cli(args.sha, args.path))
        except KeyboardInterrupt:
            return 1
    return 1  # pragma: no cover — argparse's `required=True` on the subparser already
    # rejects any command that isn't "gate"/"verify" before this line is reachable.


if __name__ == "__main__":
    sys.exit(main())
