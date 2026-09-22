// Pure helpers for bulk archive (backlog/bulk-archive.md).
//
// UI-free so the two things a destructive batch must never get wrong are unit-testable:
// the **preview headline** (what the user is agreeing to before they click, including
// what is being held back and why) and the **progress reading** (a queue that has
// stopped must not still read as draining).
import type { ArchiveOutcome, ArchiveQueueItem, ArchiveQueueRun, Workspace } from "./types";

/** Per-outcome tallies for a run (preview or live). */
export function counts(run: ArchiveQueueRun): Record<ArchiveOutcome, number> {
  const out: Record<ArchiveOutcome, number> = {
    queued: 0,
    archiving: 0,
    archived: 0,
    failed: 0,
    skipped: 0,
    canceled: 0,
  };
  for (const item of run.items) out[item.outcome] += 1;
  return out;
}

/** The items the planner held back, with the risk that held them back. */
export function heldBack(run: ArchiveQueueRun): ArchiveQueueItem[] {
  return run.items.filter((i) => i.outcome === "skipped");
}

/** The confirm dialog's headline: what this run would do, and what it would cost.
 *
 *  `canRun` is false when nothing is admitted — a dialog offering "Archive 0
 *  workspaces" is a dead button, so the caller renders the reason instead. */
export function previewHeadline(run: ArchiveQueueRun): {
  text: string;
  detail: string | null;
  canRun: boolean;
} {
  const c = counts(run);
  const held = c.skipped;
  const n = c.queued;
  if (n === 0) {
    return {
      text: held > 0 ? `Nothing can be archived safely` : "Nothing to archive",
      detail:
        held > 0
          ? `${held} held back because archiving would throw work away — include them to go ahead`
          : null,
      canRun: false,
    };
  }
  const text = `Archive ${n} workspace${n === 1 ? "" : "s"}`;
  const bits = [`one at a time${n > 1 ? ", in order" : ""}`];
  if (run.force) bits.push("including work that will be lost");
  if (held > 0) bits.push(`${held} held back`);
  return { text, detail: bits.join(" · "), canRun: true };
}

/** How far a live run has got — the panel's progress line. */
export function progress(run: ArchiveQueueRun): { done: number; total: number; label: string } {
  const c = counts(run);
  const total = run.items.length - c.skipped;
  const done = c.archived + c.failed + c.canceled;
  const current = run.items.find((i) => i.outcome === "archiving");
  const label = current
    ? `archiving ${current.name} · ${done}/${total}`
    : run.state === "running"
      ? `${done}/${total}`
      : summary(run);
  return { done, total, label };
}

/** One line for the toast/log: what actually happened to the batch. Mirrors the
 *  backend's `archive_queue.summarize` so both records read the same. */
export function summary(run: ArchiveQueueRun): string {
  const c = counts(run);
  const parts: string[] = [];
  for (const k of ["archived", "failed", "skipped", "canceled"] as const) {
    if (c[k]) parts.push(`${c[k]} ${k}`);
  }
  return parts.join(" · ") || "nothing to archive";
}

/** True while the queue is still draining — the only state that shows a Stop button. */
export function isDraining(run: ArchiveQueueRun | null): boolean {
  return !!run && !run.dry && run.state === "running";
}

/** Tone class per outcome (the ws-dot / status palette the rest of the app uses). */
export function outcomeTone(outcome: ArchiveOutcome): string {
  switch (outcome) {
    case "archived":
      return "s-pass";
    case "failed":
      return "s-fail";
    case "archiving":
      return "s-run";
    default:
      return "dim";
  }
}

/** Which workspaces a bulk archive may target.
 *
 *  Soft-archived race losers are already worktree-less — their row exists only so the
 *  scorecard can still reach the branch — so offering to archive them again would be a
 *  no-op the user can't tell apart from a real one. */
export function selectable<T extends Workspace>(workspaces: T[]): T[] {
  return workspaces.filter((w) => w.status !== "archived");
}

// --------------------------------------------------------------------------- //
// Dashboard select mode
//
// The rules live here rather than inside Dashboard's JSX because they decide what a
// destructive button targets, and a rule you can't unit-test is a rule you're
// guessing about. The component keeps only the useState.
// --------------------------------------------------------------------------- //

