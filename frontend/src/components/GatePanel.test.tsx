/** ③ verify, redesigned as a verdict-first page (notes/verify-redesign-plan.md). Static
 *  render (renderToStaticMarkup, no jsdom): the page's shape is a pure function of its
 *  props, so a plain render pins the zones without needing interaction. */
import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { GatePanel } from "./GatePanel";
import type { Cell, MutationResponse, ReviewVerdict, TestRun } from "../types";

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

const render = (props: Partial<Parameters<typeof GatePanel>[0]> = {}) =>
  renderToStaticMarkup(
    <GatePanel
      test={null}
      cells={[]}
      history={[]}
      impact={null}
      blame={null}
      coverage={null}
      flaky={null}
      analyzing={null}
      status="idle"
      busy={false}
      onRunGate={() => {}}
      onRunImpacted={() => {}}
      onRefreshImpact={() => {}}
      onCoverage={() => {}}
      onFlaky={() => {}}
      {...props}
    />,
  );

describe("GatePanel — red gate", () => {
  it("lists the failing-tests blocker with a fix-all action", () => {
    const html = render({
      status: "gate_red",
      test: run({ status: "failed", passed: 3, failed: 2 }),
      cells: [cell({ id: "1", status: "passed" }), cell({ id: "2", status: "failed" }), cell({ id: "3", status: "failed" })],
    });
    expect(html).toMatch(/not ready/);
    expect(html).toMatch(/2 failing tests/);
    expect(html).toMatch(/fix all → agent/);
  });
});

describe("GatePanel — green with things to look at", () => {
  it("shows the pending count and no blockers", () => {
    const html = render({
      status: "gate_green",
      test: run({
        unchecked_items: [{ kind: "no_test_file", file: "src/a.ts", detail: "no test imports this file", count: 1, key: "k1" }],
        unchecked_covered_files: 1,
      }),
      cells: [cell({ id: "1" })],
      codeToCheck: { enabled: true },
    });
    expect(html).toMatch(/things to look at/);
    expect(html).toMatch(/1 thing to look at/);
    expect(html).not.toMatch(/class="gate-blockers"/);
  });
});

describe("GatePanel — degraded green", () => {
  it("reads 'a check didn't run', not 'ready to ship'", () => {
    const html = render({
      status: "gate_green",
      test: run({ degraded_reasons: ["quality scanner not installed"] }),
      cells: [cell({ id: "1" })],
    });
    expect(html).toMatch(/a check didn/);
    expect(html).toMatch(/t run/);
    expect(html).not.toMatch(/ready to ship/);
  });
});

describe("GatePanel — Details accordion", () => {
  it("is collapsed by default on a settled gate", () => {
    const html = render({ status: "gate_red", test: run({ status: "failed", failed: 1 }) });
    expect(html).not.toMatch(/class="gate-details-body"/);
  });

  it("opens on first render while the gate is running (no effect needed)", () => {
    const html = render({ status: "tests_running", cells: [cell({ id: "1", status: "running" })] });
    expect(html).toMatch(/class="gate-details-body"/);
  });
});

describe("GatePanel — pane-head verdict", () => {
  it("still reads ● green* on a tamper warn (findings present, not blocked)", () => {
    const html = render({
      status: "gate_green",
      test: run({ tamper_findings: [{ kind: "skip", file: "a.ts", detail: "", test: "adds numbers" }], tamper_blocked: false }),
    });
    expect(html).toMatch(/verdict-green-star/);
    expect(html).toMatch(/●\s*green\*/);
  });
});

