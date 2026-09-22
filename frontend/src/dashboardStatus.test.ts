import { describe, it, expect } from "vitest";
import { LABEL, rankOf, gateLine, trustMeter, tamperStar, attentionSummary } from "./components/Dashboard";
import type { GateSummary, TrustSummary } from "./types";

const sum = (o: Partial<GateSummary>): GateSummary => ({
  status: "passed", total: 0, passed: 0, failed: 0, scope: "all", error_kind: null, ended_at: null,
  tamper_count: 0, tamper_note: null, ...o,
});

const trust = (o: Partial<TrustSummary>): TrustSummary => ({
  enabled: true, streak: 0, streak_required: 3, auto_action: "off", met: false, armed: false, ...o,
});

describe("dashboard broken status", () => {
  it("labels broken as 'needs repair'", () => {
    expect(LABEL.broken).toBe("needs repair");
  });

  it("triages broken alongside gate_red, ahead of active/green/idle", () => {
    expect(rankOf("broken")).toBe(rankOf("gate_red"));
    expect(rankOf("broken")).toBeLessThan(rankOf("agent_running"));
    expect(rankOf("broken")).toBeLessThan(rankOf("gate_green"));
    expect(rankOf("broken")).toBeLessThan(rankOf("idle"));
  });

  it("sorts unknown statuses last", () => {
    expect(rankOf("something_new")).toBe(4);
  });
});

describe("dashboard gate glance line", () => {
  it("shows passed count on a green gate", () => {
    expect(gateLine("gate_green", sum({ status: "passed", total: 42, passed: 42 }))?.text).toBe("✓ 42 passed");
  });

  it("shows failing count on a red gate", () => {
    const line = gateLine("gate_red", sum({ status: "failed", total: 42, passed: 39, failed: 3 }));
    expect(line?.text).toBe("✗ 3 failing · 42 tests");
    expect(line?.cls).toBe("s-fail");
  });

  it("says couldn't-run for a red gate that errored (never faking a test count)", () => {
    expect(gateLine("gate_red", sum({ status: "error", error_kind: "setup" }))?.text).toBe("gate couldn’t run");
  });

  it("says blocked for a red gate with no per-test failure (e.g. coverage guard)", () => {
    expect(gateLine("gate_red", sum({ status: "passed", total: 10, passed: 10, failed: 0 }))?.text).toBe("gate blocked");
  });

  it("shows nothing for non-gate statuses", () => {
    expect(gateLine("agent_running", null)).toBeNull();
    expect(gateLine("idle", null)).toBeNull();
  });
});

describe("dashboard green* star", () => {
  it("stars a green gate that carries tamper findings, using the backend's note", () => {
    const star = tamperStar("gate_green", sum({ total: 10, passed: 10, tamper_count: 3, tamper_note: "2 removed · 1 .skip" }))!;
    expect(star.count).toBe(3);
    expect(star.note).toBe("2 removed · 1 .skip");
  });

  it("falls back to a plain count when the run recorded no note", () => {
    expect(tamperStar("gate_green", sum({ tamper_count: 1 }))?.note).toBe("1 suspicious test change");
    expect(tamperStar("gate_green", sum({ tamper_count: 2 }))?.note).toBe("2 suspicious test changes");
  });

  it("leaves a clean green unstarred", () => {
    expect(tamperStar("gate_green", sum({ total: 10, passed: 10 }))).toBeNull();
    expect(tamperStar("gate_green", null)).toBeNull();
  });

  it("never stars a non-green status — a blocked gate is already red on its own merit", () => {
    expect(tamperStar("gate_red", sum({ tamper_count: 3, tamper_note: "3 removed" }))).toBeNull();
    expect(tamperStar("agent_running", sum({ tamper_count: 3 }))).toBeNull();
  });
});

describe("dashboard attention banner", () => {
  it("is hidden when nothing needs you", () => {
    expect(attentionSummary(0, 0)).toBeNull();
  });

  it("counts reds and starred greens together, staying red-keyed while a red exists", () => {
    const a = attentionSummary(2, 1)!;
    expect(a.title).toBe("3 gates need you");
    expect(a.icon).toBe("🔴");
    expect(a.cls).toBe("s-fail");
    expect(a.hint).toContain("2 red");
    expect(a.hint).toContain("1 green*");
  });

  it("drops to amber when it's green* only — nothing is actually failing", () => {
    const a = attentionSummary(0, 2)!;
    expect(a.title).toBe("2 gates need you");
    expect(a.cls).toBe("s-star");
    expect(a.icon).not.toBe("🔴");
    expect(a.hint).not.toContain("red");
  });

  it("agrees with itself on one gate", () => {
    expect(attentionSummary(1, 0)!.title).toBe("1 gate needs you");
  });
});

describe("dashboard trust meter", () => {
  it("is hidden when the project isn't on the ladder", () => {
    expect(trustMeter(null)).toBeNull();
    expect(trustMeter(undefined)).toBeNull();
    expect(trustMeter(trust({ enabled: false, streak: 5 }))).toBeNull();
  });

  it("shows streak progress toward the requirement", () => {
    const m = trustMeter(trust({ streak: 2, streak_required: 3 }))!;
    expect(m.streak).toBe(2);
    expect(m.required).toBe(3);
    expect(m.pct).toBe(67);
  });

  it("caps the bar at 100% when the streak overshoots the requirement", () => {
    expect(trustMeter(trust({ streak: 9, streak_required: 3 }))!.pct).toBe(100);
  });

  it("reads 'locked' with a fail cls until every condition is met", () => {
    const m = trustMeter(trust({ streak: 1, met: false }))!;
    expect(m.label).toBe("locked");
    expect(m.cls).toBe("s-fail");
  });

  it("reads 'ready' once met but no auto action is armed", () => {
    const m = trustMeter(trust({ streak: 3, met: true, armed: false, auto_action: "off" }))!;
    expect(m.label).toBe("ready");
    expect(m.cls).toBe("s-pass");
  });

  it("names the armed rung (auto-PR)", () => {
    expect(trustMeter(trust({ met: true, armed: true, auto_action: "auto_pr" }))!.label).toBe("auto-PR");
  });
});
