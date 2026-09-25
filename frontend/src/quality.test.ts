/**
 * The Double Gate's UI helpers (backlog/double-gate.md §2).
 *
 * Pure functions, so they pin the decisions rather than the markup: how findings group,
 * what routes to the agent, and — the one that matters most — that an advisory finding
 * below the severity threshold never masquerades as a blocker.
 */
import { describe, expect, it } from "vitest";

import {
  groupQualityFindings,
  qualityLocation,
  qualityReviewItems,
  qualitySummary,
  type QualityFindingRow,
} from "./gate";
import { flowSteps } from "./flow";

const f = (o: Partial<QualityFindingRow> = {}): QualityFindingRow => ({
  tool: "semgrep",
  severity: "medium",
  file: "src/a.ts",
  line: 3,
  rule: "rule",
  message: "msg",
  blocking: false,
  ...o,
});

describe("groupQualityFindings", () => {
  it("groups by tool and puts blocking groups first", () => {
    const groups = groupQualityFindings([
      f({ tool: "lint", blocking: false }),
      f({ tool: "lint", blocking: false }),
      f({ tool: "gitleaks", blocking: true, severity: "high" }),
    ]);
    expect(groups.map((g) => g.tool)).toEqual(["gitleaks", "lint"]);
    expect(groups[0].blocking).toBe(1);
    expect(groups[1].blocking).toBe(0);
  });

  it("is empty for no findings", () => {
    expect(groupQualityFindings([])).toEqual([]);
  });
});

describe("qualityLocation", () => {
  it("renders file:line for a located finding", () => {
    expect(qualityLocation(f({ file: "src/a.ts", line: 12 }))).toBe("src/a.ts:12");
  });

  it("falls back to the file when the tool reports at file scope", () => {
    expect(qualityLocation(f({ file: "src/a.ts", line: null }))).toBe("src/a.ts");
  });

  it("is empty for a diff-wide finding, so the UI can skip the deep-link", () => {
    expect(qualityLocation(f({ file: "", line: null }))).toBe("");
  });
});

describe("qualityReviewItems", () => {
  it("batches only BLOCKING findings by default", () => {
    // Sending advisory nits to the agent as a fix-everything task is how a quality gate
    // becomes busywork; below the threshold nothing is owed.
    const items = qualityReviewItems([
      f({ blocking: true, rule: "eval" }),
      f({ blocking: false, rule: "nit" }),
    ]);
    expect(items).toHaveLength(1);
    expect(items[0].target).toBe("semgrep: eval");
  });

  it("can opt into advisory findings too", () => {
    const items = qualityReviewItems([f({ blocking: false })], { includeAdvisory: true });
    expect(items).toHaveLength(1);
  });

  it("tells the agent to ROTATE a leaked secret, not just delete the line", () => {
    // Deleting the line doesn't un-leak a credential. A fix task that implies otherwise
    // teaches exactly the wrong lesson.
    const [item] = qualityReviewItems([f({ tool: "gitleaks", blocking: true })]);
    expect(item.text).toMatch(/rotate/i);
    expect(item.text).toMatch(/environment/i);
  });

  it("carries location and message as context for the agent", () => {
    const [item] = qualityReviewItems([
      f({ blocking: true, file: "src/x.ts", line: 9, message: "eval is dangerous" }),
    ]);
    expect(item.context).toContain("src/x.ts:9");
    expect(item.context).toContain("eval is dangerous");
  });
});

describe("qualitySummary", () => {
  it("is null when clean, so nothing renders", () => {
    expect(qualitySummary(0, 0, null)).toBeNull();
  });

  it("prefers the backend's note when there is one", () => {
    expect(qualitySummary(3, 1, "2 gitleaks · 1 lint")).toBe("2 gitleaks · 1 lint");
  });

  it("falls back to a count, flagging how many block", () => {
    expect(qualitySummary(1, 0, null)).toBe("1 finding");
    expect(qualitySummary(3, 2, null)).toBe("3 findings · 2 blocking");
  });
});

describe("the ③ verify step carries both signals", () => {
  const base = { status: "gate_green", hasEvents: true, filesChanged: 2, passed: 27, failed: 0 };
  const verify = (extra: object) =>
    flowSteps({ ...base, ...extra }).find((s) => s.key === "gate")!;

  it("shows quality ✓ beside the test tally when clean", () => {
    const step = verify({ qualityStatus: "clean" });
    expect(step.badge?.text).toBe("27✓ 0✗");
    expect(step.extra?.text).toBe("quality ✓");
    expect(step.extra?.tone).toBe("ok");
  });

  it("shows the blocking count and reads as bad when findings block", () => {
    const step = verify({ qualityStatus: "findings", qualityBlocking: 2 });
    expect(step.extra?.text).toBe("quality ✗ 2");
    expect(step.extra?.tone).toBe("bad");
  });

  it("stays a warning — not a failure — for advisory-only findings", () => {
    // Below the threshold nothing blocks, so painting the step red would make the
    // severity dial decorative.
    const step = verify({ qualityStatus: "findings", qualityBlocking: 0 });
    expect(step.extra?.tone).toBe("warn");
  });

  it("renders NOTHING when the project never opted in", () => {
    // An off feature should be invisible, not a permanent grey nag on every project.
    expect(verify({}).extra ?? null).toBeNull();
    expect(verify({ qualityStatus: null }).extra ?? null).toBeNull();
  });

  it("leaves the test tally alone in every case", () => {
    // The two verdicts must stay separately readable: folding "we found a secret" into
    // the passed/failed number would hide the one that matters.
    expect(verify({ qualityStatus: "findings", qualityBlocking: 5 }).badge?.text).toBe("27✓ 0✗");
  });
});