describe("GatePanel — a past run withholds every action", () => {
  it("renders no fix/send/tick actions while time-travelling", () => {
    const past = run({ id: "past1", status: "failed", passed: 3, failed: 2 });
    const html = render({
      status: "gate_green",
      test: run(),
      history: [past],
      initialPastRunId: "past1",
      cells: [],
    });
    expect(html).toMatch(/viewing a past run/);
    // The verdict card's own action button is withheld for a past run.
    expect(html).not.toMatch(/class="primary gv-action"/);
    // No fix-all action on the failing-tests blocker either.
    expect(html).not.toMatch(/fix all → agent/);
  });

  it("the live pane-head verdict never diverges from the flow stepper while past", () => {
    // Live status is green; the past run being viewed is red. The pane head must show
    // the LIVE verdict (green), not the past one, so it can never disagree with ③'s badge.
    const past = run({ id: "past1", status: "failed", passed: 1, failed: 1 });
    const html = render({
      status: "gate_green",
      test: run(),
      history: [past],
      initialPastRunId: "past1",
    });
    expect(html).toMatch(/●\s*green(?!\*)/);
  });

  it("the head never invents a star from a past run the live gate didn't earn", () => {
    // Live run is clean; the past run being viewed is starred. A vacuous version of
    // this test would use an unstarred past run too — this one actually exercises the
    // divergence.
    const starred = run({
      id: "past-star",
      tamper_findings: [{ kind: "skip", file: "a.ts", detail: "", test: null }],
    });
    const html = render({
      status: "gate_green",
      test: run({ tamper_findings: [] }),
      history: [starred],
      initialPastRunId: "past-star",
    });
    expect(html).not.toMatch(/verdict-green-star/);
    expect(html).toMatch(/●\s*green(?!\*)/);
  });

  it("the head keeps its earned star while viewing a clean past run", () => {
    // The reverse divergence: live run is starred; the past run being viewed is clean.
    const clean = run({ id: "past-clean", tamper_findings: [] });
    const html = render({
      status: "gate_green",
      test: run({ tamper_findings: [{ kind: "skip", file: "a.ts", detail: "", test: null }] }),
      history: [clean],
      initialPastRunId: "past-clean",
    });
    expect(html).toMatch(/verdict-green-star/);
    expect(html).toMatch(/●\s*green\*/);
  });
});

describe("GatePanel — mutation score, lifted to App (notes/verify-redesign-plan.md Phase 3)", () => {
  const mutationResult = (over: Partial<MutationResponse> = {}): MutationResponse => ({
    base_ref: "main",
    gate_sha: "abc123",
    supported: true,
    score: 80,
    killed: 4,
    survived: 1,
    skipped: 0,
    total_mutants: 5,
    budget_capped: false,
    survivors: [{ path: "src/discount.ts", line: 12, operator: "round → floor" }],
    note: null,
    ...over,
  });

  it("renders a passed-in result without owning any mutation state itself", () => {
    const html = render({
      status: "tests_running",
      test: run(),
      cells: [cell({ id: "1" })],
      mutation: mutationResult(),
    });
    expect(html).toMatch(/how hard are the tests to fool/);
    expect(html).toMatch(/faults the tests missed/);
    expect(html).toMatch(/discount\.ts:12/);
  });

  it("renders a passed-in error in the contextual card, not a generic banner", () => {
    const html = render({
      status: "tests_running",
      test: run(),
      cells: [cell({ id: "1" })],
      mutationError: "the mutation runner crashed",
    });
    expect(html).toMatch(/scoring didn.t run/);
    expect(html).toMatch(/the mutation runner crashed/);
  });

  it("the tools row's mutation button reflects analyzing, not local state", () => {
    const html = render({
      status: "tests_running",
      test: run(),
      cells: [cell({ id: "1" })],
      analyzing: "mutation",
    });
    expect(html).toMatch(/scoring…/);
  });

  it("disables the mutation button while coverage or flaky is running too — one shared flag, not independent state", () => {
    // Regression: mutation moved onto the shared `analyzing` flag but the button's
    // disabled condition didn't, so a coverage measure and a mutation score could run
    // concurrently and whichever settled first would wipe the other's in-flight card.
    const html = render({
      status: "tests_running",
      test: run(),
      cells: [cell({ id: "1" })],
      analyzing: "coverage",
    });
    expect(html).toMatch(/<button class="ghost" disabled="" title="[^"]*">how hard are the tests to fool<\/button>/);
  });

  it("feeds survivors into Zone 3's advisory count once scored", () => {
    const html = render({
      status: "gate_green",
      test: run(),
      cells: [cell({ id: "1" })],
      mutation: mutationResult(),
    });
    expect(html).toMatch(/1 thing to look at/);
  });
});

