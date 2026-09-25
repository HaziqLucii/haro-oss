// The bulk-archive action sequence (backlog/bulk-archive.md), lifted out of `App.tsx`.
//
// Four calls that end in worktrees being deleted, so the *order of operations* is worth
// testing on its own: plan → (re-plan with the risky ones) → start → stop. Inside a
// component they were closures over `useState`, i.e. unreachable by this suite; here
// every dependency is injected, so the invariants below are asserted directly.
//
// The invariants:
//  * a re-plan targets the SAME picked ids (a fresh selection would silently change
//    what the user is about to confirm),
//  * `start` sends the force flag of the plan ON SCREEN, never a stale local copy —
//    that flag is the difference between "skip the risky ones" and "delete them",
//  * `stop` is meaningless on a preview, so it refuses rather than 404-ing,
//  * `busy` always clears, including when the request throws.
import type { ArchiveQueueRun } from "./types";

/** Just the slice of `api` this needs — so a test needs no fetch, and no api module. */
export interface ArchiveApi {
  archiveQueue(
    projectId: string,
    workspaceIds: string[],
    opts?: { dry?: boolean; force?: boolean },
  ): Promise<ArchiveQueueRun>;
  stopArchiveQueue(runId: string): Promise<ArchiveQueueRun>;
}

/** What the user picked on the dashboard — kept so a re-plan re-asks about that set. */
export interface ArchivePick {
  projectId: string;
  ids: string[];
}

export interface ArchiveActionDeps {
  api: ArchiveApi;
  pick: () => ArchivePick | null;
  setPick: (pick: ArchivePick | null) => void;
  run: () => ArchiveQueueRun | null;
  setRun: (run: ArchiveQueueRun | null) => void;
  setBusy: (busy: boolean) => void;
}

export function bulkArchiveActions(d: ArchiveActionDeps) {
  const busy = async <T,>(fn: () => Promise<T>): Promise<T> => {
    d.setBusy(true);
    try {
      return await fn();
    } finally {
      d.setBusy(false);
    }
  };

  return {
    /** Ask the BACKEND which of these are safe. Nothing is torn down by a plan. */
    async plan(projectId: string, workspaceIds: string[]) {
      d.setPick({ projectId, ids: workspaceIds });
      await busy(async () => d.setRun(await d.api.archiveQueue(projectId, workspaceIds, { dry: true })));
    },

    /** Re-plan the same selection with the risky ones included (or excluded again).
     *  A round trip on purpose: the backend planner stays the only admission authority. */
    async replan(force: boolean) {
      const pick = d.pick();
      if (!pick) return;
      await busy(async () =>
        d.setRun(await d.api.archiveQueue(pick.projectId, pick.ids, { dry: true, force })),
      );
    },

    /** Start draining. The live run takes over the panel; progress arrives on the feed. */
    async start() {
      const pick = d.pick();
      const plan = d.run();
      if (!pick || !plan) return;
      await busy(async () =>
        d.setRun(await d.api.archiveQueue(pick.projectId, pick.ids, { force: plan.force })),
      );
    },

    /** Cooperative stop — the teardown in flight still finishes, backend-side. */
    async stop() {
      const run = d.run();
      if (!run || run.dry) return;
      d.setRun(await d.api.stopArchiveQueue(run.id));
    },

    /** Dismiss the panel and forget the selection. */
    close() {
      d.setRun(null);
      d.setPick(null);
    },
  };
}
