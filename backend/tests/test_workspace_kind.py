"""``Workspace.kind`` — the Merge Firewall provenance marker (backlog/merge-firewall.md §1).

``managed`` = haro created the worktree; ``adopted`` = a foreign worktree registered
in place via the adopt path. db.py persists the store by ``model_dump_json`` on
snapshot and ``Workspace.model_validate_json`` on hydrate, so these model-level
round-trips exercise the exact persistence path (no Postgres needed in the gate env).
The load-bearing case is backward-compat: a row snapshotted before this field existed
must hydrate to ``managed``, not raise — else db.py's ``except ValueError: pass`` would
silently drop every pre-firewall workspace on boot.
"""

from __future__ import annotations

from haro.models import Workspace


def _ws(**kw) -> Workspace:
    return Workspace(
        project_id="proj_1", name="w", branch="b",
        worktree_path="/tmp/w", base_ref="main", **kw,
    )


def test_kind_defaults_to_managed():
    assert _ws().kind == "managed"


def test_kind_survives_snapshot_hydrate_round_trip():
    for kind in ("managed", "adopted"):
        raw = _ws(kind=kind).model_dump_json()
        assert Workspace.model_validate_json(raw).kind == kind


def test_legacy_row_without_kind_hydrates_managed():
    # A snapshot written before the field existed has no `kind` key.
    legacy = _ws().model_dump()
    legacy.pop("kind")
    assert Workspace.model_validate(legacy).kind == "managed"
