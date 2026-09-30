// Things to look at — ③ verify's Zone 3 (notes/verify-redesign-plan.md). Started life as
// CodeToCheck.tsx, the side rail's diff-level pane (backlog/code-to-check.md §3): every
// condition on the Autonomy Ladder is suite-level (did the suite pass, did total coverage
// drop, was the suite weakened), so none of them can notice that the lines the agent just
// added were executed by nothing at all. A green gate says "the tests passed". It never
// says "the tests covered what changed".
//
// The redesign folded that pane into ③ itself (it moved out of the rail, which now carries
// only a one-line LookAtChip), and widened it: this is now the single advisory worklist for
// EVERYTHING that can never block a merge but is worth a human's eyes — code-to-check rows,
// warn-mode tamper findings, plan-compliance gaps, advisory quality findings, suspected-flaky
// tests, a warn-mode coverage drop, and mutation survivors. `verdict.ts`'s `lookAt()` is the
// single source that decides what belongs here (and, just as importantly, what does NOT —
// a blocking signal lives in Zone 2 instead, never both).
//
// Two things make "shrinks to zero" true rather than aspirational for the code-to-check
// rows specifically, both added after reading 125 real gate runs off this repo:
//
//   1. Rows tick off. Half the row kinds (a new dependency, a touched secret file, a
//      deletion, a migration) ask for a human's confirmation and can NEVER be closed by
//      writing a test, so without a tick the pane was structurally unable to reach zero on
//      those diffs. A tick says "I looked" — never "verified", the same naming law the row
//      labels follow. Only code-to-check rows are tickable; every other kind here is a
//      one-shot signal with nothing to "check off" beyond sending it to the agent.
//   2. Empty is not automatically clean. `codeToCheckCaveat` separates "measured, nothing
//      outstanding" from "nothing measured this diff", because the old pane showed its
//      earned green over red gates, impacted-only runs, and any change the coverage map
//      never contained.
//
// Naming law: rows state what was NOT observed. Nothing here says proven or verified,
// because a line with a hit count was *executed*, which is not the same as asserted about.
import { useState } from "react";
import type { UncheckedRow } from "../types";
import type { LookAtItem, LookAt as LookAtResult } from "../verdict";
import { Chevron } from "./Chevron";

/** The category tag for a row, when the row's own `text` doesn't already carry it
 *  (code_to_check/tamper/quality already read "kind: file" or "tool: rule"). */
function laKindLabel(item: LookAtItem): string {
  switch (item.kind) {
    case "plan_gap":
      return "plan";
    case "flaky":
      return "flaky";
    case "coverage":
      return "coverage";
    case "mutation":
      return "mutation";
    default:
      return "";
  }
}

/** The file a row's body can open in ② code, when it has one. */
function laFile(item: LookAtItem): string | null {
  switch (item.kind) {
    case "code_to_check":
    case "tamper":
    case "quality":
      return item.raw.file || null;
    case "mutation":
      return item.raw.path || null;
    default:
      return null;
  }
}

/** The plain sentence under the row, when the raw finding carries one beyond `item.text`. */
function laDetail(item: LookAtItem): string | null {
  switch (item.kind) {
    case "code_to_check":
    case "tamper":
      return item.raw.detail || null;
    case "quality":
      return item.raw.message || null;
    case "plan_gap":
      return item.raw.why || null;
    default:
      return null;
  }
}

/** One row: an optional tick box (code-to-check only), the claim, and its detail sentence.
 *
 *  The sentence is on the row rather than in a `title` tooltip because "no test ran ·
 *  rungs.py · 41" is only legible if you already know the codebase, and a pane that needs
 *  insider knowledge to read is a pane only its author uses. */
