import { describe, it, expect } from "vitest";
import type { Cell } from "./types";
import {
  failedCells,
  failureReviewItems,
  gateErrorFraming,
  coverageBlockHint,
  casesToCells,
  ribbonDot,
  tamperKindLabel,
  tamperSummary,
  tamperCountSummary,
  tamperFixHint,
  tamperReviewItems,
  mutationReviewItems,
  reviewMustFixItems,
  watchSummary,
  watchVerdict,
  uncheckedKindLabel,
  uncheckedSummary,
  uncheckedReviewItems,
  uncheckedFixHint,
  uncheckedState,
  uncheckedCoverageNote,
  UNCHECKED_KIND_LABEL,
  UNCHECKED_FIX_HINT,
} from "./gate";
import type { RibbonRun } from "./gate";
import type { MutationSurvivor, TamperFinding, TestCaseResult, UncheckedRow } from "./types";

const cell = (over: Partial<Cell>): Cell => ({
  id: over.id ?? "x",
  file: over.file ?? "a.test.ts",
  name: over.name ?? "test",
  status: over.status ?? "passed",
  duration_ms: over.duration_ms ?? null,
  message: over.message ?? null,
});

describe("failedCells", () => {
  it("keeps only failed cells, in order", () => {
    const cells = [
      cell({ id: "1", status: "passed" }),
      cell({ id: "2", status: "failed" }),
      cell({ id: "3", status: "skipped" }),
      cell({ id: "4", status: "failed" }),
      cell({ id: "5", status: "running" }),
    ];
    expect(failedCells(cells).map((c) => c.id)).toEqual(["2", "4"]);
  });

  it("returns empty when nothing failed", () => {
    expect(failedCells([cell({ status: "passed" })])).toEqual([]);
  });
});

describe("failureReviewItems", () => {
  it("builds one review item per failure, carrying the test name + message", () => {
    const items = failureReviewItems([
      cell({ name: "adds numbers", status: "failed", message: "expected 2 got 3" }),
      cell({ name: "passes", status: "passed" }),
      cell({ name: "no message", status: "failed", message: null }),
    ]);
    expect(items).toEqual([
      { target: "test: adds numbers", context: "expected 2 got 3" },
      { target: "test: no message", context: null },
    ]);
  });

  it("is empty when the gate is green", () => {
    expect(failureReviewItems([cell({ status: "passed" })])).toEqual([]);
  });
});

describe("casesToCells", () => {
  it("maps cases to cells with stable synthesized ids", () => {
    const cases: TestCaseResult[] = [
      { file: "a.test.ts", name: "one", status: "passed", duration_ms: 5, message: null },
      { file: "a.test.ts", name: "two", status: "failed", duration_ms: null, message: "boom" },
    ];
    const cells = casesToCells(cases);
    expect(cells.map((c) => c.id)).toEqual(["a.test.ts::one::0", "a.test.ts::two::1"]);
    expect(cells[1]).toMatchObject({ name: "two", status: "failed", message: "boom" });
    // ids are unique so the grid keys don't collide
    expect(new Set(cells.map((c) => c.id)).size).toBe(cells.length);
  });
});

describe("gateErrorFraming", () => {
  it("frames setup failures as 'the gate couldn’t run', not a test failure", () => {
    const f = gateErrorFraming("setup");
    expect(f.title).toMatch(/couldn.t run|setup/i);
    expect(f.hint).toMatch(/deps|dependencies|setup/i);
    // Covers command gates too: a non-launch should point at the gate command / tool.
    expect(f.hint).toMatch(/command|tool/i);
  });

  it("frames no_tests distinctly", () => {
    expect(gateErrorFraming("no_tests").title).toMatch(/no tests/i);
  });

  it("falls back to a runner-crash framing for runner/unknown", () => {
    expect(gateErrorFraming("runner").title).toMatch(/crash/i);
    expect(gateErrorFraming(null).title).toMatch(/crash/i);
  });

  it("frames a setup error on an adopted worktree as 'environment, not code'", () => {
    const f = gateErrorFraming("setup", true);
    expect(f.title).toMatch(/environment/i);
    expect(f.hint).toMatch(/adopted/i);
    expect(f.hint).toMatch(/not a test failure/i);
  });

  it("does not apply the adopted framing to non-setup errors", () => {
    // Only setup-kind errors are environment problems; a runner crash on an adopted
    // worktree is still a crash.
    expect(gateErrorFraming("runner", true).title).toMatch(/crash/i);
    expect(gateErrorFraming("no_tests", true).title).toMatch(/no tests/i);
  });

  it("keeps the plain setup framing for a managed worktree", () => {
    expect(gateErrorFraming("setup", false).title).toMatch(/couldn.t run|setup/i);
  });
});

