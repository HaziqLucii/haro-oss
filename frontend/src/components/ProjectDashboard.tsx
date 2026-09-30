import type { Project, RaceRun, Workspace } from "../types";
import { Backlog } from "./Backlog";
import { Dashboard } from "./Dashboard";
import { ProjectRemote } from "./ProjectRemote";

// The project home — shown when a project (but no workspace) is selected. It's the
// pre-workspace vantage point: survey the repo and decide what to do next. Two
// halves of the same decision sit side by side — "what's happening?" (the project's
// workspace triage) in the main column, and "what's next?" (the committed backlog)
// on the right. Picking a card drills into a workspace; the backlog is where the
// next one gets seeded. Editing lives inside workspaces (isolated worktrees), so
// this project-level view is deliberately read-only.
export function ProjectDashboard({
  project,
  workspaces,
  onSelectWorkspace,
  onNewWorkspace,
  onStartTodo,
  onStartMany,
  onRemoteChanged,
  backlogNonce,
  races,
  onPurgeRaceLosers,
  onStopRace,
  purgingRace,
  onBulkArchive,
}: {
  project: Project;
  workspaces: Workspace[];
  onSelectWorkspace: (ws: Workspace, stage?: string) => void;
  onNewWorkspace: () => void;
  onStartTodo: (title: string, task: string, seedKey?: string) => void;
  /** "Start next N" (backlog/backlog-v2.md Move 3) — optional, only offered where
   *  the caller has a direct (non-modal) create-workspace path wired up. */
  onStartMany?: (items: { title: string; task: string; seedKey?: string }[]) => void;
  onRemoteChanged: (url: string | null) => void;
  /** Bumped by App when the fs watcher reports a committed todo-*.md change for
   *  this project (e.g. after a `git pull`) → forwarded to the backlog to refetch. */
  backlogNonce?: number;
  /** This project's winner-only fan-outs — forwarded to the shared Dashboard, which
   *  groups each race's lanes into one scorecard (backlog/winner-fanout.md §3). */
  races?: RaceRun[];
  onPurgeRaceLosers?: (raceId: string) => void;
  onStopRace?: (raceId: string) => void;
  purgingRace?: string | null;
  /** Bulk archive through the serial queue (backlog/bulk-archive.md). */
  onBulkArchive?: (projectId: string, workspaceIds: string[]) => void;
}) {
  // A signature of the project's workspace statuses. It changes when a gate flips
  // or a workspace merges/archives — exactly the moments TODO.md may have been
  // ticked on main. The fs watcher (backlogNonce) covers the rest — e.g. a `git
  // pull` that changes todo files without any workspace-status change.
  const statusKey = workspaces
    .map((w) => `${w.id}:${w.status}`)
    .sort()
    .join(",");

  const rows = workspaces.map((w) => ({ ...w, projectName: project.name }));

  return (
    <div className="proj-dash">
      <div className="proj-dash-main">
        <div className="proj-dash-title">{project.name}</div>
        <ProjectRemote
          projectId={project.id}
          url={project.remote_url ?? null}
          onChanged={onRemoteChanged}
        />
        {workspaces.length === 0 ? (
          // Project-specific empty state — the repo IS registered here, so the
          // generic "register a repo" text (Dashboard's global empty) would mislead.
          <div className="proj-empty">
            <div className="proj-empty-title">No workspaces yet</div>
            <div className="dim proj-empty-sub">
              Start an agent on an isolated worktree: pick something from the backlog on the right,
              then spin up a workspace for it.
            </div>
            <button className="proj-empty-cta" onClick={onNewWorkspace}>
              + New workspace
            </button>
          </div>
        ) : (
          <Dashboard
            workspaces={rows}
            onSelect={onSelectWorkspace}
            races={races}
            onPurgeRaceLosers={onPurgeRaceLosers}
            onStopRace={onStopRace}
            purgingRace={purgingRace}
            onBulkArchive={onBulkArchive}
          />
        )}
      </div>
      <Backlog
        projectId={project.id}
        projectName={project.name}
        statusKey={statusKey}
        refreshSignal={backlogNonce}
        variant="panel"
        onStartTodo={onStartTodo}
        onStartMany={onStartMany}
        onOpenWorkspace={(wsId, stage) => {
          const ws = workspaces.find((w) => w.id === wsId);
          if (ws) onSelectWorkspace(ws, stage);
        }}
      />
    </div>
  );
}
