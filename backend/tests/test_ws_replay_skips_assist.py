"""The workspace socket replays hub history to a new client, but never the ``agent`` or
``assist`` channels: an assist ``done`` carries the plan as first written, so replaying it
on connect overwrote every tick made since (a saved 6/8 plan showed 0/8)."""

from __future__ import annotations

import asyncio

from haro import main
from haro.hub import Hub


class _FakeSocket:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    async def accept(self) -> None:
        pass

    async def send_json(self, envelope: dict) -> None:
        self.sent.append(envelope)


def test_reconnect_replays_status_but_not_assist_or_agent(monkeypatch):
    hub = Hub()
    monkeypatch.setattr(main, "hub", hub)
    socket = _FakeSocket()

    async def go() -> None:
        await hub.publish("ws1", {"channel": "status", "status": "idle"})
        await hub.publish("ws1", {"channel": "assist", "job": "plan", "kind": "token", "text": "x"})
        await hub.publish(
            "ws1",
            {
                "channel": "assist",
                "job": "plan",
                "kind": "done",
                "plan": {"id": "p", "steps": [{"text": "a", "done": False}]},
            },
        )
        await hub.publish("ws1", {"channel": "agent", "event": {}})
        task = asyncio.create_task(main.workspace_ws(socket, "ws1"))
        await asyncio.sleep(0.05)
        task.cancel()
        await task

    asyncio.run(go())
    assert [e["channel"] for e in socket.sent] == ["status"]