describe("coverageBlockHint", () => {
  it("sends a measured drop to restoring coverage", () => {
    expect(coverageBlockHint(-2.5)).toMatch(/restore coverage/i);
  });

  it("sends an unmeasured guard to fixing the measurement, not the tests", () => {
    // "restore coverage" is unactionable when there was never a number to restore —
    // the fix is the reporting setup (backlog/gate.md).
    expect(coverageBlockHint(null)).toMatch(/coverage reporting/i);
    expect(coverageBlockHint(null)).not.toMatch(/restore/i);
  });
});

const finding = (over: Partial<TamperFinding>): TamperFinding => ({
  kind: over.kind ?? "removed",
  file: over.file ?? "a.test.ts",
  detail: over.detail ?? "",
  test: over.test ?? null,
});

describe("tamperKindLabel", () => {
  it("maps each known signal to its code-shaped tag", () => {
    expect(tamperKindLabel("removed")).toBe("removed");
    expect(tamperKindLabel("skip")).toBe(".skip");
    expect(tamperKindLabel("only")).toBe(".only");
    expect(tamperKindLabel("todo")).toBe(".todo");
    expect(tamperKindLabel("assertions")).toBe("assertions");
    expect(tamperKindLabel("snapshot")).toBe("snapshot");
  });

  it("falls through to the raw kind for an unknown/future signal", () => {
    expect(tamperKindLabel("mutant")).toBe("mutant");
  });
});

describe("tamperSummary", () => {
  it("prefers the backend note when present", () => {
    const note = "3 removed · 2 skipped · snapshots 84% of diff";
    expect(tamperSummary([finding({}), finding({ kind: "skip" })], note)).toBe(note);
  });

  it("falls back to a pluralized count when the note is null", () => {
    expect(tamperSummary([finding({}), finding({ kind: "skip" })], null)).toBe(
      "2 suspicious test changes",
    );
  });

  it("uses the singular for a single finding", () => {
    expect(tamperSummary([finding({})], null)).toBe("1 suspicious test change");
  });

  it("reads the same from a bare count (the dashboard's GateSummary form)", () => {
    // The dashboard only has tamper_count + tamper_note (no findings), so both surfaces
    // must word a green* identically — one language, two call shapes.
    expect(tamperCountSummary(2, null)).toBe(tamperSummary([finding({}), finding({ kind: "skip" })], null));
    expect(tamperCountSummary(2, "3 removed")).toBe("3 removed");
    expect(tamperCountSummary(1, null)).toBe("1 suspicious test change");
  });
});

describe("tamperFixHint", () => {
  it("names the removal for a deleted test", () => {
    expect(tamperFixHint("removed")).toMatch(/restore/i);
    expect(tamperFixHint("removed")).toMatch(/assertion/i);
  });

  it("tells the agent to take the modifier back out", () => {
    expect(tamperFixHint("skip")).toMatch(/\.skip/);
    expect(tamperFixHint("only")).toMatch(/\.only/);
    expect(tamperFixHint("todo")).toMatch(/\.todo/);
  });

  it("falls back to a generic restore for an unknown/future signal", () => {
    expect(tamperFixHint("mutant")).toMatch(/restore/i);
  });
});

