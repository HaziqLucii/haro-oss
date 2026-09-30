/**
 * Verified Hunks — the diff's per-line proof, as display logic (backlog/verified-hunks.md §3).
 *
 * Pure and separate from `DiffView.tsx` for the same reason `gate.ts` is separate from
 * `GatePanel.tsx`: the *wording* is the risky part of this feature, so it has to be testable
 * without a renderer. `verifiedHunks.test.ts` includes a guard that no label anywhere in here
 * contains "verified", "proven" or "correct".
 *
 * ## The honesty rule, in one line
 * An **executed** line is not an **asserted** line. Every label says "executed"; the tooltip
 * spells out the gap. Overclaiming here would burn reviewer trust permanently, and per the
 * backlog's kill conditions it does not get a second chance — a reviewer who learns that
 * "executed" quietly meant "fine" will skip a collapsed hunk that held a real bug, once, and
 * then never trust the surface again.
 *
 * ## Five things a hunk can be, and why none of them is "verified"
 *   * `executed`   — every coverable added line ran under the passing suite.
 *   * `partial`    — some added lines never ran. The residue worth reviewing.
 *   * `unmapped`   — no test imports the file, so nothing in it ran at all.
 *   * `nonexec`    — the added lines are comments/blank/type-only: nothing to execute.
 *   * `stale`      — the file moved since the gate ran, so its evidence no longer lines up.
 */
import type { VerifiedFile, VerifiedHunksResponse } from "./types";

/** Path → the gate's proof for that file. Null when there is no usable proof at all. */
export type ProofIndex = Map<string, VerifiedFile>;

export function indexProof(v: VerifiedHunksResponse | null | undefined): ProofIndex | null {
  if (!v || !v.supported || v.files.length === 0) return null;
  return new Map(v.files.map((f) => [f.path, f]));
}

/** Per-line gutter dot state for an ADDED line. "" = draw nothing (say nothing). */
export type LineDot = "" | "hit" | "cold";

export function lineDot(file: VerifiedFile | undefined, lineNo: number | null): LineDot {
  if (!file || file.stale || lineNo == null) return "";
  // `undefined` (line absent from the map) and `null` (present but non-coverable) both mean
  // "we cannot attribute this line" — a blank line or a closing brace gets no dot, because a
  // dot there is a claim, and "add a test for your closing brace" is how a signal dies.
  const hits = file.lines[String(lineNo)];
  if (hits == null) return "";
  return hits >= 1 ? "hit" : "cold";
}

export type HunkKind = "executed" | "partial" | "unmapped" | "nonexec" | "stale";

export interface HunkProof {
  kind: HunkKind;
  added: number;
  executed: number;
  unexecuted: number;
  noncoverable: number;
}

/**
 * Tally one hunk from the line numbers it actually renders.
 *
 * Deliberately computed from the *rendered* added lines rather than from a hunk breakdown
 * sent by the backend: the two would then have to agree about how a hunk is split, and the
 * only thing that can be wrong about a badge is which lines it is describing.
 */
export function hunkProof(
  file: VerifiedFile | undefined,
  addedLineNos: number[],
): HunkProof | null {
  if (!file || addedLineNos.length === 0) return null;
  if (file.stale) {
    return { kind: "stale", added: addedLineNos.length, executed: 0, unexecuted: 0, noncoverable: 0 };
  }
  if (!file.in_map) {
    return {
      kind: "unmapped",
      added: addedLineNos.length,
      executed: 0,
      unexecuted: addedLineNos.length,
      noncoverable: 0,
    };
  }
  let executed = 0;
  let unexecuted = 0;
  let noncoverable = 0;
  for (const n of addedLineNos) {
    const hits = file.lines[String(n)];
    if (hits == null) noncoverable++;
    else if (hits >= 1) executed++;
    else unexecuted++;
  }
  const kind: HunkKind =
    unexecuted > 0 ? "partial" : executed > 0 ? "executed" : "nonexec";
  return { kind, added: addedLineNos.length, executed, unexecuted, noncoverable };
}

/** Roll several hunks' tallies into one file-level tally (the file header badge). */
export function mergeProof(parts: (HunkProof | null)[]): HunkProof | null {
  const live = parts.filter((p): p is HunkProof => !!p);
  if (live.length === 0) return null;
  if (live.some((p) => p.kind === "stale")) {
    return {
      kind: "stale",
      added: live.reduce((n, p) => n + p.added, 0),
      executed: 0,
      unexecuted: 0,
      noncoverable: 0,
    };
  }
  const total = live.reduce(
    (acc, p) => ({
      added: acc.added + p.added,
      executed: acc.executed + p.executed,
      unexecuted: acc.unexecuted + p.unexecuted,
      noncoverable: acc.noncoverable + p.noncoverable,
    }),
    { added: 0, executed: 0, unexecuted: 0, noncoverable: 0 },
  );
  const unmapped = live.every((p) => p.kind === "unmapped");
  const kind: HunkKind = unmapped
    ? "unmapped"
    : total.unexecuted > 0
      ? "partial"
      : total.executed > 0
        ? "executed"
        : "nonexec";
  return { kind, ...total };
}

