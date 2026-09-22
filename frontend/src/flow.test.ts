import { describe, it, expect } from "vitest";
import { flowSteps, connectorDone, stepTarget, focusesFailures, type FlowState } from "./flow";
import type { Cell, TestRun } from "./types";

const states = (inp: Parameters<typeof flowSteps>[0]): Record<string, FlowState> =>
  Object.fromEntries(flowSteps(inp).map((s) => [s.key, s.state]));

const run = (over: Partial<TestRun> = {}): TestRun => ({
  id: "r1",
  workspace_id: "w1",
  runner: "vitest",
  scope: "all",
  status: "passed",
  total: 5,
  passed: 5,
  failed: 0,
  skipped: 0,
  duration_ms: 100,
  wall_ms: 120,
  cases: [],
  error: null,
  error_kind: null,
  flaky_tests: [],
  coverage_delta: null,
  coverage_note: null,
  coverage_blocked: false,
  tamper_findings: [],
  tamper_note: null,
  tamper_blocked: false,
  merge_conflict: false,
  merge_note: null,
  started_at: 0,
  ended_at: 1,
  ...over,
});

const cell = (over: Partial<Cell>): Cell => ({
  id: over.id ?? "x",
  file: over.file ?? "a.test.ts",
  name: over.name ?? "test",
  status: over.status ?? "passed",
  duration_ms: over.duration_ms ?? null,
  message: over.message ?? null,
});

describe("flowSteps — truth, not cursor position", () => {
  it("a red gate never paints downstream as done: ship is blocked, gate is blocked", () => {
    const s = states({ status: "gate_red", hasEvents: true, filesChanged: 3 });
    expect(s.agent).toBe("done"); // agent genuinely produced output
    expect(s.code).toBe("done"); // there are real changes
    expect(s.gate).toBe("blocked");
    expect(s.git).toBe("blocked"); // NOT "done" — the bug this fixes
  });

  it("a green gate makes ship ready (actionable), not yet done", () => {
    const s = states({ status: "gate_green", hasEvents: true, filesChanged: 2 });
    expect(s.gate).toBe("done");
    expect(s.git).toBe("ready");
  });

  it("merged marks both gate and ship done", () => {
    const s = states({ status: "merged", hasEvents: true, filesChanged: 2 });
    expect(s.gate).toBe("done");
    expect(s.git).toBe("done");
  });

  it("running states are active, not done", () => {
    expect(states({ status: "agent_running", hasEvents: false, filesChanged: 0 }).agent).toBe("active");
    expect(states({ status: "tests_running", hasEvents: true, filesChanged: 1 }).gate).toBe("active");
  });

  it("a fresh workspace: everything todo except nothing done", () => {
    const s = states({ status: "idle", hasEvents: false, filesChanged: 0 });
    expect(Object.values(s).every((v) => v === "todo")).toBe(true);
  });

  it("code is done only when files changed", () => {
    expect(states({ status: "idle", hasEvents: true, filesChanged: 0 }).code).toBe("todo");
    expect(states({ status: "idle", hasEvents: true, filesChanged: 1 }).code).toBe("done");
  });
});

describe("badges match state", () => {
  it("gate badge shows the pass/fail tally once tests have run (numbers, not emoji)", () => {
    const red = flowSteps({ status: "gate_red", hasEvents: true, filesChanged: 1, passed: 3, failed: 2 });
    expect(red.find((s) => s.key === "gate")?.badge).toEqual({ text: "3✓ 2✗", tone: "bad" });
    const green = flowSteps({ status: "gate_green", hasEvents: true, filesChanged: 1, passed: 5, failed: 0 });
    expect(green.find((s) => s.key === "gate")?.badge).toEqual({ text: "5✓ 0✗", tone: "ok" });
  });

  it("gate badge falls back to a single word when no tally is available", () => {
    const red = flowSteps({ status: "gate_red", hasEvents: true, filesChanged: 1 });
    expect(red.find((s) => s.key === "gate")?.badge).toEqual({ text: "failed", tone: "bad" });
    const green = flowSteps({ status: "gate_green", hasEvents: true, filesChanged: 1 });
    expect(green.find((s) => s.key === "gate")?.badge).toEqual({ text: "passed", tone: "ok" });
  });

  it("ship badge reads blocked / ready / merged", () => {
    const by = (status: string) =>
      flowSteps({ status, hasEvents: true, filesChanged: 1 }).find((s) => s.key === "git")?.badge?.text;
    expect(by("gate_red")).toBe("blocked");
    expect(by("gate_green")).toBe("ready");
    expect(by("merged")).toBe("merged");
  });
});

