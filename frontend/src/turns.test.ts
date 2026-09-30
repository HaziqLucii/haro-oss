import { describe, it, expect } from "vitest";
import { deriveTurns } from "./turns";
import type { AgentEvent } from "./types";

// Compact factory — only the fields deriveTurns reads.
const ev = (p: Partial<AgentEvent>): AgentEvent => ({
  run_id: "run",
  workspace_id: "ws",
  ts: 0,
  type: "token",
  payload: {},
  ...p,
});

describe("deriveTurns — rewind anchors from the flat transcript", () => {
  it("one marker per user event, carrying its turn ordinal + prompt", () => {
    const turns = deriveTurns([
      ev({ type: "user", run_id: "user", turn: 1, ts: 10, payload: { text: "first" } }),
      ev({ type: "token", turn: 1, payload: { text: "hi" } }),
      ev({ type: "done", turn: 1, payload: {} }),
      ev({ type: "user", run_id: "user", turn: 2, ts: 20, payload: { text: "second" } }),
      ev({ type: "token", turn: 2, payload: { text: "yo" } }),
    ]);
    expect(turns.map((t) => t.turn)).toEqual([1, 2]);
    expect(turns.map((t) => t.prompt)).toEqual(["first", "second"]);
    expect(turns[0]).toMatchObject({ turn: 1, ts: 10, kind: "user" });
  });

  it("tags an auto-fix announce as kind:autofix so the UI can dim it", () => {
    const turns = deriveTurns([
      ev({ type: "user", run_id: "user", turn: 1, payload: { text: "do it" } }),
      ev({ type: "user", run_id: "autofix", turn: 2, payload: { text: "gate red…" } }),
    ]);
    expect(turns.map((t) => t.kind)).toEqual(["user", "autofix"]);
  });

  it("tags a review-fix announce as kind:reviewfix (Phase 3 — distinct from autofix)", () => {
    const turns = deriveTurns([
      ev({ type: "user", run_id: "user", turn: 1, payload: { text: "do it" } }),
      ev({ type: "user", run_id: "reviewfix", turn: 2, payload: { text: "refuter round 1/2…" } }),
    ]);
    expect(turns.map((t) => t.kind)).toEqual(["user", "reviewfix"]);
  });

  it("skips non-user events and legacy events with no turn tag", () => {
    const turns = deriveTurns([
      ev({ type: "token", payload: { text: "orphan" } }),
      ev({ type: "user", run_id: "user", payload: { text: "no turn field" } }), // pre-markers
      ev({ type: "user", run_id: "user", turn: 1, payload: { text: "tagged" } }),
    ]);
    expect(turns).toHaveLength(1);
    expect(turns[0].prompt).toBe("tagged");
  });
});