function LookAtRow({
  item,
  checked,
  tickable,
  onToggle,
  onOpenFile,
}: {
  item: LookAtItem;
  checked: boolean;
  tickable: boolean;
  onToggle?: (checked: boolean) => void;
  onOpenFile: (file: string) => void;
}) {
  const file = laFile(item);
  const kind = laKindLabel(item);
  const detail = laDetail(item);
  return (
    <div className={"ctc-row" + (checked ? " ctc-row-done" : "") + " ctc-row-" + item.kind}>
      {tickable ? (
        <button
          className={"ctc-tick" + (checked ? " on" : "")}
          onClick={() => onToggle?.(!checked)}
          aria-pressed={checked}
          title={checked ? "put this back on the list" : "I looked at this"}
        >
          {checked ? "✓" : ""}
        </button>
      ) : (
        <span className="ctc-tick ctc-tick-spacer" aria-hidden="true" />
      )}
      <button
        className="ctc-body"
        onClick={() => file && onOpenFile(file)}
        disabled={!file}
        title={file ?? undefined}
      >
        <span className="la-line">
          {kind && <span className="ctc-kind">{kind}</span>}
          <span className="ctc-file">{item.text}</span>
        </span>
        {detail && <span className="ctc-detail dim">{detail}</span>}
      </button>
    </div>
  );
}

export function LookAt({
  result,
  caveat = null,
  past = false,
  onOpenFile,
  onToggleChecked,
  onSendToAgent,
  onSendToBacklog,
}: {
  result: LookAtResult;
  /** From `codeToCheckCaveat` — the honesty distinctions a bare pending count can't carry
   *  (a red gate, an impacted-only run, a coverage map that never saw this diff). */
  caveat?: string | null;
  /** Time-travelling a past run withholds every action, same rule as the rest of ③. */
  past?: boolean;
  onOpenFile: (file: string) => void;
  onToggleChecked: (row: UncheckedRow, checked: boolean) => void;
  onSendToAgent: (items: LookAtItem[]) => void;
  // "Send to backlog" (backlog/backlog-v2.md Move 3): queue every pending item
  // (an untested hunk, a mutation survivor, …) as a follow-up instead of
  // re-tasking the current agent right now. Optional for callers with no
  // project context to write a backlog file into.
  onSendToBacklog?: (items: LookAtItem[]) => void;
}) {
  const [showDone, setShowDone] = useState(false);
  const { pending, done } = result;

  if (pending.length === 0 && done.length === 0) {
    return <div className="la-empty dim">{caveat ?? "nothing to look at"}</div>;
  }

  return (
    <div className="gate-lookat-body">
      <div className="la-summary">
        {pending.length > 0
          ? `${pending.length} thing${pending.length === 1 ? "" : "s"} to look at`
          : "all checked off by you"}
      </div>
      {caveat && <div className="la-caveat dim">{caveat}</div>}
      <div className="ctc-rows">
        {pending.map((item) => (
          <LookAtRow
            key={item.key}
            item={item}
            checked={false}
            tickable={item.kind === "code_to_check" && !past}
            onToggle={item.kind === "code_to_check" ? (c) => onToggleChecked(item.raw, c) : undefined}
            onOpenFile={onOpenFile}
          />
        ))}
        {done.length > 0 && (
          <>
            {/* Ticked rows stay visible under their own heading rather than vanishing.
                The difference between a checklist and a dismiss button is whether the
                answer survives where the question was asked. */}
            <button className="ctc-done-head" onClick={() => setShowDone((s) => !s)}>
              <Chevron open={showDone} />
              <span>checked by you</span>
              <span className="dim">{done.length}</span>
            </button>
            {showDone &&
              done.map((item) => (
                <LookAtRow
                  key={item.key}
                  item={item}
                  checked
                  tickable={item.kind === "code_to_check" && !past}
                  onToggle={item.kind === "code_to_check" ? (c) => onToggleChecked(item.raw, c) : undefined}
                  onOpenFile={onOpenFile}
                />
              ))}
          </>
        )}
      </div>
      {pending.length > 0 && !past && (
        <div className="ctc-actions">
          <button className="ghost ctc-send" onClick={() => onSendToAgent(pending)}>
            + send to agent
          </button>
          {onSendToBacklog && (
            <button
              className="ghost ctc-send"
              onClick={() => onSendToBacklog(pending)}
              title="Queue every pending item as a backlog follow-up instead"
            >
              + send to backlog
            </button>
          )}
        </div>
      )}
    </div>
  );
}
