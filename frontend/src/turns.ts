// Pure turn-boundary derivation for the agent transcript — the "rewind to here"
// anchors. Mirrors the backend `Store.turns` derivation (backend/haro/store.py) so the
// UI can compute rewind points straight from the streamed/loaded events without a
// second fetch; the GET /workspaces/{id}/turns endpoint returns the same shape.
//
// A `user` event (the prompt echo, or a platform auto-fix announce) opens a turn; every
// agent event that follows shares its `turn` ordinal until the next `user` event. We
// key off the `turn` field the backend tags — older events persisted before markers
// existed have no `turn`, so they're skipped (they predate the feature; nothing to
// rewind to). `kind` separates a real user prompt from an auto-fix round or a
// refuter review-fix round (Phase 3 of notes/workflow-roles-plan.md).
import type { AgentEvent, TurnMarker } from "./types";

export function deriveTurns(events: AgentEvent[]): TurnMarker[] {
  const out: TurnMarker[] = [];
  for (const ev of events) {
    if (ev.type !== "user" || typeof ev.turn !== "number") continue;
    out.push({
      turn: ev.turn,
      run_id: ev.run_id,
      ts: ev.ts,
      prompt: String(ev.payload?.text ?? ""),
      kind: ev.run_id === "autofix" ? "autofix" : ev.run_id === "reviewfix" ? "reviewfix" : "user",
    });
  }
  return out;
}
