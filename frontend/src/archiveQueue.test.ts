import { describe, expect, it } from "vitest";
import {
  archiveFeedEffects,
  bulkBar,
  cardPick,
  counts,
  heldBack,
  isDraining,
  mergeArchiveRun,
  outcomeTone,
  pickedProjectOf,
  previewHeadline,
  progress,
  selectable,
  summary,
  togglePicked,
} from "./archiveQueue";
import type { ArchiveOutcome, ArchiveQueueItem, ArchiveQueueRun, Workspace } from "./types";

function item(name: string, outcome: ArchiveOutcome, over: Partial<ArchiveQueueItem> = {}): ArchiveQueueItem {
  return { workspace_id: name, name, outcome, reason: null, risks: [], ...over };
}

function run(items: ArchiveQueueItem[], over: Partial<ArchiveQueueRun> = {}): ArchiveQueueRun {
  return {
    id: "arq_1",
    project_id: "p1",
    dry: false,
    force: false,
    state: "running",
    stop_requested: false,
    items,
    created_at: 0,
    finished_at: null,
    ...over,
  };
}

function ws(id: string, status: Workspace["status"] = "idle", projectId = "p1"): Workspace {
  return {
    id,
    project_id: projectId,
    name: id,
    branch: `haro/${id}`,
    worktree_path: `/tmp/${id}`,
    base_ref: "main",
    port: null,
    status,
    kind: "managed",
    race_id: null,
  };
}

describe("the wire shape", () => {
  // `types.ts` is declaration-only (it compiles to nothing), so the honest runtime check
  // is this: take the JSON the backend actually emits — snake_case field names straight
  // out of `models.ArchiveQueueRun.model_dump()` — and drive the real helpers with it. A
  // field renamed on either side lands here rather than as a blank panel.
  const wire = JSON.parse(`{
    "id": "arq_ab12cd34",
    "project_id": "proj_1",
    "dry": false,
    "force": false,
    "state": "running",
    "stop_requested": false,
    "items": [
      {"workspace_id": "ws_1", "name": "safe", "outcome": "archived", "reason": null, "risks": []},
      {"workspace_id": "ws_2", "name": "busy", "outcome": "archiving", "reason": null, "risks": []},
      {"workspace_id": "ws_3", "name": "dirty", "outcome": "skipped",
       "reason": "uncommitted changes will be discarded",
       "risks": ["uncommitted changes will be discarded"]}
    ],
    "created_at": 1753600000.0,
    "finished_at": null
  }`) as ArchiveQueueRun;

  it("reads a live backend payload end to end", () => {
    expect(counts(wire)).toMatchObject({ archived: 1, archiving: 1, skipped: 1 });
    expect(progress(wire).label).toBe("archiving busy · 1/2");
    expect(heldBack(wire).map((i) => i.name)).toEqual(["dirty"]);
    expect(isDraining(wire)).toBe(true);
    expect(summary(wire)).toBe("1 archived · 1 skipped");
  });

  it("reads a dry-run payload as a plan", () => {
    const plan = { ...wire, dry: true, state: "planned" as const };
    expect(isDraining(plan)).toBe(false);
    expect(previewHeadline(plan).detail).toContain("1 held back");
  });
});

describe("counts / summary", () => {
  it("tallies every outcome", () => {
    const c = counts(run([item("a", "archived"), item("b", "failed"), item("c", "skipped")]));
    expect(c.archived).toBe(1);
    expect(c.failed).toBe(1);
    expect(c.skipped).toBe(1);
    expect(c.queued).toBe(0);
  });

  it("reads the same way the backend's summarize does", () => {
    expect(summary(run([item("a", "archived"), item("b", "skipped")]))).toBe("1 archived · 1 skipped");
    expect(summary(run([]))).toBe("nothing to archive");
  });
});