describe("tamperReviewItems", () => {
  it("builds one prefilled review item per finding, keyed on the test name", () => {
    const items = tamperReviewItems([
      finding({ kind: "removed", file: "src/math.test.ts", test: "adds numbers", detail: "test removed" }),
      finding({ kind: "skip", file: "src/math.test.ts", test: "divides", detail: ".skip added" }),
    ]);
    expect(items).toEqual([
      {
        target: "removed: adds numbers",
        context: "test removed · src/math.test.ts",
        text: tamperFixHint("removed"),
      },
      {
        target: ".skip: divides",
        context: ".skip added · src/math.test.ts",
        text: tamperFixHint("skip"),
      },
    ]);
  });

  it("falls back to the file's basename when the finding carries no test name", () => {
    // assertion-delta findings are per-file, not per-test.
    const [item] = tamperReviewItems([
      finding({ kind: "assertions", file: "src/deep/math.test.ts", test: null, detail: "3 fewer expect() calls" }),
    ]);
    expect(item.target).toBe("assertions: math.test.ts");
    expect(item.context).toBe("3 fewer expect() calls · src/deep/math.test.ts");
  });

  it("uses the bare kind for a diff-wide finding with neither test nor file", () => {
    // Snapshot churn is a ratio over the whole diff (tamper.py sets file="").
    const [item] = tamperReviewItems([
      finding({ kind: "snapshot", file: "", test: null, detail: "snapshots 84% of diff" }),
    ]);
    expect(item.target).toBe("snapshot");
    expect(item.context).toBe("snapshots 84% of diff");
  });

  it("nulls the context when a finding carries no detail or file", () => {
    expect(tamperReviewItems([finding({ kind: "snapshot", file: "", test: null, detail: "" })])[0].context).toBeNull();
  });

  it("is empty for a clean green gate", () => {
    expect(tamperReviewItems([])).toEqual([]);
  });
});

// --- kill-the-survivors loop (usp-critique-plan.md idea 4) ------------------- //
describe("mutationReviewItems", () => {
  const survivor = (over: Partial<MutationSurvivor> = {}): MutationSurvivor => ({
    path: over.path ?? "src/discount.ts",
    line: over.line ?? 12,
    operator: over.operator ?? "round → floor",
  });

  it("builds one prefilled review item per survivor, keyed on file:line", () => {
    const items = mutationReviewItems([
      survivor({ path: "src/discount.ts", line: 12, operator: "round → floor" }),
      survivor({ path: "src/deep/tax.ts", line: 4, operator: "< → <=" }),
    ]);
    expect(items).toEqual([
      {
        target: "discount.ts:12",
        context: "src/discount.ts:12 · mutation survived: round → floor",
        text: expect.stringContaining("write a test that fails"),
      },
      {
        target: "tax.ts:4",
        context: "src/deep/tax.ts:4 · mutation survived: < → <=",
        text: expect.stringContaining("write a test that fails"),
      },
    ]);
  });

  it("asks for a new test, never a code fix — a survivor indicts the tests, not the code", () => {
    const [item] = mutationReviewItems([survivor()]);
    expect(item.text).not.toMatch(/fix the code/i);
    expect(item.text).toMatch(/write a test/i);
  });

  it("is empty when nothing survived", () => {
    expect(mutationReviewItems([])).toEqual([]);
  });
});

// --- the refuter's must-fix list → agent (Phase 3 of notes/workflow-roles-plan.md) - //
describe("reviewMustFixItems", () => {
  it("builds one prefilled review item per must-fix, with the cited diff line as context", () => {
    const items = reviewMustFixItems([
      { file: "src/discount.ts", line: 12, title: "off-by-one", detail: "excludes the last item", cited: "for (i = 0; i < xs.length - 1; i++)" },
      { file: "src/tax.ts", line: null, title: "missing null check", detail: "", cited: "+ x.value" },
    ]);
    expect(items).toEqual([
      { target: "src/discount.ts:12", context: "for (i = 0; i < xs.length - 1; i++)", text: "off-by-one — excludes the last item" },
      { target: "src/tax.ts", context: "+ x.value", text: "missing null check" },
    ]);
  });

  it("falls back to the bare file when there's no line", () => {
    const [item] = reviewMustFixItems([{ file: "a.ts", line: null, title: "x", detail: "", cited: "+ y" }]);
    expect(item.target).toBe("a.ts");
  });

  it("omits the ' — detail' suffix when there's no detail", () => {
    const [item] = reviewMustFixItems([{ file: "a.ts", line: 1, title: "x", detail: "", cited: "+ y" }]);
    expect(item.text).toBe("x");
  });

  it("is empty for an empty list", () => {
    expect(reviewMustFixItems([])).toEqual([]);
  });
});

