import { describe, it, expect } from "vitest";
import type { RolesConfig } from "./types";
import { nextRole, roleLabel, runArgs, stripSteps } from "./roles";

const cfg = (over: Partial<RolesConfig> = {}): RolesConfig => ({
  enabled: true,
  plan: "fable:xhigh",
  build: "sonnet:high",
  review: "opus:high",
  scout: "haiku",
  review_enforce: "off",
  review_max_rounds: 2,
  ...over,
});

describe("nextRole", () => {
  it("is plan when Plan first is on", () => {
    expect(nextRole(true)).toBe("plan");
  });
  it("is build otherwise", () => {
    expect(nextRole(false)).toBe("build");
  });
});

describe("roleLabel", () => {
  it("renders model and effort", () => {
    expect(roleLabel("fable:xhigh")).toBe("fable · xhigh");
  });
  it("renders a bare model with no effort (scout)", () => {
    expect(roleLabel("haiku")).toBe("haiku");
  });
  it("renders 'not set' for an empty shorthand, never a dangling separator", () => {
    expect(roleLabel("")).toBe("not set");
  });
});

describe("stripSteps", () => {
  it("highlights plan when Plan first is on", () => {
    const steps = stripSteps(cfg(), true);
    expect(steps.map((s) => [s.step, s.active])).toEqual([
      ["plan", true],
      ["build", false],
      ["review", false],
    ]);
  });

  it("highlights build otherwise", () => {
    const steps = stripSteps(cfg(), false);
    expect(steps.map((s) => [s.step, s.active])).toEqual([
      ["plan", false],
      ["build", true],
      ["review", false],
    ]);
  });

  it("labels each step from the project's roles config", () => {
    const steps = stripSteps(cfg(), false);
    expect(steps.find((s) => s.step === "plan")?.label).toBe("fable · xhigh");
    expect(steps.find((s) => s.step === "build")?.label).toBe("sonnet · high");
    expect(steps.find((s) => s.step === "review")?.label).toBe("opus · high");
  });

  it("review is never highlighted (the refuter runs on the gate, not a submit)", () => {
    expect(stripSteps(cfg(), true).find((s) => s.step === "review")?.active).toBe(false);
    expect(stripSteps(cfg(), false).find((s) => s.step === "review")?.active).toBe(false);
  });

  it("an unconfigured step reads 'not set'", () => {
    const steps = stripSteps(cfg({ build: "" }), false);
    expect(steps.find((s) => s.step === "build")?.label).toBe("not set");
  });
});

describe("runArgs", () => {
  // This is the exact seam a Phase 1 regression slipped through on: `rolesEnabled`
  // must win over whatever the (stale, hidden) model/effort picker state says,
  // otherwise `req.model` always wins server-side and the role's model never runs.
  it("omits model/effort and forces claude-code when roles are enabled, even with a concrete model/effort picked", () => {
    const args = runArgs({
      model: "opus", effort: "high", backend: "claude-code", localModel: "", rolesEnabled: true,
    });
    expect(args).toEqual({ adapter: "claude-code", model: undefined, effort: undefined });
  });

  it("forces claude-code (not local) when roles are enabled despite a stale local backend pick", () => {
    const args = runArgs({
      model: "default", effort: "default", backend: "local", localModel: "qwen2.5-coder",
      rolesEnabled: true,
    });
    expect(args.adapter).toBe("claude-code");
    expect(args.model).toBeUndefined();
  });

  it("passes an explicit model/effort through when roles are off", () => {
    const args = runArgs({ model: "opus", effort: "high", backend: "claude-code", localModel: "" });
    expect(args).toEqual({ adapter: "claude-code", model: "opus", effort: "high" });
  });

  it("omits 'default' picker values (not a roles concern) when roles are off", () => {
    const args = runArgs({ model: "default", effort: "default", backend: "claude-code", localModel: "" });
    expect(args).toEqual({ adapter: "claude-code", model: undefined, effort: undefined });
  });

  it("routes to the local adapter with its model tag when roles are off", () => {
    const args = runArgs({
      model: "default", effort: "default", backend: "local", localModel: "qwen2.5-coder",
    });
    expect(args).toEqual({ adapter: "local", model: "qwen2.5-coder", effort: undefined });
  });
});
