import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { TrustChecklist, TRUST_FIX_LABELS, trustUnmet } from "./TrustChecklist";
import { GatePanel } from "./GatePanel";
import type { TrustCondition, TrustReport } from "../types";

const cond = (over: Partial<TrustCondition> = {}): TrustCondition => ({
  key: "no_tamper",
  met: true,
  detail: "test suite intact vs base",
  required: true,
  fix: null,
  ...over,
});

const report = (over: Partial<TrustReport> = {}): TrustReport => ({
  enabled: true,
  conditions: [cond()],
  streak: 3,
  streak_required: 3,
  auto_action: "auto_pr",
  met: true,
  armed: true,
  ...over,
});

const html = (t: TrustReport) =>
  renderToStaticMarkup(<TrustChecklist trust={t} onFix={() => {}} />);

describe("TrustChecklist — the no-tamper rung condition", () => {
  it("shows a clean suite as met, with no fix button", () => {
    const out = html(report());
    expect(out).toContain("No tamper findings");
    expect(out).toContain("test suite intact vs base");
    expect(out).toContain("trust-row-met");
    expect(out).not.toContain("trust-fix");
  });

  it("deep-links an unmet tamper row to the green* findings chip", () => {
    // The backend sets fix="tamper" on a green* run; the row must offer the way there,
    // or a weakened suite blocks auto-ship with no route to the fix.
    const out = html(
      report({
        conditions: [cond({ met: false, detail: "1 tamper finding(s): 1 removed", fix: "tamper" })],
        met: false,
        armed: false,
      })
    );
    expect(out).toContain("trust-row-unmet");
    expect(out).toContain("1 tamper finding(s): 1 removed");
    expect(out).toContain(TRUST_FIX_LABELS.tamper);
  });

  it("counts an unmet tamper row as a blocker, and auto-PR reads as locked", () => {
    const t = report({
      conditions: [cond({ met: false, fix: "tamper" })],
      met: false,
      armed: false,
    });
    expect(trustUnmet(t)).toBe(1);
    expect(html(t)).toContain("auto-PR locked");
  });

  it("still counts the row when the alarm is off — unmeasured is not clean", () => {
    const t = report({
      conditions: [
        cond({ met: false, detail: "tamper alarm off: enable [workflow] tamper_alarm", fix: "gate_settings" }),
      ],
      met: false,
      armed: false,
    });
    expect(trustUnmet(t)).toBe(1);
    expect(html(t)).toContain(TRUST_FIX_LABELS.gate_settings);
  });
});

describe("the checklist left ③ verify for ④ ship (notes/verify-redesign-plan.md)", () => {
  it("GatePanel markup contains no trust-lane", () => {
    const markup = renderToStaticMarkup(
      <GatePanel
        test={null}
        cells={[]}
        history={[]}
        impact={null}
        blame={null}
        coverage={null}
        flaky={null}
        analyzing={null}
        status="gate_green"
        busy={false}
        onRunGate={() => {}}
        onRunImpacted={() => {}}
        onRefreshImpact={() => {}}
        onCoverage={() => {}}
        onFlaky={() => {}}
      />,
    );
    expect(markup).not.toContain("trust-lane");
  });
});
