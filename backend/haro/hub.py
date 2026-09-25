"""Per-workspace pub/sub hub for realtime events.

The WebSocket to each workspace is a *multiplexed* stream: agent events, test
results, and status changes all flow down it, each wrapped in a small envelope
with a ``channel`` discriminator so the UI can route them:

    {"channel": "agent",  "event": {...AgentEvent...}}
    {"channel": "test",   "test":  {...TestRun...}}
    {"channel": "status", "status": "gate_green", "workspace_id": "..."}

The hub is channel-agnostic — it moves already-serialized dict envelopes and
keeps a bounded backlog per workspace so a client connecting mid-run (or
reconnecting) is replayed recent history instead of a blank screen. Single
process, so plain asyncio structures suffice.

**Every buffer here is bounded**, including each subscriber's own queue. A
subscriber queue used to be unbounded, so a consumer that stopped draining (a
wedged WebSocket, a paused browser tab, a slow global-feed reader) grew without
limit while a chatty agent streamed tokens into it — memory with no back-pressure
and no ceiling. A full queue now drops its OLDEST envelope: recent output is what
a live view needs, and the durable transcript (``store.events``) is the record.
"""

from __future__ import annotations

import asyncio
import logging
from collections import defaultdict, deque
from typing import Any, Deque

log = logging.getLogger(__name__)

Envelope = dict[str, Any]

_BACKLOG = 1000  # envelopes retained per workspace for replay to new subscribers

#: Per-subscriber queue ceiling. Generous — a fast agent can burst hundreds of token
#: envelopes — but finite, so a stuck consumer sheds old output instead of growing
#: without bound. Roughly the same order as ``_BACKLOG`` on purpose: a subscriber
#: further behind than the replay buffer has already lost continuity anyway.
_QUEUE_MAX = 2000


# Channels a *global* dashboard subscriber cares about (status + gate results +
# coarse per-run notifications), so we don't flood it with every agent token/cell
# from every workspace. ``notify`` carries one small event when an agent finishes,
# powering the cross-workspace "agent done" beep.
_GLOBAL_CHANNELS = {"status", "test", "notify"}


class Hub:
    def __init__(self) -> None:
        self._subscribers: dict[str, set[asyncio.Queue[Envelope]]] = defaultdict(set)
        self._backlog: dict[str, Deque[Envelope]] = defaultdict(lambda: deque(maxlen=_BACKLOG))
        # Global subscribers see coarse per-workspace status/gate events for every
        # workspace at once — the multi-agent dashboard's live feed.
        self._global: set[asyncio.Queue[Envelope]] = set()
        # How many envelopes each queue has shed (see _offer). Keyed by queue identity
        # and cleared on unsubscribe, so it can't outlive its socket.
        self._dropped: dict[int, int] = {}

    def history(self, workspace_id: str) -> list[Envelope]:
        return list(self._backlog[workspace_id])

    def _offer(self, q: asyncio.Queue[Envelope], envelope: Envelope) -> None:
        """Hand an envelope to one subscriber, never blocking the publisher.

        A publisher is an agent/gate/lifecycle task doing real work; making it *wait*
        on a slow WebSocket would let one stalled reader stall the run itself. So the
        queue is bounded and a full one drops its oldest entry instead — losing the
        stalest line of a live view, which is the cheapest thing here to lose. The
        first drop per subscriber is logged so it isn't a silent hole."""
        if q.maxsize and q.qsize() >= q.maxsize:
            try:
                q.get_nowait()
            except asyncio.QueueEmpty:  # drained between the check and here — fine
                pass
            n = self._dropped.get(id(q), 0) + 1
            self._dropped[id(q)] = n
            if n == 1:
                log.warning(
                    "hub subscriber queue full (%d): dropping oldest envelopes — "
                    "a consumer has stopped draining", q.maxsize,
                )
        try:
            q.put_nowait(envelope)
        except asyncio.QueueFull:  # racing producers; the next envelope will fit
            pass

    async def publish(self, workspace_id: str, envelope: Envelope) -> None:
        self._backlog[workspace_id].append(envelope)
        for q in list(self._subscribers[workspace_id]):
            self._offer(q, envelope)
        # Fan coarse events out to the global dashboard feed (tag with workspace_id).
        if envelope.get("channel") in _GLOBAL_CHANNELS:
            tagged = {**envelope, "workspace_id": workspace_id}
            for q in list(self._global):
                self._offer(q, tagged)

    def subscribe(self, workspace_id: str) -> asyncio.Queue[Envelope]:
        q: asyncio.Queue[Envelope] = asyncio.Queue(maxsize=_QUEUE_MAX)
        self._subscribers[workspace_id].add(q)
        return q

    def unsubscribe(self, workspace_id: str, q: asyncio.Queue[Envelope]) -> None:
        self._subscribers[workspace_id].discard(q)
        self._dropped.pop(id(q), None)

    async def broadcast_global(self, envelope: Envelope) -> None:
        """Push an app-level event (not tied to any one workspace) to global
        subscribers only — e.g. a project-scoped ``backlog_changed`` signal. Unlike
        ``publish`` it touches no per-workspace backlog, so it needs no workspace id."""
        for q in list(self._global):
            self._offer(q, envelope)

    def subscribe_global(self) -> asyncio.Queue[Envelope]:
        q: asyncio.Queue[Envelope] = asyncio.Queue(maxsize=_QUEUE_MAX)
        self._global.add(q)
        return q

    def unsubscribe_global(self, q: asyncio.Queue[Envelope]) -> None:
        self._global.discard(q)
        self._dropped.pop(id(q), None)
