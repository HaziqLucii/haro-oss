// The ③ verify step's single derivation layer (notes/verify-redesign-plan.md). Every
// consumer of "can I ship this / what's wrong / what should I still look at" — the
// pane-head chip, the flow stepper's badge, the verdict-first page's headline, the
// blockers list, the "things to look at" zone — reads off these functions so they
// cannot disagree by construction. Pure, UI-free, unit-tested (verdict.test.ts).
import type { Cell, MutationSurvivor, QualityFindingRow, ReviewMustFix, TamperFinding, TestRun, UncheckedRow } from "./types";
import {
  coverageBlockHint,
  gateErrorFraming,
  mutationReviewItems,
  qualityReviewItems,
  qualitySummary,
  reviewMustFixItems,
  tamperKindLabel,
  tamperReviewItems,
  tamperSummary,
  uncheckedKindLabel,
  uncheckedReviewItems,
  uncheckedState,
} from "./gate";

export interface Tally {
  passed: number;
  failed: number;
  skipped: number;
  inflight: number;
  total: number;
}

/** Cell counts the pane head, the running badge and the grid summary all draw from —
 *  one place so "3 of 9" never disagrees with the grid it describes. */
export function tally(cells: Cell[]): Tally {
  const done = cells.filter((c) => c.status !== "running");
  return {
    passed: cells.filter((c) => c.status === "passed").length,
    failed: cells.filter((c) => c.status === "failed").length,
    skipped: cells.filter((c) => c.status === "skipped").length,
    inflight: cells.length - done.length,
    total: cells.length,
  };
}

/** A run's OWN status collapsed to what a badge needs to say, independent of the
 *  workspace-level status (which lags a beat behind the run that just landed, and
 *  which folds "tests failed" and "the gate crashed" into the same `gate_red`). */
export function statusForRun(run: TestRun | null): "none" | "running" | "error" | "failed" | "passed" {
  if (!run) return "none";
  if (run.status === "running") return "running";
  if (run.status === "error") return "error";
  if (run.status === "failed") return "failed";
  return "passed";
}

/**
 * True when the gate cannot honestly ship, for a reason the "ready/blocked" pair alone
 * doesn't capture: a red gate always blocks, but so does an otherwise-green run that's
 * DEGRADED (a check the project asked for didn't run — backlog/double-gate.md §0). Ship
 * used to read "ready" on a degraded green because it only ever looked at `status`; this
 * is the one place that stops lying. `integrate.ship_preflight` already refuses this ship
 * server-side — this just makes the stepper agree with it.
 */
export function isCantShip(status: string, run: TestRun | null): boolean {
  if (status === "gate_red") return true;
  if (status === "gate_green" && (run?.degraded_reasons?.length ?? 0) > 0) return true;
  return false;
}

/** The verify step's FlowState. `run` is optional so every existing call site (which
 *  only ever had `status`) keeps behaving exactly as before. */
export function verdictFlowState(status: string, run: TestRun | null = null): "done" | "active" | "blocked" | "ready" | "todo" {
  if (status === "tests_running") return "active";
  if (status === "merged") return "done";
  if (isCantShip(status, run)) return "blocked";
  if (status === "gate_green") return "done";
  return "todo";
}

/**
 * The verify step's badge (and the pane-head chip, once wired). `passed`/`failed` are
 * the old flat inputs every call site already had; `run`/`cells` are new and optional —
 * when absent the badge is byte-identical to the pre-redesign logic. When present they
 * add: a live "x of y" while running, `*` when the tamper alarm starred this green, and
 * "didn't run" instead of "failed" when the gate crashed rather than the tests failing.
 */
export function verdictBadge({
  status,
  passed = 0,
  failed = 0,
  run = null,
  cells = [],
}: {
  status: string;
  passed?: number;
  failed?: number;
  run?: TestRun | null;
  cells?: Cell[];
}): { text: string; tone: string } | null {
  const green = status === "gate_green";
  const red = status === "gate_red";
  const merged = status === "merged";
  const testing = status === "tests_running";
  const p = run?.passed ?? passed;
  const f = run?.failed ?? failed;
  const ran = p + f > 0;
  // green* (backlog/tamper-alarm.md §3): the suite passed but changed suspiciously.
  // Starred on the badge itself, not just the pane head, so the stepper never claims a
  // plainer green than the one the gate actually returned.
  const star = (run?.tamper_findings?.length ?? 0) > 0 ? "*" : "";

  if (testing) {
    const t = tally(cells);
    return t.total > 0
      ? { text: `gate… ${t.total - t.inflight}/${t.total}`, tone: "run" }
      : { text: "gate…", tone: "run" };
  }
  // The gate never ran at all (setup/no_tests/runner crash) — a categorically different
  // claim from "the tests ran and some failed", so it gets its own word.
  if (red && run?.status === "error") return { text: "didn't run", tone: "bad" };
  if (ran) return { text: `${p}✓ ${f}✗${star}`, tone: f ? "bad" : "ok" };
  if (green || merged) return { text: `passed${star}`, tone: "ok" };
  if (red) return { text: "failed", tone: "bad" };
  return null;
}

