import { useEffect, useRef, useState } from "react";
import { ArrowDown, ArrowUp, Maximize, Minimize } from "./icons";
import type {
  BlameHunk,
  BlameResponse,
  Cell,
  CoverageResponse,
  FlakyResponse,
  ImpactResponse,
  MutationResponse,
  MutationSurvivor,
  ReviewMustFix,
  ReviewVerdict,
  TamperFinding,
  TestRun,
  UncheckedRow,
} from "../types";
import { Chevron } from "./Chevron";
import { ImpactMap } from "./ImpactMap";
import { LookAt } from "./LookAt";
import type { GateFocus } from "../flow";
import {
  failedCells,
  gateErrorFraming,
  casesToCells,
  groupQualityFindings,
  qualityLocation,
  qualitySummary,
  ribbonDot,
  tamperKindLabel,
  tamperSummary,
  type QualityFindingRow,
} from "../gate";
import {
  blockers,
  codeToCheckCaveat,
  gateVerdict,
  lookAt,
  reviewCaveat,
  type Blocker,
  type BlockerFixAction,
  type LookAtItem,
  type VerdictAction,
} from "../verdict";

/** ③ verify, redesigned as a verdict-first page (notes/verify-redesign-plan.md): one
 *  headline, blockers in a fixed order, an advisory "things to look at" worklist, and
 *  everything else — grid, ribbon, impact map, on-demand tools — behind one Details
 *  accordion. Replaces the earlier grid/impact/trust/strength tab strip. The pane-head
 *  verdict stays LIVE (never `viewTest`) so it can never diverge from the flow stepper,
 *  even while the body below is time-travelling a past run. */
