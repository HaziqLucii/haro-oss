// Sub-agent delegation rows (haro's own scout, Phase 2 —
// notes/workflow-roles-plan.md): a tool_call whose summary starts with "↳"
// (rendered by the backend's claude_code.py _delegate_summary for an Agent/Task
// tool_use with a subagent_type) must read as a distinct, dimmed/indented beat —
// not another ordinary op line. Tested at the unit level like the prompt-echo
// markdown tests: no jsdom in this project, so render EventRow directly.
import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { EventRow } from "./AgentStream";
import type { AgentEvent } from "../types";

const toolCall = (summary: string, tool = "Agent"): AgentEvent => ({
  run_id: "r1", workspace_id: "w1", ts: 0, type: "tool_call",
  payload: { tool, summary },
});

describe("delegation rows", () => {
  it("gets the ev-delegate class when the summary starts with the arrow", () => {
    const html = renderToStaticMarkup(<EventRow ev={toolCall("↳ scout: map the pages")} />);
    expect(html).toContain("ev-delegate");
    expect(html).toContain("↳ scout: map the pages");
  });

  it("does not show the tool name separately (the arrow summary already says scout)", () => {
    const html = renderToStaticMarkup(<EventRow ev={toolCall("↳ scout: map the pages")} />);
    expect(html).not.toContain('class="ev-op-name"');
  });

  it("an ordinary tool call gets neither the class nor the arrow", () => {
    const html = renderToStaticMarkup(<EventRow ev={toolCall("src/App.tsx", "Read")} />);
    expect(html).not.toContain("ev-delegate");
    expect(html).toContain('class="ev-op-name"');
    expect(html).toContain("Read");
  });

  it("a summary that merely mentions the arrow mid-string is not treated as a delegation", () => {
    // Only a LEADING arrow (the backend's exact rendering) counts.
    const html = renderToStaticMarkup(<EventRow ev={toolCall("grep for ↳ in the codebase", "Grep")} />);
    expect(html).not.toContain("ev-delegate");
  });
});

describe("delegation handback (the sub-agent returning context to the main agent)", () => {
  // The completion event (claude_code.py's _normalize_tool_results,
  // payload.delegate.status "done"/"error") IS the sub-agent handing its result
  // back to the driving agent — it gets its own visible row, worded explicitly,
  // not just a silent AgentManagerCard update. A user watching only the stream
  // must be able to see the handback happen, not just infer it from a dot
  // changing color in a side panel.
  const delegateEvent = (status: "running" | "done" | "error"): AgentEvent => ({
    run_id: "r1", workspace_id: "w1", ts: 0, type: "tool_call",
    payload: {
      tool: "Agent",
      summary: status === "running" ? "↳ scout: map the pages" : `↳ scout: ${status} — sent back to main agent`,
      delegate: { id: "toolu_1", subagent_type: "scout", status },
    },
  });

  it("renders the row while the delegation is running", () => {
    const html = renderToStaticMarkup(<EventRow ev={delegateEvent("running")} />);
    expect(html).toContain("ev-delegate");
  });

  it("renders a distinct, visible row when the sub-agent hands its result back", () => {
    const html = renderToStaticMarkup(<EventRow ev={delegateEvent("done")} />);
    expect(html).toContain("ev-delegate");
    expect(html).toContain("sent back to main agent");
  });

  it("renders a visible row for an errored handback too", () => {
    const html = renderToStaticMarkup(<EventRow ev={delegateEvent("error")} />);
    expect(html).toContain("ev-delegate");
    expect(html).toContain("error — sent back to main agent");
  });
});
