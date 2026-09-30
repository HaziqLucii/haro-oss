import { describe, it, expect } from "vitest";
import type { Cell, QualityFindingRow, TamperFinding, TestRun, UncheckedRow } from "./types";
import {
  blockers,
  codeToCheckCaveat,
  gateVerdict,
  isCantShip,
  lookAt,
  lookAtReviewItems,
  reviewCaveat,
  statusForRun,
  tally,
  verdictBadge,
  verdictFlowState,
} from "./verdict";
import type { ReviewVerdict } from "./types";

const reviewVerdict = (over: Partial<ReviewVerdict> = {}): ReviewVerdict => ({
  ran_at: 0,
  model: "opus",
  verdict: "pass",
  summary: "",
  must_fix: [],
  notes: [],
  error: null,
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

describe("tally", () => {
  it("counts cells by status and derives inflight from what's not settled", () => {
    const t = tally([
      cell({ id: "1", status: "passed" }),
      cell({ id: "2", status: "failed" }),
      cell({ id: "3", status: "skipped" }),
      cell({ id: "4", status: "running" }),
    ]);
    expect(t).toEqual({ passed: 1, failed: 1, skipped: 1, inflight: 1, total: 4 });
  });

  it("is all zero for an empty grid", () => {
    expect(tally([])).toEqual({ passed: 0, failed: 0, skipped: 0, inflight: 0, total: 0 });
  });
});

describe("statusForRun", () => {
  it("is none for a null run", () => {
    expect(statusForRun(null)).toBe("none");
  });
  it("reads the run's own status", () => {
    expect(statusForRun(run({ status: "running" }))).toBe("running");
    expect(statusForRun(run({ status: "error" }))).toBe("error");
    expect(statusForRun(run({ status: "failed" }))).toBe("failed");
    expect(statusForRun(run({ status: "passed" }))).toBe("passed");
  });
});

describe("isCantShip", () => {
  it("is true for any red gate", () => {
    expect(isCantShip("gate_red", null)).toBe(true);
  });
  it("is false for a clean green", () => {
    expect(isCantShip("gate_green", run())).toBe(false);
  });
  it("is true for a green gate that's degraded — the bug this fixes", () => {
    expect(isCantShip("gate_green", run({ degraded_reasons: ["quality scanner not installed"] }))).toBe(true);
  });
  it("is false for idle/running/merged", () => {
    expect(isCantShip("idle", null)).toBe(false);
    expect(isCantShip("tests_running", null)).toBe(false);
    expect(isCantShip("merged", null)).toBe(false);
  });
});

describe("verdictFlowState — degraded blocks like a red gate", () => {
  it("a red gate blocks, with or without a run", () => {
    expect(verdictFlowState("gate_red")).toBe("blocked");
    expect(verdictFlowState("gate_red", run({ status: "failed", passed: 3, failed: 2 }))).toBe("blocked");
  });
  it("a clean green is done", () => {
    expect(verdictFlowState("gate_green", run())).toBe("done");
  });
  it("a degraded green is blocked, not done", () => {
    expect(verdictFlowState("gate_green", run({ degraded_reasons: ["plan compliance skipped"] }))).toBe("blocked");
  });
  it("running is active, merged is done, idle is todo — unchanged from before", () => {
    expect(verdictFlowState("tests_running")).toBe("active");
    expect(verdictFlowState("merged")).toBe("done");
    expect(verdictFlowState("idle")).toBe("todo");
  });
});

describe("verdictBadge — byte-identical to the old flow.ts logic when run/cells are absent", () => {
  it("shows the pass/fail tally once tests have run", () => {
    expect(verdictBadge({ status: "gate_red", passed: 3, failed: 2 })).toEqual({ text: "3✓ 2✗", tone: "bad" });
    expect(verdictBadge({ status: "gate_green", passed: 5, failed: 0 })).toEqual({ text: "5✓ 0✗", tone: "ok" });
  });
  it("falls back to a single word with no tally", () => {
    expect(verdictBadge({ status: "gate_red" })).toEqual({ text: "failed", tone: "bad" });
    expect(verdictBadge({ status: "gate_green" })).toEqual({ text: "passed", tone: "ok" });
  });
  it("plain gate… while running, with no cells", () => {
    expect(verdictBadge({ status: "tests_running" })).toEqual({ text: "gate…", tone: "run" });
  });
});

describe("verdictBadge — new behaviour once run/cells are supplied", () => {
  it("shows live progress while running: settled of total", () => {
    const cells = [
      cell({ id: "1", status: "passed" }),
      cell({ id: "2", status: "passed" }),
      cell({ id: "3", status: "passed" }),
      cell({ id: "4", status: "running" }),
      cell({ id: "5", status: "running" }),
      cell({ id: "6", status: "running" }),
      cell({ id: "7", status: "running" }),
      cell({ id: "8", status: "running" }),
      cell({ id: "9", status: "running" }),
    ];
    expect(verdictBadge({ status: "tests_running", cells })).toEqual({ text: "gate… 3/9", tone: "run" });
  });

  it("ends the badge with * on a starred green (the tamper alarm found something)", () => {
    const tampered = run({ passed: 5, failed: 0, tamper_findings: [{ kind: "skip", file: "a.ts", detail: "", test: null }] });
    expect(verdictBadge({ status: "gate_green", run: tampered })).toEqual({ text: "5✓ 0✗*", tone: "ok" });
  });

  it("stars the no-tally fallback too", () => {
    const tampered = run({ passed: 0, failed: 0, total: 0, tamper_findings: [{ kind: "only", file: "a.ts", detail: "", test: null }] });
    expect(verdictBadge({ status: "gate_green", run: tampered })).toEqual({ text: "passed*", tone: "ok" });
  });

  it("says the gate didn't run, distinct from tests failing", () => {
    const errored = run({ status: "error", error_kind: "setup", passed: 0, failed: 0 });
    expect(verdictBadge({ status: "gate_red", run: errored })).toEqual({ text: "didn't run", tone: "bad" });
  });

  it("a genuine test failure still says failed, not didn't run", () => {
    const failing = run({ status: "failed", passed: 3, failed: 2 });
    expect(verdictBadge({ status: "gate_red", run: failing })).toEqual({ text: "3✓ 2✗", tone: "bad" });
  });
});

describe("blockers — fixed order, gate_error short-circuits everything else", () => {
  it("is empty with no run", () => {
    expect(blockers({ status: "gate_red", run: null, cells: [] })).toEqual([]);
  });

  it("a gate error is the only blocker, since nothing else could be judged", () => {
    const b = blockers({ status: "gate_red", run: run({ status: "error", error_kind: "runner" }), cells: [] });
    expect(b.map((x) => x.kind)).toEqual(["gate_error"]);
  });

  it("an adopted worktree's setup error offers re-run setup", () => {
    const b = blockers({
      status: "gate_red",
      run: run({ status: "error", error_kind: "setup" }),
      cells: [],
      adopted: true,
    });
    expect(b[0].fix).toEqual({ label: "re-run setup", action: "rerun_setup" });
  });

  it("orders every other blocker: failing, merge, tamper, quality, coverage, degraded", () => {
    const r = run({
      status: "failed",
      passed: 3,
      failed: 2,
      merge_conflict: true,
      merge_note: "conflict",
      tamper_blocked: true,
      tamper_findings: [{ kind: "removed", file: "a.ts", detail: "", test: null }],
      quality_blocked: true,
      quality_findings: [{ tool: "gitleaks", severity: "high", file: "a.ts", line: 1, rule: "secret", message: "m", blocking: true }],
      coverage_blocked: true,
      coverage_note: "-5%",
      degraded_reasons: ["plan compliance skipped"],
    });
    const b = blockers({ status: "gate_red", run: r, cells: [] });
    expect(b.map((x) => x.kind)).toEqual([
      "failing_tests",
      "merge_conflict",
      "tamper_blocked",
      "quality_blocked",
      "coverage_blocked",
      "degraded",
    ]);
  });

  it("a merge conflict has no fix — there's nothing to send to the agent", () => {
    const b = blockers({ status: "gate_red", run: run({ status: "failed", merge_conflict: true, merge_note: "x" }), cells: [] });
    expect(b.find((x) => x.kind === "merge_conflict")?.fix).toBeNull();
  });

  it("a clean green has no blockers", () => {
    expect(blockers({ status: "gate_green", run: run(), cells: [] })).toEqual([]);
  });

  it("names the plan-compliance gaps when they, not a deterministic finding, caused the block", () => {
    const r = run({
      quality_blocked: true,
      quality_findings: [],
      plan_compliance: {
        ran_at: 0, model: "x", compliant: false, confidence: "high", summary: "",
        gaps: [{ item: "auth check", why: "missing", cited: "a.ts:1" }], error: null,
      },
    });
    const b = blockers({ status: "gate_red", run: r, cells: [] });
    expect(b.find((x) => x.kind === "quality_blocked")?.text).toBe("1 plan requirement not implemented");
  });

  it("still names the plan gaps even when a deterministic finding is ALSO present, so nothing drops silently", () => {
    // The bug this pins: a blocking scanner finding must not swallow a plan gap out of
    // the UI entirely just because it already gave qualitySummary() something to say.
    const r = run({
      quality_blocked: true,
      quality_findings: [
        { tool: "gitleaks", severity: "high", file: "a.ts", line: 1, rule: "secret", message: "m", blocking: true },
        { tool: "semgrep", severity: "low", file: "b.ts", line: 2, rule: "nit", message: "m", blocking: false },
      ],
      plan_compliance: {
        ran_at: 0, model: "x", compliant: false, confidence: "high", summary: "",
        gaps: [
          { item: "auth check", why: "missing", cited: "a.ts:1" },
          { item: "rate limit", why: "missing", cited: "a.ts:5" },
        ],
        error: null,
      },
    });
    const b = blockers({ status: "gate_red", run: r, cells: [] });
    expect(b.find((x) => x.kind === "quality_blocked")?.text).toBe("2 findings · 1 blocking · 2 plan requirements not implemented");
  });
});

describe("blockers — the refuter (Phase 3 of notes/workflow-roles-plan.md)", () => {
  it("blocks with the must-fix count and the verdict's summary", () => {
    const r = run({
      review_blocked: true,
      review: reviewVerdict({
        verdict: "fail", summary: "off-by-one in the loop",
        must_fix: [{ file: "a.ts", line: 3, title: "off-by-one", detail: "", cited: "+ x" }],
      }),
    });
    const b = blockers({ status: "gate_red", run: r, cells: [] });
    expect(b.find((x) => x.kind === "review_blocked")?.text).toBe(
      "review: 1 must-fix finding — off-by-one in the loop",
    );
    expect(b.find((x) => x.kind === "review_blocked")?.fix).toEqual({
      label: "fix all → agent", action: "fix_review",
    });
  });

  it("sits in the fixed order between quality_blocked and coverage_blocked", () => {
    const r = run({
      status: "failed", passed: 3, failed: 2,
      quality_blocked: true,
      quality_findings: [{ tool: "gitleaks", severity: "high", file: "a.ts", line: 1, rule: "secret", message: "m", blocking: true }],
      review_blocked: true,
      review: reviewVerdict({ verdict: "fail", must_fix: [{ file: "a.ts", line: 1, title: "x", detail: "", cited: "+ y" }] }),
      coverage_blocked: true,
      coverage_note: "-5%",
    });
    const b = blockers({ status: "gate_red", run: r, cells: [] });
    expect(b.map((x) => x.kind)).toEqual([
      "failing_tests", "quality_blocked", "review_blocked", "coverage_blocked",
    ]);
  });

  it("a warn-mode fail (review_blocked false) is not a blocker at all", () => {
    const r = run({
      review_blocked: false,
      review: reviewVerdict({ verdict: "fail", must_fix: [{ file: "a.ts", line: 1, title: "x", detail: "", cited: "+ y" }] }),
    });
    expect(blockers({ status: "gate_green", run: r, cells: [] })).toEqual([]);
  });

  it("a clean pass is not a blocker", () => {
    const r = run({ review: reviewVerdict() });
    expect(blockers({ status: "gate_green", run: r, cells: [] })).toEqual([]);
  });
});

describe("lookAt — advisory-only, never duplicates a blocker", () => {
  const row = (over: Partial<UncheckedRow> = {}): UncheckedRow => ({
    kind: "no_test_file",
    file: "src/a.ts",
    detail: "",
    count: 1,
    key: "k1",
    ...over,
  });

  it("is empty with no run", () => {
    expect(lookAt({ status: "gate_green", run: null, cells: [] })).toEqual({ pending: [], done: [] });
  });

  it("lists pending code-to-check rows only when the feature is enabled", () => {
    const r = run({ unchecked_items: [row()], unchecked_covered_files: 2 });
    const off = lookAt({ status: "gate_green", run: r, cells: [] });
    expect(off.pending).toEqual([]);
    const on = lookAt({ status: "gate_green", run: r, cells: [], codeToCheck: { enabled: true } });
    expect(on.pending.map((i) => i.kind)).toEqual(["code_to_check"]);
  });

  it("splits ticked code-to-check rows into done without losing them", () => {
    const a = row({ key: "a" });
    const b = row({ key: "b", kind: "new_dep", file: "package.json" });
    const r = run({ unchecked_items: [a, b], unchecked_covered_files: 2 });
    const la = lookAt({ status: "gate_green", run: r, cells: [], codeToCheck: { enabled: true }, checkedKeys: ["b"] });
    expect(la.pending.map((i) => i.key)).toEqual(["a"]);
    expect(la.done.map((i) => i.key)).toEqual(["b"]);
  });

  it("includes tamper findings only in warn mode, never when they already blocked the gate", () => {
    const finding: TamperFinding = { kind: "skip", file: "a.ts", detail: "", test: "adds numbers" };
    const warn = lookAt({ status: "gate_green", run: run({ tamper_findings: [finding], tamper_blocked: false }), cells: [] });
    expect(warn.pending.map((i) => i.kind)).toEqual(["tamper"]);
    const blocked = lookAt({ status: "gate_red", run: run({ status: "failed", tamper_findings: [finding], tamper_blocked: true }), cells: [] });
    expect(blocked.pending).toEqual([]);
  });

  it("includes only non-blocking quality findings — blocking ones already live in Zone 2", () => {
    const findings: QualityFindingRow[] = [
      { tool: "semgrep", severity: "low", file: "a.ts", line: 1, rule: "nit", message: "m", blocking: false },
      { tool: "gitleaks", severity: "high", file: "b.ts", line: 2, rule: "secret", message: "m", blocking: true },
    ];
    const la = lookAt({ status: "gate_green", run: run({ quality_findings: findings, quality_blocked: true }), cells: [] });
    expect(la.pending.map((i) => i.kind)).toEqual(["quality"]);
  });

  it("keeps a severity-blocking finding in Zone 3 when enforce=warn never made the run quality_blocked", () => {
    // The bug this pins: f.blocking is severity-vs-threshold, independent of
    // [quality] enforce. Under enforce="warn", quality_blocked stays false even for a
    // high-severity finding, so it never renders in Zone 2 either — it must not vanish.
    const findings: QualityFindingRow[] = [
      { tool: "gitleaks", severity: "high", file: "a.ts", line: 1, rule: "aws-key", message: "m", blocking: true },
    ];
    const la = lookAt({ status: "gate_green", run: run({ quality_findings: findings, quality_blocked: false }), cells: [] });
    expect(la.pending.map((i) => i.kind)).toEqual(["quality"]);
  });

  it("includes plan gaps, flaky tests, a warn-mode coverage drop, and mutation survivors", () => {
    const r = run({
      plan_compliance: { ran_at: 0, model: "x", compliant: false, confidence: "high", summary: "", gaps: [{ item: "auth check", why: "missing", cited: "a.ts:1" }], error: null },
      flaky_tests: ["adds numbers"],
      coverage_note: "-2%",
      coverage_blocked: false,
    });
    const la = lookAt({
      status: "gate_green",
      run: r,
      cells: [],
      survivors: [{ path: "src/x.ts", line: 4, operator: "< → <=" }],
    });
    expect(la.pending.map((i) => i.kind)).toEqual(["plan_gap", "flaky", "coverage", "mutation"]);
  });

  it("omits the coverage drop once it's a blocker instead", () => {
    const la = lookAt({ status: "gate_red", run: run({ status: "failed", coverage_note: "-9%", coverage_blocked: true }), cells: [] });
    expect(la.pending.find((i) => i.kind === "coverage")).toBeUndefined();
  });

  it("omits plan gaps once a high-confidence non-compliant plan is what blocked the gate", () => {
    // [quality] plan_compliance = "block": gate.py sets quality_blocked off the plan
    // verdict alone, with no deterministic findings. Those gaps are the blocking cause,
    // so they belong in blockers(), not here — never both.
    const r = run({
      quality_blocked: true,
      quality_findings: [],
      plan_compliance: {
        ran_at: 0, model: "x", compliant: false, confidence: "high", summary: "",
        gaps: [{ item: "auth check", why: "missing", cited: "a.ts:1" }], error: null,
      },
    });
    const la = lookAt({ status: "gate_red", run: r, cells: [] });
    expect(la.pending.find((i) => i.kind === "plan_gap")).toBeUndefined();
  });

  it("still excludes plan gaps when a deterministic finding is ALSO present, and still shows that finding's advisory half", () => {
    const r = run({
      quality_blocked: true,
      quality_findings: [
        { tool: "gitleaks", severity: "high", file: "a.ts", line: 1, rule: "secret", message: "m", blocking: true },
        { tool: "semgrep", severity: "low", file: "b.ts", line: 2, rule: "nit", message: "m", blocking: false },
      ],
      plan_compliance: {
        ran_at: 0, model: "x", compliant: false, confidence: "high", summary: "",
        gaps: [{ item: "auth check", why: "missing", cited: "a.ts:1" }], error: null,
      },
    });
    const la = lookAt({ status: "gate_red", run: r, cells: [] });
    expect(la.pending.map((i) => i.kind)).toEqual(["quality"]);
  });
});

describe("lookAt / reviewCaveat — the refuter (Phase 3 of notes/workflow-roles-plan.md)", () => {
  it("a non-blocking fail (warn mode) surfaces its must-fix list as look-at rows", () => {
    const r = run({
      review_blocked: false,
      review: reviewVerdict({
        verdict: "fail",
        must_fix: [{ file: "a.ts", line: 3, title: "missing null check", detail: "guard against undefined", cited: "+ x.value" }],
      }),
    });
    const la = lookAt({ status: "gate_green", run: r, cells: [] });
    expect(la.pending.map((i) => i.kind)).toEqual(["review"]);
    expect(la.pending[0].text).toBe("a.ts:3 — missing null check");
  });

  it("omits the must-fix list once review_blocked makes it a Zone 2 blocker instead", () => {
    const r = run({
      review_blocked: true,
      review: reviewVerdict({ verdict: "fail", must_fix: [{ file: "a.ts", line: 3, title: "x", detail: "", cited: "+ y" }] }),
    });
    const la = lookAt({ status: "gate_red", run: r, cells: [] });
    expect(la.pending.find((i) => i.kind === "review")).toBeUndefined();
  });

  it("a clean pass with notes surfaces them as review_note rows", () => {
    const r = run({ review: reviewVerdict({ notes: ["consider extracting a helper", "the retry loop could use backoff"] }) });
    const la = lookAt({ status: "gate_green", run: r, cells: [] });
    expect(la.pending.map((i) => i.kind)).toEqual(["review_note", "review_note"]);
    expect(la.pending[0].text).toBe("consider extracting a helper");
  });

  it("a clean pass with no notes surfaces nothing", () => {
    const r = run({ review: reviewVerdict() });
    const la = lookAt({ status: "gate_green", run: r, cells: [] });
    expect(la.pending).toEqual([]);
  });

  it("reviewCaveat reads PASS with the model once measured clean", () => {
    expect(reviewCaveat(run({ review: reviewVerdict({ model: "opus" }) }))).toBe("review: PASS (opus)");
  });

  it("reviewCaveat is null when never measured", () => {
    expect(reviewCaveat(run())).toBeNull();
    expect(reviewCaveat(null)).toBeNull();
  });

  it("reviewCaveat is null on a fail verdict (that's a blocker or a look-at row, not a caveat)", () => {
    expect(reviewCaveat(run({ review: reviewVerdict({ verdict: "fail", must_fix: [{ file: "a.ts", line: 1, title: "x", detail: "", cited: "+ y" }] }) }))).toBeNull();
  });

  it("reviewCaveat is null when the pass couldn't run (that's a degraded reason instead)", () => {
    expect(reviewCaveat(run({ review: reviewVerdict({ error: "the claude CLI was not found" }) }))).toBeNull();
  });
});

describe("codeToCheckCaveat — the honesty distinctions lookAt's plain pending count can't carry", () => {
  it("is null when the feature is off", () => {
    expect(codeToCheckCaveat({ status: "gate_green", run: run(), cells: [], codeToCheck: { enabled: false } })).toBeNull();
  });

  it("is null with no run", () => {
    expect(codeToCheckCaveat({ status: "idle", run: null, cells: [], codeToCheck: { enabled: true } })).toBeNull();
  });

  it("names the reason when the diff was never measured", () => {
    const c = codeToCheckCaveat({
      status: "gate_red",
      run: run({ status: "failed" }),
      cells: [],
      codeToCheck: { enabled: true },
    });
    expect(c).toMatch(/red/);
  });

  it("names the reason when coverage was blind (quiet, not unmeasured)", () => {
    const c = codeToCheckCaveat({
      status: "gate_green",
      run: run({ unchecked_items: [], unchecked_covered_files: null }),
      cells: [],
      codeToCheck: { enabled: true },
    });
    expect(c).toMatch(/no coverage data/);
  });

  it("is null once it earnestly measured cleanly", () => {
    const c = codeToCheckCaveat({
      status: "gate_green",
      run: run({ unchecked_items: [], unchecked_covered_files: 3 }),
      cells: [],
      codeToCheck: { enabled: true },
    });
    expect(c).toBeNull();
  });

  it("is null when there are pending rows — the caveat is only for the empty case", () => {
    const row: UncheckedRow = { kind: "no_test_file", file: "a.ts", detail: "", count: 1, key: "k" };
    const c = codeToCheckCaveat({
      status: "gate_green",
      run: run({ unchecked_items: [row], unchecked_covered_files: 1 }),
      cells: [],
      codeToCheck: { enabled: true },
    });
    expect(c).toBeNull();
  });
});

describe("lookAtReviewItems — routes each kind through the same composer builder blockers use", () => {
  it("code-to-check rows go through uncheckedReviewItems", () => {
    const row: UncheckedRow = { kind: "no_test_file", file: "src/a.ts", detail: "no test imports", count: 1, key: "k" };
    const [item] = lookAtReviewItems([{ kind: "code_to_check", key: "k", text: "x", raw: row }]);
    expect(item.target).toBe("no test imports: a.ts");
  });

  it("plan gaps carry the cited line as context", () => {
    const [item] = lookAtReviewItems([
      { kind: "plan_gap", key: "p", text: "x", raw: { item: "auth check", why: "not implemented", cited: "a.ts:1" } },
    ]);
    expect(item.target).toBe("auth check");
    expect(item.context).toBe("a.ts:1");
    expect(item.text).toMatch(/not implemented/);
  });

  it("flaky items ask to fix the flake, not the test's assertions", () => {
    const [item] = lookAtReviewItems([{ kind: "flaky", key: "f", text: "adds numbers", raw: "adds numbers" }]);
    expect(item.target).toBe("flaky: adds numbers");
    expect(item.text).toMatch(/flake/i);
  });

  it("quality items include advisory findings, unlike the blocking-only fix path", () => {
    const finding: QualityFindingRow = { tool: "semgrep", severity: "low", file: "a.ts", line: 1, rule: "nit", message: "m", blocking: false };
    const [item] = lookAtReviewItems([{ kind: "quality", key: "q", text: "x", raw: finding }]);
    expect(item.target).toBe("semgrep: nit");
  });

  it("review must-fix items carry the cited diff line as context", () => {
    const [item] = lookAtReviewItems([
      {
        kind: "review", key: "r", text: "x",
        raw: { file: "a.ts", line: 3, title: "missing null check", detail: "guard against undefined", cited: "+ x.value" },
      },
    ]);
    expect(item.target).toBe("a.ts:3");
    expect(item.context).toBe("+ x.value");
    expect(item.text).toBe("missing null check — guard against undefined");
  });

  it("review_note items pass the note through as the fix text", () => {
    const [item] = lookAtReviewItems([{ kind: "review_note", key: "n", text: "x", raw: "consider a helper" }]);
    expect(item.target).toBe("refuter note");
    expect(item.text).toBe("consider a helper");
  });

  it("is empty for an empty list", () => {
    expect(lookAtReviewItems([])).toEqual([]);
  });
});

describe("gateVerdict — one headline, no em dashes, never verified/proven/correct", () => {
  it("idle with no run yet", () => {
    expect(gateVerdict({ status: "idle", run: null, cells: [] })).toEqual({
      kind: "idle",
      lead: "no gate run yet",
      detail: null,
      sep: " · ",
      headline: "no gate run yet",
      action: { label: "run all", action: "run_all" },
    });
  });

  it("running shows live progress", () => {
    const cells = [cell({ id: "1" }), cell({ id: "2", status: "running" })];
    const v = gateVerdict({ status: "tests_running", run: null, cells });
    expect(v.kind).toBe("running");
    expect(v.headline).toBe("running · 1 of 2");
  });

  it("merged has no action", () => {
    expect(gateVerdict({ status: "merged", run: run(), cells: [] })).toEqual({
      kind: "merged",
      lead: "merged",
      detail: null,
      sep: " · ",
      headline: "merged",
      action: null,
    });
  });

  it("not ready names the failing count and offers fix all", () => {
    const v = gateVerdict({ status: "gate_red", run: run({ status: "failed", passed: 3, failed: 2 }), cells: [] });
    expect(v.kind).toBe("not_ready");
    expect(v.headline).toBe("not ready · 2 failing tests");
    expect(v.action).toEqual({ label: "fix all → agent", action: "fix_all" });
  });

  it("falls back to not_ready (never idle) on a red status with a stale run carrying no blocker", () => {
    // Unreachable from a fresh backend run, but reachable if a caller ever hands over a
    // previous run object after `status` already flipped red — "no gate run yet" would
    // be a lie in that case.
    const v = gateVerdict({ status: "gate_red", run: run(), cells: [] });
    expect(v.kind).toBe("not_ready");
    expect(v.headline).toBe("not ready");
  });

  it("cant_tell for a gate that never ran, distinct from failing tests", () => {
    const v = gateVerdict({ status: "gate_red", run: run({ status: "error", error_kind: "runner" }), cells: [] });
    expect(v.kind).toBe("cant_tell");
    expect(v.headline).toBe("can't tell · the gate didn't run");
  });

  it("cant_tell for a degraded green, distinct from a genuine ready", () => {
    const v = gateVerdict({ status: "gate_green", run: run({ degraded_reasons: ["quality scanner not installed"] }), cells: [] });
    expect(v.kind).toBe("cant_tell");
    expect(v.headline).toBe("can't tell · a check didn't run");
  });

  it("a genuinely failing gate that's ALSO degraded reads not_ready, not cant_tell", () => {
    // The bug this pins: degraded must never outrank a more concrete blocker. "2 failing
    // tests" is the actionable story here, not a shrug of "can't tell".
    const v = gateVerdict({
      status: "gate_red",
      run: run({ status: "failed", passed: 3, failed: 2, degraded_reasons: ["merge-result gating skipped"] }),
      cells: [],
    });
    expect(v.kind).toBe("not_ready");
    expect(v.headline).toBe("not ready · 2 failing tests");
    expect(v.action).toEqual({ label: "fix all → agent", action: "fix_all" });
  });

  it("ready_star when the tamper alarm starred an otherwise-clean green", () => {
    const v = gateVerdict({
      status: "gate_green",
      run: run({ tamper_findings: [{ kind: "skip", file: "a.ts", detail: "", test: null }] }),
      cells: [],
    });
    expect(v.kind).toBe("ready_star");
    expect(v.headline).toBe("ready, but tests were changed");
    // The comma separator is exposed as `sep`, not hardcoded by whatever renders
    // lead/detail as two elements — a renderer that DOES want them joined must use it
    // rather than guessing "·" (the bug this pins: GatePanel briefly hardcoded "·" for
    // every kind, contradicting this exact headline).
    expect(v.sep).toBe(", ");
    expect(v.lead).toBe("ready");
    expect(v.detail).toBe("but tests were changed");
  });

  it("ready_advisory when clean but there are things to look at", () => {
    const row: UncheckedRow = { kind: "no_test_file", file: "a.ts", detail: "", count: 1, key: "k" };
    const v = gateVerdict({
      status: "gate_green",
      run: run({ unchecked_items: [row], unchecked_covered_files: 1 }),
      cells: [],
      codeToCheck: { enabled: true },
    });
    expect(v.kind).toBe("ready_advisory");
    expect(v.headline).toBe("ready, 1 thing to look at");
  });

  it("ready to ship when clean with nothing to look at", () => {
    const v = gateVerdict({ status: "gate_green", run: run(), cells: [] });
    expect(v).toEqual({
      kind: "ready",
      lead: "ready to ship",
      detail: null,
      sep: " · ",
      headline: "ready to ship",
      action: { label: "open ④", action: "open_ship" },
    });
  });

  it("splits a stacked blocker text into lead + detail, not one flattened string", () => {
    // The bug this pins (notes/verify-redesign-plan.md Phase-1 addendum): a blocker's
    // own text can already contain a "·" (a joined quality/plan sentence), so the
    // VerdictCard must render lead/detail as two elements rather than concatenating
    // "not ready" + "·" + a string that has its own internal "·"s.
    const v = gateVerdict({
      status: "gate_red",
      run: run({
        status: "failed",
        quality_blocked: true,
        quality_findings: [
          { tool: "gitleaks", severity: "high", file: "a.ts", line: 1, rule: "secret", message: "m", blocking: true },
        ],
        plan_compliance: {
          ran_at: 0, model: "x", compliant: false, confidence: "high", summary: "",
          gaps: [{ item: "auth check", why: "missing", cited: "a.ts:1" }], error: null,
        },
      }),
      cells: [],
    });
    expect(v.lead).toBe("not ready");
    // The detail is the WHOLE blocker text, itself "·"-joined — a second, nested split
    // point that lead/detail deliberately does not try to parse further.
    expect(v.detail).toBe("1 finding · 1 blocking · 1 plan requirement not implemented");
    expect(v.headline).toBe("not ready · 1 finding · 1 blocking · 1 plan requirement not implemented");
  });

  it("no headline anywhere claims verified, proven or correct", () => {
    const cases = [
      gateVerdict({ status: "idle", run: null, cells: [] }),
      gateVerdict({ status: "gate_red", run: run({ status: "failed", failed: 1 }), cells: [] }),
      gateVerdict({ status: "gate_green", run: run(), cells: [] }),
      gateVerdict({
        status: "gate_green",
        run: run({ tamper_findings: [{ kind: "skip", file: "a.ts", detail: "", test: null }] }),
        cells: [],
      }),
    ];
    const text = cases.map((c) => c.headline).join(" ").toLowerCase();
    expect(text).not.toMatch(/verified|proven|correct/);
  });

  it("uses no em dashes in any headline", () => {
    const cases = [
      gateVerdict({ status: "idle", run: null, cells: [] }),
      gateVerdict({ status: "gate_red", run: run({ status: "failed", failed: 1 }), cells: [] }),
      gateVerdict({ status: "gate_red", run: run({ status: "error", error_kind: "runner" }), cells: [] }),
      gateVerdict({ status: "gate_green", run: run(), cells: [] }),
    ];
    const text = cases.map((c) => c.headline).join(" ");
    expect(text).not.toMatch(/[—–]/);
  });
});