// --------------------------------------------------------------------------------- //
// Zone 2: Blockers — everything that keeps this gate from shipping, one sentence + its
// fix per row. Order is fixed (notes/verify-redesign-plan.md): a reader should never
// have to guess which blocker is "the real one" — it's always the first.
// --------------------------------------------------------------------------------- //

export type BlockerKind =
  | "gate_error"
  | "failing_tests"
  | "merge_conflict"
  | "tamper_blocked"
  | "quality_blocked"
  | "review_blocked"
  | "coverage_blocked"
  | "degraded";

export type BlockerFixAction =
  | "rerun_gate"
  | "rerun_setup"
  | "fix_all"
  | "restore_tampered"
  | "fix_quality"
  | "fix_review"
  | "open_gate_settings";

export interface Blocker {
  kind: BlockerKind;
  text: string;
  fix: { label: string; action: BlockerFixAction } | null;
}

const BLOCKER_ORDER: BlockerKind[] = [
  "gate_error",
  "failing_tests",
  "merge_conflict",
  "tamper_blocked",
  "quality_blocked",
  "review_blocked",
  "coverage_blocked",
  "degraded",
];

export interface VerdictInputs {
  status: string;
  run: TestRun | null;
  cells: Cell[];
  checkedKeys?: string[];
  survivors?: MutationSurvivor[] | null;
  /** Whether the project opted into code-to-check ([workflow] code_to_check) — the
   *  feature flag lives on project config, not on the run itself. */
  codeToCheck?: { enabled: boolean };
  adopted?: boolean;
  /** True when this verdict describes a past (time-travelled) run — callers withhold
   *  every action for a past run, the same rule GatePanel already applies. */
  past?: boolean;
}

/**
 * True when a high-confidence, non-compliant plan verdict is plausibly WHY
 * `quality_blocked` is set — the one path that could block on plan compliance alone,
 * with no deterministic finding involved (a legacy shape: `[quality] plan_compliance
 * = "block"` was cut 2026-09-17, so no NEW run can set `quality_blocked` this way, but
 * a run gated before the cut can still carry it, and the UI has to render it sensibly).
 * The frontend has no way to see which specific check tripped `quality_blocked`
 * when several are eligible (`PlanComplianceResult` carries no mode, and the backend's
 * own `blocking` derivation is a `@property`, never serialized), so this is a heuristic,
 * not a certainty — used identically by `blockers()` (to name the gaps) and `lookAt()`
 * (to exclude them), so the two can never drift into "dropped from both" or "shown in
 * both" independently of each other.
 */
function planComplianceIsBlocking(run: TestRun | null): boolean {
  if (!run?.quality_blocked) return false;
  const pc = run.plan_compliance;
  return !!pc && pc.confidence === "high" && !pc.compliant && pc.gaps.length > 0;
}

/** Every reason this gate refuses to ship, in the fixed order above. A gate error stops
 *  here (there is nothing else to judge if the gate never ran). */
