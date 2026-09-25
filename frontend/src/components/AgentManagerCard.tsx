import { useMemo } from "react";
import type { AgentEvent } from "../types";

type DelegateStatus = "running" | "done" | "error";

interface Delegation {
  id: string;
  subagent_type: string;
  description?: string;
  status: DelegateStatus;
}

/** One row per sub-agent Claude Code has delegated to this session (its own Task/Agent
 *  tool — see claude_code.py's `_delegate_info`/`_normalize_tool_results`), not just
 *  haro's own injected scout role: the detection is generic, so this card grows for
 *  ANY sub-agent Claude decides to spawn. Reconstructed by scanning the session's full
 *  event history (delegations persist across turns), keyed by tool_use id so a later
 *  "done"/"error" event updates the same row instead of adding a new one. Hidden
 *  entirely when nothing has ever been delegated — most sessions never spawn a
 *  sub-agent, and a permanently-empty card is worse than no card.
 *
 *  `running` (the overall agent's own live state) is only needed for one edge case:
 *  a ⏹ stop mid-delegation can't be closed out backend-side (the adapter can't yield
 *  from inside its own GeneratorExit teardown — see claude_code.py's end-of-stream
 *  sweep, which only covers a crash/exit, not a cancel), so a "running" row is shown
 *  as stalled once the session itself is no longer running. */
export function AgentManagerCard({ events, running }: { events: AgentEvent[]; running: boolean }) {
  const delegations = useMemo(() => {
    const byId = new Map<string, Delegation>();
    for (const ev of events) {
      if (ev.type !== "tool_call") continue;
      const d = ev.payload.delegate;
      if (!d?.id || !d?.subagent_type) continue;
      const prev = byId.get(d.id);
      byId.set(d.id, {
        id: d.id,
        subagent_type: d.subagent_type,
        description: d.description ?? prev?.description,
        status: (d.status as DelegateStatus) ?? prev?.status ?? "running",
      });
    }
    return [...byId.values()];
  }, [events]);

  if (delegations.length === 0) return null;

  return (
    <section className="card agent-mgr-card">
      <div className="card-head">
        <span>
          agents
          <span className="dim">
            {" · "}
            {delegations.length}
          </span>
        </span>
      </div>
      <div className="agent-mgr-rows">
        {delegations.map((d) => {
          const stalled = d.status === "running" && !running;
          const displayStatus = stalled ? "stalled" : d.status;
          return (
            <div key={d.id} className="agent-mgr-row">
              <span
                className={"agent-mgr-dot agent-mgr-dot-" + displayStatus}
                title={stalled ? "the session ended before this delegation reported back" : undefined}
              />
              <span className="agent-mgr-name">{d.subagent_type}</span>
              {d.description && <span className="agent-mgr-desc">{d.description}</span>}
              {/* The dot alone (opacity/animation) turned out too subtle to read at a
                  glance — a screenshot can't show the "running" pulse at all, and even
                  live it's easy to miss. Spell out the state explicitly instead. */}
              <span className={"agent-mgr-status agent-mgr-status-" + displayStatus}>
                {displayStatus === "running" ? "running…" : displayStatus}
              </span>
            </div>
          );
        })}
      </div>
    </section>
  );
}
