// Pure helpers for the gate's red→green loop. Kept UI-free so the batching logic
// behind "fix all failures → agent" is unit-testable (see gate.test.ts).
import type { Cell, MutationSurvivor, ReviewMustFix, TamperFinding, TestCaseResult, UncheckedRow } from "./types";

// The tamper-finding kind labels for the green* drill-down — short, code-shaped tags
// that echo the source syntax the alarm keys off (`.skip`/`.only`/`.todo`), so a row
// reads like the thing it flagged. Falls through to the raw kind for any future signal.
export const TAMPER_KIND_LABEL: Record<string, string> = {
  removed: "removed",
  skip: ".skip",
  only: ".only",
  todo: ".todo",
  assertions: "assertions",
  snapshot: "snapshot",
  config: "config",
  vacuous: "vacuous",
};

/** Short label for a tamper finding's `kind` — the green* drill-down's per-row tag;
 *  an unknown kind (a signal added later) falls through to its raw string. */
export function tamperKindLabel(kind: string): string {
  return TAMPER_KIND_LABEL[kind] ?? kind;
}

/**
 * The green* chip's collapsed line: the backend's compact note ("3 removed · 2
 * skipped") when it built one, else a plain count fallback so the banner always says
 * *something* even if note-building was skipped for a set of findings.
 */
export function tamperSummary(findings: TamperFinding[], note: string | null): string {
  return tamperCountSummary(findings.length, note);
}

/**
 * The same collapsed line from a finding COUNT — the shape the dashboard has, since its
 * denormalized `GateSummary` carries `tamper_count`, not the findings themselves (that's
 * the whole point: `green*` renders off the coarse status feed with no fetch-per-card).
 * One wording for both surfaces, so the card and the gate panel never disagree.
 */
export function tamperCountSummary(count: number, note: string | null): string {
  if (note) return note;
  return `${count} suspicious test change${count === 1 ? "" : "s"}`;
}

/**
 * Map a past run's cases to grid cells so the ribbon can time-travel — render an old
 * TestRun's grid from its stored `.cases` (which carry no id, so we synthesize a stable
 * one from file + name + index).
 */
export function casesToCells(cases: TestCaseResult[]): Cell[] {
  return cases.map((c, i) => ({
    id: `${c.file}::${c.name}::${i}`,
    file: c.file,
    name: c.name,
    status: c.status,
    duration_ms: c.duration_ms,
    message: c.message,
  }));
}

/** The failing test cells, in grid order — the summary header + fix-all both draw on this. */
export function failedCells(cells: Cell[]): Cell[] {
  return cells.filter((c) => c.status === "failed");
}

/**
 * Turn every failing test into a review item ({target, context}) — the same shape
 * the per-cell `+ comment → agent` produces, so a batch drops straight into the
 * existing review composer round-trip. Caller stamps ids + empty text.
 */
export function failureReviewItems(cells: Cell[]): { target: string; context: string | null }[] {
  return failedCells(cells).map((c) => ({ target: `test: ${c.name}`, context: c.message }));
}

/**
 * The restore instruction prefilled into each tamper review item, keyed by finding
 * kind. This is why `+ restore weakened tests → agent` is sendable without typing a
 * word: for a failing test only the dev knows what "fix" means, but for a tamper
 * finding the *finding is the ask* (".only added" ⇒ "take it out"). An unknown/future
 * kind falls back to a generic restore, so a new signal is still actionable.
 */
export const TAMPER_FIX_HINT: Record<string, string> = {
  removed: "restore this deleted test: re-add it with its original assertions, do not weaken it",
  skip: "remove the added .skip so this test runs again, and make it pass for real",
  only: "remove the added .only: it silently stops every other test from running",
  todo: "remove the added .todo and restore the real test body",
  assertions: "restore the expect() assertions removed from this file",
  snapshot: "re-verify these snapshot rewrites and revert any that hide a real behaviour change",
  // Never "fix the code" — same rule as the mutation tab's kill-the-survivors loop.
  // A config-scope finding might be entirely legitimate (unlike a removed test, the
  // diff alone can't tell); the hint asks to LOOK first. It still counts toward
  // green*/tamper_blocked/no_tamper like every other finding — this is a softer
  // FIX HINT, not a softer VERDICT.
  config: "review this test-config change: confirm it doesn't quietly widen an exclude glob, retarget a test script, or otherwise change which tests run",
  // Vacuous is a NEW test, not a weakened one — the fix is a stronger assertion, not a restore.
  vacuous: "this test already passes without your change: strengthen its assertion so it actually fails without the fix",
};

