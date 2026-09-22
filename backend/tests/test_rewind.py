"""Rewind action — restoring the session to a turn boundary.

``Store.rewind`` is the *conversation* half of "rewind to here": it truncates the
persisted transcript at/after a target ``turn`` (the ordinal ``append_event`` tags,
see test_turn_markers.py) and reports the prompt that opened it, so the composer can
re-prompt from there. The *worktree* half (an optional checkpoint commit) lives in the
route and isn't exercised here. These pin: (a) events at/after the turn are dropped and
earlier ones kept, (b) the rewound turn's prompt comes back for the composer, (c) events
predating markers (no ``turn``) are never dropped, and (d) the resumed session continues
*from* N — a re-prompt after rewinding re-opens turn N.
"""

from haro.store import DEFAULT_SESSION, Store


def _user(text: str, run_id: str = "user") -> dict:
    return {"run_id": run_id, "workspace_id": "w", "ts": 0.0, "type": "user",
            "payload": {"text": text}}


def _agent(ev_type: str, **payload) -> dict:
    return {"run_id": "r", "workspace_id": "w", "ts": 0.0, "type": ev_type,
            "payload": payload}


def test_rewind_drops_events_at_and_after_turn():
    store = Store()
    store.append_event("w", _user("first"))             # turn 1
    store.append_event("w", _agent("tool_call", tool="Read"))  # turn 1
    store.append_event("w", _user("second"))            # turn 2
    store.append_event("w", _agent("done"))             # turn 2
    store.append_event("w", _user("third"))             # turn 3

    res = store.rewind("w", 2)

    assert res["turn"] == 2
    assert res["prompt"] == "second"       # the rewound turn's prompt, for the composer
    assert res["dropped"] == 3             # turn-2 user + turn-2 done + turn-3 user
    assert [e["turn"] for e in store.events_for("w")] == [1, 1]  # only turn 1 survives


def test_rewind_keeps_events_predating_markers():
    """A legacy event with no ``turn`` (persisted before the feature existed) can't be a
    rewind target and is never dropped — only ``turn``-tagged events at/after N go."""
    store = Store()
    store.events[("w", DEFAULT_SESSION)] = [_agent("token", text="old")]  # no turn tag
    store.append_event("w", _user("go"))               # gets turn 1

    res = store.rewind("w", 1)

    assert res["dropped"] == 1
    assert len(store.events_for("w")) == 1
    assert store.events_for("w")[0]["payload"]["text"] == "old"


def test_rewind_to_missing_turn_drops_nothing():
    store = Store()
    store.append_event("w", _user("only"))  # turn 1
    res = store.rewind("w", 5)              # nothing at/after turn 5
    assert res["dropped"] == 0
    assert res["prompt"] == ""
    assert len(store.events_for("w")) == 1


def test_reprompt_after_rewind_continues_from_turn_n():
    """The resumed session continues from N: after rewinding to turn N the transcript
    tail's max turn is N-1, so the next user prompt re-opens turn N."""
    store = Store()
    store.append_event("w", _user("one"))    # 1
    store.append_event("w", _user("two"))    # 2
    store.append_event("w", _user("three"))  # 3

    store.rewind("w", 2)
    store.append_event("w", _user("two, take two"))  # the re-prompt

    assert store.events_for("w")[-1]["turn"] == 2
    assert [m["turn"] for m in store.turns("w")] == [1, 2]