describe("GatePanel — review (the refuter, Phase 3 of notes/workflow-roles-plan.md)", () => {
  it("renders a RefuterBanner blocker with must-fix rows and a fix-all action", () => {
    const html = render({
      status: "gate_red",
      onFixReview: () => {},
      test: run({
        review_blocked: true,
        review: reviewVerdict({
          verdict: "fail", summary: "off-by-one in the loop",
          must_fix: [
            { file: "src/discount.ts", line: 12, title: "off-by-one", detail: "excludes the last item", cited: "for (i = 0; i < xs.length - 1; i++)" },
          ],
        }),
      }),
    });
    // The per-must-fix detail list is collapsed by default on a live run (matching
    // QualityBanner's own collapsed-by-default behavior); the summary line and the
    // fix-all action are always visible regardless.
    expect(html).toMatch(/review/);
    expect(html).toMatch(/🛑 blocked/);
    expect(html).toMatch(/1 must-fix finding · off-by-one in the loop/);
    expect(html).toMatch(/\+ fix all → agent/);
  });

  it("the expandable must-fix list, including the cited diff line, renders when open", () => {
    // The banner is collapsed by default on a live run (see the previous test's own
    // comment) — force it open the same way the "past run" tests do, via
    // initialPastRunId, since that's what RefuterBanner's `defaultOpen={past}` reads.
    const past = run({
      id: "past1",
      review_blocked: true,
      review: reviewVerdict({
        verdict: "fail",
        must_fix: [
          { file: "src/discount.ts", line: 12, title: "off-by-one", detail: "excludes the last item", cited: "for (i = 0; i < xs.length - 1; i++)" },
        ],
      }),
    });
    const html = render({
      status: "gate_red",
      test: run(),
      history: [past],
      initialPastRunId: "past1",
    });
    expect(html).toMatch(/class="gate-quality-list"/);
    expect(html).toMatch(/qf-item-column/);
    expect(html).toMatch(/<summary class="dim">cited<\/summary>/);
    expect(html).toMatch(/class="qf-cited-line"/);
    expect(html).toMatch(/for \(i = 0; i &lt; xs\.length - 1; i\+\+\)/);
  });

  it("a warn-mode fail (not review_blocked) surfaces in Zone 3, not as a Zone 2 banner", () => {
    const html = render({
      status: "gate_green",
      test: run({
        review_blocked: false,
        review: reviewVerdict({
          verdict: "fail",
          must_fix: [{ file: "a.ts", line: 3, title: "missing null check", detail: "", cited: "+ x.value" }],
        }),
      }),
    });
    expect(html).not.toMatch(/class="gate-quality-flag"/); // no 🛑 banner
    expect(html).toMatch(/things to look at/);
    expect(html).toMatch(/missing null check/);
  });

  it("a clean PASS shows a Zone 1 caveat, not a Zone 2/3 row", () => {
    const html = render({
      status: "gate_green",
      test: run({
        review: reviewVerdict(),
      }),
    });
    expect(html).toMatch(/review: PASS \(opus\)/);
    expect(html).not.toMatch(/class="gate-quality-flag"/);
  });

  it("a PASS with non-blocking notes surfaces them in Zone 3", () => {
    const html = render({
      status: "gate_green",
      test: run({
        review: reviewVerdict({ notes: ["consider extracting this into a helper"] }),
      }),
    });
    expect(html).toMatch(/things to look at/);
    expect(html).toMatch(/consider extracting this into a helper/);
  });

  it("the review-now button is hidden entirely when the project has no review role", () => {
    // tests_running forces Details open (see the next test's comment) so this actually
    // exercises canRefute hiding the button, not just the accordion being collapsed.
    const html = render({ status: "tests_running", test: run(), cells: [cell({ id: "1" })], canRefute: false });
    expect(html).not.toMatch(/review now/);
  });

  it("the review-now button renders whenever a review role is configured, gate color aside", () => {
    // status: tests_running forces the Details accordion (where ToolsRow lives) open
    // on first render — matching the mutation-score tests' own convention, since
    // effects (which would keep it open through a settled gate_green) don't run under
    // a static render. Visibility is `canRefute` alone (a project-config question);
    // readiness (green gate) only affects whether the button is ENABLED, mirroring
    // "disabled while busy or on a red gate" — the next test covers that.
    const html = render({ status: "tests_running", test: run(), cells: [cell({ id: "1" })], canRefute: true });
    expect(html).toMatch(/review now/);
  });

  it("the review-now button is disabled when the gate isn't green (readiness, not visibility)", () => {
    // status: tests_running is the only way to force Details open under a static
    // render (see the comment above) — it also means `green` is false here, so this
    // doubles as the "disabled while … on a red gate" case the plan calls for:
    // `refuteReady` (derived from `green`) is what disables the button, `canRefute`
    // alone is what shows it — the two are deliberately independent props.
    const html = render({ status: "tests_running", test: run(), cells: [cell({ id: "1" })], canRefute: true });
    expect(html).toMatch(/<button class="ghost" disabled="" title="[^"]*">review now<\/button>/);
  });

  it("reads 'reviewing…' while an on-demand review is in flight", () => {
    const html = render({
      status: "tests_running", test: run(), cells: [cell({ id: "1" })],
      canRefute: true, refuting: true, analyzing: "review",
    });
    expect(html).toMatch(/reviewing…/);
  });
});

describe("GatePanel — GateFocus (notes/verify-redesign-plan.md Phase 3)", () => {
  it("accepts a gateFocus prop without crashing (effects don't run under a static render)", () => {
    expect(() =>
      render({
        status: "gate_red",
        test: run({ status: "failed", failed: 1 }),
        gateFocus: { target: "blockers", nonce: 1 },
      }),
    ).not.toThrow();
  });
});