/** The per-kind restore instruction for a tamper finding (see `TAMPER_FIX_HINT`). */
export function tamperFixHint(kind: string): string {
  return TAMPER_FIX_HINT[kind] ?? "restore this weakened test to its pre-change strength";
}

/**
 * Turn every tamper finding into a review item — the `green*` twin of
 * `failureReviewItems`, so a suspicious green routes to action the way a red does.
 * Same `{target, context}` shape the review composer already round-trips, plus a
 * prefilled `text` (the restore ask). Caller stamps ids.
 *
 * `target` locates the finding the way the drill-down row reads it (`.skip: adds
 * numbers`), preferring the test name and falling back to the file's basename — and
 * to the bare kind for a diff-wide signal like snapshot churn, which carries neither.
 */
export function tamperReviewItems(
  findings: TamperFinding[],
): { target: string; context: string | null; text: string }[] {
  return findings.map((f) => {
    const label = tamperKindLabel(f.kind);
    const where = f.test || (f.file ? f.file.split("/").pop() : "");
    return {
      target: where ? `${label}: ${where}` : label,
      // Full path in the context line (the target only carries the basename), so the
      // agent gets an unambiguous file to open.
      context: [f.detail, f.file].filter(Boolean).join(" · ") || null,
      text: tamperFixHint(f.kind),
    };
  });
}

// --------------------------------------------------------------------------- //
// THE DOUBLE GATE — quality findings (backlog/double-gate.md §2)
// --------------------------------------------------------------------------- //

/** One deterministic quality finding, mirroring `models.QualityFindingRow`. */
export interface QualityFindingRow {
  tool: string;
  severity: "high" | "medium" | "low" | "info";
  file: string;
  line: number | null;
  rule: string;
  message: string;
  blocking: boolean;
}

/**
 * Group findings by the tool that produced them — the findings panel's shape.
 *
 * By tool rather than by file on purpose: the reader's first question is "what KIND of
 * problem is this?" ("two secrets" is a different reaction from "two lint nits"), and the
 * tools already carry that meaning. Blocking groups sort first so the thing standing
 * between you and a merge is the thing you read first.
 */
export function groupQualityFindings(
  findings: QualityFindingRow[],
): { tool: string; findings: QualityFindingRow[]; blocking: number }[] {
  const byTool = new Map<string, QualityFindingRow[]>();
  for (const f of findings) {
    const list = byTool.get(f.tool);
    if (list) list.push(f);
    else byTool.set(f.tool, [f]);
  }
  return [...byTool.entries()]
    .map(([tool, list]) => ({
      tool,
      findings: list,
      blocking: list.filter((f) => f.blocking).length,
    }))
    .sort((a, b) => b.blocking - a.blocking || b.findings.length - a.findings.length);
}

/** `file:line` for a finding's deep-link, or just the file when the tool reports at file
 *  scope. Empty for a diff-wide finding (an unattributable linter failure), which the UI
 *  renders without a link rather than inventing a location. */
export function qualityLocation(f: QualityFindingRow): string {
  if (!f.file) return "";
  return f.line ? `${f.file}:${f.line}` : f.file;
}

/**
 * Turn quality findings into review items — the third sibling of `failureReviewItems`
 * and `tamperReviewItems`, so a quality-red routes to the agent exactly like a red gate
 * and a `green*` do. Caller stamps ids.
 *
 * Only BLOCKING findings by default: batching advisory nits into a fix-everything task is
 * how a quality gate turns into busywork the dev learns to dismiss, and the whole point of
 * the severity threshold is that below it nothing is owed.
 */