// --- the regression ribbon (backlog/tamper-alarm.md §3) --------------------- //
// The ribbon is where you go to ask "was this workspace ever really green?", so a
// green* run has to stay marked in history — else the next clean run launders it.
describe("ribbonDot", () => {
  const run = (over: Partial<RibbonRun> = {}): RibbonRun => ({
    status: "passed",
    scope: "all",
    passed: 12,
    failed: 0,
    wall_ms: null,
    ...over,
  });

  it("draws a clean full-suite green as a plain passed dot", () => {
    const dot = ribbonDot(run());
    expect(dot.className).toBe("rdot rdot-passed");
    expect(dot.title).toBe("all · 12✓ 0✗");
  });

  it("marks an impacted-only run, so a partial green never looks full-suite", () => {
    expect(ribbonDot(run({ scope: "impacted" })).className).toBe("rdot rdot-passed rdot-impacted");
  });

  it("stars a green* run and names the reason in the tooltip", () => {
    const dot = ribbonDot(
      run({
        tamper_findings: [finding({ kind: "removed" }), finding({ kind: "skip" })],
        tamper_note: "2 removed · 1 skipped",
      }),
    );
    // Still a pass dot — warn mode doesn't change the verdict, it annotates it.
    expect(dot.className).toBe("rdot rdot-passed rdot-star");
    expect(dot.title).toBe("all · 12✓ 0✗ · green* · 2 removed · 1 skipped");
  });

  it("falls back to a finding count when the run carries no note", () => {
    expect(ribbonDot(run({ tamper_findings: [finding({})] })).title).toBe(
      "all · 12✓ 0✗ · green* · 1 suspicious test change",
    );
  });

  it("names the alarm on a block-mode red, so it isn't mistaken for a test failure", () => {
    const dot = ribbonDot(
      run({
        status: "failed",
        tamper_findings: [finding({ kind: "only" })],
        tamper_note: "1 .only added",
        tamper_blocked: true,
      }),
    );
    expect(dot.className).toBe("rdot rdot-failed rdot-star rdot-star-block");
    // Keeps the banner's "green*" wording (same signal, same words everywhere) but says
    // outright that the alarm, not a failing test, is what turned this dot red.
    expect(dot.title).toBe("all · 12✓ 0✗ · green* · blocked by the tamper alarm · 1 .only added");
  });

  it("leaves a genuine red unstarred", () => {
    // A red gate skips the alarm entirely (it's already blocked), so no findings.
    expect(ribbonDot(run({ status: "failed", passed: 9, failed: 3 })).className).toBe("rdot rdot-failed");
  });

  it("stars nothing for a run with an empty findings list", () => {
    expect(ribbonDot(run({ tamper_findings: [], tamper_note: null })).className).not.toContain("rdot-star");
  });

  it("survives a run persisted before the alarm existed (no tamper fields)", () => {
    // db.py hydrates old TestRun rows without the tamper trio; the dot must not blow up.
    const { tamper_findings, ...legacy } = run({ tamper_findings: [] });
    expect(ribbonDot(legacy).className).toBe("rdot rdot-passed");
    expect(tamper_findings).toEqual([]);
  });

  it("appends wall time and the selection ring when asked", () => {
    const dot = ribbonDot(run({ wall_ms: 431.7 }), true);
    expect(dot.className).toBe("rdot rdot-passed rdot-sel");
    expect(dot.title).toBe("all · 12✓ 0✗ · 432ms");
  });
});

