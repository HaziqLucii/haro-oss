import { describe, it, expect, vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { ProjectDashboard } from "./ProjectDashboard";
import type { Project, Workspace } from "../types";

// A project home renders the SHARED Dashboard, so the only thing that can break here is
// the forwarding: a prop dropped in the middle silently removes the affordance from the
// per-project view while the global one keeps it (backlog/bulk-archive.md).

// Nothing here should reach the network — static render runs no effects, but the child
// panels do read `fetch` lazily, so fail loudly if one ever does.
vi.stubGlobal("fetch", () => Promise.reject(new Error("no network in this test")));

const project: Project = { id: "p1", name: "proj", path: "/tmp/proj", default_branch: "main" };

const ws = (id: string): Workspace => ({
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
});

const html = (props: Partial<Parameters<typeof ProjectDashboard>[0]> = {}) =>
  renderToStaticMarkup(
    <ProjectDashboard
      project={project}
      workspaces={[ws("a"), ws("b")]}
      onSelectWorkspace={() => {}}
      onNewWorkspace={() => {}}
      onStartTodo={() => {}}
      onRemoteChanged={() => {}}
      {...props}
    />,
  );

describe("ProjectDashboard — bulk-archive forwarding", () => {
  it("passes onBulkArchive through to the shared Dashboard", () => {
    expect(html({ onBulkArchive: () => {} })).toContain("dash-pick-toggle");
  });

  it("shows no select affordance when the host didn't wire one", () => {
    expect(html()).not.toContain("dash-pick-toggle");
  });

  it("still renders the project's cards either way", () => {
    const out = html({ onBulkArchive: () => {} });
    expect(out).toContain("haro/a");
    expect(out).toContain("haro/b");
  });
});
