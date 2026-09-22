import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { ArchiveQueuePanel } from "./ArchiveQueuePanel";
import type { ArchiveOutcome, ArchiveQueueItem, ArchiveQueueRun } from "../types";

// Static render (no jsdom in this suite), which is the right shape here anyway: the
// panel is entirely prop-driven — it holds no state and decides no admission — so its
// whole surface is reachable by rendering the states the backend can put it in.

const item = (
  name: string,
  outcome: ArchiveOutcome,
  over: Partial<ArchiveQueueItem> = {},
): ArchiveQueueItem => ({ workspace_id: name, name, outcome, reason: null, risks: [], ...over });

const run = (items: ArchiveQueueItem[], over: Partial<ArchiveQueueRun> = {}): ArchiveQueueRun => ({
  id: "arq_1",
  project_id: "p1",
  dry: true,
  force: false,
  state: "planned",
  stop_requested: false,
  items,
  created_at: 0,
  finished_at: null,
  ...over,
});

const html = (r: ArchiveQueueRun, busy = false) =>
  renderToStaticMarkup(
    <ArchiveQueuePanel
      run={r}
      busy={busy}
      onToggleForce={() => {}}
      onConfirm={() => {}}
      onStop={() => {}}
      onClose={() => {}}
    />,
  );

describe("the plan (dry run)", () => {
  it("says how many, and that they go one at a time", () => {
    const out = html(run([item("a", "queued"), item("b", "queued")]));
    expect(out).toContain("Archive 2 workspaces");
    expect(out).toContain("one at a time");
    expect(out).toContain("you can stop the queue between them");
    // The confirm is live and there is no stop button before anything is running.
    expect(out).toContain(">archive 2 workspaces<");
    expect(out).not.toContain(">stop<");
  });

  it("names every held-back workspace AND what it would lose", () => {
    const out = html(
      run([
        item("safe", "queued"),
        item("dirty", "skipped", { reason: "uncommitted changes will be discarded" }),
        item("ahead", "skipped", { reason: "2 unmerged commits — the branch is deleted too" }),
      ]),
    );
    // "2 held back" alone is an invitation to force it blindly — the reasons carry it.
    expect(out).toContain("2 held back");
    expect(out).toContain("uncommitted changes will be discarded");
    expect(out).toContain("2 unmerged commits");
    expect(out).toContain("archiving deletes the branch");
    expect(out).toContain("include them anyway");
  });

  it("offers no risk checkbox when nothing is held back", () => {
    const out = html(run([item("a", "queued")]));
    expect(out).not.toContain("include them anyway");
    expect(out).not.toContain("arq-risk");
  });

  it("disables the confirm when nothing is admitted", () => {
    const out = html(run([item("dirty", "skipped", { reason: "uncommitted changes will be discarded" })]));
    expect(out).toContain("Nothing can be archived safely");
    expect(out).toMatch(/class="danger"[^>]*disabled/);
  });

  it("a forced plan says out loud that work will be lost, and keeps the risks visible", () => {
    const out = html(
      run([item("dirty", "queued", { risks: ["uncommitted changes will be discarded"] })], { force: true }),
    );
    expect(out).toContain("work that will be lost");
    expect(out).toContain("1 will lose work");
    expect(out).toContain("uncommitted changes will be discarded");
    // The toggle must SURVIVE being ticked — keying the block on "held back" alone made
    // it vanish the moment you forced, with no way back to the safe plan.
    expect(out).toContain("include them anyway");
    expect(out).toContain('checked=""');
  });

  it("busy disables the confirm without hiding the plan", () => {
    const out = html(run([item("a", "queued")]), true);
    expect(out).toContain("Archive 1 workspace");
    expect(out).toMatch(/class="danger"[^>]*disabled/);
  });
});

describe("the live queue", () => {
  const live = (items: ArchiveQueueItem[], over: Partial<ArchiveQueueRun> = {}) =>
    run(items, { dry: false, state: "running", ...over });

  it("names the workspace being torn down right now, and offers a stop", () => {
    const out = html(live([item("a", "archived"), item("b", "archiving"), item("c", "queued")]));
    expect(out).toContain("Archiving…");
    expect(out).toContain("archiving b · 1/3");
    expect(out).toContain(">stop<");
    expect(out).toContain("arq-bar-fill");
    // A live run is not a plan: no confirm, no risk checkbox.
    expect(out).not.toContain("include them anyway");
    expect(out).not.toContain("cancel");
  });

  it("a requested stop says the current teardown still finishes", () => {
    const out = html(live([item("a", "archiving")], { stop_requested: true }));
    expect(out).toContain("stopping after this one…");
  });

  it("a finished run reports its outcome and closes rather than stops", () => {
    const out = html(live([item("a", "archived"), item("b", "failed", { reason: "git worktree remove failed" })], {
      state: "done",
    }));
    expect(out).toContain("Done");
    expect(out).toContain("1 archived · 1 failed");
    expect(out).toContain("git worktree remove failed");
    expect(out).toContain(">close<");
    expect(out).not.toContain(">stop<");
  });

  it("a stopped run reads as stopped, with the untouched ones canceled", () => {
    const out = html(live([item("a", "archived"), item("b", "canceled")], { state: "canceled" }));
    expect(out).toContain("Stopped");
    expect(out).toContain("canceled");
  });

  it("the close button is disabled while the queue is still draining", () => {
    // Dismissing the panel mid-teardown would leave a destructive batch unwatched.
    expect(html(live([item("a", "archiving")]))).toMatch(/aria-label="close"[^>]*disabled/);
    expect(html(live([item("a", "archived")], { state: "done" }))).not.toMatch(
      /aria-label="close"[^>]*disabled/,
    );
  });
});