// --- Live Gate (backlog/live-gate.md) --------------------------------------- //
// The rail's advisory verdict. Its vocabulary is deliberately NOT the gate's
// green/red: an impacted-only advisory run can't ship anything, so it must not
// borrow the words that mean "mergeable".
describe("watchVerdict", () => {
  it("is off when [gate] watch is disabled, whatever else is around", () => {
    expect(watchVerdict(false, [cell({ status: "failed" })], { status: "failed" })).toBe("off");
  });

  it("is idle when enabled but nothing has run yet", () => {
    expect(watchVerdict(true, [], null)).toBe("idle");
  });

  it("is running while any cell is still in flight", () => {
    expect(watchVerdict(true, [cell({}), cell({ id: "b", status: "running" })], null)).toBe("running");
  });

  it("prefers failing over running-out-of-order cells that already settled red", () => {
    // A failure is the actionable signal — don't hide it behind "running…" once seen.
    expect(watchVerdict(true, [cell({ id: "b", status: "failed" })], null)).toBe("failing");
  });

  it("is passing when every settled cell passed", () => {
    expect(watchVerdict(true, [cell({}), cell({ id: "b" })], { status: "passed" })).toBe("passing");
  });

  it("is errored when the runner couldn't run at all", () => {
    expect(watchVerdict(true, [], { status: "error" })).toBe("errored");
  });

  it("reads a cold rehydrate off the run alone (no cells yet)", () => {
    // After a reload GET /watch returns the run; cells are backfilled from its cases,
    // but a cases-free run must still produce a verdict rather than looking idle.
    expect(watchVerdict(true, [], { status: "passed" })).toBe("passing");
    expect(watchVerdict(true, [], { status: "failed" })).toBe("failing");
  });
});

describe("watchSummary", () => {
  const run = (over = {}) => ({ passed: 0, failed: 0, total: 0, wall_ms: null, ...over });

  it("always names the scope — the panel must never imply full-suite coverage", () => {
    // This is the line that keeps an advisory green from reading as shippable.
    expect(watchSummary([cell({})], run())).toContain("impacted");
  });

  it("counts live cells while a run streams, and omits the timing until it settles", () => {
    const summary = watchSummary(
      [cell({}), cell({ id: "b", status: "failed" }), cell({ id: "c", status: "running" })],
      run({ wall_ms: 1200 }),
    );
    expect(summary).toBe("1 passing · 1 failing · impacted");
  });

  it("adds wall time once the run has settled", () => {
    expect(watchSummary([cell({})], run({ wall_ms: 1240 }))).toBe("1 passing · impacted · 1.2s");
  });

  it("falls back to the run's counts on a cold rehydrate with no cells", () => {
    expect(watchSummary([], run({ passed: 7, failed: 2, total: 9 }))).toBe(
      "7 passing · 2 failing · impacted",
    );
  });

  it("omits the failing clause when nothing is red", () => {
    expect(watchSummary([], run({ passed: 3, total: 3 }))).toBe("3 passing · impacted");
  });
});

// --- Code to check (backlog/code-to-check.md) ------------------------------- //
describe("uncheckedKindLabel", () => {
  it("labels each row literally, so the pane title carries the imperative", () => {
    expect(uncheckedKindLabel("no_test_file")).toBe("no test imports");
    expect(uncheckedKindLabel("untested_lines")).toBe("no test ran");
    expect(uncheckedKindLabel("new_dep")).toBe("new dependency");
    expect(uncheckedKindLabel("secret")).toBe("secret touched");
    expect(uncheckedKindLabel("suite_weakened")).toBe("suite weakened");
    expect(uncheckedKindLabel("assertion_rewritten")).toBe("assertion rewritten");
  });

  it("words a rewritten assertion as a change, not an accusation", () => {
    // It is equally what a deliberate contract change looks like, which is why it's a row
    // here and never part of green*. A loaded label would make an honest edit read as a cheat.
    const label = uncheckedKindLabel("assertion_rewritten");
    const hint = uncheckedFixHint("assertion_rewritten");
    expect(`${label} ${hint}`.toLowerCase()).not.toMatch(/tamper|gam(e|ed|ing)|cheat|weakened/);
    expect(hint).toMatch(/confirm/i);
  });

  it("never claims anything is proven or verified", () => {
    // The whole naming law: a hit count means EXECUTED, not asserted about. A positive
    // word here would become the metric an agent games.
    const all = Object.values(UNCHECKED_KIND_LABEL).join(" ").toLowerCase();
    expect(all).not.toMatch(/proven|verified|vouched|safe/);
  });

  it("falls through to the raw kind for a future signal", () => {
    expect(uncheckedKindLabel("mutation_survived")).toBe("mutation_survived");
  });
});