describe("adopted worktrees are agentless — ① agent is dropped", () => {
  it("omits the agent step, opening the flow on code › verify › ship", () => {
    const keys = flowSteps({ status: "gate_green", hasEvents: false, filesChanged: 2, kind: "adopted" }).map(
      (s) => s.key
    );
    expect(keys).toEqual(["code", "gate", "git"]);
  });

  it("code/verify/ship still read real state (a red gate blocks ship)", () => {
    const s = states({ status: "gate_red", hasEvents: false, filesChanged: 1, kind: "adopted" });
    expect(s.agent).toBeUndefined();
    expect(s.code).toBe("done");
    expect(s.gate).toBe("blocked");
    expect(s.git).toBe("blocked");
  });

  it("managed (default) keeps the full agent › code › verify › ship", () => {
    const keys = flowSteps({ status: "idle", hasEvents: false, filesChanged: 0 }).map((s) => s.key);
    expect(keys).toEqual(["agent", "code", "gate", "git"]);
  });
});

describe("connectorDone", () => {
  it("fills only after a genuinely-done step", () => {
    const [agent, , gate] = flowSteps({ status: "gate_red", hasEvents: true, filesChanged: 1 });
    expect(connectorDone(agent)).toBe(true); // agent done
    expect(connectorDone(gate)).toBe(false); // gate blocked → connector to ship stays empty
  });
});

describe("a degraded green blocks verify AND ship — notes/verify-redesign-plan.md", () => {
  it("a clean green is done/ready, same as before verdict.ts existed", () => {
    const s = states({ status: "gate_green", hasEvents: true, filesChanged: 1, run: run() });
    expect(s.gate).toBe("done");
    expect(s.git).toBe("ready");
  });

  it("a degraded green blocks both, since a check the project asked for never ran", () => {
    const s = states({
      status: "gate_green",
      hasEvents: true,
      filesChanged: 1,
      run: run({ degraded_reasons: ["quality scanner not installed"] }),
    });
    expect(s.gate).toBe("blocked");
    expect(s.git).toBe("blocked");
  });
});

describe("the verify badge stars a green* run and shows live progress while running", () => {
  it("ends the badge with * when the tamper alarm found something", () => {
    const badge = flowSteps({
      status: "gate_green",
      hasEvents: true,
      filesChanged: 1,
      run: run({ tamper_findings: [{ kind: "skip", file: "a.ts", detail: "", test: null }] }),
    }).find((s) => s.key === "gate")?.badge;
    expect(badge).toEqual({ text: "5✓ 0✗*", tone: "ok" });
  });

  it("shows settled-of-total while the gate is running, given live cells", () => {
    const cells = Array.from({ length: 9 }, (_, i) => cell({ id: String(i), status: i < 3 ? "passed" : "running" }));
    const badge = flowSteps({
      status: "tests_running",
      hasEvents: true,
      filesChanged: 1,
      cells,
    }).find((s) => s.key === "gate")?.badge;
    expect(badge).toEqual({ text: "gate… 3/9", tone: "run" });
  });

  it("says the gate didn't run, not that tests failed, on a gate error", () => {
    const badge = flowSteps({
      status: "gate_red",
      hasEvents: true,
      filesChanged: 1,
      run: run({ status: "error", error_kind: "setup", passed: 0, failed: 0 }),
    }).find((s) => s.key === "gate")?.badge;
    expect(badge).toEqual({ text: "didn't run", tone: "bad" });
  });
});

describe("stepTarget — blocked ship is a live link to the gate", () => {
  const step = (status: string, key: "gate" | "git") =>
    flowSteps({ status, hasEvents: true, filesChanged: 1 }).find((s) => s.key === key)!;

  it("routes a blocked ship step to the gate (not its dead-end Git tab)", () => {
    expect(stepTarget(step("gate_red", "git"))).toBe("gate");
  });
  it("a ready ship step still goes to the Git panel", () => {
    expect(stepTarget(step("gate_green", "git"))).toBe("git");
  });
  it("other steps route to themselves", () => {
    expect(stepTarget(step("gate_red", "gate"))).toBe("gate");
  });
  it("blocked steps focus the failure summary", () => {
    expect(focusesFailures(step("gate_red", "git"))).toBe(true);
    expect(focusesFailures(step("gate_red", "gate"))).toBe(true);
    expect(focusesFailures(step("gate_green", "git"))).toBe(false);
  });
});
