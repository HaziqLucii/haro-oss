import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { BulkSelectBar, Dashboard, WorkspaceCard, sourceLabel } from "./Dashboard";
import { bulkBar, cardPick } from "../archiveQueue";
import type { Workspace } from "../types";

// Bulk-archive select mode (backlog/bulk-archive.md). This suite renders statically
// (no jsdom), so the two select-mode surfaces are exported and rendered directly with
// the states a click would produce — the decisions behind them are pure and tested in
// `archiveQueue.test.ts`.

type Row = Workspace & { projectName: string };

const row = (id: string, over: Partial<Row> = {}): Row => ({
  id,
  project_id: "p1",
  name: id,
  branch: `haro/${id}`,
  worktree_path: `/tmp/${id}`,
  base_ref: "main",
  port: null,
  status: "idle",
  kind: "managed",
  race_id: null,
  projectName: "proj",
  ...over,
});

describe("Dashboard — the select affordance", () => {
  it("offers select only when bulk archive is wired up", () => {
    const rows = [row("a"), row("b")];
    expect(
      renderToStaticMarkup(<Dashboard workspaces={rows} onSelect={() => {}} onBulkArchive={() => {}} />),
    ).toContain("dash-pick-toggle");
    // Without the handler there is nothing to select FOR.
    expect(renderToStaticMarkup(<Dashboard workspaces={rows} onSelect={() => {}} />)).not.toContain(
      "dash-pick-toggle",
    );
  });

  it("does not offer it for a single workspace — that's the ⋯ archive, not a batch", () => {
    const out = renderToStaticMarkup(
      <Dashboard workspaces={[row("a")]} onSelect={() => {}} onBulkArchive={() => {}} />,
    );
    expect(out).not.toContain("dash-pick-toggle");
  });

  it("starts with select mode OFF — an ordinary card click must open, not tick", () => {
    const out = renderToStaticMarkup(
      <Dashboard workspaces={[row("a"), row("b")]} onSelect={() => {}} onBulkArchive={() => {}} />,
    );
    expect(out).not.toContain("dash-pickbar");
    expect(out).not.toContain("dash-tick");
    expect(out).not.toContain("dash-card-pick");
  });
});

describe("BulkSelectBar", () => {
  const rows = [row("a"), row("b"), row("other", { project_id: "p2", projectName: "other" })];
  const bar = (picked: string[]) =>
    renderToStaticMarkup(
      <BulkSelectBar
        bar={bulkBar(rows, new Set(picked))}
        onSelectAll={() => {}}
        onClear={() => {}}
        onArchive={() => {}}
      />,
    );

  it("every action is dead until something is picked", () => {
    const out = bar([]);
    expect(out).toContain("0 selected");
    expect(out).toMatch(/class="danger"[^>]*disabled/);
    // "select all in project" has no project yet, and there is nothing to clear.
    expect(out.match(/disabled/g)).toHaveLength(3);
    // Nothing is picked, so there is no project to be "one at a time" about.
    expect(out).not.toContain("one project at a time");
  });

  it("counts the picks and arms the archive button", () => {
    const out = bar(["a", "b"]);
    expect(out).toContain("2 selected");
    expect(out).toContain("archive 2");
    expect(out).not.toMatch(/class="danger"[^>]*disabled/);
  });

  it("warns when other projects are on screen — a queue drains one repo", () => {
    expect(bar(["a"])).toContain("one project at a time");
    // A dashboard showing only one project has nothing to warn about.
    const single = renderToStaticMarkup(
      <BulkSelectBar
        bar={bulkBar([row("a"), row("b")], new Set(["a"]))}
        onSelectAll={() => {}}
        onClear={() => {}}
        onArchive={() => {}}
      />,
    );
    expect(single).not.toContain("one project at a time");
  });
});

describe("WorkspaceCard — select-mode states", () => {
  const card = (w: Row, picking: boolean, picked: string[], pickedProject: string | null) =>
    renderToStaticMarkup(
      <WorkspaceCard
        w={w}
        picking={picking}
        pick={cardPick(w, { picking, picked: new Set(picked), pickedProject })}
        onClick={() => {}}
      />,
    );

  it("renders as an ordinary card when select mode is off", () => {
    const out = card(row("a"), false, [], null);
    expect(out).not.toContain("dash-tick");
    expect(out).not.toContain("aria-pressed");
    expect(out).toContain("dash-name");
  });

  it("shows an unticked box for a pickable card", () => {
    const out = card(row("a"), true, [], null);
    expect(out).toContain("dash-card-pick");
    expect(out).toContain('class="dash-tick"');
    expect(out).toContain('aria-pressed="false"');
  });

  it("shows a ticked box for a picked card", () => {
    const out = card(row("a"), true, ["a"], "p1");
    expect(out).toContain("dash-tick-on");
    expect(out).toContain("dash-card-picked");
    expect(out).toContain('aria-pressed="true"');
  });

  it("locks (and disables) a card from another project", () => {
    const out = card(row("other", { project_id: "p2" }), true, ["a"], "p1");
    expect(out).toContain("dash-card-locked");
    expect(out).toMatch(/<button[^>]*disabled/);
  });

  it("keeps the ordinary glance data — the tick decorates the card, it doesn't replace it", () => {
    const out = card(
      row("a", { status: "gate_green", gate: { status: "passed", total: 7, passed: 7, failed: 0 } as never }),
      true,
      ["a"],
      "p1",
    );
    expect(out).toContain("✓ 7 passed");
    expect(out).toContain("haro/a");
  });
});

// The backlog ↔ workspace link goes both ways (backlog-v2.md Move 2): a card
// names the item that seeded it, the same way the backlog names the workspace.
describe("sourceLabel", () => {
  it("renders an issue seed_key as #<n>", () => {
    expect(sourceLabel("issue:42")).toBe("#42");
  });

  it("renders a todo seed_key as its item text, dropping the file prefix", () => {
    expect(sourceLabel("backlog/gate.md::Wire the dispatch")).toBe("Wire the dispatch");
  });

  it("falls back to the raw key when it doesn't look like either shape", () => {
    expect(sourceLabel("weird-key")).toBe("weird-key");
  });
});

describe("WorkspaceCard — source item", () => {
  const card = (w: Row) =>
    renderToStaticMarkup(
      <WorkspaceCard w={w} picking={false} pick={cardPick(w, { picking: false, picked: new Set(), pickedProject: null })} onClick={() => {}} />,
    );

  it("shows the source item when the card was seeded from the backlog", () => {
    const out = card(row("a", { seed_key: "issue:7" }));
    expect(out).toContain("dash-source");
    expect(out).toContain("#7");
  });

  it("shows nothing extra for a workspace with no seed_key", () => {
    const out = card(row("a"));
    expect(out).not.toContain("dash-source");
  });
});