export function blockers({ run, adopted = false }: VerdictInputs): Blocker[] {
  if (!run) return [];
  const out: Blocker[] = [];

  if (run.status === "error") {
    const framing = gateErrorFraming(run.error_kind, adopted);
    out.push({
      kind: "gate_error",
      text: framing.title,
      fix:
        run.error_kind === "setup" && adopted
          ? { label: "re-run setup", action: "rerun_setup" }
          : { label: "re-run gate", action: "rerun_gate" },
    });
    return out;
  }

  const failed = run.failed ?? 0;
  if (failed > 0) {
    out.push({
      kind: "failing_tests",
      text: `${failed} failing test${failed === 1 ? "" : "s"}`,
      fix: { label: "fix all → agent", action: "fix_all" },
    });
  }

  if (run.merge_conflict) {
    out.push({
      kind: "merge_conflict",
      text: run.merge_note ?? "can't merge the base branch into this workspace",
      fix: null,
    });
  }

  if (run.tamper_blocked) {
    out.push({
      kind: "tamper_blocked",
      text: tamperSummary(run.tamper_findings ?? [], run.tamper_note ?? null),
      fix: { label: "restore weakened tests → agent", action: "restore_tampered" },
    });
  }

  if (run.quality_blocked) {
    const findings = run.quality_findings ?? [];
    const blocking = findings.filter((f) => f.blocking).length;
    // Joined, not a fallback: when the plan verdict IS excluded from Zone 3 (see
    // `lookAt`'s matching `planComplianceIsBlocking` check), it needs a home here
    // regardless of whether deterministic findings ALSO exist on the same run — a
    // scanner finding must never silently swallow a plan gap out of the UI entirely.
    const pc = run.plan_compliance;
    const planGaps = pc && planComplianceIsBlocking(run) ? pc.gaps.length : 0;
    const parts = [
      qualitySummary(findings.length, blocking, run.quality_note ?? null),
      planGaps > 0 ? `${planGaps} plan requirement${planGaps === 1 ? "" : "s"} not implemented` : null,
    ].filter((p): p is string => !!p);
    out.push({
      kind: "quality_blocked",
      text: parts.length > 0 ? parts.join(" · ") : "quality findings block this gate",
      fix: { label: "fix all quality → agent", action: "fix_quality" },
    });
  }

  // REVIEW (the refuter role, Phase 3 of notes/workflow-roles-plan.md):
  // `review_blocked` is structurally always false since 2026-09-17
  // (`review_enforce = "block"`, the only thing that ever set it, was cut — an
  // LLM verdict never blocks a merge on its own). This branch is dead in
  // practice; kept for symmetry with quality_blocked above.
  if (run.review_blocked) {
    const n = run.review?.must_fix.length ?? 0;
    const text = n > 0 ? `review: ${n} must-fix finding${n === 1 ? "" : "s"}` : "review: must-fix findings block this gate";
    out.push({
      kind: "review_blocked",
      text: run.review?.summary ? `${text} — ${run.review.summary}` : text,
      fix: { label: "fix all → agent", action: "fix_review" },
    });
  }

  if (run.coverage_blocked) {
    out.push({
      kind: "coverage_blocked",
      text: run.coverage_note ?? "coverage dropped below the guard",
      fix: { label: coverageBlockHint(run.coverage_delta), action: "open_gate_settings" },
    });
  }

  if ((run.degraded_reasons?.length ?? 0) > 0) {
    out.push({
      kind: "degraded",
      text: "a check didn't run",
      fix: { label: "re-run gate", action: "rerun_gate" },
    });
  }

  return out.sort((a, b) => BLOCKER_ORDER.indexOf(a.kind) - BLOCKER_ORDER.indexOf(b.kind));
}

// --------------------------------------------------------------------------------- //
// Zone 3: Look at — advisory signals that can never block a merge, but are worth a
// human's eyes. Each pending item carries the raw finding so `lookAtReviewItems` can
// route it through the same composer builder the blocking flows already use.
// --------------------------------------------------------------------------------- //

export type LookAtItem =
  | { kind: "code_to_check"; key: string; text: string; raw: UncheckedRow }
  | { kind: "tamper"; key: string; text: string; raw: TamperFinding }
  | { kind: "plan_gap"; key: string; text: string; raw: { item: string; why: string; cited: string } }
  | { kind: "quality"; key: string; text: string; raw: QualityFindingRow }
  | { kind: "review"; key: string; text: string; raw: ReviewMustFix }
  | { kind: "review_note"; key: string; text: string; raw: string }
  | { kind: "flaky"; key: string; text: string; raw: string }
  | { kind: "coverage"; key: string; text: string; raw: { note: string } }
  | { kind: "mutation"; key: string; text: string; raw: MutationSurvivor };

export interface LookAt {
  pending: LookAtItem[];
  /** Ticked-off items — only code-to-check rows are tickable today. */
  done: LookAtItem[];
}

/** Everything to look at, in the fixed order (notes/verify-redesign-plan.md): code to
 *  check, tamper findings under warn mode, plan gaps, advisory quality findings,
 *  suspected-flaky tests, a warn-mode coverage drop, then mutation survivors once
 *  scored. Blocked signals (tamper_blocked, quality_blocked, coverage_blocked) are
 *  Blockers, not look-at rows — the same finding never appears in both zones. */