/**
 * The badge, exactly as the reviewer reads it.
 *
 * "executed by the green suite" is §3's interim copy on purpose: the target phrasing
 * "executed by N passing tests" needs §4's per-test attribution, and claiming a number we
 * cannot yet attribute would be the first crack in the surface.
 */
export const EXECUTED_TOOLTIP =
  "executed ≠ asserted — these lines ran under passing tests; no assertion necessarily checked them";

export function hunkBadge(
  p: HunkProof | null,
): { label: string; tone: "hit" | "cold" | "flat"; title: string } | null {
  if (!p) return null;
  switch (p.kind) {
    case "stale":
      return {
        label: "gate ran on an older version of this file",
        tone: "flat",
        title:
          "the file changed after the gate measured it, so its line numbers no longer line up — re-run the gate to annotate this diff",
      };
    case "unmapped":
      return {
        label: `no test imports this file · ${p.added} added line${p.added === 1 ? "" : "s"} never executed`,
        tone: "cold",
        title: "no test in the suite imports this file, so nothing in it ran",
      };
    case "nonexec":
      return {
        label: "no executable lines added",
        tone: "flat",
        title:
          "the added lines are comments, blanks or type-only declarations — there is nothing here for a test to execute",
      };
    case "partial":
      return {
        label: `${p.unexecuted} of ${p.added} added lines never executed`,
        tone: "cold",
        title: `${p.executed} executed · ${p.unexecuted} never executed${
          p.noncoverable ? ` · ${p.noncoverable} not executable` : ""
        }. ${EXECUTED_TOOLTIP}`,
      };
    case "executed":
      return { label: "executed by the green suite", tone: "hit", title: EXECUTED_TOOLTIP };
  }
}

/**
 * How many added lines in this file the suite never executed — the untested-first sort key,
 * and the collapse decision.
 *
 * A file with no proof sorts as 0: absent evidence must not be presented as absent risk, but
 * it must not jump the queue ahead of a file we KNOW has untested lines either.
 */
export function unexecutedCount(proof: ProofIndex | null, path: string): number {
  const f = proof?.get(path);
  if (!f || f.stale) return 0;
  return f.unexecuted;
}

/**
 * Collapse a file whose added lines all ran. On real agent diffs this usually collapses the
 * WHOLE diff (measured: 0% residue when the agent writes its own tests), which is the correct
 * quiet answer — the feature earns its keep on the inverse case, an unmapped or never-executed
 * file left conspicuously open under a green gate.
 *
 * Refuses to collapse anything it isn't sure about — no proof, stale proof, or an unmapped
 * file all stay open. Hiding a file on weak evidence is the exact failure the kill conditions
 * describe, so the bar is "we measured it and every coverable line ran".
 */
export function collapsesByDefault(proof: ProofIndex | null, path: string): boolean {
  const f = proof?.get(path);
  if (!f || f.stale || !f.in_map) return false;
  return f.added > 0 && f.unexecuted === 0 && f.executed > 0;
}

/**
 * "Review the residue → agent": batch the never-executed files into the comment round-trip
 * (the same `failureReviewItems` / `uncheckedReviewItems` path, v1.3).
 *
 * The prefilled ask says "add tests or justify" rather than just "add tests", because
 * sometimes the honest answer is that a line cannot be covered — and a signal that only
 * accepts one answer gets gamed into accepting anything.
 */
export function residueReviewItems(
  v: VerifiedHunksResponse | null,
): { target: string; context: string | null; text: string }[] {
  if (!v || !v.supported) return [];
  return v.files
    .filter((f) => !f.stale && f.unexecuted > 0)
    .sort((a, b) => b.unexecuted - a.unexecuted)
    .map((f) => {
      const base = f.path.split("/").pop() || f.path;
      const detail = f.in_map
        ? `${f.unexecuted} of ${f.added} added lines never executed by the gate`
        : `no test imports this file — all ${f.added} added lines never executed by the gate`;
      return {
        target: `never executed: ${base}`,
        context: `${detail} · ${f.path}`,
        text: "these added lines never executed under the green suite — add tests that exercise them, or explain why they cannot be covered",
      };
    });
}

/** How many files carry a reviewable residue — the button's count. */
export function residueCount(v: VerifiedHunksResponse | null): number {
  return residueReviewItems(v).length;
}