export function qualityReviewItems(
  findings: QualityFindingRow[],
  { includeAdvisory = false }: { includeAdvisory?: boolean } = {},
): { target: string; context: string | null; text: string }[] {
  return findings
    .filter((f) => includeAdvisory || f.blocking)
    .map((f) => ({
      target: `${f.tool}: ${f.rule || "finding"}`,
      context: [qualityLocation(f), f.message].filter(Boolean).join(" · ") || null,
      // Secrets get a categorically different instruction: deleting the line is not
      // enough once a credential has been written down, and a fix task that doesn't say
      // so teaches people the wrong lesson about leaks.
      text:
        f.tool === "gitleaks"
          ? "remove this secret from the code and load it from the environment instead — " +
            "and treat the credential as compromised: rotate it"
          : "fix this finding, or explain why it is a false positive here",
    }));
}

// --------------------------------------------------------------------------- //
// Kill-the-survivors loop (usp-critique-plan.md idea 4, backlog/mutation-gate.md)
// --------------------------------------------------------------------------- //

/**
 * Turn mutation-score survivors into review items — the fourth sibling of
 * `failureReviewItems`/`tamperReviewItems`/`qualityReviewItems`, so a survivor
 * routes to the agent exactly like a red test, a `green*`, or a quality-red do.
 * Caller stamps ids.
 *
 * This is the loop nobody else closes: the gate doesn't just judge the suite's
 * strength, a survivor sent back becomes a new test the agent writes — the ask
 * is deliberately "write a test that fails on this", never "fix the code", since
 * a survivor is evidence the TESTS are too weak to notice the mutation, not
 * evidence the code itself is wrong.
 */
export function mutationReviewItems(
  survivors: MutationSurvivor[],
): { target: string; context: string | null; text: string }[] {
  return survivors.map((s) => ({
    target: `${s.path.split("/").pop() || s.path}:${s.line}`,
    context: `${s.path}:${s.line} · mutation survived: ${s.operator}`,
    text:
      "write a test that fails when this mutation is applied — right now no test " +
      "notices the change, which means nothing here is actually verifying this line",
  }));
}

/** THE REFUTER's must-fix list → the composer's fix-task shape (Phase 3 of
 *  notes/workflow-roles-plan.md) — `qualityReviewItems`'s twin. Every must-fix reaching
 *  here already survived the backend's cite-or-drop guardrail, so `cited` is always
 *  worth surfacing as the grounding context. */
export function reviewMustFixItems(
  mustFix: ReviewMustFix[],
): { target: string; context: string | null; text: string }[] {
  return mustFix.map((mf) => ({
    target: mf.line ? `${mf.file}:${mf.line}` : mf.file,
    context: mf.cited || null,
    text: mf.detail ? `${mf.title} — ${mf.detail}` : mf.title,
  }));
}

/** The compact chip line for a quality verdict, e.g. `2 findings · 1 blocking`. Null when
 *  clean, because a verdict with nothing to say should render nothing. */
export function qualitySummary(count: number, blocking: number, note: string | null): string | null {
  if (!count) return null;
  if (note) return note;
  const base = `${count} finding${count === 1 ? "" : "s"}`;
  return blocking ? `${base} · ${blocking} blocking` : base;
}

/** The slice of a past `TestRun` the regression ribbon draws a dot from. Kept structural
 *  (not the full `TestRun`) so the helper is testable from a literal, and the tamper trio
 *  is optional — runs persisted before the alarm existed hydrate without it. */
export interface RibbonRun {
  status: string;
  scope: string;
  passed: number;
  failed: number;
  wall_ms: number | null;
  tamper_findings?: TamperFinding[] | null;
  tamper_note?: string | null;
  tamper_blocked?: boolean;
}

/**
 * One regression-ribbon dot's class list + tooltip for a past gate run.
 *
 * The star is the point (backlog/tamper-alarm.md §3): a `green*` run — the tests passed
 * but the tamper alarm found the *suite* changed suspiciously — has to stay visible in
 * HISTORY, not just in the live verdict. The ribbon is the one place you go to ask "was
 * this workspace ever really green?", so if every past green renders as the same clean
 * dot, a suspicious green launders itself into the record the moment the next run lands.
 * Starred, the strip reads honestly: these greens were clean, that one had an asterisk,
 * click it to see what the alarm found.
 *
 * Starred in BOTH modes, keyed off the findings rather than the verdict: in warn mode the
 * run is still green, so the dot keeps its pass colour and takes an amber asterisk; in
 * block mode the alarm already turned the run red, so the star goes red with it and the
 * tooltip names the alarm as the reason (otherwise that red is indistinguishable from a
 * genuine test failure).
 */