describe("previewHeadline", () => {
  it("says how many, and that they go one at a time", () => {
    const h = previewHeadline(run([item("a", "queued"), item("b", "queued")], { state: "planned", dry: true }));
    expect(h.text).toBe("Archive 2 workspaces");
    expect(h.detail).toContain("one at a time");
    expect(h.canRun).toBe(true);
  });

  it("names what is being held back rather than hiding it", () => {
    const h = previewHeadline(
      run([item("a", "queued"), item("b", "skipped", { reason: "uncommitted changes will be discarded" })], {
        dry: true,
        state: "planned",
      }),
    );
    expect(h.detail).toContain("1 held back");
  });

  it("refuses to offer a run when nothing is admitted", () => {
    const h = previewHeadline(
      run([item("b", "skipped", { reason: "2 unmerged commits — the branch is deleted too" })], {
        dry: true,
        state: "planned",
      }),
    );
    expect(h.canRun).toBe(false);
    expect(h.detail).toContain("throw work away");
  });

  it("a forced run says out loud that work will be lost", () => {
    const h = previewHeadline(
      run([item("a", "queued", { risks: ["uncommitted changes will be discarded"] })], {
        dry: true,
        force: true,
        state: "planned",
      }),
    );
    expect(h.detail).toContain("work that will be lost");
  });
});

describe("progress", () => {
  it("names the workspace currently being torn down", () => {
    const p = progress(run([item("a", "archived"), item("b", "archiving"), item("c", "queued")]));
    expect(p.label).toBe("archiving b · 1/3");
    expect(p.done).toBe(1);
  });

  it("excludes skipped items from the total — they were never queued", () => {
    const p = progress(run([item("a", "archived"), item("b", "skipped")]));
    expect(p.total).toBe(1);
  });

  it("a finished run reads as its summary, not as progress", () => {
    const p = progress(run([item("a", "archived"), item("b", "failed")], { state: "done" }));
    expect(p.label).toBe("1 archived · 1 failed");
  });
});

describe("isDraining", () => {
  it("is true only for a live, running queue", () => {
    expect(isDraining(run([], { state: "running" }))).toBe(true);
    expect(isDraining(run([], { state: "done" }))).toBe(false);
    expect(isDraining(run([], { state: "canceled" }))).toBe(false);
    // A preview is never draining — offering to stop it would be nonsense.
    expect(isDraining(run([], { state: "running", dry: true }))).toBe(false);
    expect(isDraining(null)).toBe(false);
  });
});

describe("heldBack / outcomeTone / selectable", () => {
  it("held back is exactly the skipped set", () => {
    expect(heldBack(run([item("a", "queued"), item("b", "skipped")])).map((i) => i.name)).toEqual(["b"]);
  });

  it("tones a failure apart from a success", () => {
    expect(outcomeTone("archived")).toBe("s-pass");
    expect(outcomeTone("failed")).toBe("s-fail");
    expect(outcomeTone("queued")).toBe("dim");
  });

  it("leaves soft-archived race losers out — there is no worktree left to archive", () => {
    expect(selectable([ws("a"), ws("loser", "archived")]).map((w) => w.id)).toEqual(["a"]);
  });
});