describe("uncheckedSummary", () => {
  const row = (over: Partial<UncheckedRow> = {}): UncheckedRow => ({
    kind: "no_test_file", file: "src/a.ts", detail: "", count: 0, key: "k", ...over,
  });

  it("prefers the backend note", () => {
    expect(uncheckedSummary([row()], "3 files no test imports · 1 dep change"))
      .toBe("3 files no test imports · 1 dep change");
  });

  it("falls back to a pluralized count", () => {
    expect(uncheckedSummary([row(), row()], null)).toBe("2 things to look at");
    expect(uncheckedSummary([row()], null)).toBe("1 thing to look at");
  });
});

describe("uncheckedReviewItems", () => {
  const row = (over: Partial<UncheckedRow> = {}): UncheckedRow => ({
    kind: "no_test_file", file: "frontend/src/components/CodePanel.tsx",
    detail: "no test imports this file (142 added lines)", count: 142, key: "k", ...over,
  });

  it("builds a sendable item per row, prefilled because the row IS the ask", () => {
    const [item] = uncheckedReviewItems([row()]);
    expect(item.target).toBe("no test imports: CodePanel.tsx");
    expect(item.context).toBe(
      "no test imports this file (142 added lines) · frontend/src/components/CodePanel.tsx",
    );
    expect(item.text).toMatch(/add a test/i);
  });

  it("asks for a test only where a test is the answer", () => {
    // A touched secret or a new dependency wants a human's eyes, not coverage. Asking for
    // a test there is how a signal trains people to ignore it.
    expect(uncheckedFixHint("secret")).not.toMatch(/add a test/i);
    expect(uncheckedFixHint("new_dep")).not.toMatch(/add a test/i);
    expect(uncheckedFixHint("secret")).toMatch(/nothing secret was committed/i);
    expect(uncheckedFixHint("no_test_file")).toMatch(/add a test/i);
  });

  it("falls back to a generic confirm for an unknown kind", () => {
    expect(uncheckedFixHint("whatever")).toMatch(/nothing checked it/i);
  });

  it("uses the bare label when a row carries no file", () => {
    const [item] = uncheckedReviewItems([row({ file: "", kind: "suite_weakened" })]);
    expect(item.target).toBe("suite weakened");
  });

  it("is empty for a clean run", () => {
    expect(uncheckedReviewItems([])).toEqual([]);
  });
});