export function lookAt({ run, checkedKeys = [], survivors, codeToCheck }: VerdictInputs): LookAt {
  const pending: LookAtItem[] = [];
  const done: LookAtItem[] = [];

  if (codeToCheck?.enabled && run) {
    const state = uncheckedState({
      enabled: true,
      rows: run.unchecked_items,
      coveredFiles: run.unchecked_covered_files,
      checkedKeys,
      status: run.status,
      scope: run.scope,
    });
    if (state.kind === "rows") {
      for (const r of state.pending) {
        pending.push({ kind: "code_to_check", key: r.key, text: rowText(r), raw: r });
      }
      for (const r of state.done) {
        done.push({ kind: "code_to_check", key: r.key, text: rowText(r), raw: r });
      }
    }
  }

  if (run && !run.tamper_blocked) {
    for (const f of run.tamper_findings ?? []) {
      const where = f.test || f.file;
      pending.push({
        kind: "tamper",
        key: `tamper:${f.kind}:${f.file}:${f.test ?? ""}`,
        text: where ? `${tamperKindLabel(f.kind)}: ${where}` : tamperKindLabel(f.kind),
        raw: f,
      });
    }
  }

  // When `planComplianceIsBlocking` holds, the gaps are the blocking cause and belong in
  // Zone 2 via `blockers()` (which names them there, always — see its comment), not Zone
  // 3 — the same "never in both zones" rule the tamper/quality findings above follow.
  if (!planComplianceIsBlocking(run)) {
    for (const g of run?.plan_compliance?.gaps ?? []) {
      pending.push({ kind: "plan_gap", key: `plan:${g.item}`, text: g.item, raw: g });
    }
  }

  for (const f of run?.quality_findings ?? []) {
    // `f.blocking` is severity-vs-threshold, set independent of `[quality] enforce`
    // (backend/haro/gate.py). Under enforce="warn" a finding can be `blocking: true`
    // while `run.quality_blocked` stays false, so it never reaches Zone 2 either —
    // excluding it here on `f.blocking` alone would drop it from BOTH zones. Only skip
    // it here when it's actually rendered as a Zone 2 blocker, i.e. when the run itself
    // is quality_blocked (never in both zones, but never in neither either).
    if (f.blocking && run?.quality_blocked) continue;
    pending.push({
      kind: "quality",
      key: `quality:${f.tool}:${f.rule}:${f.file}:${f.line ?? ""}`,
      text: `${f.tool}: ${f.rule}`,
      raw: f,
    });
  }

  // THE REFUTER (Phase 3): "never in both zones" — a blocking verdict already has its
  // home in blockers() above; only a non-blocking one (warn mode, or a "fail" verdict
  // under an unenforced/off policy) surfaces its must-fix list here instead. A clean
  // PASS with non-blocking notes gets its own row kind so an observation worth reading
  // isn't silently dropped just because nothing failed.
  if (run?.review && !run.review_blocked) {
    if (run.review.verdict === "fail") {
      for (const mf of run.review.must_fix) {
        const where = mf.line ? `${mf.file}:${mf.line}` : mf.file;
        pending.push({
          kind: "review",
          key: `review:${mf.file}:${mf.line ?? ""}:${mf.title}`,
          text: `${where} — ${mf.title}`,
          raw: mf,
        });
      }
    } else {
      for (const note of run.review.notes) {
        pending.push({ kind: "review_note", key: `review_note:${note}`, text: note, raw: note });
      }
    }
  }

  for (const name of run?.flaky_tests ?? []) {
    pending.push({ kind: "flaky", key: `flaky:${name}`, text: name, raw: name });
  }

  if (run?.coverage_note && !run.coverage_blocked) {
    pending.push({ kind: "coverage", key: "coverage", text: run.coverage_note, raw: { note: run.coverage_note } });
  }

  for (const s of survivors ?? []) {
    pending.push({
      kind: "mutation",
      key: `mutation:${s.path}:${s.line}`,
      text: `${s.path.split("/").pop()}:${s.line} · ${s.operator}`,
      raw: s,
    });
  }

  return { pending, done };
}

function rowText(r: UncheckedRow): string {
  const label = uncheckedKindLabel(r.kind);
  return r.file ? `${label}: ${r.file}` : label;
}

