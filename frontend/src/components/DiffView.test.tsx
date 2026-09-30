import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { DiffView } from "./DiffView";
import type { DiffResponse, VerifiedHunksResponse } from "../types";

/**
 * Render-level checks for Verified Hunks (backlog/verified-hunks.md §3).
 *
 * The pure tallying + copy lives in `verifiedHunks.test.ts`; what matters here is the
 * *contract with the existing diff*: pass no proof and the surface must be byte-identical to
 * what shipped before, because a regression in the plain diff would be a far worse trade than
 * anything this feature buys. Static markup only (no jsdom), the `TrustChecklist.test.tsx`
 * pattern — effects don't run, so this asserts the initial render, not the collapse seeding.
 */
const RAW = [
  "diff --git a/src/math.ts b/src/math.ts",
  "--- a/src/math.ts",
  "+++ b/src/math.ts",
  "@@ -1,2 +1,4 @@",
  " const zero = 0",
  "+export const add = (a, b) => a + b",
  "+export const wild = () => { throw new Error('cold') }",
  "+// a comment",
  " export default zero",
  "",
].join("\n");

const diff: DiffResponse = { base_ref: "main", diff: RAW, files_changed: 1 };

function proof(over: Partial<VerifiedHunksResponse> = {}): VerifiedHunksResponse {
  return {
    base_ref: "main",
    gate_sha: "abc1234",
    supported: true,
    stale: false,
    note: "1 of 3 added lines executed · 1 never executed",
    files: [
      {
        path: "src/math.ts",
        in_map: true,
        stale: false,
        added: 3,
        executed: 1,
        unexecuted: 1,
        noncoverable: 1,
        // line 2 ran, line 3 never ran, line 4 is the comment (non-coverable)
        lines: { "2": 4, "3": 0, "4": null },
      },
    ],
    ...over,
  };
}

describe("DiffView without proof", () => {
  const html = renderToStaticMarkup(<DiffView diff={diff} />);

  it("renders no badge, no dot column and no proof line", () => {
    expect(html).not.toContain("diff-proof");
    expect(html).not.toContain("diff-dot");
    expect(html).not.toContain("diff-sort-toggle");
  });

  it("still renders the diff itself", () => {
    expect(html).toContain("diff-file-header");
    expect(html).toContain("export const add");
  });
});

describe("DiffView with proof", () => {
  const html = renderToStaticMarkup(<DiffView diff={diff} verified={proof()} />);

  it("shows the residue count in the badge, not a verified claim", () => {
    expect(html).toContain("1 of 3 added lines never executed");
    expect(html.toLowerCase()).not.toMatch(/verified|proven|correct/);
  });

  it("draws a filled dot for the executed line and a hollow one for the cold line", () => {
    expect(html).toContain("dot-hit");
    expect(html).toContain("dot-cold");
  });

  it("draws no dot for the comment line — a dot is a claim", () => {
    // 3 added lines + 2 context lines + the hunk header spacer = 6 dot cells, of which
    // exactly one is `hit` and one is `cold`; the rest are deliberately blank.
    const hit = html.match(/dot-hit/g)?.length ?? 0;
    const cold = html.match(/dot-cold/g)?.length ?? 0;
    expect([hit, cold]).toEqual([1, 1]);
  });

  it("offers the untested-first sort and the executed ≠ asserted tooltip", () => {
    expect(html).toContain("diff-sort-toggle");
    expect(html).toContain("executed ≠ asserted");
  });

  it("shows the gate's own summary line", () => {
    expect(html).toContain("1 of 3 added lines executed");
  });
});

describe("DiffView with stale proof", () => {
  const stale = proof({
    stale: true,
    note: "1 file changed since the gate ran",
    files: [
      {
        path: "src/math.ts",
        in_map: true,
        stale: true,
        added: 3,
        executed: 0,
        unexecuted: 0,
        noncoverable: 0,
        lines: {},
      },
    ],
  });
  const html = renderToStaticMarkup(<DiffView diff={diff} verified={stale} />);

  it("says the gate ran on an older tree and draws no dots", () => {
    expect(html).toContain("the gate ran on an older tree");
    expect(html).not.toContain("dot-hit");
    expect(html).not.toContain("dot-cold");
  });
});

describe("DiffView residue action", () => {
  it("offers the agent hand-off only when there is a residue to review", () => {
    const withResidue = renderToStaticMarkup(
      <DiffView diff={diff} verified={proof()} onReviewResidue={() => {}} />,
    );
    expect(withResidue).toContain("review the residue → agent (1)");

    const clean = proof({
      note: "3 of 3 added lines executed",
      files: [
        {
          path: "src/math.ts",
          in_map: true,
          stale: false,
          added: 3,
          executed: 2,
          unexecuted: 0,
          noncoverable: 1,
          lines: { "2": 4, "3": 1, "4": null },
        },
      ],
    });
    const html = renderToStaticMarkup(
      <DiffView diff={diff} verified={clean} onReviewResidue={() => {}} />,
    );
    expect(html).not.toContain("review the residue");
    expect(html).toContain("executed by the green suite");
  });
});
