/** The Gate Receipt panel (usp-critique-plan.md idea 1) — the ④ ship step's exportable
 *  evidence packet. Static-rendered like LookAt.test.tsx: this pane is driven
 *  entirely by its `data` prop (fetched by App.tsx), so a plain render covers the one
 *  claim worth pinning — it never overclaims what wasn't actually measured.
 */
import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { ReceiptPanel } from "./ReceiptPanel";
import type { Receipt, ReceiptResponse } from "../types";

const receipt = (over: Partial<Receipt> = {}): Receipt => ({
  workspace_id: "ws_1",
  branch: "feat",
  base_ref: "main",
  verdict: "green",
  gate_sha: "abc1234",
  degraded_reasons: [],
  suite: { runner: "vitest", scope: "all", total: 12, passed: 12, failed: 0, skipped: 0, impacted_count: null },
  tamper: { measured: true, clean: true, findings_count: 0, note: null },
  quality: {
    measured: false, blocked: false, findings_count: 0, blocking_count: 0, note: null,
    plan_compliance: { ran: false, error: null, compliant: true, confidence: null, summary: null, gaps: 0, blocking: false, enforced: false },
  },
  review: { ran: false, error: null, verdict: "pass", summary: null, must_fix: 0, blocking: false, enforced: false },
  verified_hunks: { supported: true, percentage: 87.5, untested_files: ["src/legacy.ts"], note: null },
  mutation: { supported: false, ran: false, stale: false, score: null, survivors: [], note: "mutation score has not been run for this tree" },
  agent: { model: "sonnet", effort: "medium", cost_usd: 0.42 },
  generated_at: 0,
  ...over,
});

const response = (over: Partial<Receipt> = {}): ReceiptResponse => {
  const r = receipt(over);
  return { receipt: r, markdown: `# haro gate receipt — ${r.verdict.toUpperCase()}\n` };
};

const render = (data: ReceiptResponse | null, hasRemote = false) =>
  renderToStaticMarkup(<ReceiptPanel workspaceId="ws_1" data={data} hasRemote={hasRemote} />);

