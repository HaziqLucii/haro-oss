"""Multi-session data model — a workspace holds N agent sessions, not one.

The transcript/session state is keyed by ``(workspace_id, session_id)`` (mirrors how
run scripts are keyed by ``(workspace_id, run_id)``), with ``DEFAULT_SESSION`` as the
primary session every single-session caller lands on. These pin: (a) two sessions in
one workspace keep independent transcripts, turns, and rewinds; (b) the default-session
path is unchanged when no ``session_id`` is passed; (c) ``sessions()`` enumerates a
workspace's sessions; (d) dropping a workspace forgets every session; and (e) the DB
row-id round-trips the composite key, with a legacy bare id folding onto the primary
session so old transcripts survive the upgrade.
"""

from haro.db import _events_row_id, _split_events_row_id
from haro.store import DEFAULT_SESSION, Store


def _user(text: str) -> dict:
    return {"run_id": "user", "workspace_id": "w", "ts": 0.0, "type": "user",
            "payload": {"text": text}}


def _agent(ev_type: str, **payload) -> dict:
    return {"run_id": "r", "workspace_id": "w", "ts": 0.0, "type": ev_type,
            "payload": payload}


def test_sessions_have_independent_transcripts_and_turns():
    store = Store()
    store.append_event("w", _user("impl: build it"))          # default session, turn 1
    store.append_event("w", _agent("done"))
    store.append_event("w", _user("review this"), session_id="review")  # other session, turn 1
    store.append_event("w", _agent("token", text="looks ok"), session_id="review")

    # Each session keeps its own list — the default one is untouched by the review one.
    assert [e["payload"].get("text") for e in store.events_for("w") if e["type"] == "user"] == [
        "impl: build it"
    ]
    assert [m["prompt"] for m in store.turns("w")] == ["impl: build it"]
    assert [m["prompt"] for m in store.turns("w", session_id="review")] == ["review this"]
    # Turn ordinals restart per session (each is its own conversation).
    assert store.turns("w")[0]["turn"] == 1
    assert store.turns("w", session_id="review")[0]["turn"] == 1


def test_default_session_path_is_unchanged():
    """A caller that passes no session_id lands on the primary session — identical to
    the old single-session behaviour."""
    store = Store()
    store.append_event("w", _user("hi"))
    assert store.events_for("w") == store.events.get(("w", DEFAULT_SESSION))


def test_sessions_enumerates_first_seen_order():
    store = Store()
    store.append_event("w", _user("a"))                       # default
    store.append_event("w", _user("b"), session_id="review")
    store.append_event("w2", _user("other ws"))               # different workspace
    assert store.sessions("w") == [DEFAULT_SESSION, "review"]
    assert store.sessions("w2") == [DEFAULT_SESSION]
    assert store.sessions("missing") == []


def test_rewind_is_scoped_to_one_session():
    store = Store()
    store.append_event("w", _user("keep me"))                 # default, turn 1
    store.append_event("w", _user("first"), session_id="s2")  # s2, turn 1
    store.append_event("w", _user("second"), session_id="s2") # s2, turn 2

    res = store.rewind("w", 2, session_id="s2")

    assert res["dropped"] == 1                                # only s2's turn 2
    assert [m["turn"] for m in store.turns("w", session_id="s2")] == [1]
    assert len(store.events_for("w")) == 1                    # default session untouched


def test_dropping_a_workspace_forgets_every_session():
    store = Store()
    store.append_event("w", _user("a"))
    store.append_event("w", _user("b"), session_id="review")
    store.append_event("keep", _user("survivor"))

    store.drop_transcript("w")

    assert store.sessions("w") == []
    assert not any(k[0] == "w" for k in store._events_dirty)
    assert store.sessions("keep") == ["main"]                 # other workspaces untouched


def test_events_row_id_round_trips_and_legacy_folds_to_primary():
    # composite key ⇄ row id
    rid = _events_row_id("ws_abc", "review")
    assert _split_events_row_id(rid) == ("ws_abc", "review")
    # a legacy row (bare workspace id, no separator) → the primary session
    assert _split_events_row_id("ws_abc") == ("ws_abc", DEFAULT_SESSION)