export function ribbonDot(run: RibbonRun, selected = false): { className: string; title: string } {
  const count = run.tamper_findings?.length ?? 0;
  const starred = count > 0;

  const cls = ["rdot", `rdot-${run.status}`];
  if (run.scope === "impacted") cls.push("rdot-impacted");
  if (starred) cls.push("rdot-star");
  if (starred && run.tamper_blocked) cls.push("rdot-star-block");
  if (selected) cls.push("rdot-sel");

  const parts = [run.scope, `${run.passed}✓ ${run.failed}✗`];
  if (run.wall_ms != null) parts.push(`${run.wall_ms.toFixed(0)}ms`);
  if (starred) {
    parts.push(run.tamper_blocked ? "green* · blocked by the tamper alarm" : "green*");
    parts.push(tamperCountSummary(count, run.tamper_note ?? null));
  }
  return { className: cls.join(" "), title: parts.join(" · ") };
}

/**
 * The Live Gate's verdict (backlog/live-gate.md) — deliberately its OWN vocabulary, not
 * the gate's `green`/`red`. A watch run is advisory: it can never ship anything, so it
 * must never *look* like the verdict that can. "passing"/"failing" describe the suite
 * right now; "green"/"red" stay reserved for the ③ gate that gates the merge.
 *
 * `off` — `[gate] watch` disabled · `idle` — on, nothing has run yet · `running` — cells
 * still streaming · `failing`/`passing` — a settled advisory result · `errored` — the
 * runner couldn't run (deps, no tests). Errors read as neutral, not alarming: a broken
 * advisory loop is our problem, not the dev's.
 */
export function watchVerdict(
  enabled: boolean,
  cells: Cell[],
  run: { status: string } | null,
): "off" | "idle" | "running" | "passing" | "failing" | "errored" {
  if (!enabled) return "off";
  if (cells.some((c) => c.status === "running")) return "running";
  if (cells.some((c) => c.status === "failed")) return "failing";
  if (run?.status === "error") return "errored";
  if (cells.length > 0) return "passing";
  if (run?.status === "passed") return "passing";
  if (run?.status === "failed") return "failing";
  return "idle";
}

/**
 * The rail panel's one-line summary. Counts come from live cells while a run streams and
 * from the settled run afterwards, so the line never blanks between the two. Always
 * carries the scope word ("impacted") — the panel must never imply full-suite coverage,
 * because that's exactly the distinction that keeps an advisory green from reading as
 * shippable.
 */
export function watchSummary(
  cells: Cell[],
  run: { passed: number; failed: number; total: number; wall_ms: number | null } | null,
): string {
  const done = cells.filter((c) => c.status !== "running");
  const passed = done.length ? done.filter((c) => c.status === "passed").length : (run?.passed ?? 0);
  const failed = done.length ? done.filter((c) => c.status === "failed").length : (run?.failed ?? 0);
  const parts = [`${passed} passing`];
  if (failed) parts.push(`${failed} failing`);
  parts.push("impacted");
  if (!cells.some((c) => c.status === "running") && run?.wall_ms != null) {
    parts.push(`${(run.wall_ms / 1000).toFixed(1)}s`);
  }
  return parts.join(" · ");
}

/**
 * Plain-language framing for a gate that *couldn't run* (status === "error"), keyed by
 * `error_kind`. This is the difference between "your tests failed" (a code problem) and
 * "the gate never ran" (a setup problem) — so the raw log stops reading like a test failure.
 */
