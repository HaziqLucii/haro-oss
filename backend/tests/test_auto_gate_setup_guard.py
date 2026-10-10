"""``gate.auto_gate_allowed`` — the Merge Firewall cry-wolf guard (backlog/merge-firewall.md §2).

An adopted (foreign) worktree is provisioned only at adopt time; auto-gating it before
that setup reports ``ok`` gates red for *environment* reasons (missing deps/toolchain),
so the firewall would cry wolf on work it just took over. This holds the auto-gate until
``setup_state`` is ``ok``. Managed workspaces (haro provisioned them on create) always
pass, and a *manual* gate is honored regardless (enforced by ``run_gate``'s trigger check,
not this pure helper).
"""

from __future__ import annotations

from haro.gate import auto_gate_allowed
from haro.models import Workspace


def _ws(kind: str) -> Workspace:
    return Workspace(
        project_id="proj_1", name="w", branch="b",
        worktree_path="/tmp/w", base_ref="main", kind=kind,
    )


def test_managed_always_auto_gates_regardless_of_setup():
    ws = _ws("managed")
    assert auto_gate_allowed(ws, None) is True
    assert auto_gate_allowed(ws, {"status": "failed"}) is True
    assert auto_gate_allowed(ws, {"status": "running"}) is True


def test_adopted_held_until_setup_ok():
    ws = _ws("adopted")
    assert auto_gate_allowed(ws, None) is False
    assert auto_gate_allowed(ws, {"status": "unknown"}) is False
    assert auto_gate_allowed(ws, {"status": "running"}) is False
    assert auto_gate_allowed(ws, {"status": "failed"}) is False


def test_adopted_auto_gates_once_setup_ok():
    assert auto_gate_allowed(_ws("adopted"), {"status": "ok"}) is True
