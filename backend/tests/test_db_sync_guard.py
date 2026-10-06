"""Task 1 — `_sync` safety guard.

Proves the full-table wipe in `db._sync` only fires for tables a loader actually
ran for this session. A forgotten/broken loader leaves the table out of
`_hydrated`, so an (incorrectly) empty store can never `DELETE` the real rows —
the catastrophic chat-wipe failure mode.
"""

from haro import db


def _reset():
    db._hydrated.clear()


def test_unhydrated_table_is_not_wiped():
    _reset()
    # No loader ran → empty collection is suspect, not authoritative.
    assert db._should_wipe("agent_events") is False


def test_hydrated_table_is_wiped():
    _reset()
    # Loader ran (even a 0-row fetch) → an empty collection is genuine.
    db._hydrated.add("agent_events")
    assert db._should_wipe("agent_events") is True


def test_hydration_is_per_table():
    _reset()
    db._hydrated.add("workspaces")
    assert db._should_wipe("workspaces") is True
    assert db._should_wipe("agent_events") is False