export function gateErrorFraming(
  kind: "setup" | "no_tests" | "runner" | null,
  adopted = false,
): { title: string; hint: string } {
  // Adopted (foreign) worktrees are only provisioned at adopt time, so a setup-kind
  // error means the *environment* isn't ready — not that the code failed. Frame it as
  // "environment, not code" and point at re-running setup (POST /workspaces/{id}/setup),
  // so the Merge Firewall never cries wolf on a worktree it just took over.
  if (kind === "setup" && adopted) {
    return {
      title: "Environment, not code",
      hint: "This is an adopted worktree, and its deps/toolchain aren’t ready yet, so the gate never ran. This is not a test failure. Re-run setup to provision the worktree, then re-run the gate.",
    };
  }
  switch (kind) {
    case "setup":
      return {
        title: "The gate couldn’t run: setup failed",
        hint: "Your gate never ran: the workspace’s deps/toolchain aren’t ready, or the configured gate command isn’t installed. Run the setup script / install the tool, then re-run the gate.",
      };
    case "no_tests":
      return {
        title: "The gate ran, but found no tests",
        hint: "No test files matched. Add tests or check the runner’s include/config. An empty suite can’t gate a merge.",
      };
    default:
      return {
        title: "The gate crashed",
        hint: "The test runner errored before finishing. The log below has the details. Fix the cause and re-run.",
      };
  }
}

/**
 * What to do about a coverage-blocked gate. Two genuinely different fixes, told apart by
 * whether there IS a number: a measured drop asks you to restore coverage, an *unmeasured*
 * one asks you to fix the measurement (backlog/gate.md). Keyed on `coverage_delta` — the
 * fact itself — rather than by sniffing the note's wording.
 */
export function coverageBlockHint(coverageDelta: number | null): string {
  return coverageDelta == null
    ? "fix coverage reporting or turn the guard off to ship"
    : "restore coverage or relax the guard to ship";
}

// --- Code to check (backlog/code-to-check.md) ------------------------------- //
// Row labels for the diff-level signal. Literal on purpose: the pane title carries the
// imperative ("code to check"), the rows state plainly what was NOT observed. Nothing here
// says proven or verified, because a line with a hit count was *executed*, which is not the
// same as asserted about — and a positive word would become the metric an agent games.
export const UNCHECKED_KIND_LABEL: Record<string, string> = {
  no_test_file: "no test imports",
  untested_lines: "no test ran",
  new_dep: "new dependency",
  secret: "secret touched",
  deleted: "file deleted",
  migration: "migration",
  suite_weakened: "suite weakened",
  // The tamper alarm's advisory half: a base test retitled AND re-asserted in place. Worded
  // as the change it is, not as an accusation — it's equally what a deliberate contract
  // change looks like, which is exactly why it's a row here and never part of `green*`.
  assertion_rewritten: "assertion rewritten",
};

/** Short label for a row's `kind`; an unknown/future kind falls through to its raw string. */
export function uncheckedKindLabel(kind: string): string {
  return UNCHECKED_KIND_LABEL[kind] ?? kind;
}

/**
 * The pane's one-line summary: the backend's compact note when it built one, else a plain
 * count fallback so the header always says something. Mirrors `tamperSummary`.
 */
export function uncheckedSummary(rows: UncheckedRow[], note?: string | null): string {
  if (note) return note;
  return `${rows.length} thing${rows.length === 1 ? "" : "s"} to look at`;
}

/**
 * What the pane is entitled to say, resolved in one pure place so the component only
 * renders it.
 *
 * This exists because the pane used to have exactly two states, rows and clean, and
 * therefore said "every changed line ran" in three situations where nothing had run
 * anything: a red gate, an impacted-only run, and a diff the coverage map never contained
 * (a Python change under a vitest gate — on this repo's own history, the majority of
 * "clean" panes). An empty list is not a clean bill of health unless something looked.
 */
export type UncheckedState =
  | { kind: "off" }
  /** Nothing measured the diff on this run; `reason` says which of the several whys. */
  | { kind: "unmeasured"; reason: string }
  /** Measured, nothing outstanding, and coverage really did watch `files` files run. */
  | { kind: "clean"; files: number }
  /** Measured, nothing outstanding, but coverage could not speak about this diff. */
  | { kind: "quiet"; reason: string }
  | {
      kind: "rows";
      pending: UncheckedRow[];
      done: UncheckedRow[];
      /** Caveat under the summary when the coverage half was blind, else null. */
      coverage: string | null;
    };