describe("uncheckedState", () => {
  const row = (over: Partial<UncheckedRow> = {}): UncheckedRow => ({
    kind: "untested_lines", file: "src/a.ts", detail: "3 never ran", count: 3,
    key: "untested_lines|src/a.ts|3", ...over,
  });
  const base = { enabled: true, status: "passed", scope: "all" };

  it("is off when the project has not opted in", () => {
    expect(uncheckedState({ ...base, enabled: false }).kind).toBe("off");
  });

  it("says nothing measured while the gate is still running", () => {
    expect(uncheckedState({ ...base, status: "running" }).kind).toBe("unmeasured");
    expect(uncheckedState({ ...base, status: null }).kind).toBe("unmeasured");
  });

  it("does NOT render the clean state over a red gate", () => {
    // The bug this function exists to kill: rows are absent because nothing looked, and
    // the pane used to read that as "every changed line ran".
    const s = uncheckedState({ ...base, status: "failed", rows: null });
    expect(s.kind).toBe("unmeasured");
    if (s.kind === "unmeasured") expect(s.reason).toMatch(/red/);
  });

  it("names the impacted-only run as the reason, since the fix is different", () => {
    const s = uncheckedState({ ...base, scope: "impacted", rows: null });
    if (s.kind !== "unmeasured") throw new Error("expected unmeasured");
    expect(s.reason).toMatch(/full gate/);
  });

  it("is clean only when coverage actually watched files run", () => {
    const s = uncheckedState({ ...base, rows: [], coveredFiles: 4 });
    expect(s).toEqual({ kind: "clean", files: 4 });
  });

  it("is quiet, not clean, when no coverage provider answered", () => {
    const s = uncheckedState({ ...base, rows: [], coveredFiles: null });
    expect(s.kind).toBe("quiet");
  });

  it("is quiet, not clean, when the map held nothing from this diff", () => {
    // A Python change under a vitest gate: zero rows is correct AND uninformative, and on
    // this repo's own history that was the majority of "clean" panes.
    const s = uncheckedState({ ...base, rows: [], coveredFiles: 0 });
    expect(s.kind).toBe("quiet");
    if (s.kind === "quiet") expect(s.reason).toMatch(/none of the changed files/);
  });

  it("splits ticked rows out of the pending list without deleting them", () => {
    const a = row();
    const b = row({ kind: "new_dep", file: "package.json", count: 0, key: "new_dep|package.json|x" });
    const s = uncheckedState({ ...base, rows: [a, b], coveredFiles: 2, checkedKeys: [b.key] });
    if (s.kind !== "rows") throw new Error("expected rows");
    expect(s.pending).toEqual([a]);
    expect(s.done).toEqual([b]);
  });

  it("keeps the rows state when every row is ticked, so the answers stay visible", () => {
    const a = row();
    const s = uncheckedState({ ...base, rows: [a], coveredFiles: 1, checkedKeys: [a.key] });
    if (s.kind !== "rows") throw new Error("expected rows");
    expect(s.pending).toEqual([]);
    expect(s.done).toEqual([a]);
  });

  it("carries the coverage caveat alongside rows when the coverage half was blind", () => {
    const s = uncheckedState({ ...base, rows: [row({ kind: "new_dep" })], coveredFiles: null });
    if (s.kind !== "rows") throw new Error("expected rows");
    expect(s.coverage).toMatch(/no coverage data/);
  });

  it("adds no caveat when coverage did its job", () => {
    const s = uncheckedState({ ...base, rows: [row()], coveredFiles: 3 });
    if (s.kind !== "rows") throw new Error("expected rows");
    expect(s.coverage).toBeNull();
  });
});

describe("uncheckedCoverageNote", () => {
  it("distinguishes no map from a map that said nothing", () => {
    expect(uncheckedCoverageNote(null)).toMatch(/no coverage data/);
    expect(uncheckedCoverageNote(0)).toMatch(/executed none/);
    expect(uncheckedCoverageNote(5)).toBeNull();
  });

  it("never claims anything was verified", () => {
    const all = [uncheckedCoverageNote(null), uncheckedCoverageNote(0)].join(" ");
    expect(all.toLowerCase()).not.toMatch(/proven|verified|vouched|safe/);
  });
});

describe("code-to-check copy", () => {
  it("uses no em dashes anywhere the user reads it", () => {
    // House rule for haro's UI voice: a full stop or a comma, never a dash holding two
    // clauses together. Pinned as a test because copy drifts back one string at a time.
    const copy = [
      ...Object.values(UNCHECKED_KIND_LABEL),
      ...Object.values(UNCHECKED_FIX_HINT),
      uncheckedCoverageNote(null) ?? "",
      uncheckedCoverageNote(0) ?? "",
      ...["failed", "passed"].flatMap((status) =>
        ["all", "impacted"].map((scope) => {
          const s = uncheckedState({ enabled: true, status, scope, rows: null });
          return s.kind === "unmeasured" ? s.reason : "";
        }),
      ),
    ].join(" ");
    expect(copy).not.toMatch(/[—–]/);
  });
});
