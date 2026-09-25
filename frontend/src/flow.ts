// The task-flow stepper's truth model: ① agent › ② code › ③ verify › ④ ship.
//
// Each step's visual state derives from *real workspace state* (agent output, diff,
// gate verdict) — NOT from which step the user happens to be viewing. That keeps the
// flow honest: while the gate is red, ship reads "blocked" and nothing downstream
// paints as done, so the flow only ever *looks* resolved once the gate is green.
// Which step is currently on-screen is tracked separately (see `viewed` in App.tsx).
import type { Cell, TestRun } from "./types";
import { isCantShip, verdictBadge, verdictFlowState } from "./verdict";

export type FlowState = "done" | "active" | "blocked" | "ready" | "todo";

/**
 * Where the ③ verify page should snap the user's eye to, and a nonce to re-trigger it
 * on a repeat click. Replaces the old scalar `gateFocusNonce` (notes/verify-redesign-
 * plan.md): a bare number couldn't say WHICH zone to land on, so every deep-link ended
 * up on the same tab regardless of what actually needed attention.
 */
export interface GateFocus {
  target: "blockers" | "look_at" | "ribbon" | "tamper";
  nonce: number;
}

export interface FlowStep {
  key: "agent" | "code" | "gate" | "git";
  label: string;
  state: FlowState;
  badge: { text: string; tone: string } | null;
  /** A SECOND badge, currently only ③'s quality signal (backlog/double-gate.md §2). Kept
   *  separate from `badge` so the tests tally and the quality verdict can disagree
   *  visibly — the whole point of a double gate is that they are two answers. */
  extra?: { text: string; tone: string } | null;
}

export interface FlowInputs {
  /** The workspace status (`agent_running` | `tests_running` | `gate_green` | `gate_red` | `merged` | …). */
  status: string;
  /** Whether the agent has produced any output this run. */
  hasEvents: boolean;
  /** Files changed in the worktree (from the diff). */
  filesChanged: number;
  /** Test-gate tallies — the verify step's glanceable count (was the top-strip stat). */
  passed?: number;
  failed?: number;
  /** Worktree provenance. `adopted` = a foreign worktree haro registered in place: it's
   *  agentless (haro never ran ① agent), so that step is dropped and the flow opens on
   *  ② code. `managed` (default) keeps the full ①②③④. backlog/merge-firewall.md §1. */
  kind?: "managed" | "adopted";
  /** The Double Gate's other half (backlog/double-gate.md §2). Tri-state, mirroring the
   *  backend: `undefined`/`null` = not measured on this run (gate off, or tests red so it
   *  never ran), `"clean"`, or `"findings"`. Rendered as a SECOND badge on ③ rather than
   *  folded into the test tally, because "27 tests passed" and "we found a secret" are
   *  different claims and merging them into one number would hide the one that matters. */
  qualityStatus?: "clean" | "findings" | null;
  /** How many of those findings met the severity threshold — the ones that actually block. */
  qualityBlocking?: number;
  /** The full gate run and its live cells, so the verify/ship badges can read the
   *  degraded flag, the tamper star and live progress via verdict.ts. Optional: every
   *  existing call site omits these and gets byte-identical behaviour off `passed`/
   *  `failed` alone (notes/verify-redesign-plan.md Phase 1). */
  run?: TestRun | null;
  cells?: Cell[];
}

export function flowSteps({
  status, hasEvents, filesChanged, passed = 0, failed = 0, kind = "managed",
  qualityStatus = null, qualityBlocking = 0, run = null, cells = [],
}: FlowInputs): FlowStep[] {
  const green = status === "gate_green";
  const merged = status === "merged";
  const cantShip = isCantShip(status, run);

  const agent: FlowStep = {
    key: "agent",
    label: "agent",
    state: status === "agent_running" ? "active" : hasEvents ? "done" : "todo",
    badge:
      status === "agent_running"
        ? { text: "running", tone: "run" }
        : hasEvents
          ? { text: "✓", tone: "ok" }
          : null,
  };

  const code: FlowStep = {
    key: "code",
    label: "code",
    state: filesChanged > 0 ? "done" : "todo",
    badge: filesChanged > 0 ? { text: `${filesChanged} changed`, tone: "warn" } : null,
  };

  const verify: FlowStep = {
    key: "gate",
    label: "verify",
    // Reads the ground truth through verdict.ts so the stepper can never disagree with
    // the ③ page: a degraded green (a check the project asked for didn't run) blocks
    // here exactly like it blocks there, not just at ship.
    state: verdictFlowState(status, run),
    // No emoji: tone drives the color, text carries the verdict. When tests have run
    // we show the tally the old top-strip "gate" stat used to (verify is now its only
    // home); otherwise a single-word status. The running badge says "gate…", NOT
    // "running" — the agent step also uses "running", and the auto-gate fires the
    // moment the agent finishes, so an identical word made the handoff invisible
    // ("I didn't even know a gate ran"). Naming the action makes ①→③ legible.
    badge: verdictBadge({ status, passed, failed, run, cells }),
    // THE DOUBLE GATE made visible (backlog/double-gate.md §2): ③ reads
    // `tests ✓ · quality ✓/✗`. Absent when the project never opted in, so the step looks
    // exactly as it did for everyone else — an off feature should be invisible, not a
    // permanent grey "quality —" nagging every project to turn it on.
    extra:
      qualityStatus === "findings"
        ? {
            text: qualityBlocking ? `quality ✗ ${qualityBlocking}` : "quality ⚠",
            // A finding below the severity threshold is advisory: it must not paint the
            // step red, or the threshold dial would be decorative.
            tone: qualityBlocking ? "bad" : "warn",
          }
        : qualityStatus === "clean"
          ? { text: "quality ✓", tone: "ok" }
          : null,
  };

  const ship: FlowStep = {
    key: "git",
    label: "ship",
    // `cantShip` covers a red gate AND a degraded green — ship must not read "ready" on
    // either (notes/verify-redesign-plan.md: "④ ship reads blocked on cant_tell").
    state: merged ? "done" : cantShip ? "blocked" : green ? "ready" : "todo",
    badge: merged
      ? { text: "merged", tone: "ok" }
      : cantShip
        ? { text: "blocked", tone: "bad" }
        : green
          ? { text: "ready", tone: "ok" }
          : null,
  };

  // Adopted worktrees are agentless — haro never ran ① agent — so drop it. The flow then
  // renumbers ② code as ①, keeping the stepper's numbers honest to what actually runs.
  return kind === "adopted" ? [code, verify, ship] : [agent, code, verify, ship];
}

/** The connector after a step is "filled" only once that step is genuinely complete. */
export function connectorDone(step: FlowStep): boolean {
  return step.state === "done";
}

/**
 * Where clicking a step should actually land. A `blocked` ship step is a dead end on
 * its own Git/PR tab — you can't ship a red gate — so it routes to the gate instead,
 * where the failure summary shows *why* it's blocked (and offers "fix all → agent").
 */
export function stepTarget(step: FlowStep): FlowStep["key"] {
  if (step.key === "git" && step.state === "blocked") return "gate";
  return step.key;
}

/** True when clicking this step should focus the gate's failure summary. */
export function focusesFailures(step: FlowStep): boolean {
  return step.state === "blocked";
}
