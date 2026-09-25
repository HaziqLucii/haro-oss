import { describe, it, expect } from "vitest";
import { composerButtonLabel, isAgentBusy, shouldClientQueue } from "./composerButton";

describe("composer button label", () => {
  it("reads 'queue' while an agent or its gate is running", () => {
    expect(composerButtonLabel("agent_running")).toBe("queue");
    expect(composerButtonLabel("tests_running")).toBe("queue");
  });

  it("reads 'run agent' when idle", () => {
    expect(composerButtonLabel("idle")).toBe("run agent");
  });

  // Regression: seeding a workspace from a backlog TODO briefly flashed "queue"
  // during the setup (dep-install) window before flipping to "run agent". No
  // agent is running while setting up, so the button must say "run agent".
  it("reads 'run agent' during setup — not 'queue'", () => {
    expect(composerButtonLabel("setting_up")).toBe("run agent");
    expect(isAgentBusy("setting_up")).toBe(false);
  });

  it("treats unknown/other statuses as not busy", () => {
    expect(composerButtonLabel("gate_green")).toBe("run agent");
    expect(composerButtonLabel("broken")).toBe("run agent");
  });
});

describe("client-side queueing", () => {
  // The felt bug (backlog/agent-session-lifecycle.md §1): submitting during setup used
  // to file the task into a localStorage queue whose ONLY drainer was an effect scoped
  // to the selected workspace. Create from the backlog → click run → switch away, and
  // the agent never ran. Setup is the backend's wait to own now: POST immediately and
  // the run is held server-side as `queued`.
  it("does NOT client-queue during setup", () => {
    expect(shouldClientQueue("setting_up")).toBe(false);
  });

  // The legitimate follow-up-while-busy feature, unchanged.
  it("client-queues behind a real agent or gate run", () => {
    expect(shouldClientQueue("agent_running")).toBe(true);
    expect(shouldClientQueue("tests_running")).toBe(true);
  });

  it("does not queue when idle or settled", () => {
    expect(shouldClientQueue("idle")).toBe(false);
    expect(shouldClientQueue("gate_green")).toBe(false);
    expect(shouldClientQueue("gate_red")).toBe(false);
  });

  // The label and the behaviour read the SAME predicate, so a click can never say
  // "run agent" while silently queueing (or vice versa).
  it("agrees with the button label for every status", () => {
    for (const s of ["idle", "setting_up", "agent_running", "tests_running",
                     "gate_green", "gate_red", "merged", "broken"]) {
      expect(shouldClientQueue(s)).toBe(composerButtonLabel(s) === "queue");
    }
  });
});