/**
 * Why nothing from code-to-check showed up in `lookAt`, when that's worth saying: the
 * gate never measured the diff (red gate, impacted-only run), or measured it but the
 * coverage half couldn't speak about it. Null when the feature is off, when it found
 * rows (already in `lookAt().pending`), or when it was earnestly clean — `uncheckedState`
 * earns several honesty distinctions that a single pending-count can't carry, and Phase 2
 * surfaces them as one caveat line instead of a dedicated empty state per source.
 */
export function codeToCheckCaveat(inputs: VerdictInputs): string | null {
  const { run, codeToCheck, checkedKeys = [] } = inputs;
  if (!codeToCheck?.enabled || !run) return null;
  const state = uncheckedState({
    enabled: true,
    rows: run.unchecked_items,
    coveredFiles: run.unchecked_covered_files,
    checkedKeys,
    status: run.status,
    scope: run.scope,
  });
  if (state.kind === "unmeasured" || state.kind === "quiet") return state.reason;
  return null;
}

/**
 * The Zone 1 verdict card's caveat line for a clean review pass ("review: PASS
 * (<model>)"), so a green gate visibly carries the review instead of the refuter's
 * work being invisible unless it found something. Null when never measured, when it
 * couldn't run (that's a `degraded` reason instead), or on a "fail" verdict — a fail's
 * story is already told by `blockers()` (blocking) or `lookAt()` (advisory), never by
 * a Zone 1 caveat too.
 */
export function reviewCaveat(run: TestRun | null): string | null {
  if (!run?.review || run.review.error || run.review.verdict !== "pass") return null;
  return `review: PASS (${run.review.model})`;
}

/** Turn selected look-at items into the composer's `{target, context, text}` round-trip
 *  shape, routing each kind through the same builder the blocking flows already use
 *  (`uncheckedReviewItems`, `tamperReviewItems`, …), so "send all" from Zone 3 is not a
 *  second, divergent wording of the same ask. Quality findings pass `includeAdvisory:
 *  true` deliberately: everything reaching this function already survived the
 *  blocking-findings filter in `lookAt`, so nothing here is a duplicate of Zone 2. */
export function lookAtReviewItems(items: LookAtItem[]): { target: string; context: string | null; text: string }[] {
  const out: { target: string; context: string | null; text: string }[] = [];
  for (const it of items) {
    switch (it.kind) {
      case "code_to_check":
        out.push(...uncheckedReviewItems([it.raw]));
        break;
      case "tamper":
        out.push(...tamperReviewItems([it.raw]));
        break;
      case "quality":
        out.push(...qualityReviewItems([it.raw], { includeAdvisory: true }));
        break;
      case "review":
        out.push(...reviewMustFixItems([it.raw]));
        break;
      case "review_note":
        out.push({ target: "refuter note", context: null, text: it.raw });
        break;
      case "mutation":
        out.push(...mutationReviewItems([it.raw]));
        break;
      case "plan_gap":
        out.push({ target: it.raw.item, context: it.raw.cited || null, text: `implement: ${it.raw.why}` });
        break;
      case "flaky":
        out.push({
          target: `flaky: ${it.raw}`,
          context: null,
          text: "this test failed then passed on re-run. find and fix the flake, or mark it skip with a reason",
        });
        break;
      case "coverage":
        out.push({
          target: "coverage drop",
          context: it.raw.note,
          text: "add tests to restore the coverage guard, or explain why the drop is expected",
        });
        break;
    }
  }
  return out;
}

// --------------------------------------------------------------------------------- //
// Zone 1: the verdict itself — one headline, one primary action, produced by a pure
// function so the badge, the stepper and the page can never disagree.
// --------------------------------------------------------------------------------- //

export type VerdictKind =
  | "idle"
  | "running"
  | "merged"
  | "not_ready"
  | "cant_tell"
  | "ready_star"
  | "ready_advisory"
  | "ready";

export type VerdictAction =
  | "run_all"
  | "rerun_gate"
  | "rerun_setup"
  | "fix_all"
  | "restore_tampered"
  | "fix_quality"
  | "fix_review"
  | "open_gate_settings"
  | "focus_tamper"
  | "open_look_at"
  | "open_ship";

