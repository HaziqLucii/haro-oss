import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { Project, Workspace } from "../types";
import { Chevron } from "./Chevron";
import { Check, Gear, Pencil } from "./icons";
import { StackIcons } from "./StackIcon";

/** Sidebar navigator: projects, each expanding to its workspaces.
 *  This is the spine of the (coming) parallel multi-agent dashboard. */
export function Sidebar({
  projects,
  wsByProject,
  expanded,
  selectedId,
  selectedProjectId,
  draftIds,
  onToggle,
  onSelectProject,
  onSelect,
  onOpenPicker,
  onNewWorkspace,
  onArchiveWorkspace,
  onRenameWorkspace,
  onRemoveProject,
  onOpenProjectSettings,
  onOpenBacklog,
  onOpenSettings,
}: {
  projects: Project[];
  wsByProject: Record<string, Workspace[]>;
  expanded: Record<string, boolean>;
  selectedId: string | null;
  selectedProjectId: string | null; // project whose dashboard is showing (no ws selected)
  draftIds?: Set<string>; // workspaces with unsent composer text (client-derived "draft" overlay)
  onToggle: (projectId: string) => void;
  onSelectProject: (projectId: string) => void; // opens the project dashboard
  onSelect: (ws: Workspace) => void;
  onOpenPicker: () => void;
  onNewWorkspace: (projectId: string) => void; // opens the new-workspace modal
  onArchiveWorkspace: (ws: Workspace) => void; // tears down a single worktree
  onRenameWorkspace: () => void; // opens the rename-workspace modal for the selected workspace
  onRemoveProject: (project: Project) => void; // untracks a repo + all its worktrees
  onOpenProjectSettings: (projectId: string) => void; // opens the per-project settings surface
  onOpenBacklog: (projectId: string) => void; // opens the backlog overlay (reachable without leaving a workspace)
  onOpenSettings: () => void;
}) {
  // The workspace the appbar crumb points at — the drawer footer's "archive"
  // acts on it (on mobile the top-bar archive button moves down here).
  const selectedWs = selectedId
    ? Object.values(wsByProject)
        .flat()
        .find((w) => w.id === selectedId) ?? null
    : null;
  return (
    <aside className="sidebar card">
      <div className="side-head">
        <span className="side-head-title">projects</span>
        <button className="ghost" onClick={onOpenPicker} title="add a repo">
          +
        </button>
      </div>

      <div className="side-scroll">
        {projects.length === 0 && (
          <div className="side-empty dim">No projects yet. Click + to browse for a repo.</div>
        )}

        {projects.map((p) => {
          // Soft-archived race losers keep their store row so the scorecard can still
          // link to their transcript + branch (backlog/winner-fanout.md §3), but their
          // worktree is gone — so they are NOT navigable work and don't belong in the
          // spine. The scorecard is their home; the sidebar stays a list of live
          // workspaces. (Nothing else ever produces an `archived` row: every other
          // archive path deletes it outright.)
          const workspaces = (wsByProject[p.id] ?? []).filter((w) => w.status !== "archived");
          const open = expanded[p.id];
          // Highlight the project capsule whenever it's the active context — either
          // its dashboard is showing, OR one of its workspaces is selected (so you
          // always see which project the current workspace belongs to).
          const projectActive =
            selectedProjectId === p.id || workspaces.some((w) => w.id === selectedId);
          return (
            <div key={p.id} className="side-project">
              <div className="side-project-head">
                <button
                  className={"side-project-row" + (projectActive ? " side-project-row-sel" : "")}
                  onClick={() => {
                    onSelectProject(p.id); // open the project dashboard
                    if (!open) onToggle(p.id); // and reveal its workspaces
                  }}
                >
                  <span
                    className="side-project-caret"
                    role="button"
                    aria-label={open ? "Collapse" : "Expand"}
                    onClick={(e) => {
                      e.stopPropagation(); // caret only toggles; it doesn't reselect
                      onToggle(p.id);
                    }}
                  >
                    <Chevron open={open} />
                  </span>
                  <StackIcons ids={p.stack} />
                  <span className="side-project-name">{p.name}</span>
                </button>
                <button
                  className="side-row-menu-btn"
                  aria-label={`${p.name} backlog`}
                  title={`${p.name} backlog`}
                  onMouseDown={(e) => e.stopPropagation()}
                  onClick={(e) => {
                    e.stopPropagation();
                    onOpenBacklog(p.id);
                  }}
                >
                  <Check size={13} />
                </button>
                <button
                  className="side-row-menu-btn"
                  aria-label={`${p.name} settings`}
                  title={`${p.name} settings`}
                  onMouseDown={(e) => {
                    // don't let the row's select/toggle fire underneath
                    e.stopPropagation();
                  }}
                  onClick={(e) => {
                    e.stopPropagation();
                    onOpenProjectSettings(p.id);
                  }}
                >
                  <Gear size={13} />
                </button>
                <RowMenu
                  title={`Manage ${p.name}`}
                  danger={{
                    label: "Remove project",
                    confirmText:
                      workspaces.length > 0
                        ? `Untrack “${p.name}” and archive its ${workspaces.length} workspace${
                            workspaces.length === 1 ? "" : "s"
                          }? The repo on disk is kept, haro just stops tracking it.`
                        : `Untrack “${p.name}”? The repo on disk is kept, haro just stops tracking it.`,
                    confirmLabel: "Remove",
                    onConfirm: () => onRemoveProject(p),
                  }}
                />
              </div>

              {open && (
                <div className="side-ws-list">
                  {workspaces.map((w) => (
                    <div
                      key={w.id}
                      className={"side-ws-row" + (w.id === selectedId ? " side-ws-row-sel" : "")}
                    >
                      <button
                        className={"side-ws" + (w.id === selectedId ? " side-ws-sel" : "")}
                        onClick={() => onSelect(w)}
                        title={w.branch}
                      >
                        <span className={"ws-dot ws-dot-" + w.status} />
                        <span className="side-ws-name">{w.name}</span>
                        {w.kind === "adopted" && (
                          <span
                            className="side-ws-adopted"
                            title={`Adopted foreign worktree${w.source ? ` (${w.source})` : ""} · agentless, gated in place`}
                          >
                            adopted{w.source ? ` · ${w.source}` : ""}
                          </span>
                        )}
                        {draftIds?.has(w.id) && (
                          <span className="side-ws-draft" title="unsent prompt · not run yet">
                            draft
                          </span>
                        )}
                      </button>
                      <RowMenu
                        title={`Manage ${w.name}`}
                        danger={{
                          label: "Archive workspace",
                          confirmText: `Archive “${w.name}”? Its worktree and any uncommitted work are removed. This can't be undone.`,
                          confirmLabel: "Archive",
                          onConfirm: () => onArchiveWorkspace(w),
                        }}
                      />
                    </div>
                  ))}

                  <button className="side-newws ghost" onClick={() => onNewWorkspace(p.id)}>
                    + new workspace
                  </button>
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* Mobile-only footer: on a phone the appbar shrinks to ☰ + brand + the
          workspace name, and these controls (theme / settings / archive) fold
          in here. Hidden on desktop (they live in the appbar there). */}
      <div className="side-foot">
        <button className="ghost side-foot-btn" onClick={onOpenSettings}>
          <span className="side-foot-glyph"><Gear size={13} /></span>
          settings
        </button>
        {selectedWs && (
          <button
            className="ghost side-foot-btn"
            onClick={onRenameWorkspace}
            title={`Rename ${selectedWs.name}`}
          >
            <span className="side-foot-glyph"><Pencil size={13} /></span>
            rename
          </button>
        )}
        {selectedWs && (
          <button
            className="ghost side-foot-btn side-foot-archive"
            onClick={() => onArchiveWorkspace(selectedWs)}
            title={`Archive ${selectedWs.name}`}
          >
            <span className="side-foot-glyph">⌫</span>
            archive
          </button>
        )}
      </div>
    </aside>
  );
}

// ---- per-row actions menu (the tight-sidebar-friendly "⋯") ----
// A hover-revealed kebab that opens a small popover. Destructive actions live
// here rather than as always-visible buttons so the spine stays clean; the
// popover is position:fixed (computed from the trigger's rect) so the
// scrolling sidebar never clips it, and it requires a two-step confirm.

type DangerAction = {
  label: string;
  confirmText: string;
  confirmLabel: string;
  onConfirm: () => void;
};

function RowMenu({ title, danger }: { title: string; danger: DangerAction }) {
  const btnRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [pos, setPos] = useState<{ top: number; right: number } | null>(null);

  // Anchor the fixed popover to the trigger, opening leftward (the kebab sits
  // at the sidebar's right edge). Re-measured on open.
  useLayoutEffect(() => {
    if (!open || !btnRef.current) return;
    const r = btnRef.current.getBoundingClientRect();
    setPos({ top: r.bottom + 4, right: window.innerWidth - r.right });
  }, [open]);

  // Close on any outside click, scroll, or Escape.
  useEffect(() => {
    if (!open) return;
    const dismiss = () => {
      setOpen(false);
      setConfirming(false);
    };
    // capture-phase so a press anywhere dismisses first; but ignore presses on
    // the trigger (let its onClick toggle) or inside the menu itself.
    const onDown = (e: MouseEvent) => {
      const t = e.target as Node;
      if (btnRef.current?.contains(t) || menuRef.current?.contains(t)) return;
      dismiss();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") dismiss();
    };
    window.addEventListener("mousedown", onDown, true);
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("scroll", dismiss, true);
    return () => {
      window.removeEventListener("mousedown", onDown, true);
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("scroll", dismiss, true);
    };
  }, [open]);

  return (
    <>
      <button
        ref={btnRef}
        className="side-row-menu-btn ghost"
        aria-label={title}
        aria-expanded={open}
        title={title}
        onMouseDown={(e) => {
          // stop the row's select/toggle from firing, and pre-empt the global
          // close handler on this same mousedown.
          e.stopPropagation();
          e.preventDefault();
        }}
        onClick={(e) => {
          e.stopPropagation();
          setOpen((o) => !o);
          setConfirming(false);
        }}
      >
        ⋯
      </button>

      {open && pos && (
        <div
          ref={menuRef}
          className="side-row-menu"
          style={{ top: pos.top, right: pos.right }}
        >
          {!confirming ? (
            <button
              className="side-row-menu-item danger"
              onClick={() => setConfirming(true)}
            >
              {danger.label}
            </button>
          ) : (
            <div className="side-row-confirm">
              <div className="side-row-confirm-text">{danger.confirmText}</div>
              <div className="side-row-confirm-actions">
                <button className="ghost" onClick={() => setOpen(false)}>
                  Cancel
                </button>
                <button
                  className="side-row-confirm-go danger"
                  onClick={() => {
                    danger.onConfirm();
                    setOpen(false);
                    setConfirming(false);
                  }}
                >
                  {danger.confirmLabel}
                </button>
              </div>
            </div>
          )}
        </div>
      )}
    </>
  );
}