/** The caveat line for a coverage half that could not speak, or null when it could. */
export function uncheckedCoverageNote(coveredFiles?: number | null): string | null {
  if (coveredFiles == null)
    return "no coverage data for this run, so only the risk checks ran";
  if (coveredFiles === 0)
    return "the suite executed none of the changed files, so only the risk checks ran";
  return null;
}

export function uncheckedState(args: {
  enabled: boolean;
  /** null/undefined = the pass never ran. `[]` = it ran and found nothing. */
  rows?: UncheckedRow[] | null;
  coveredFiles?: number | null;
  checkedKeys?: string[];
  /** The run's own state, used only to explain WHY nothing was measured. */
  status?: string | null;
  scope?: string | null;
}): UncheckedState {
  const { enabled, rows, coveredFiles, status, scope } = args;
  if (!enabled) return { kind: "off" };
  if (!status || status === "running")
    return { kind: "unmeasured", reason: "run the gate to see what nothing checked" };
  if (rows == null) {
    // Each why wants a different next action, so none of them get a shrug.
    const reason =
      status === "failed"
        ? "the gate is red, so nothing has looked at the diff yet. get it green first"
        : scope && scope !== "all"
          ? "this was an impacted-only run, so run the full gate to check the diff"
          : "this run did not measure the diff";
    return { kind: "unmeasured", reason };
  }
  const checked = new Set(args.checkedKeys ?? []);
  const pending = rows.filter((r) => !checked.has(r.key));
  const done = rows.filter((r) => checked.has(r.key));
  if (!rows.length) {
    const blind = uncheckedCoverageNote(coveredFiles);
    // "Quiet" and "clean" look similar and mean opposite things: one is a suite that
    // watched the change happen, the other is a suite that was not in the room.
    return blind ? { kind: "quiet", reason: blind } : { kind: "clean", files: coveredFiles ?? 0 };
  }
  return { kind: "rows", pending, done, coverage: uncheckedCoverageNote(coveredFiles) };
}

/**
 * Turn every row into a review item, so `+ send to agent` reuses the composer round-trip
 * that `failureReviewItems` and `tamperReviewItems` already feed. Unlike a failing test,
 * a row IS the ask ("nothing tests this file"), so `text` arrives prefilled and the batch
 * is sendable without typing — same reasoning as `tamperReviewItems`.
 */
export function uncheckedReviewItems(
  rows: UncheckedRow[],
): { target: string; context: string | null; text: string }[] {
  return rows.map((r) => {
    const label = uncheckedKindLabel(r.kind);
    const base = r.file ? r.file.split("/").pop() : "";
    return {
      target: base ? `${label}: ${base}` : label,
      context: [r.detail, r.file].filter(Boolean).join(" · ") || null,
      text: uncheckedFixHint(r.kind),
    };
  });
}

/**
 * What to actually do about a row, per kind. Deliberately asks for a *test* only where a
 * test is the answer; a touched secret or a new dependency wants a human's eyes, not
 * coverage, and pretending otherwise is how a signal gets ignored.
 */
export const UNCHECKED_FIX_HINT: Record<string, string> = {
  no_test_file: "nothing imports this file in any test. add a test that exercises what changed here",
  untested_lines: "these added lines never executed in the suite. cover them, or explain why they can't be",
  new_dep: "confirm this dependency is needed, pinned, and from a source we trust",
  secret: "confirm nothing secret was committed and the value came from the environment",
  deleted: "confirm this deletion is intended and nothing still references it",
  migration: "confirm this migration is reversible and safe to run on real data",
  suite_weakened: "restore the weakened test rather than leaving the suite thinner",
  assertion_rewritten:
    "this test was retitled and now asserts something else. confirm the behaviour it checked at base is either still asserted somewhere or was meant to change",
};

export function uncheckedFixHint(kind: string): string {
  return UNCHECKED_FIX_HINT[kind] ?? "confirm this change is intended, since nothing checked it";
}
