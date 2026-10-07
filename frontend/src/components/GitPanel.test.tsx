/** The trust checklist's visibility rule on ④ ship (notes/verify-redesign-plan.md):
 *  its only home now that ③ verify dropped its "trust" tab. Static render only
 *  (renderToStaticMarkup, no jsdom) — GitPanel's own data-fetching effects never run
 *  in this mode, so `status`/`pr` stay null and `green`/`merged` derive purely from
 *  the `gateStatus` prop, which is enough to exercise the visibility rule itself.
 */
import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { GitPanel } from "./GitPanel";
import type { TrustReport } from "../types";

const trustReport = (over: Partial<TrustReport> = {}): TrustReport => ({
  enabled: true,
  conditions: [],
  streak: 2,
  streak_required: 3,
  auto_action: "auto_pr",
  met: false,
  armed: false,
  ...over,
});

const render = (props: Partial<Parameters<typeof GitPanel>[0]> = {}) =>
  renderToStaticMarkup(
    <GitPanel workspaceId="w1" gateStatus="gate_red" onMerge={() => {}} {...props} />,
  );

describe("GitPanel — trust checklist visibility", () => {
  it("is absent entirely when the project isn't on the ladder", () => {
    const html = render({ gateStatus: "gate_red", trust: null });
    expect(html).not.toMatch(/gh-trust/);
  });

  it("is absent once merged, even with the ladder enabled", () => {
    const html = render({ gateStatus: "merged", trust: trustReport() });
    expect(html).not.toMatch(/class="gh-trust"/);
  });

  it("renders open (TrustChecklist's own head) while merge-blocked", () => {
    const html = render({ gateStatus: "gate_red", trust: trustReport() });
    expect(html).toMatch(/class="gh-trust"/);
    expect(html).toMatch(/trust-title/);
    expect(html).not.toMatch(/gh-trust-head/);
  });

  it("renders collapsed (a one-line summary) once green, not the full checklist", () => {
    const html = render({ gateStatus: "gate_green", trust: trustReport({ met: true, armed: true }) });
    expect(html).toMatch(/class="gh-trust"/);
    expect(html).toMatch(/gh-trust-head/);
    expect(html).not.toMatch(/trust-title/);
    expect(html).toMatch(/armed/);
  });

  it("the collapsed summary never says 'trust checklist' twice", () => {
    // Guards against the head + TrustChecklist's own head both rendering at once.
    const html = render({ gateStatus: "gate_green", trust: trustReport({ met: true, armed: true }) });
    expect((html.match(/trust checklist/g) ?? []).length).toBe(1);
  });

  it("shows an unmet count when neither met nor armed", () => {
    const html = render({
      gateStatus: "gate_green",
      trust: trustReport({
        met: false,
        armed: false,
        conditions: [
          { key: "no_tamper", met: false, detail: "d", required: true, fix: null },
        ],
      }),
    });
    expect(html).toMatch(/1 unmet/);
  });

});
