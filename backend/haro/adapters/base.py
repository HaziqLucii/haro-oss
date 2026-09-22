"""The ``AgentAdapter`` seam.

An adapter's one job: run some coding agent as a subprocess in a worktree and
translate its native output into a *normalized* event stream the rest of
haro understands. The five event types (token / tool_call / file_edit /
done / error) are the contract; nothing downstream ever sees a vendor's raw
protocol. Add a new agent later = add a new adapter, change nothing else.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, AsyncIterator

from ..models import AgentEventType


@dataclass
class NormalizedEvent:
    """What an adapter yields. Deliberately lighter than the wire-level
    ``AgentEvent`` model — the runner stamps on run_id/workspace_id/ts."""

    type: AgentEventType
    payload: dict[str, Any] = field(default_factory=dict)


class AgentAdapter(ABC):
    """Base class for all agent backends."""

    #: Stable identifier stored on AgentRun.adapter (e.g. "claude-code").
    name: str = "abstract"

    @abstractmethod
    def run(
        self,
        *,
        task: str,
        cwd: str,
        model: str | None = None,
        effort: str | None = None,
        resume: str | None = None,
        instructions: str | None = None,
        plan: bool = False,
    ) -> AsyncIterator[NormalizedEvent]:
        """Spawn the agent in ``cwd`` and yield NormalizedEvents until it ends.

        If ``plan`` is set, the run is a **plan-only** turn — the agent proposes a
        plan and touches no files (the review surface before any edit). Adapters
        that can't offer a plan mode should ignore the flag (run normally).

        If ``instructions`` is given, it's prepended to the agent's system prompt
        (the project's haro custom instructions — a standing workflow the
        agent should follow every run). Adapters that can't inject a system prompt
        may fold it into the task instead.

        If ``resume`` (a prior session id) is given, continue that conversation
        so the agent keeps its context (and can auto-compact) instead of starting
        fresh. Both the bootstrap (``system``) event and the terminal
        ``done``/``error`` event carry the current ``session_id`` in their payload,
        so the caller can persist it for the next turn as soon as it's known —
        a user stop cancels the stream before any terminal event, and the run must
        still be resumable afterwards.

        Implementations are async generators. They must always terminate with
        exactly one ``done`` **or** ``error`` event so the runner can finalize
        the AgentRun regardless of how the subprocess exited.
        """
        raise NotImplementedError