export interface Verdict {
  kind: VerdictKind;
  /** Short, plain lead word/phrase ("not ready", "can't tell", "ready") — always safe to
   *  render as its own element. */
  lead: string;
  /** The rest of the story, when there is one, rendered as a SEPARATE element from
   *  `lead` rather than concatenated into one string. This is load-bearing: a blocker's
   *  own `text` can itself contain a `·` (a joined quality/plan sentence, a tamper
   *  note's "3 removed · 2 skipped"), and flattening `lead + " · " + detail` would stack
   *  multiple `·`-separated clauses into one ambiguous line with no safe place to split
   *  it back apart. Structure, not punctuation, is what keeps them apart. */
  detail: string | null;
  /** How `lead` and `detail` join in this kind's copy ("not ready" and "can't tell" use
   *  " · ", the `ready*` kinds use ", " per the plan's table) — exposed so a renderer
   *  that DOES want them adjacent uses the right glyph instead of guessing one. */
  sep: " · " | ", ";
  /** Convenience flat string (`lead` + `sep` + `detail`), for a tooltip, log line, or
   *  test assertion — never for the VerdictCard headline itself, which renders
   *  `lead`/`detail` as two elements. */
  headline: string;
  action: { label: string; action: VerdictAction } | null;
}

function verdict(
  kind: VerdictKind,
  lead: string,
  detail: string | null,
  sep: " · " | ", ",
  action: Verdict["action"],
): Verdict {
  return { kind, lead, detail, sep, headline: detail ? `${lead}${sep}${detail}` : lead, action };
}

/** The single verdict-first headline (notes/verify-redesign-plan.md Zone 1), never the
 *  words verified / proven / correct. No em dashes, matching the house copy rule. */
export function gateVerdict(inputs: VerdictInputs): Verdict {
  const { status, run, cells } = inputs;

  if (status === "tests_running") {
    const t = tally(cells);
    return verdict("running", "running", t.total > 0 ? `${t.total - t.inflight} of ${t.total}` : null, " · ", null);
  }

  if (status === "merged") return verdict("merged", "merged", null, " · ", null);

  const blks = blockers(inputs);

  // A gate error is the sole blocker `blockers()` ever returns (it short-circuits every
  // other check there), so it always wins: there is nothing else to judge if the gate
  // never ran.
  const gateError = blks.find((b) => b.kind === "gate_error");
  if (gateError) {
    return verdict(
      "cant_tell",
      "can't tell",
      "the gate didn't run",
      " · ",
      gateError.fix ? { label: gateError.fix.label, action: gateError.fix.action } : null,
    );
  }

  // Every OTHER blocker outranks "degraded": a red gate with 2 failing tests must read
  // "not ready · 2 failing tests", not "can't tell", even if that same run is also
  // degraded — degraded only becomes the story when nothing more concrete is wrong.
  const shipBlockers = blks.filter((b) => b.kind !== "degraded");
  if (shipBlockers.length > 0) {
    const first = shipBlockers[0];
    return verdict(
      "not_ready",
      "not ready",
      first.text,
      " · ",
      first.fix ? { label: first.fix.label, action: first.fix.action } : { label: "fix all → agent", action: "fix_all" },
    );
  }

  const degraded = blks.find((b) => b.kind === "degraded");
  if (degraded) {
    return verdict(
      "cant_tell",
      "can't tell",
      "a check didn't run",
      " · ",
      degraded.fix ? { label: degraded.fix.label, action: degraded.fix.action } : null,
    );
  }

  if (status === "gate_green") {
    const tampered = (run?.tamper_findings?.length ?? 0) > 0;
    if (tampered) {
      return verdict("ready_star", "ready", "but tests were changed", ", ", {
        label: "jump to that row",
        action: "focus_tamper",
      });
    }
    const la = lookAt(inputs);
    if (la.pending.length > 0) {
      return verdict(
        "ready_advisory",
        "ready",
        `${la.pending.length} thing${la.pending.length === 1 ? "" : "s"} to look at`,
        ", ",
        { label: "open zone 3", action: "open_look_at" },
      );
    }
    return verdict("ready", "ready to ship", null, " · ", { label: "open ④", action: "open_ship" });
  }

  // A red status with no blocker at all shouldn't happen from a fresh backend run (every
  // red path sets a failure, an error, or a `*_blocked` flag) but is reachable from a
  // stale/previous run object if a caller ever hands one over after `status` already
  // flipped. "no gate run yet" would be a lie in that case; "not ready" at least tells
  // the truth about the one thing we do know.
  if (status === "gate_red") {
    return verdict("not_ready", "not ready", null, " · ", { label: "re-run gate", action: "rerun_gate" });
  }

  return verdict("idle", "no gate run yet", null, " · ", { label: "run all", action: "run_all" });
}
