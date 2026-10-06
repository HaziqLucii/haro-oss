import { describe, expect, it, vi } from "vitest";
import { bulkArchiveActions, type ArchivePick } from "./archiveActions";
import type { ArchiveQueueRun } from "./types";

const RUN = (over: Partial<ArchiveQueueRun> = {}): ArchiveQueueRun => ({
  id: "arq_1",
  project_id: "p1",
  dry: true,
  force: false,
  state: "planned",
  stop_requested: false,
  items: [],
  created_at: 0,
  finished_at: null,
  ...over,
});

function harness(initial: { pick?: ArchivePick | null; run?: ArchiveQueueRun | null } = {}) {
  let pick = initial.pick ?? null;
  let run = initial.run ?? null;
  const busy: boolean[] = [];
  const archiveQueue = vi.fn(async (_p: string, _ids: string[], _o?: object) => RUN({ id: "arq_new" }));
  const stopArchiveQueue = vi.fn(async (_id: string) => RUN({ dry: false, state: "canceled" }));
  const actions = bulkArchiveActions({
    api: { archiveQueue, stopArchiveQueue },
    pick: () => pick,
    setPick: (p) => {
      pick = p;
    },
    run: () => run,
    setRun: (r) => {
      run = r;
    },
    setBusy: (b) => busy.push(b),
  });
  return {
    actions,
    archiveQueue,
    stopArchiveQueue,
    busy,
    get pick() {
      return pick;
    },
    get run() {
      return run;
    },
  };
}

describe("plan", () => {
  it("asks the backend for a DRY plan and remembers the selection", async () => {
    const h = harness();
    await h.actions.plan("p1", ["a", "b"]);
    expect(h.archiveQueue).toHaveBeenCalledWith("p1", ["a", "b"], { dry: true });
    expect(h.pick).toEqual({ projectId: "p1", ids: ["a", "b"] });
    expect(h.run?.id).toBe("arq_new");
    expect(h.busy).toEqual([true, false]);
  });
});

describe("replan", () => {
  it("re-asks about the SAME ids with the force flag flipped", async () => {
    const h = harness({ pick: { projectId: "p1", ids: ["a", "b"] } });
    await h.actions.replan(true);
    // A fresh selection here would silently change what the user is about to confirm.
    expect(h.archiveQueue).toHaveBeenCalledWith("p1", ["a", "b"], { dry: true, force: true });
  });

  it("re-plans back to the safe subset when unticked", async () => {
    const h = harness({ pick: { projectId: "p1", ids: ["a"] } });
    await h.actions.replan(false);
    expect(h.archiveQueue).toHaveBeenCalledWith("p1", ["a"], { dry: true, force: false });
  });

  it("does nothing without a selection", async () => {
    const h = harness();
    await h.actions.replan(true);
    expect(h.archiveQueue).not.toHaveBeenCalled();
  });
});

describe("start", () => {
  it("launches the live run with the force flag of the plan on screen", async () => {
    const h = harness({ pick: { projectId: "p1", ids: ["a"] }, run: RUN({ force: true }) });
    await h.actions.start();
    // Not dry, and force carried across — that flag is the difference between
    // "skip the risky ones" and "delete them".
    expect(h.archiveQueue).toHaveBeenCalledWith("p1", ["a"], { force: true });
    expect(h.busy).toEqual([true, false]);
  });

  it("carries a safe plan's force=false through unchanged", async () => {
    const h = harness({ pick: { projectId: "p1", ids: ["a"] }, run: RUN() });
    await h.actions.start();
    expect(h.archiveQueue).toHaveBeenCalledWith("p1", ["a"], { force: false });
  });

  it("refuses to start with no plan on screen — the preview is the confirm", async () => {
    const noPlan = harness({ pick: { projectId: "p1", ids: ["a"] } });
    await noPlan.actions.start();
    expect(noPlan.archiveQueue).not.toHaveBeenCalled();

    const noPick = harness({ run: RUN() });
    await noPick.actions.start();
    expect(noPick.archiveQueue).not.toHaveBeenCalled();
  });

  it("clears busy even when the request fails", async () => {
    const h = harness({ pick: { projectId: "p1", ids: ["a"] }, run: RUN() });
    h.archiveQueue.mockRejectedValueOnce(new Error("409 already running"));
    await expect(h.actions.start()).rejects.toThrow("409 already running");
    // A wedged "busy" would leave the confirm button dead until a reload.
    expect(h.busy).toEqual([true, false]);
  });
});

describe("stop", () => {
  it("stops the live run and takes the returned state", async () => {
    const h = harness({ run: RUN({ dry: false, state: "running" }) });
    await h.actions.stop();
    expect(h.stopArchiveQueue).toHaveBeenCalledWith("arq_1");
    expect(h.run?.state).toBe("canceled");
  });

  it("is a no-op on a preview — there is nothing draining to stop", async () => {
    const h = harness({ run: RUN({ dry: true }) });
    await h.actions.stop();
    expect(h.stopArchiveQueue).not.toHaveBeenCalled();
  });
});

describe("close", () => {
  it("drops the panel and forgets the selection", () => {
    const h = harness({ pick: { projectId: "p1", ids: ["a"] }, run: RUN() });
    h.actions.close();
    expect(h.run).toBe(null);
    expect(h.pick).toBe(null);
  });
});