describe("ReceiptPanel", () => {
  it("renders nothing when there's no receipt yet", () => {
    expect(render(null)).toBe("");
  });

  it("renders nothing for a workspace that's never been gated", () => {
    expect(render(response({ verdict: "none" }))).toBe("");
  });

  it("shows the suite verdict and tamper state for a green gate", () => {
    const html = render(response());
    expect(html).toMatch(/GREEN/);
    expect(html).toMatch(/12\/12 passed/);
    expect(html).toMatch(/clean/);
  });

  it("never claims a mutation score that was never run", () => {
    const html = render(response());
    expect(html).not.toMatch(/\d+% \(\d+ survivor/);
    expect(html).toMatch(/mutation score has not been run/);
  });

  it("reports the verified-hunks percentage when supported", () => {
    const html = render(response());
    expect(html).toMatch(/87\.5% of added lines executed/);
  });

  it("falls back to the note when verified hunks aren't supported", () => {
    const html = render(
      response({ verified_hunks: { supported: false, percentage: null, untested_files: [], note: "per-line proof is off for this project" } })
    );
    expect(html).toMatch(/per-line proof is off for this project/);
    expect(html).not.toMatch(/% of added lines executed/);
  });

  it("shows the post-to-PR action only when a remote exists", () => {
    expect(render(response(), true)).toMatch(/post to PR/);
    expect(render(response(), false)).not.toMatch(/post to PR/);
  });

  it("hides the agent line when no agent run is on record", () => {
    const html = render(response({ agent: { model: null, effort: null, cost_usd: null } }));
    expect(html).not.toMatch(/>Agent</);
  });

  const tamperRowHtml = (html: string) => {
    const idx = html.indexOf("Tamper alarm");
    return html.slice(html.lastIndexOf("<li", idx), idx);
  };

  it("never renders the tamper row as met when it wasn't actually measured", () => {
    // The round-2/3 regression: `tamper.clean` alone used to drive the ✓ glyph and the
    // met styling, so an unmeasured alarm (clean=true by construction, since there are
    // no findings to report) rendered as if it had run clean. (Note: "trust-row-unmet"
    // contains the substring "met", so assertions here match the exact class string.)
    const html = render(response({ tamper: { measured: false, clean: true, findings_count: 0, note: null } }));
    expect(html).toMatch(/not measured/);
    const row = tamperRowHtml(html);
    expect(row).toMatch(/class="trust-row trust-row-unmet"/);
    expect(row).not.toMatch(/class="trust-row trust-row-met"/);
  });

  it("still renders the tamper row as met for a real clean measurement", () => {
    const html = render(response({ tamper: { measured: true, clean: true, findings_count: 0, note: null } }));
    expect(tamperRowHtml(html)).toMatch(/class="trust-row trust-row-met"/);
  });

  it("flags a stale mutation score instead of showing a bare percentage", () => {
    const html = render(
      response({ mutation: { supported: true, ran: true, stale: true, score: 82, survivors: [], note: "tree changed since this score was measured — re-run mutation to refresh it" } })
    );
    expect(html).toMatch(/82%.*stale/);
  });

  it("surfaces degraded reasons instead of hiding them behind the DEGRADED header word", () => {
    const html = render(
      response({
        verdict: "degraded",
        degraded_reasons: ["the tamper alarm is on but the base test inventory was unavailable: removed tests could not be detected for this run"],
      })
    );
    expect(html).toMatch(/DEGRADED/);
    expect(html).toMatch(/base test inventory was unavailable/);
  });

  it("shows no degraded section when nothing degraded", () => {
    const html = render(response({ degraded_reasons: [] }));
    expect(html).not.toMatch(/could not run/);
  });

  it("renders the quality section instead of dropping it entirely", () => {
    // The round-7 regression: ReceiptQuality was in the payload and types.ts but the
    // panel never rendered it at all, so a blocked quality verdict showed a RED header
    // over a checklist with no quality row anywhere.
    const html = render(response({ quality: { measured: true, blocked: false, findings_count: 0, blocking_count: 0, note: null, plan_compliance: { ran: false, error: null, compliant: true, confidence: null, summary: null, gaps: 0, blocking: false, enforced: false } } }));
    expect(html).toMatch(/Quality scan/);
    expect(html).toMatch(/clean/);
  });

  it("explains a plan-compliance block even when the deterministic tier never measured", () => {
    // The round-7 regression: plan compliance runs independently of the deterministic
    // scanners and can block on its own (round 9: `quality.blocked` never reflects
    // this — it's the scanners' own blocking_count only) — the old markdown (and the
    // missing panel row) left a blocked verdict with literally no stated cause here.
    const html = render(
      response({
        verdict: "red",
        quality: {
          measured: false, blocked: false, findings_count: 0, blocking_count: 0, note: null,
          plan_compliance: { ran: true, error: null, compliant: false, confidence: "high", summary: "added a cache layer the task never asked for", gaps: 1, blocking: true, enforced: true },
        },
      })
    );
    expect(html).toMatch(/Plan compliance/);
    expect(html).toMatch(/BLOCKING/);
    expect(html).toMatch(/added a cache layer the task never asked for/);
  });

  it("hides the plan-compliance row when it never ran", () => {
    const html = render(response());
    expect(html).not.toMatch(/Plan compliance/);
  });

  const rowHtml = (html: string, label: string) => {
    const idx = html.indexOf(label);
    return html.slice(html.lastIndexOf("<li", idx), idx);
  };

  it("never renders a plan-compliance check that could not run as met", () => {
    // The round-8 regression: the row picked its met/unmet styling from `blocking`
    // alone, so a check that produced NO answer (error) fell into the met branch by
    // default (blocking=false, compliant=true are the model's own defaults on error).
    const html = render(
      response({
        verdict: "degraded",
        quality: {
          measured: false, blocked: false, findings_count: 0, blocking_count: 0, note: null,
          plan_compliance: { ran: true, error: "the `claude` CLI was not found on PATH", compliant: true, confidence: null, summary: null, gaps: 0, blocking: false, enforced: false },
        },
      })
    );
    expect(html).toMatch(/could not run/);
    const row = rowHtml(html, "Plan compliance");
    expect(row).toMatch(/class="trust-row trust-row-unmet"/);
    expect(row).not.toMatch(/class="trust-row trust-row-met"/);
  });

  it("never claims BLOCKING on a plan-compliance flag that was never enforced", () => {
    // The round-8 regression: `blocking` means "meets the bar to block", not "blocked"
    // — under plan_compliance="warn" it can be true on a genuinely GREEN run, and
    // showing "BLOCKING" there contradicts the receipt's own header.
    const html = render(
      response({
        verdict: "green",
        quality: {
          measured: false, blocked: false, findings_count: 0, blocking_count: 0, note: null,
          plan_compliance: { ran: true, error: null, compliant: false, confidence: "high", summary: "added a cache layer the task never asked for", gaps: 1, blocking: true, enforced: false },
        },
      })
    );
    expect(html).not.toMatch(/BLOCKING/);
    expect(html).toMatch(/not enforced/);
  });

  it("never attributes a plan-compliance block to a clean deterministic scan", () => {
    // The round-8/9 regression: `quality.blocked` is now strictly derived from the
    // deterministic scanners' OWN blocking_count (round 9), so a plan-compliance
    // block can never set it — but pin the rendering anyway: the Quality scan line
    // must not mention blocking when the scan itself was clean.
    const html = render(
      response({
        verdict: "red",
        quality: {
          measured: true, blocked: false, findings_count: 0, blocking_count: 0, note: null,
          plan_compliance: { ran: true, error: null, compliant: false, confidence: "high", summary: "added a cache layer the task never asked for", gaps: 1, blocking: true, enforced: true },
        },
      })
    );
    // The quality row's OWN detail text — from the "Quality scan" label to the row's
    // closing </li> — must not mention blocking, since the actual cause (plan
    // compliance) has its own row below with its own "BLOCKING" text.
    const start = html.indexOf("Quality scan");
    const end = html.indexOf("</li>", start);
    expect(html.slice(start, end)).not.toMatch(/blocking/i);
  });

  it("flags a blocking finding under warn mode instead of showing a green checkmark", () => {
    // The round-9 regression: `quality.blocked` used to mirror `TestRun.quality_blocked`,
    // which only fires under [quality] enforce = "block" — under "warn" it stayed False
    // even with a blocking-severity finding, which ship_preflight still refuses to merge.
    // `blocking_count` (mode-agnostic) is what the receipt has to key off instead.
    const html = render(
      response({
        verdict: "red",
        quality: { measured: true, blocked: true, findings_count: 1, blocking_count: 1, note: "1 gitleaks", plan_compliance: { ran: false, error: null, compliant: true, confidence: null, summary: null, gaps: 0, blocking: false, enforced: false } },
      })
    );
    const row = rowHtml(html, "Quality scan");
    expect(row).toMatch(/class="trust-row trust-row-unmet"/);
    expect(html).toMatch(/1 finding\(s\) \(1 blocking\)/);
  });

  it("keeps the verified-hunks caveat note visible alongside a real percentage", () => {
    // The round-3 regression: the note (e.g. "N files changed since the gate ran") used
    // to be dropped entirely whenever a percentage existed, even though the percentage
    // itself already excludes those files — losing exactly the caveat a reviewer needs.
    const html = render(
      response({ verified_hunks: { supported: true, percentage: 66.7, untested_files: [], note: "2 of 3 added lines executed · 1 file changed since the gate ran" } })
    );
    expect(html).toMatch(/66\.7% of added lines executed/);
    expect(html).toMatch(/file changed since the gate ran/);
  });
});