describe("select mode", () => {
  const rows = [ws("a"), ws("b"), ws("other", "idle", "p2")];

  it("the first pick decides the project", () => {
    expect(pickedProjectOf(rows, new Set(["other"]))).toBe("p2");
    expect(pickedProjectOf(rows, new Set())).toBe(null);
  });

  it("locks out cards from any other project — a queue drains one repo", () => {
    const opts = { picking: true, picked: new Set(["a"]), pickedProject: "p1" };
    expect(cardPick(rows[0], opts)).toMatchObject({ isPicked: true, locked: false });
    expect(cardPick(rows[2], opts).locked).toBe(true);
    expect(cardPick(rows[2], opts).className).toContain("dash-card-locked");
  });

  it("locks nothing while select mode is off", () => {
    const opts = { picking: false, picked: new Set<string>(), pickedProject: null };
    expect(cardPick(rows[2], opts)).toEqual({ isPicked: false, locked: false, className: "" });
  });

  it("toggling returns a NEW set (React must see the change)", () => {
    const first = new Set<string>();
    const withA = togglePicked(first, "a");
    expect(withA).not.toBe(first);
    expect([...withA]).toEqual(["a"]);
    expect([...togglePicked(withA, "a")]).toEqual([]);
  });

  it("the bar reports what each button may do, and what archive would target", () => {
    const bar = bulkBar(rows, new Set(["b", "a"]));
    expect(bar).toMatchObject({
      count: 2,
      pickedProject: "p1",
      mixed: true, // a visible row belongs to another project
      canSelectAll: true,
      canArchive: true,
    });
    // Row order, never Set order — the confirm dialog lists them in the order shown.
    expect(bar.pickedIds).toEqual(["a", "b"]);
    expect(bar.projectIds).toEqual(["a", "b"]);
  });

  it("an empty selection can archive nothing", () => {
    const bar = bulkBar(rows, new Set());
    expect(bar).toMatchObject({ count: 0, canArchive: false, canSelectAll: false, mixed: false });
  });

  it("a single-project dashboard never says 'one project at a time'", () => {
    expect(bulkBar([ws("a"), ws("b")], new Set(["a"])).mixed).toBe(false);
  });
});

describe("the global feed", () => {
  const live = (over: Partial<ArchiveQueueRun> = {}) =>
    run([item("a", "archived"), item("b", "queued")], over);

  it("a live run takes over the dry-run plan it continues", () => {
    const plan = run([item("a", "queued")], { id: "arq_1", dry: true, state: "planned" });
    const started = live({ id: "arq_2" });
    expect(mergeArchiveRun(plan, started)).toBe(started);
    expect(mergeArchiveRun(null, started)).toBe(started);
  });

  it("updates the run you're watching, and only that one", () => {
    const watching = live({ id: "arq_1" });
    const update = live({ id: "arq_1", state: "done" });
    expect(mergeArchiveRun(watching, update)).toBe(update);
    // Another project's queue must not yank the panel out from under you.
    expect(mergeArchiveRun(watching, live({ id: "arq_9" }))).toBe(watching);
  });

  it("resyncs the sidebar only when the archived count actually moved", () => {
    const r = live({ id: "arq_1" });
    const first = archiveFeedEffects({ id: "", done: 0 }, r, null);
    expect(first.reload).toBe(true);
    expect(first.seen).toEqual({ id: "arq_1", done: 1 });
    // A progress tick that archived nothing new must not refetch every project.
    expect(archiveFeedEffects(first.seen, r, null).reload).toBe(false);
  });

  it("drops the selected workspace when the queue archived it", () => {
    const r = live({ id: "arq_1" });
    expect(archiveFeedEffects({ id: "", done: 0 }, r, "a").clearSelected).toBe(true);
    expect(archiveFeedEffects({ id: "", done: 0 }, r, "b").clearSelected).toBe(false);
  });

  it("toasts only once the batch is over, and errors when something failed", () => {
    expect(archiveFeedEffects({ id: "", done: 0 }, live({ state: "running" }), null).toast).toBe(null);
    const ok = archiveFeedEffects({ id: "", done: 0 }, run([item("a", "archived")], { state: "done" }), null);
    expect(ok.toast).toEqual({ kind: "success", text: "Bulk archive: 1 archived" });
    const bad = archiveFeedEffects(
      { id: "", done: 0 },
      run([item("a", "archived"), item("b", "failed")], { state: "done" }),
      null,
    );
    expect(bad.toast?.kind).toBe("error");
    // A stopped queue still reports — silence would read as "it's still going".
    const stopped = archiveFeedEffects(
      { id: "", done: 0 },
      run([item("a", "canceled")], { state: "canceled" }),
      null,
    );
    expect(stopped.toast).toEqual({ kind: "success", text: "Bulk archive: 1 canceled" });
  });
});
