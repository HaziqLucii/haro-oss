// Side-rail card listing Claude Code's own Task/Agent delegations as rows (one per
// tool_use id), fed by claude_code.py's delegate payload. No jsdom in this project,
// so render statically like AgentStream.delegate.test.tsx.
import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { AgentManagerCard } from "./AgentManagerCard";
import type { AgentEvent } from "../types";

const delegateEvent = (
  id: string,
  status: "running" | "done" | "error",
  extra: Record<string, any> = {},
): AgentEvent => ({
  run_id: "r1", workspace_id: "w1", ts: 0, type: "tool_call",
  payload: { tool: "Agent", summary: `↳ scout: ${status}`, delegate: { id, subagent_type: "scout", status, ...extra } },
});

describe("AgentManagerCard", () => {
  it("renders nothing when no delegation has ever happened", () => {
    const html = renderToStaticMarkup(<AgentManagerCard events={[]} running={true} />);
    expect(html).toBe("");
  });

  it("shows one row for a single running delegation", () => {
    const html = renderToStaticMarkup(
      <AgentManagerCard events={[delegateEvent("t1", "running", { description: "map the pages" })]} running={true} />,
    );
    expect(html).toContain("agent-mgr-row");
    expect(html).toContain("scout");
    expect(html).toContain("map the pages");
    expect(html).toContain("agent-mgr-dot-running");
    expect(html).toContain("running…");
  });

  it("a later done event updates the same row instead of adding a second one", () => {
    const events = [
      delegateEvent("t1", "running", { description: "map the pages" }),
      delegateEvent("t1", "done"),
    ];
    const html = renderToStaticMarkup(<AgentManagerCard events={events} running={true} />);
    expect((html.match(/class="agent-mgr-row"/g) ?? []).length).toBe(1);
    expect(html).toContain("agent-mgr-dot-done");
    expect(html).toContain(">done<");
    expect(html).not.toContain("running…");
    // The done event carries no description — the running row's must survive the merge.
    expect(html).toContain("map the pages");
  });

  it("two different delegations render as two rows", () => {
    const events = [delegateEvent("t1", "running"), delegateEvent("t2", "running")];
    const html = renderToStaticMarkup(<AgentManagerCard events={events} running={true} />);
    expect((html.match(/class="agent-mgr-row"/g) ?? []).length).toBe(2);
  });

  it("a still-running delegation shows as stalled once the session itself has stopped", () => {
    // A ⏹ stop mid-delegation can't be closed out backend-side (the adapter can't
    // yield from inside its own GeneratorExit teardown) — the card must not show
    // a breathing "running" dot forever once the whole session is no longer live.
    const html = renderToStaticMarkup(
      <AgentManagerCard events={[delegateEvent("t1", "running")]} running={false} />,
    );
    expect(html).toContain("agent-mgr-dot-stalled");
    expect(html).not.toContain("agent-mgr-dot-running");
    expect(html).toContain(">stalled<");
  });

  it("a done delegation stays done even after the session has stopped", () => {
    const html = renderToStaticMarkup(
      <AgentManagerCard events={[delegateEvent("t1", "done")]} running={false} />,
    );
    expect(html).toContain("agent-mgr-dot-done");
  });
});