export function GatePanel({
  test,
  cells = [],
  history = [],
  impact = null,
  blame = null,
  coverage = null,
  flaky = null,
  analyzing = null,
  status,
  busy,
  onRunGate,
  onRunImpacted,
  onRunFailed,
  onRefreshImpact,
  onCoverage,
  onFlaky,
  onAddComment,
  onSendTestToBacklog,
  onFixAll,
  onRestoreTampered,
  onFixQuality,
  onFixReview,
  onKillSurvivors,
  onSendSurvivorsToBacklog,
  onOpenGateSettings,
  onRunRefuter,
  refuting = false,
  canRefute = false,
  gateFocus,
  adopted = false,
  onReRunSetup,
  checkedKeys = [],
  codeToCheck,
  onToggleChecked,
  onOpenFile,
  onOpenShip,
  onSendLookAt,
  onSendLookAtToBacklog,
  initialPastRunId = null,
  mutation = null,
  mutationError = null,
  onRunMutation,
}: {
  test: TestRun | null;
  cells: Cell[];
  history: TestRun[];
  impact: ImpactResponse | null;
  blame: BlameResponse | null;
  coverage: CoverageResponse | null;
  flaky: FlakyResponse | null;
  analyzing: string | null;
  status: string;
  busy: boolean;
  onRunGate: () => void;
  onRunImpacted: () => void;
  onRunFailed?: () => void;
  onRefreshImpact: () => void;
  onCoverage: () => void;
  onFlaky: () => void;
  onAddComment?: (target: string, context: string | null) => void;
  /** "Send to backlog" sibling of onAddComment (backlog/backlog-v2.md Move 3). */
  onSendTestToBacklog?: (target: string, context: string | null) => void;
  onFixAll?: (cells: Cell[]) => void;
  /** green* → agent: batch every tamper finding into the review composer as one
      restore task — the fix-all of the tamper alarm, so a suspicious green routes to
      action the way a red does. */
  onRestoreTampered?: (findings: TamperFinding[]) => void;
  /** Batch the blocking quality findings into the review composer — the Double Gate's
   *  twin of `onRestoreTampered` (backlog/double-gate.md §2). */
  onFixQuality?: (findings: QualityFindingRow[]) => void;
  /** Batch the refuter's must-fix findings into the review composer (Phase 3 of
   *  notes/workflow-roles-plan.md) — the refuter's twin of `onFixQuality`. */
  onFixReview?: (mustFix: ReviewMustFix[]) => void;
  /** Batch every surviving mutant into the review composer as one "write a test that
   *  fails on this mutation" task — the tools row's twin of `onFixQuality`. */
  onKillSurvivors?: (survivors: MutationSurvivor[]) => void;
  /** "Send to backlog" sibling of onKillSurvivors (backlog/backlog-v2.md Move 3):
   *  queue every surviving mutant as a follow-up instead of re-tasking the agent. */
  onSendSurvivorsToBacklog?: (survivors: MutationSurvivor[]) => void;
  /** Open the project's Gate settings tab — the deep-link for a guard-off trust row. */
  onOpenGateSettings?: () => void;
  /** On-demand refuter re-run (Zone 4's "refute now") — advisory only: it updates the
   *  displayed verdict but never `review_blocked`, which only a real gate run sets. */
  onRunRefuter?: () => void;
  refuting?: boolean;
  /** Whether the project has `[roles] enabled` with a review role configured — the
   *  refuter tool is hidden (not just disabled) otherwise, same as `canScore` gates
   *  mutation on a green gate rather than showing a permanently-disabled button. */
  canRefute?: boolean;
  /** Where to snap the eye on ③ and a nonce to re-trigger it (notes/verify-redesign-
   *  plan.md's GateFocus) — the deep-link every "go look at the gate" action in the
   *  app routes through (a blocked flow-step click, a ④ ship trust-row fix). */
  gateFocus?: GateFocus;
  /** This workspace is an adopted (foreign) worktree — a setup-kind gate error is
      "environment, not code", surfaced with a re-run-setup affordance, not a plain red. */
  adopted?: boolean;
  /** Re-run the workspace's setup script (POST /workspaces/{id}/setup) — the fix path
      for an adopted worktree whose provisioning left the gate unable to run. */
  onReRunSetup?: () => void;
  /** Rows this viewer already ticked off (workspace.checked_rows) — the only tickable
   *  kind in the "things to look at" zone. */
  checkedKeys?: string[];
  /** Whether the project opted into code-to-check ([workflow] code_to_check !== "off"). */
  codeToCheck?: { enabled: boolean };
  onToggleChecked?: (row: UncheckedRow, checked: boolean) => void;
  /** Open a file in ② code — a look-at row's body action. */
  onOpenFile?: (file: string) => void;
  /** Jump to ④ ship — the "ready to ship" verdict's primary action. */
  onOpenShip?: () => void;
  /** Batch every pending look-at row into the review composer as follow-up tasks. */
  onSendLookAt?: (items: LookAtItem[]) => void;
  /** "Send to backlog" sibling of onSendLookAt (backlog/backlog-v2.md Move 3). */
  onSendLookAtToBacklog?: (items: LookAtItem[]) => void;
  /** Pre-select a run from `history` to time-travel to on mount — what makes the
   *  past-run render path (every action withheld) directly testable via a static
   *  render (no click simulation needed). */
  initialPastRunId?: string | null;
  /** Mutation score, lifted to App (notes/verify-redesign-plan.md Phase 3) so its
   *  survivors also feed the rail's look-at count, not just this page's. */
  mutation?: MutationResponse | null;
  mutationError?: string | null;
  onRunMutation?: () => void;
}) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  // Lazily seeded from `status` (not only the `running` effect below) so a first render
  // while the gate is already running opens straight into the streaming grid — including
  // under a static/server render, where effects never fire.
  const [detailsOpen, setDetailsOpen] = useState(() => status === "tests_running");
  const [lookAtOpen, setLookAtOpen] = useState(true);
  const [full, setFull] = useState(false); // fullscreen "focus mode" overlay — room for the diff + inline comments
  // Ribbon time-travel: when set, the grid renders a *past* run (from its stored
  // cases) instead of the live cells — "when did this go red?". null = live.
  const [pastRunId, setPastRunId] = useState<string | null>(initialPastRunId);
  // Streak deep-link: pulse the regression ribbon so a "see the ribbon" click has
  // somewhere to land the eye.
  const [ribbonPulse, setRibbonPulse] = useState(false);

  // GateFocus targets — refs the focus effect below (after `blks` is computed)
  // scrolls into view. Guarded optional chaining throughout: renderToStaticMarkup
  // never runs effects at all, and even in a real DOM a ref can be null on first paint.
  const blockersRef = useRef<HTMLDivElement>(null);
  const lookAtRef = useRef<HTMLDivElement>(null);
  const historyRef = useRef<HTMLDivElement>(null);

  // Esc exits fullscreen (only while expanded).
  useEffect(() => {
    if (!full) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setFull(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [full]);

  const green = status === "gate_green";
  const red = status === "gate_red";
  const running = status === "tests_running";
  const merged = status === "merged";

  // Details auto-opens while running (the streaming grid IS the feedback), collapsed
  // otherwise.
  useEffect(() => {
    if (running) setDetailsOpen(true);
  }, [running]);

  // The Nord aurora sweep must fire only on a GENUINE flip to green (red / running to
  // green), not every time an already-green workspace opens: mounting .verdict-green
  // would otherwise replay the one-shot animation with no visible trigger. Track the
  // prior status and flag a transient flip; a first mount (prev undefined) never sets it.
  const prevStatus = useRef<string | undefined>(undefined);
  const [justFlippedGreen, setJustFlippedGreen] = useState(false);
  useEffect(() => {
    const prev = prevStatus.current;
    prevStatus.current = status;
    if (status === "gate_green" && prev !== undefined && prev !== "gate_green") {
      setJustFlippedGreen(true);
      const t = setTimeout(() => setJustFlippedGreen(false), 3300);
      return () => clearTimeout(t);
    }
  }, [status]);

  // A live run flushes any past-run view (the ribbon updates and you want the fresh
  // grid). Otherwise the ribbon dot you picked drives what the grid shows.
  useEffect(() => {
    if (running) setPastRunId(null);
  }, [running]);

  const pastRun = pastRunId ? history.find((h) => h.id === pastRunId) ?? null : null;
  const past = !!pastRun;
  const viewCells = pastRun ? casesToCells(pastRun.cases) : cells;
  const viewTest = pastRun ?? test;

  // Tamper alarm (the green* signal), for the PANE HEAD only — deliberately read off
  // the LIVE `test`, never `viewTest`: the head must stay live so it can never diverge
  // from the flow stepper elsewhere in the app (which also reads live status), even
  // while the body below is time-travelling a starred or unstarred past run.
  const tampered = (test?.tamper_findings?.length ?? 0) > 0;

  const done = viewCells.filter((c) => c.status !== "running");
  const passed = viewCells.filter((c) => c.status === "passed").length;
  const failing = failedCells(viewCells);
  const failed = failing.length;
  const skipped = viewCells.filter((c) => c.status === "skipped").length;
  const inflight = viewCells.length - done.length;

  const flame = done
    .filter((c) => c.duration_ms != null)
    .sort((a, b) => (b.duration_ms ?? 0) - (a.duration_ms ?? 0))
    .slice(0, 20);
  const maxDur = Math.max(1, ...flame.map((c) => c.duration_ms ?? 0));
  const selected = viewCells.find((c) => c.id === selectedId) ?? null;

  // Failure → blame: the changed lines a red test's stack implicates. Only for the
  // live run (a past run's blame vs the current diff would be meaningless).
  const blameFor = (c: Cell): BlameHunk[] =>
    !pastRun && blame ? blame.entries.find((e) => e.file === c.file && e.name === c.name)?.hunks ?? [] : [];

  // A past TestRun's own status, folded into the same `gate_green`/`gate_red`/
  // `tests_running` vocabulary verdict.ts expects — so Zone 1-4 can describe whichever
  // run is being viewed, live or past, through one set of pure functions.
  const runStatusWord = (t: TestRun): string => {
    if (t.status === "running") return "tests_running";
    if (t.status === "passed") return "gate_green";
    return "gate_red";
  };
  const verdictStatus = pastRun ? runStatusWord(pastRun) : status;

  const verdictInputs = {
    status: verdictStatus,
    run: viewTest,
    cells: viewCells,
    checkedKeys,
    // Mutation scoring is about the live diff regardless of which past run is on
    // screen, but only worth surfacing once it's actually been scored.
    survivors: mutation?.survivors ?? null,
    codeToCheck,
    adopted,
    past,
  };
  const verdict = gateVerdict(verdictInputs);
  const blks = blockers(verdictInputs);
  const la = lookAt(verdictInputs);
  const caveat = codeToCheckCaveat(verdictInputs);
  // The refuter (Phase 3): a clean PASS's Zone 1 caveat — so a green gate visibly
  // carries the review even when it found nothing worth a Zone 2/3 row.
  const reviewNote = reviewCaveat(viewTest);

  // One effect, keyed on the nonce (not the target, so a repeat click on the same
  // target still re-fires): scrolls to or opens whichever zone GateFocus names.
  useEffect(() => {
    if (!gateFocus) return;
    const scrollTo = (ref: React.RefObject<HTMLElement | null>) =>
      ref.current?.scrollIntoView?.({ behavior: "smooth", block: "start" });
    switch (gateFocus.target) {
      case "blockers":
        scrollTo(blockersRef);
        break;
      case "look_at":
        setLookAtOpen(true);
        scrollTo(lookAtRef);
        break;
      case "ribbon": {
        setDetailsOpen(true);
        setRibbonPulse(true);
        scrollTo(historyRef);
        const t = setTimeout(() => setRibbonPulse(false), 1800);
        return () => clearTimeout(t);
      }
      case "tamper":
        // Blocked tamper findings render in Zone 2 (always visible, no toggle);
        // warn-mode findings are a Zone 3 look-at row instead.
        if (blks.some((b) => b.kind === "tamper_blocked")) {
          scrollTo(blockersRef);
        } else {
          setLookAtOpen(true);
          scrollTo(lookAtRef);
        }
        break;
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- keyed on the nonce only:
    // a repeat click on the same target must re-fire even though `blks` is unchanged.
  }, [gateFocus?.nonce]);

  // Actions always act on the LIVE diff — they are hidden entirely while `past` is
  // true, so `test`/`cells` (not `viewTest`/`viewCells`) is always correct here.
  const dispatchFix = (action: BlockerFixAction) => {
    switch (action) {
      case "rerun_gate":
        onRunGate();
        break;
      case "rerun_setup":
        onReRunSetup?.();
        break;
      case "fix_all":
        onFixAll?.(cells);
        break;
      case "restore_tampered":
        onRestoreTampered?.(test?.tamper_findings ?? []);
        break;
      case "fix_quality":
        onFixQuality?.(test?.quality_findings ?? []);
        break;
      case "fix_review":
        onFixReview?.(test?.review?.must_fix ?? []);
        break;
      case "open_gate_settings":
        onOpenGateSettings?.();
        break;
    }
  };

  const dispatchVerdictAction = (action: VerdictAction) => {
    switch (action) {
      case "run_all":
      case "rerun_gate":
        onRunGate();
        break;
      case "rerun_setup":
        onReRunSetup?.();
        break;
      case "fix_all":
        onFixAll?.(cells);
        break;
      case "restore_tampered":
        onRestoreTampered?.(test?.tamper_findings ?? []);
        break;
      case "fix_quality":
        onFixQuality?.(test?.quality_findings ?? []);
        break;
      case "fix_review":
        onFixReview?.(test?.review?.must_fix ?? []);
        break;
      case "open_gate_settings":
        onOpenGateSettings?.();
        break;
      case "focus_tamper":
        // ready_star only fires for a non-blocked tamper finding, which lives in Zone 3
        // (lookAt), never in Details — see verdict.ts's lookAt().
        setLookAtOpen(true);
        break;
      case "open_look_at":
        setLookAtOpen(true);
        break;
      case "open_ship":
        onOpenShip?.();
        break;
    }
  };

  const openDetails = () => {
    setDetailsOpen((o) => {
      const next = !o;
      if (next && !impact) onRefreshImpact();
      return next;
    });
  };

  const summaryLine =
    viewCells.length > 0
      ? `${passed}✓ ${failed}✗${skipped ? ` ${skipped}⊘` : ""} · ${viewCells.length} total` +
        (viewTest?.scope === "impacted" ? " · impacted-only" : "") +
        (viewTest?.wall_ms != null ? ` · ${viewTest.wall_ms.toFixed(0)}ms` : "")
      : viewTest
        ? "no tests ran"
        : "not run yet";

  return (
    <>
      {full && <div className="card-backdrop" onClick={() => setFull(false)} />}
      <div className={"pane" + (full ? " pane--full" : "")}>
        <div className="pane-head">
          <span className="gate-verdict rule-title">
            gate
            {green && (
              <span
                className={
                  "verdict verdict-green" +
                  (tampered ? " verdict-green-star" : "") +
                  (justFlippedGreen ? " verdict-flip" : "")
                }
                title={
                  tampered
                    ? "green*, with test-suite-integrity findings: the tests passed, but the suite changed suspiciously. See the reason chip below."
                    : undefined
                }
              >
                ● green{tampered ? "*" : ""}
              </span>
            )}
            {red && <span className="verdict verdict-red">● red</span>}
            {running && <span className="verdict verdict-run">running…</span>}
            {merged && <span className="verdict verdict-merged">● merged</span>}
            {green && !pastRun && test?.scope && test.scope !== "all" && (
              <button
                className="verdict-scope-hint"
                onClick={onRunGate}
                disabled={busy}
                title={
                  test.scope === "failed"
                    ? "This green only re-ran the previously-failing tests, not the whole suite. Run the full suite before you ship."
                    : "This gate ran only the impacted tests, fast, but not the whole suite. Run the full suite before you ship."
                }
              >
                {test.scope === "failed" ? "re-ran failures" : "impacted"} · run full before ship
              </button>
            )}
          </span>
          <span className="gate-actions">
            <button className="ghost" onClick={onRunGate} disabled={busy} title="Run the project's full test suite now.">
              run all
            </button>
            <button
              className="ghost"
              onClick={onRunImpacted}
              disabled={busy}
              title="Run only the tests affected by the current changes, faster than the full suite."
            >
              impacted
            </button>
            {onRunFailed && !pastRun && failing.length > 0 && (
              <button
                className="ghost"
                onClick={onRunFailed}
                disabled={busy}
                title="Re-run just the tests that are red right now, the fastest loop while you fix them. Run the full gate once they pass."
              >
                re-run failed
              </button>
            )}
            <button
              className="ghost btn-icon btn-full"
              onClick={() => setFull((f) => !f)}
              title={full ? "exit fullscreen (Esc)" : "expand · more room for the test grid & failures"}
              aria-label={full ? "exit fullscreen" : "expand gate"}
            >
              {full ? <Minimize /> : <Maximize />}
            </button>
          </span>
        </div>

        <div className="gate-body gate-page">
          {/* Time-travel strip FIRST: every zone below it describes the past run, not
              the live one, so the "you're looking at history" frame has to land before
              them or the verdict reads as current. */}
          {pastRun && (
            <div className="gate-timetravel">
              ▸ viewing a past run
              <span className="dim">
                {" "}
                · {pastRun.scope} · {pastRun.passed}✓ {pastRun.failed}✗
              </span>
              <button className="ghost" onClick={() => setPastRunId(null)}>
                ● back to live
              </button>
            </div>
          )}

          {/* Zone 1 — the verdict itself: one headline, one primary action. `lead` and
              `detail` render as two elements, not one concatenated string — a blocker's
              own text can itself contain a "·" (a joined quality/plan sentence, a
              tamper note), and flattening them would stack multiple "·"-clauses into
              one ambiguous line (notes/verify-redesign-plan.md Phase-1 addendum). */}
          <div className={"gate-verdict-card gv-" + verdict.kind}>
            <div className="gv-headline">
              {past && <span className="gv-past dim">this run: </span>}
              <span className="gv-lead">{verdict.lead}</span>
              {verdict.detail && <span className="gv-detail">{verdict.sep}{verdict.detail}</span>}
            </div>
            {verdict.action && !past && (
              <button className="primary gv-action" onClick={() => dispatchVerdictAction(verdict.action!.action)}>
                {verdict.action.label}
              </button>
            )}
            {reviewNote && <div className="gv-review-caveat dim">{reviewNote}</div>}
          </div>

          {/* Zone 2 — blockers, fixed order, one sentence + its fix per row. A gate
              error is always alone here (blockers() short-circuits everything else).
              Never rendered at all for a past run — its raw log/re-run affordances
              describe a diff that may no longer exist, and the verdict headline above
              already says "can't tell" for it — so it's filtered out before the
              non-empty check, not just hidden inside the map (an empty wrapper div
              would otherwise render for a past gate-error run). */}
          {blks.filter((b) => !(past && b.kind === "gate_error")).length > 0 && (
            <div className="gate-blockers" ref={blockersRef}>
              {blks.map((b) => {
                if (b.kind === "gate_error") {
                  return !past ? (
                    <GateErrorCard
                      key="gate_error"
                      error={test?.error ?? null}
                      kind={test?.error_kind ?? null}
                      onRun={onRunGate}
                      busy={busy}
                      adopted={adopted}
                      onReRunSetup={onReRunSetup}
                    />
                  ) : null;
                }
                if (b.kind === "tamper_blocked") {
                  return (
                    <TamperBanner
                      key="tamper"
                      findings={viewTest?.tamper_findings ?? []}
                      note={viewTest?.tamper_note ?? null}
                      blocked
                      defaultOpen={past}
                      onRestore={past ? undefined : onRestoreTampered}
                    />
                  );
                }
                if (b.kind === "quality_blocked") {
                  return (
                    <QualityBanner
                      key="quality"
                      findings={viewTest?.quality_findings ?? []}
                      note={viewTest?.quality_note ?? null}
                      blocked
                      defaultOpen={past}
                      onFix={past ? undefined : onFixQuality}
                    />
                  );
                }
                if (b.kind === "review_blocked") {
                  return (
                    <RefuterBanner
                      key="review"
                      verdict={viewTest?.review ?? null}
                      blocked
                      defaultOpen={past}
                      onFix={past ? undefined : onFixReview}
                    />
                  );
                }
                return <BlockerRow key={b.kind} blocker={b} past={past} onFix={dispatchFix} />;
              })}
            </div>
          )}

          {/* Zone 3 — things to look at: advisory, never blocks a merge. */}
          {(la.pending.length > 0 || la.done.length > 0 || caveat) && (
            <div className="gate-lookat" ref={lookAtRef}>
              <button className="gate-lookat-head" onClick={() => setLookAtOpen((o) => !o)} aria-expanded={lookAtOpen}>
                <Chevron open={lookAtOpen} />
                <span>things to look at</span>
                {la.pending.length > 0 && <span className="gate-lookat-count">{la.pending.length}</span>}
              </button>
              {lookAtOpen && (
                <LookAt
                  result={la}
                  caveat={caveat}
                  past={past}
                  onOpenFile={onOpenFile ?? (() => {})}
                  onToggleChecked={(row, checked) => onToggleChecked?.(row, checked)}
                  onSendToAgent={(items) => onSendLookAt?.(items)}
                  onSendToBacklog={onSendLookAtToBacklog && ((items) => onSendLookAtToBacklog(items))}
                />
              )}
            </div>
          )}

          {/* Zone 4 — details: the streaming grid, history, impact map, on-demand
              tools. Collapsed by default, auto-open while running. */}
          <div className="gate-details">
            <button className="gate-details-head" onClick={openDetails} aria-expanded={detailsOpen}>
              <Chevron open={detailsOpen} />
              <span>details</span>
              <span className="dim">{summaryLine}</span>
            </button>
            {detailsOpen && (
              <div className="gate-details-body">
                {/* DEGRADED (backlog/double-gate.md §0): the one-line "a check didn't
                    run" blocker/verdict already said the headline; this is the detail
                    a reader needs once they open up to ask "which check?". */}
                {(viewTest?.degraded_reasons?.length ?? 0) > 0 && (
                  <div className="dim gate-degraded-note">
                    checks that didn't run: {viewTest!.degraded_reasons!.join(", ")}
                  </div>
                )}
                {viewTest?.merge_note && !viewTest.merge_conflict && (
                  <div className="gate-cov">⌥ {viewTest.merge_note}</div>
                )}

                {viewCells.length === 0 && !viewTest && (
                  <div className="empty">No gate run yet. It runs automatically after the agent, or hit “run all”.</div>
                )}

                {viewCells.length > 0 && (
                  <>
                    <div className="gate-summary">
                      {passed > 0 && <span className="s-pass">{passed} passed</span>}
                      {failed > 0 && <span className="s-fail">{failed} failed</span>}
                      {skipped > 0 && <span className="s-skip">{skipped} skipped</span>}
                      {inflight > 0 && <span className="s-run">{inflight} running</span>}
                      <span className="dim">
                        · {viewCells.length} total
                        {viewTest?.scope === "impacted" ? " · impacted-only" : ""}
                        {viewTest?.wall_ms != null ? ` · ${viewTest.wall_ms.toFixed(0)}ms wall` : ""}
                      </span>
                    </div>

                    {failing.length > 0 && (
                      <div className="gate-failures">
                        <div className="gate-failures-head">
                          <span className="s-fail">
                            {failed} failing test{failed > 1 ? "s" : ""}
                          </span>
                        </div>
                        <ul className="gate-failure-list">
                          {failing.map((c) => (
                            <li key={c.id}>
                              <button
                                className={"gate-failure" + (selectedId === c.id ? " gate-failure-sel" : "")}
                                onClick={() => setSelectedId(selectedId === c.id ? null : c.id)}
                                title={c.file}
                              >
                                <span className="case-glyph case-failed">✗</span>
                                <span className="gate-failure-name">{c.name}</span>
                                <span className="gate-failure-file dim">{c.file.split("/").pop()}</span>
                                {blameFor(c).length > 0 && (
                                  <span className="gate-blame-chip" title="a line you changed is implicated in this failure">
                                    ⤳ blame
                                  </span>
                                )}
                              </button>
                            </li>
                          ))}
                        </ul>
                      </div>
                    )}

                    <div className="grid">
                      {viewCells.map((c) => (
                        <button
                          key={c.id}
                          className={`cell cell-${c.status}${selectedId === c.id ? " cell-sel" : ""}`}
                          title={`${c.name} · ${c.status}${c.duration_ms != null ? ` · ${c.duration_ms.toFixed(1)}ms` : ""}`}
                          onClick={() => setSelectedId(selectedId === c.id ? null : c.id)}
                        />
                      ))}
                    </div>

                    {selected && (
                      <CellDetail
                        cell={selected}
                        blame={blameFor(selected)}
                        onAddComment={pastRun ? undefined : onAddComment}
                        onSendTestToBacklog={pastRun ? undefined : onSendTestToBacklog}
                      />
                    )}

                    {flame.length > 0 && (
                      <div className="flame">
                        <div className="flame-title dim">slowest tests</div>
                        {flame.map((c) => (
                          <div key={c.id} className="flame-row" onClick={() => setSelectedId(c.id)} title={c.name}>
                            <div
                              className={`flame-bar flame-${c.status}`}
                              style={{ width: `${((c.duration_ms ?? 0) / maxDur) * 100}%` }}
                            />
                            <span className="flame-label">
                              {c.name} <span className="dim">{(c.duration_ms ?? 0).toFixed(1)}ms</span>
                            </span>
                          </div>
                        ))}
                      </div>
                    )}
                  </>
                )}

                {history.length > 0 && (
                  <div className="gate-history" ref={historyRef}>
                    {/* The ribbon used to live in the tab strip, where proximity to the
                        other tabs implied what it was. Isolated in Details now, it needs
                        its own label or it reads as decoration, not a clickable history
                        (found live: three unlabeled dots are genuinely illegible on
                        first sight). */}
                    <div className="gate-history-label dim">history</div>
                    <Ribbon
                      history={history}
                      pulse={ribbonPulse}
                      activeId={pastRunId}
                      onPick={(id) => {
                        setPastRunId((cur) => (cur === id ? null : id));
                        setSelectedId(null);
                        setDetailsOpen(true);
                      }}
                    />
                  </div>
                )}

                <ImpactMap impact={impact} busy={busy} onRefresh={onRefreshImpact} onRunImpacted={onRunImpacted} />

                <ToolsRow
                  busy={busy}
                  coverage={coverage}
                  flaky={flaky}
                  analyzing={analyzing}
                  onCoverage={onCoverage}
                  onFlaky={onFlaky}
                  mutRunning={analyzing === "mutation"}
                  hasResult={!!mutation}
                  canScore={green && !!test?.workspace_id}
                  onRunMutation={() => onRunMutation?.()}
                  canRefute={canRefute}
                  refuteReady={green && !!test?.workspace_id}
                  refuting={refuting}
                  onRunRefuter={() => onRunRefuter?.()}
                />
                <CoverageResult coverage={coverage} />
                <FlakyResult flaky={flaky} />
                {(analyzing === "mutation" || mutation || mutationError) && (
                  <MutationResults
                    running={analyzing === "mutation"}
                    result={mutation}
                    error={mutationError}
                    onKillSurvivors={onKillSurvivors}
                    onSendSurvivorsToBacklog={onSendSurvivorsToBacklog}
                  />
                )}
              </div>
            )}
          </div>
        </div>
      </div>
    </>
  );
}

/** One blocker's plain sentence + fix button (Zone 2). The richer signals (gate_error,
 *  tamper_blocked, quality_blocked) render their own component instead — see the switch
 *  in `GatePanel` above — so this only ever handles failing_tests, merge_conflict,
 *  coverage_blocked and degraded. */
function BlockerRow({
  blocker,
  past,
  onFix,
}: {
  blocker: Blocker;
  past: boolean;
  onFix: (action: BlockerFixAction) => void;
}) {
  return (
    <div className="blk-row">
      <span className="blk-text">{blocker.text}</span>
      {blocker.fix && !past && (
        <button className="ghost blk-fix" onClick={() => onFix(blocker.fix!.action)}>
          {blocker.fix.label}
        </button>
      )}
    </div>
  );
}

const METRICS = ["lines", "statements", "functions", "branches"] as const;

function CoverageResult({ coverage }: { coverage: CoverageResponse | null }) {
  if (!coverage) return null;
  return (
    <div className="analysis-block">
      <div className="analysis-head">
        <span className="dim">coverage delta</span>
      </div>
      <div className="cov-grid">
        {METRICS.map((m) => {
          const cur = coverage.current?.[m];
          const d = coverage.delta?.[m];
          return (
            <div key={m} className="cov-cell">
              <div className="cov-metric dim">{m}</div>
              <div className="cov-pct">{cur != null ? `${cur.toFixed(0)}%` : "—"}</div>
              {d != null && d !== 0 && (
                <div className={d > 0 ? "cov-up" : "cov-down"}>
                  {d > 0 ? <ArrowUp size={11} /> : <ArrowDown size={11} />} {Math.abs(d).toFixed(1)}
                </div>
              )}
            </div>
          );
        })}
      </div>
      {coverage.note && <div className="dim analysis-note">{coverage.note}</div>}
    </div>
  );
}

function FlakyResult({ flaky }: { flaky: FlakyResponse | null }) {
  if (!flaky) return null;
  return (
    <div className="analysis-block">
      <div className="analysis-head">
        <span className="dim">flaky detector</span>
      </div>
      <div className="flaky-result">
        {flaky.stable ? (
          <span className="s-pass">
            ● stable · 0 flaky across {flaky.runs} runs ({flaky.checked} tests)
          </span>
        ) : (
          <>
            <span className="s-fail">
              ⚠ {flaky.flaky.length} flaky test(s) over {flaky.runs} runs
            </span>
            {flaky.flaky.map((f, i) => (
              <div key={i} className="flaky-row">
                <span className="if-path">
                  {f.file} › {f.name}
                </span>
                <span className="dim">
                  {f.passed}✓ / {f.failed}✗
                </span>
              </div>
            ))}
          </>
        )}
      </div>
    </div>
  );
}

/** The Details accordion's on-demand tools, folded from the old AnalysisPanel (coverage
 *  + flaky) and MutationLane's trigger button into one row (notes/verify-redesign-
 *  plan.md). Each button's result renders below it via `CoverageResult`/`FlakyResult`/
 *  `MutationResults`. */
function ToolsRow({
  busy,
  coverage,
  flaky,
  analyzing,
  onCoverage,
  onFlaky,
  mutRunning,
  hasResult,
  canScore,
  onRunMutation,
  canRefute = false,
  refuteReady = false,
  refuting = false,
  onRunRefuter,
}: {
  busy: boolean;
  coverage: CoverageResponse | null;
  flaky: FlakyResponse | null;
  analyzing: string | null;
  onCoverage: () => void;
  onFlaky: () => void;
  mutRunning: boolean;
  hasResult: boolean;
  canScore: boolean;
  onRunMutation: () => void;
  /** The project has a `[roles] review` role configured at all — gates whether the
   *  button renders. Unlike `canScore` (mutation, always available), a project with no
   *  review role has nothing this button would meaningfully run, so it's hidden
   *  entirely rather than shown disabled. */
  canRefute?: boolean;
  /** Gate is green and has a run to refute — gates whether the (visible) button is
   *  ENABLED, same "disabled while busy or on a red gate" rule as every other tool
   *  here (canScore's rule, split into its own prop since `canRefute` already answers
   *  a different question). */
  refuteReady?: boolean;
  refuting?: boolean;
  onRunRefuter?: () => void;
}) {
  return (
    <div className="gate-tools">
      <button className="ghost" onClick={onCoverage} disabled={busy || analyzing != null} title="Re-run the suite and compare line coverage against the base branch.">
        {analyzing === "coverage" ? "measuring…" : coverage ? "re-measure coverage" : "measure coverage vs base"}
      </button>
      <button className="ghost" onClick={onFlaky} disabled={busy || analyzing != null} title="Re-run the suite 5× to spot tests that flip between passes.">
        {analyzing === "flaky" ? "re-running…" : flaky ? "re-check flaky" : "check flaky ×5"}
      </button>
      <button
        className="ghost"
        onClick={onRunMutation}
        disabled={busy || analyzing != null || !canScore}
        title="How hard are the tests to fool: inject one fault at a time into the changed lines and re-run the tests."
      >
        {mutRunning ? "scoring…" : hasResult ? "re-score tests" : "how hard are the tests to fool"}
      </button>
      {/* On-demand review: hidden (not just disabled) when the project has no
          `[roles] review` role configured — a permanently-greyed-out button that
          will never work is worse than no button. */}
      {canRefute && (
        <button
          className="ghost"
          onClick={onRunRefuter}
          disabled={busy || analyzing != null || !refuteReady}
          title="Re-run review: an independent re-check of this diff against the task/plan, with read-only tools to open files around it."
        >
          {refuting ? "reviewing…" : "review now"}
        </button>
      )}
    </div>
  );
}

/** Mutation score results (backlog/mutation-gate.md). Advisory: the copy never says
 *  verified/proven/correct — a survivor is a fault the tests can't tell apart, not a bug
 *  proven present, and nothing here can block a merge. The trigger button lives in
 *  `ToolsRow`; this is just the result body. */
function MutationResults({
  running,
  result,
  error,
  onKillSurvivors,
  onSendSurvivorsToBacklog,
}: {
  running: boolean;
  result: MutationResponse | null;
  error: string | null;
  onKillSurvivors?: (survivors: MutationSurvivor[]) => void;
  onSendSurvivorsToBacklog?: (survivors: MutationSurvivor[]) => void;
}) {
  return (
    <div className="review-lane">
      <div className="rv-head">
        <span className="rv-title">
          how hard are the tests to fool
          <span className="dim"> · advisory, never blocks the gate</span>
        </span>
      </div>

      {running && (
        <div className="rv-running">
          <span className="rv-spinner" /> mutating the diff: one injected fault at a time, a test re-run each — this
          takes a moment.
        </div>
      )}

      {error && (
        <div className="gate-errcard gate-errcard-runner">
          <div className="gate-errcard-head">
            <span className="gate-errcard-title">scoring didn’t run</span>
          </div>
          <p className="gate-errcard-hint">{error}</p>
        </div>
      )}

      {!running && result && !result.supported && (
        <div className="empty rv-empty">{result.note ?? "mutation score is unavailable here"}</div>
      )}

      {!running && result && result.supported && (
        <>
          <div className="rv-summary">
            {result.score == null ? (
              <>No runnable mutants{result.note ? `, ${result.note}` : ""}.</>
            ) : (
              <>
                Mutation score <strong>{result.score}%</strong>: the suite caught {result.killed} of{" "}
                {result.killed + result.survived} injected faults
                {result.skipped > 0 ? ` (${result.skipped} didn’t compile, skipped)` : ""}
                {result.budget_capped ? ` · ${result.note ?? "capped"}` : ""}.
              </>
            )}
          </div>
          {result.survivors.length === 0 ? (
            result.score != null && <div className="rv-clean">✓ every injected fault was caught, these tests are hard to fool</div>
          ) : (
            <>
              {onKillSurvivors && (
                <div className="rv-batch-actions">
                  <button
                    className="ghost rv-batch-fix"
                    onClick={() => onKillSurvivors(result.survivors)}
                    title="Send every surviving mutant (file:line · operator) to the agent as one kill-the-survivors task"
                  >
                    + kill survivors → agent
                  </button>
                  {onSendSurvivorsToBacklog && (
                    <button
                      className="ghost rv-batch-fix"
                      onClick={() => onSendSurvivorsToBacklog(result.survivors)}
                      title="Queue every surviving mutant as a backlog follow-up instead"
                    >
                      + send to backlog
                    </button>
                  )}
                  <span className="dim">
                    {result.survivors.length} survivor{result.survivors.length === 1 ? "" : "s"} → one follow-up task
                  </span>
                </div>
              )}
              <ul className="rv-list">
                {result.survivors.map((s, i) => (
                  <li key={i} className="rv-item rv-item-medium">
                    <div className="rv-item-head">
                      <span className="rv-sev rv-sev-medium">faults the tests missed</span>
                      <span className="rv-loc dim">
                        {s.path.split("/").pop()}:{s.line}
                      </span>
                    </div>
                    <div className="rv-item-title">
                      <code>{s.operator}</code>, no test failed when this was changed
                    </div>
                  </li>
                ))}
              </ul>
            </>
          )}
        </>
      )}
    </div>
  );
}

/** The green* reason chip: an otherwise-green gate whose test suite changed in a way
 *  the tamper alarm flags (tests removed, `.skip`/`.only` added, assertions or
 *  snapshots gutted). Collapsed it's the compact note; click to drill into each
 *  finding's kind · test · detail · file. Red when block mode turned the finding
 *  merge-blocking (the only mode this now renders in — Zone 2 is blockers-only; a
 *  warn-mode finding is a Zone 3 "look at" row instead). */
function TamperBanner({
  findings,
  note,
  blocked,
  onRestore,
  defaultOpen = false,
}: {
  findings: TamperFinding[];
  note: string | null;
  blocked: boolean;
  onRestore?: (findings: TamperFinding[]) => void;
  /** Start expanded — set when time-travelling, since clicking a starred ribbon dot IS
      the request to see that run's findings. Read once at mount, so the caller keys the
      banner by run id to re-apply it when you hop between dots. */
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  const summary = tamperSummary(findings, note);
  return (
    <div className={"gate-tamper" + (blocked ? " gate-tamper-block" : "")}>
      <button
        className="gate-tamper-head"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        title="Test-suite integrity: how the suite changed vs the base branch. Click for per-finding detail."
      >
        <Chevron open={open} />
        <span className="gate-tamper-badge">
          green<span className="gate-tamper-star">*</span>
        </span>
        {blocked && <span className="gate-tamper-flag">🛑 blocked</span>}
        <span className="gate-tamper-note">{summary}</span>
      </button>
      {blocked && (
        <div className="gate-tamper-sub dim">
          restore the weakened tests, or set <code>tamper_alarm</code> to “warn” to ship
        </div>
      )}
      {/* The green* action row — always visible (not gated on `open`), because this is
          the whole point of the chip: a suspicious green must route to a fix as
          directly as a red does via "fix all → agent". */}
      {onRestore && (
        <div className="gate-tamper-actions">
          <button
            className="ghost gate-tamper-fix"
            onClick={() => onRestore(findings)}
            title="Send every tamper finding (kind · test · file) to the agent as one restore task"
          >
            + restore weakened tests → agent
          </button>
          <span className="dim">
            {findings.length} finding{findings.length === 1 ? "" : "s"} → one follow-up task
          </span>
        </div>
      )}
      {open && (
        <ul className="gate-tamper-list">
          {findings.map((f, i) => (
            <li key={i} className={"gate-tamper-item gate-tamper-kind-" + f.kind}>
              <span className="tf-kind">{tamperKindLabel(f.kind)}</span>
              {f.test && <span className="tf-test">{f.test}</span>}
              {f.detail && <span className="tf-detail dim">{f.detail}</span>}
              {f.file && (
                <span className="tf-file dim" title={f.file}>
                  {f.file.split("/").pop()}
                </span>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** THE DOUBLE GATE's findings panel (backlog/double-gate.md §2), Zone 2's blocking-only
 *  render (an advisory quality finding is a Zone 3 "look at" row instead).
 *
 *  Deliberately the same shape as `TamperBanner` above — chip, expandable detail, one
 *  action row — because they answer the same question in different registers ("is this
 *  green trustworthy?") and a reader shouldn't have to learn two layouts for that. */
function QualityBanner({
  findings,
  note,
  blocked,
  onFix,
  defaultOpen = false,
}: {
  findings: QualityFindingRow[];
  note: string | null;
  blocked: boolean;
  onFix?: (findings: QualityFindingRow[]) => void;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  const groups = groupQualityFindings(findings);
  const blocking = findings.filter((f) => f.blocking).length;
  const summary = qualitySummary(findings.length, blocking, note);
  return (
    <div className={"gate-quality" + (blocked ? " gate-quality-block" : "")}>
      <button
        className="gate-quality-head"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        title="Quality gate: secrets, security patterns and your linter, scoped to this diff. Click for per-finding detail."
      >
        <Chevron open={open} />
        <span className="gate-quality-badge">quality</span>
        {blocked && <span className="gate-quality-flag">🛑 blocked</span>}
        <span className="gate-quality-note">{summary}</span>
      </button>
      {blocked && (
        <div className="gate-quality-sub dim">
          fix the blocking findings, or raise <code>severity_threshold</code> / set <code>enforce</code> to “warn” to
          ship
        </div>
      )}
      {onFix && blocking > 0 && (
        <div className="gate-quality-actions">
          <button
            className="ghost gate-quality-fix"
            onClick={() => onFix(findings)}
            title="Send every blocking quality finding (tool · rule · file:line) to the agent as one fix task"
          >
            + fix all quality → agent
          </button>
          <span className="dim">
            {blocking} blocking finding{blocking === 1 ? "" : "s"} → one follow-up task
          </span>
        </div>
      )}
      {open && (
        <div className="gate-quality-groups">
          {groups.map((g) => (
            <div key={g.tool} className="gate-quality-group">
              <div className="gate-quality-group-head">
                <span className="qf-tool">{g.tool}</span>
                <span className="dim">
                  {g.findings.length} finding{g.findings.length === 1 ? "" : "s"}
                  {g.blocking > 0 && ` · ${g.blocking} blocking`}
                </span>
              </div>
              <ul className="gate-quality-list">
                {g.findings.map((f, i) => (
                  <li key={i} className={"gate-quality-item qf-sev-" + f.severity + (f.blocking ? " qf-blocking" : "")}>
                    <span className="qf-sev">{f.severity}</span>
                    <span className="qf-rule">{f.rule}</span>
                    <span className="qf-msg dim">{f.message}</span>
                    {qualityLocation(f) && (
                      <span className="qf-loc dim" title={f.file}>
                        {qualityLocation(f)}
                      </span>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

/** THE REFUTER's findings panel (Phase 3 of notes/workflow-roles-plan.md), Zone 2's
 *  blocking-only render — a non-blocking must-fix (warn mode) or a pass-with-notes is a
 *  Zone 3 "look at" row instead (see verdict.ts's lookAt). Same shape as `QualityBanner`
 *  above on purpose: it answers the same question ("is this green trustworthy?") in a
 *  different register, and a reader shouldn't have to learn two layouts for that. */
function RefuterBanner({
  verdict,
  blocked,
  onFix,
  defaultOpen = false,
}: {
  verdict: ReviewVerdict | null;
  blocked: boolean;
  onFix?: (mustFix: ReviewMustFix[]) => void;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  const mustFix = verdict?.must_fix ?? [];
  const n = mustFix.length;
  return (
    <div className={"gate-quality" + (blocked ? " gate-quality-block" : "")}>
      <button
        className="gate-quality-head"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        title="Review: an independent re-check of the diff against the task/plan, with read-only tools. Click for per-finding detail."
      >
        <Chevron open={open} />
        <span className="gate-quality-badge">review</span>
        {blocked && <span className="gate-quality-flag">🛑 blocked</span>}
        <span className="gate-quality-note">
          {n} must-fix finding{n === 1 ? "" : "s"}
          {verdict?.summary ? ` · ${verdict.summary}` : ""}
        </span>
      </button>
      {blocked && (
        <div className="gate-quality-sub dim">
          fix the must-fix findings, or set <code>[roles] review_enforce</code> to “warn” to ship
        </div>
      )}
      {onFix && n > 0 && (
        <div className="gate-quality-actions">
          <button
            className="ghost gate-quality-fix"
            onClick={() => onFix(mustFix)}
            title="Send every must-fix finding (file:line + the cited diff line) to the agent as one fix task"
          >
            + fix all → agent
          </button>
          <span className="dim">
            {n} must-fix finding{n === 1 ? "" : "s"} → one follow-up task
          </span>
        </div>
      )}
      {open && (
        <ul className="gate-quality-list">
          {mustFix.map((mf, i) => (
            <li key={i} className="gate-quality-item qf-blocking qf-item-column">
              <div className="qf-item-row">
                <span className="qf-rule">{mf.title}</span>
                {mf.detail && <span className="qf-msg dim">{mf.detail}</span>}
                <span className="qf-loc dim" title={mf.file}>
                  {mf.line ? `${mf.file}:${mf.line}` : mf.file}
                </span>
              </div>
              {mf.cited && (
                <details className="qf-cited">
                  <summary className="dim">cited</summary>
                  <pre className="qf-cited-line">{mf.cited}</pre>
                </details>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** Regression ribbon: one dot per past gate run, newest on the right. A `green*` run
    (tamper findings) wears an asterisk, so history tells you which greens were clean —
    see `ribbonDot`. */
function Ribbon({
  history,
  activeId,
  onPick,
  pulse = false,
}: {
  history: TestRun[];
  activeId: string | null;
  onPick: (id: string) => void;
  pulse?: boolean;
}) {
  return (
    <span
      className={"ribbon" + (pulse ? " ribbon-pulse" : "")}
      title="gate history (oldest → newest) · click a dot to time-travel · * = green (tamper findings)"
    >
      {history.slice(-24).map((h) => {
        const dot = ribbonDot(h, activeId === h.id);
        return <button key={h.id} className={dot.className} onClick={() => onPick(h.id)} title={dot.title} />;
      })}
    </span>
  );
}

/** A gate that couldn't *run* — framed plainly (setup vs no-tests vs crash), with the
    raw log tucked below and a retry, so it doesn't read like a test failure.

    For an adopted (foreign) worktree a setup-kind error is "environment, not code": the
    worktree's provisioning isn't ready, so the primary fix is re-running setup (not the
    gate). We surface that affordance first and keep re-run-gate as the follow-up. */
function GateErrorCard({
  error,
  kind,
  onRun,
  busy,
  adopted = false,
  onReRunSetup,
}: {
  error: string | null;
  kind: "setup" | "no_tests" | "runner" | null;
  onRun: () => void;
  busy: boolean;
  adopted?: boolean;
  onReRunSetup?: () => void;
}) {
  const envNotCode = kind === "setup" && adopted;
  const { title, hint } = gateErrorFraming(kind, adopted);
  return (
    <div className={`gate-errcard gate-errcard-${kind ?? "runner"}${envNotCode ? " gate-errcard-env" : ""}`}>
      <div className="gate-errcard-head">
        <span className="gate-errcard-title">{title}</span>
        {envNotCode && onReRunSetup && (
          <button
            className="primary"
            onClick={onReRunSetup}
            disabled={busy}
            title="Re-run this worktree's setup script to provision its deps/toolchain"
          >
            re-run setup
          </button>
        )}
        <button className="ghost" onClick={onRun} disabled={busy} title="Re-run the gate">
          re-run gate
        </button>
      </div>
      <p className="gate-errcard-hint">{hint}</p>
      {error && <pre className="gate-error">{error}</pre>}
    </div>
  );
}

function CellDetail({
  cell,
  blame = [],
  onAddComment,
  onSendTestToBacklog,
}: {
  cell: Cell;
  blame?: BlameHunk[];
  onAddComment?: (target: string, context: string | null) => void;
  /** "Send to backlog" sibling of onAddComment (backlog/backlog-v2.md Move 3): defer
   *  this failing test instead of routing it to the current agent right now. */
  onSendTestToBacklog?: (target: string, context: string | null) => void;
}) {
  return (
    <div className={`cell-detail cell-detail-${cell.status}`}>
      <div className="cd-head">
        <span className={`case-glyph case-${cell.status}`}>
          {cell.status === "passed" ? "✓" : cell.status === "failed" ? "✗" : "○"}
        </span>
        <span className="cd-name">{cell.name}</span>
        {cell.status === "failed" && onAddComment && (
          <button
            className="ghost cd-comment"
            onClick={() => onAddComment(`test: ${cell.name}`, cell.message)}
            title="send this failure to the agent to fix"
          >
            + comment → agent
          </button>
        )}
        {cell.status === "failed" && onSendTestToBacklog && (
          <button
            className="ghost cd-comment"
            onClick={() => onSendTestToBacklog(`test: ${cell.name}`, cell.message)}
            title="queue this failure as a backlog follow-up instead of fixing it now"
          >
            + backlog
          </button>
        )}
      </div>
      <div className="cd-file dim">
        {cell.file}
        {cell.duration_ms != null ? ` · ${cell.duration_ms.toFixed(1)}ms` : ""}
      </div>
      {cell.message && <pre className="case-msg">{cell.message}</pre>}
      {blame.length > 0 && <BlameBox hunks={blame} />}
    </div>
  );
}

/** Failure → blame: the changed lines this failure's stack runs through — turns
    "test X is red" into "because you changed line Y". */
function BlameBox({ hunks }: { hunks: BlameHunk[] }) {
  return (
    <div className="cd-blame">
      <div className="cd-blame-head dim">
        ⤳ likely from your changes
        <span className="cd-blame-sub"> · lines you changed appear in this failure’s trace</span>
      </div>
      <ul className="cd-blame-list">
        {hunks.map((h, i) => (
          <li key={i} className="cd-blame-item">
            <span className="cd-blame-loc">
              {h.file.split("/").pop()}
              {h.line != null ? `:${h.line}` : ""}
            </span>
            {h.code ? (
              <code className="cd-blame-code">{h.code}</code>
            ) : (
              <span className="dim"> · changed file (no single line pinned)</span>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}