/** The project a selection belongs to — the FIRST picked workspace's project, which
 *  then locks the others out. A queue drains one repo, so a selection that straddles
 *  projects has no valid target; refusing at pick time beats failing at confirm time. */
export function pickedProjectOf<T extends Workspace>(rows: T[], picked: Set<string>): string | null {
  return rows.find((w) => picked.has(w.id))?.project_id ?? null;
}

/** How one card renders in select mode. */
export function cardPick<T extends Workspace>(
  w: T,
  opts: { picking: boolean; picked: Set<string>; pickedProject: string | null },
): { isPicked: boolean; locked: boolean; className: string } {
  const isPicked = opts.picked.has(w.id);
  const locked = opts.picking && !!opts.pickedProject && w.project_id !== opts.pickedProject;
  const className =
    (opts.picking ? " dash-card-pick" : "") +
    (isPicked ? " dash-card-picked" : "") +
    (locked ? " dash-card-locked" : "");
  return { isPicked, locked, className };
}

/** Add/remove one id — a new Set, so React sees the change. */
export function togglePicked(picked: Set<string>, id: string): Set<string> {
  const next = new Set(picked);
  if (next.has(id)) next.delete(id);
  else next.add(id);
  return next;
}

/** Everything the selection bar needs: the counts, whether each action is legal, and
 *  the exact id list an archive would target (in row order, never Set order). */
export function bulkBar<T extends Workspace>(
  rows: T[],
  picked: Set<string>,
): {
  count: number;
  pickedProject: string | null;
  /** Some visible rows belong to another project — the bar says "one project at a time". */
  mixed: boolean;
  canSelectAll: boolean;
  canArchive: boolean;
  pickedIds: string[];
  projectIds: string[];
} {
  const pickedProject = pickedProjectOf(rows, picked);
  const inProject = rows.filter((w) => w.project_id === pickedProject);
  return {
    count: picked.size,
    pickedProject,
    mixed: !!pickedProject && rows.some((w) => w.project_id !== pickedProject),
    canSelectAll: !!pickedProject,
    canArchive: picked.size > 0 && !!pickedProject,
    pickedIds: rows.filter((w) => picked.has(w.id)).map((w) => w.id),
    projectIds: inProject.map((w) => w.id),
  };
}

// --------------------------------------------------------------------------- //
// The global feed
// --------------------------------------------------------------------------- //

/** Which run the panel should show when an `archive_queue` event lands.
 *
 *  A live run replaces nothing you're mid-way through reading EXCEPT a dry-run plan
 *  (which the live run is the continuation of) or the same run. Otherwise a second
 *  project's queue would yank the panel out from under you. */
export function mergeArchiveRun(
  prev: ArchiveQueueRun | null,
  incoming: ArchiveQueueRun,
): ArchiveQueueRun {
  if (!prev || prev.dry || prev.id === incoming.id) return incoming;
  return prev;
}

/** What the app must DO about an `archive_queue` event, beyond re-rendering.
 *
 *  A queue removes workspaces behind the UI's back, so the sidebar has to follow it
 *  item by item — but only when the archived count actually moved, or every progress
 *  tick would refetch every project. `seen` is the caller's memo of that count. */
export function archiveFeedEffects(
  seen: { id: string; done: number },
  run: ArchiveQueueRun,
  selectedWorkspaceId: string | null,
): {
  seen: { id: string; done: number };
  reload: boolean;
  clearSelected: boolean;
  toast: { kind: "success" | "error"; text: string } | null;
} {
  const done = run.items.filter((i) => i.outcome === "archived").length;
  const moved = run.id !== seen.id || done !== seen.done;
  const clearSelected =
    moved &&
    !!selectedWorkspaceId &&
    run.items.some((i) => i.outcome === "archived" && i.workspace_id === selectedWorkspaceId);
  const finished = run.state === "done" || run.state === "canceled";
  const failed = run.items.filter((i) => i.outcome === "failed").length;
  return {
    seen: moved ? { id: run.id, done } : seen,
    reload: moved && done > 0,
    clearSelected,
    toast: finished
      ? { kind: failed > 0 ? "error" : "success", text: `Bulk archive: ${summary(run)}` }
      : null,
  };
}
