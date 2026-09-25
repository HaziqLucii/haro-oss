import { Fragment, useEffect, useMemo, useState, type ReactNode } from "react";
import { Maximize, Minimize, Refresh, X } from "./icons";
import { Chevron } from "./Chevron";
import { IssueDetail } from "./IssueDetail";
import { FileMarkdown } from "./FileMarkdown";
import { api } from "../api";
import type { IssueItem, IssuesResponse, TodoFile, TodoItem, TodoResponse } from "../types";

// The two backlog sources are shown as top-level tabs (not mixed into one rail):
// the committed todo-*.md files and the project's GitHub Issues.
type BacklogTab = "todo" | "issues";
// GitHub-style state filter for the issues tab. Defaults to "open" — the live queue.
type IssueFilter = "open" | "closed" | "all";

// The row glyph for a seeded item's derived `stage` (backlog/backlog-v2.md Move 2)
// — the item's status IS its gate status, so the glyph mirrors the gate's own
// states rather than the old plain done/in-progress/startable set. `done` (the
// checkbox) wins outright: a ticked item reads finished even if its stage field
// is stale (e.g. the workspace was since archived).
export function stageGlyph(done: boolean, stage: string | undefined, seeded: boolean): string {
  // A live seeded workspace wins over `done` — a closed issue being backtracked
  // (re-seeded into a new workspace) must still read as active work, not as
  // finished; a todo item is never both done and seeded (renderTodoItem only
  // marks `seeded` on a NOT-done item), so this never changes that case.
  if (seeded) {
    if (stage === "green") return "●";
    if (stage === "red") return "✕";
    return "◐"; // queued / running / no stage data yet
  }
  if (done || stage === "shipped") return "✔";
  return "○";
}

// Empty-state copy for the graceful-degrade cases, mirroring the PR chip's tone.
// "no-gh" is rendered separately (with a copyable `gh auth login` line) — see
// the issues-panel empty state below — so it never reaches this plain-text path.
function issuesEmptyMsg(reason?: string | null): string {
  if (reason === "no-remote") return "Link a GitHub remote to pull issues.";
  if (reason === "no-gh") return "Install the GitHub CLI (gh) to pull issues.";
  return "Couldn't load issues" + (reason ? ` · ${reason}` : "") + ".";
}

// GitHub issue titles here follow a "[TAG] - real title" convention (e.g.
// "[MO] - ACUVUE pop-up", a Malaya-Optical naming pattern). Strip a leading
// bracketed tag (and any dash that follows it) so the seeded workspace name is the
// descriptive part, not the project tag. Scoped to the issues tab on purpose:
// todo-file items don't use this convention, so their names are left untouched.
// Falls back to the original title if stripping would leave nothing.
function issueSeedName(title: string): string {
  return title.replace(/^\s*\[[^\]]*\]\s*[-–—]?\s*/, "").trim() || title;
}

// ── Issues-tab display filters (pure, so they're unit-tested in isolation) ──────
// Free-text match over #number / title / label. `q` must be pre-lowercased+trimmed.
export function issueMatchesQuery(it: IssueItem, q: string): boolean {
  if (!q) return true;
  return (
    it.title.toLowerCase().includes(q) ||
    String(it.number).includes(q) ||
    it.labels.some((l) => l.toLowerCase().includes(q))
  );
}

// Distinct labels across the given issues, each with its issue count, ranked
// count-desc then name — powers the label-filter chips and the group ordering.
export function labelCountsOf(issues: IssueItem[]): [string, number][] {
  const m = new Map<string, number>();
  for (const it of issues) for (const l of it.labels) m.set(l, (m.get(l) ?? 0) + 1);
  return [...m.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}

// Group each issue under its FIRST label ("" = unlabeled, always sorted last),
// mirroring the todo `## heading` model: one group per row-owner, so every issue
// stays a single seedable row (multi-label duplication would spawn two "seed #n"
// buttons). `order` ranks the labelled groups; anything not in it falls to the end.
export function groupIssuesByLabel(
  issues: IssueItem[],
  order: string[],
): [string, IssueItem[]][] {
  const groups = new Map<string, IssueItem[]>();
  for (const it of issues) {
    const key = it.labels[0] ?? "";
    (groups.get(key) ?? groups.set(key, []).get(key)!).push(it);
  }
  const rank = (l: string) => {
    if (l === "") return Number.MAX_SAFE_INTEGER;
    const i = order.indexOf(l);
    return i === -1 ? Number.MAX_SAFE_INTEGER - 1 : i;
  };
  return [...groups.entries()].sort((a, b) => rank(a[0]) - rank(b[0]));
}

// The magnifying-glass used by both search inputs (todo-file rail + issues tab).
function SearchIcon() {
  return (
    <svg
      className="backlog-search-icon"
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.4"
      aria-hidden
    >
      <circle cx="11" cy="11" r="7" />
      <path d="m21 21-4.3-4.3" />
    </svg>
  );
}

// ISO stamp → local "HH:MM" for the display-cache "as of …" badge.
function fmtTime(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

// Minimal inline markdown for TODO lines so items don't render with raw `**` and
// backticks: `code`, **bold**, *italic*. (The backlog is read-only prose, so this
// is deliberately tiny — no block/link parsing.)
function renderInline(text: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  const re = /`([^`]+)`|\*\*([^*]+)\*\*|\*([^*]+)\*/g;
  let last = 0;
  let k = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    if (m.index > last) nodes.push(text.slice(last, m.index));
    if (m[1] != null) nodes.push(<code key={k++} className="side-todo-code">{m[1]}</code>);
    // bold/italic recurse so `code` nested inside them still renders (e.g. **shared `x`**)
    else if (m[2] != null) nodes.push(<strong key={k++}>{renderInline(m[2])}</strong>);
    else if (m[3] != null) nodes.push(<em key={k++}>{renderInline(m[3])}</em>);
    last = re.lastIndex;
  }
  if (last < text.length) nodes.push(text.slice(last));
  return nodes;
}

// A todo file falls into one of three lifecycle buckets, each with its own colour so
// the list reads at a glance: what's underway, what's untouched, what's shipped.
//   active  — some (not all) items ticked → work in progress (amber)
//   todo    — nothing ticked yet          → not started       (dim)
//   done    — every item ticked           → completed         (green)
type Category = "active" | "todo" | "done";
const CATEGORY: Record<Category, string> = {
  active: "In progress",
  todo: "Not started",
  done: "Completed",
};
// needs-attention → untouched → shipped: the same "what's next?" ranking the dashboard uses.
const CATEGORY_ORDER: Category[] = ["active", "todo", "done"];

function categoryOf(f: TodoFile): Category {
  const total = f.items.length;
  if (total > 0 && f.done >= total) return "done";
  if (f.done > 0) return "active";
  return "todo";
}

// The project backlog — the repo's committed TODO.md files, read-only.
// "The gate is the whole point": the rest of the UI answers "what's happening?"
// (status dots, dashboard, gate). This panel answers "what's next?". A todo flips
// to done when an agent's branch merges the tick back to main, so this reads as
// "shipped vs. pending". It re-fetches on the same status changes that signal a
// merge/gate flip (statusKey) AND on `refreshSignal` — bumped when the backend's
// filesystem watcher sees a committed todo-*.md change (e.g. after a `git pull`),
// so a pull's new/ticked items appear without a manual refresh.
//
// It's a *project-level* artifact (one set of TODO files per repo, shared across
// every workspace), so its home is the project dashboard — the pre-workspace view
// where you decide what to work on next — not a workspace-scoped panel.
//
// Two backlog sources sit behind top-level tabs: the parsed todo-*.md files (a
// searchable master-detail: file rail + the selected file's checklist) and the
// project's GitHub Issues (a live `gh` read with an Open/Closed/All filter). They
// used to share one rail — the issues entry sat among the todo files — which read
// as "issues are one of the files". Splitting them into source tabs keeps each
// backlog kind legible and gives issues room for their own state filter.

export function Backlog({
  projectId,
  projectName,
  statusKey,
  refreshSignal,
  variant = "sidebar",
  onStartTodo,
  onOpenWorkspace,
  onStartMany,
}: {
  projectId: string | null;
  projectName: string | null;
  statusKey: string;
  /** Bumped by the backend fs watcher when a committed todo-*.md file changes
   *  (e.g. after a `git pull`) → refetch so the backlog stays live. */
  refreshSignal?: number;
  variant?: "sidebar" | "panel";
  // Click a pending todo → seed a new workspace from it. `title` (compact prose)
  // drives the short branch/workspace name; `task` (full item incl. code) is the
  // agent's brief; `seedKey` links the workspace back to this item so it can't be
  // clicked into a duplicate.
  onStartTodo?: (title: string, task: string, seedKey?: string) => void;
  // Click an item that already has a workspace in flight → jump to that workspace
  // instead of starting another. `stage` (Move 2) lets the caller deep-link: green
  // to ④ ship, red to ③ verify, instead of always landing on the default view.
  onOpenWorkspace?: (workspaceId: string, stage?: string) => void;
  // "Start next N" (backlog/backlog-v2.md Move 3): N prompts x 1 lane each, through
  // the existing [agent] max_parallel queue — distinct from race.py's 1 prompt x N
  // lanes. Optional: the multi-select toolbar only appears when this is given.
  onStartMany?: (items: { title: string; task: string; seedKey?: string }[]) => void;
}) {
  const [todo, setTodo] = useState<TodoResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  // The active file is tracked by path so it survives a re-fetch; if that file
  // disappears we fall back to the first below (no effect needed).
  const [activePath, setActivePath] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  // Which backlog source is on screen. Todo files are the default (the committed,
  // always-present backlog); GitHub Issues are opt-in via the tab.
  const [tab, setTab] = useState<BacklogTab>("todo");
  // GitHub Issues tab: fetched live via `gh` (never persisted). Refetches on the
  // same status/gate signals as the todo tab (statusKey/refreshSignal) — no new
  // poller — plus a manual ⟳ force-refresh.
  const [issues, setIssues] = useState<IssuesResponse | null>(null);
  const [issuesRefreshing, setIssuesRefreshing] = useState(false);
  // Open is the working queue; Closed is for backtracking a resolved issue.
  const [issueFilter, setIssueFilter] = useState<IssueFilter>("open");
  // Assignee scope: false = the project's configured `[backlog] issue_assignee`
  // default ("" = anyone, unless the project opts back into `@me`); true forces
  // `@me` regardless of config. Triggers a refetch (unlike state, which stays a
  // client-side filter over one "all" fetch — assignee is a real gh query change).
  const [mineOnly, setMineOnly] = useState(false);
  const [copiedGhLogin, setCopiedGhLogin] = useState(false);
  // Which issue's detail (body + comments) is expanded inline, by number. Read-only
  // detail fetched on demand by <IssueDetail>; only one row is open at a time.
  const [expandedIssue, setExpandedIssue] = useState<number | null>(null);
  // Issues-tab display filters (all client-side over the live `gh` fetch — no refetch):
  //   issueQuery  — free-text over #number / title / label
  //   labelFilter — narrow to a single label (toggled from the label-chip bar)
  //   groupByLabel — mirror the todo `## heading` grouping, one group per first label
  const [issueQuery, setIssueQuery] = useState("");
  const [labelFilter, setLabelFilter] = useState<string | null>(null);
  const [groupByLabel, setGroupByLabel] = useState(false);
  // In-app backlog editing (PUT /todo). `editing` opens a raw-markdown editor over
  // the active file; `creating` is the new-file form (its own path input). `draft`
  // is the shared editor buffer; `reloadNonce` re-runs the todo fetch after a save
  // (on top of the fs-watcher refresh, so the panel updates instantly).
  //
  // C9 tried dropping `editing` in favor of ② code (Monaco already edits any file
  // in the worktree) — reverted: the backlog panel also renders on the PROJECT
  // HOME, with no workspace open and therefore no ② code to send anyone to, so
  // that removal was a straight regression (you could create a file and then never
  // touch it again from here). Kept for the workspace-embedded panel too, since a
  // typo fix shouldn't require leaving the backlog for the code step.
  const [editing, setEditing] = useState(false);
  const [creating, setCreating] = useState(false);
  const [draft, setDraft] = useState("");
  const [newPath, setNewPath] = useState("");
  const [saving, setSaving] = useState(false);
  const [saveErr, setSaveErr] = useState<string | null>(null);
  const [reloadNonce, setReloadNonce] = useState(0);
  // Fullscreen overlay — mirrors the workspace cards' pattern (.card--full +
  // .card-backdrop, Esc to exit). Kept local since the backlog is a self-contained
  // component reused across views (no shared Esc handler to hook into).
  const [full, setFull] = useState(false);
  // "Start next N" multi-select (Move 3) — off by default; toggled on from the
  // toolbar. Selection is keyed by seed_key, since that's what identifies a
  // startable item across a refetch (an index would drift).
  const [selectMode, setSelectMode] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());

  // Esc exits fullscreen (only while expanded).
  useEffect(() => {
    if (!full) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setFull(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [full]);

  useEffect(() => {
    if (!projectId) {
      setTodo(null);
      return;
    }
    let cancelled = false;
    api
      .getTodo(projectId)
      .then((t) => {
        if (!cancelled) {
          setTodo(t);
          setError(null);
        }
      })
      .catch((e) => {
        if (!cancelled) setError(e?.message ?? "failed to load todo files");
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, statusKey, refreshSignal, reloadNonce]);

  useEffect(() => {
    if (!projectId) {
      setIssues(null);
      return;
    }
    let cancelled = false;
    // state is a real query param (not a client-side filter over one "all" fetch):
    // gh's newest-first ordering under one shared `issue_limit` means an "all" fetch
    // can get filled entirely by closed issues, silently hiding open ones from the
    // Open tab. Refetching per tab costs the cross-tab live counts (see the filter
    // bar below) but never hides real data behind a truncated window.
    api
      .getIssues(projectId, { state: issueFilter, mine: mineOnly })
      .then((r) => {
        if (!cancelled) setIssues(r);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [projectId, statusKey, refreshSignal, issueFilter, mineOnly]);

  const refreshIssues = () => {
    if (!projectId || issuesRefreshing) return;
    setIssuesRefreshing(true);
    api
      .getIssues(projectId, { refresh: true, state: issueFilter, mine: mineOnly })
      .then(setIssues)
      .catch(() => {})
      .finally(() => setIssuesRefreshing(false));
  };

  const files = todo?.files ?? [];
  // Flat lookup across every file's items, keyed by seed_key — "Start N" can pick
  // items from any file, not just the one currently open. Actionable items only
  // (not done, not already seeded): a stale selection surviving a refetch — the
  // item was ticked, or a workspace picked it up between selecting and clicking
  // Start — must silently drop out here rather than start a SECOND workspace for
  // an item the in-progress lock already covers.
  const itemsBySeedKey = useMemo(() => {
    const m = new Map<string, { item: TodoItem; path: string }>();
    for (const f of files)
      for (const it of f.items)
        if (it.seed_key && !it.done && !it.seeded_workspace) m.set(it.seed_key, { item: it, path: f.path });
    return m;
  }, [files]);

  // Search is a filename filter (label + repo-relative path), so a query narrows the
  // rail but never hides the file you already have open in the detail column.
  const q = query.trim().toLowerCase();
  const filtered = useMemo(
    () =>
      q
        ? files.filter(
            (f) => f.label.toLowerCase().includes(q) || f.path.toLowerCase().includes(q),
          )
        : files,
    [files, q],
  );

  const active =
    files.find((f) => f.path === activePath) ?? filtered[0] ?? files[0] ?? null;
  const items = active?.items ?? [];
  const blocks = active?.blocks ?? [];

  // Switching files (or projects) closes any open editor — an edit is scoped to the
  // file it was opened on, and we don't carry an unsaved draft across selections.
  useEffect(() => {
    setEditing(false);
    setCreating(false);
    setSaveErr(null);
  }, [active?.path, projectId]);

  // Create/overwrite a backlog file, then reload + select it. Used by both the
  // "Edit" (existing file) and "New file" (fresh path) flows.
  const saveFile = (path: string, content: string) => {
    if (!projectId || saving) return;
    setSaving(true);
    setSaveErr(null);
    api
      .putTodo(projectId, path, content)
      .then((r) => {
        setReloadNonce((n) => n + 1);
        setActivePath(r.path);
        setEditing(false);
        setCreating(false);
      })
      .catch((e) => setSaveErr(e?.message ?? "failed to save"))
      .finally(() => setSaving(false));
  };

  const startEdit = () => {
    if (!active) return;
    setDraft(active.content);
    setEditing(true);
    setSaveErr(null);
  };

  const startNewFile = () => {
    setNewPath("backlog/");
    setDraft("# Title\n\n- [ ] First task — describe it\n");
    setCreating(true);
    setEditing(false);
    setSaveErr(null);
  };

  // The empty-state "Create backlog/TODO.md" action: one call to the existing
  // putTodo path with a starter template, no modal round-trip.
  const createDefaultTodo = () => {
    saveFile(
      "backlog/TODO.md",
      "# TODO\n\n- [ ] First task — describe it\n- [ ] Second task — describe it\n",
    );
  };

  // "Start next N" (Move 3): resolve each selected seed_key back to its item +
  // source file, build the same task shape a single click would, and hand the
  // whole batch to the caller in one go (it loops createWorkspace through the
  // existing [agent] max_parallel queue — N prompts x 1 lane, not race.py's
  // 1 prompt x N lanes).
  const startSelected = () => {
    if (!onStartMany || selected.size === 0) return;
    const items = [...selected]
      .map((key) => itemsBySeedKey.get(key))
      .filter((v): v is { item: TodoItem; path: string } => !!v)
      .map(({ item, path }) => ({
        title: item.text,
        task: `${item.body || item.text}\n\nReference: ${path}`,
        seedKey: item.seed_key,
      }));
    onStartMany(items);
    setSelected(new Set());
    setSelectMode(false);
  };

  // One backlog task row (clickable → seed a workspace / open the in-flight one, or
  // a static done/seeded row). Rendered among the file's note blocks in doc order.
  function renderTodoItem(it: TodoItem, key: number): ReactNode {
    const seeded = !it.done && !!it.seeded_workspace;
    const actionable = !!onStartTodo && !it.done && !seeded;
    const picking = selectMode && actionable && !!it.seed_key;
    const isPicked = picking && selected.has(it.seed_key!);
    const inner = (
      <>
        <span className={"side-todo-box" + (picking ? " side-todo-pick" : "")}>
          {picking ? (isPicked ? "☑" : "☐") : stageGlyph(it.done, it.stage, seeded)}
        </span>
        <span className="side-todo-text">{renderInline(it.text)}</span>
        {actionable && !selectMode && <span className="side-todo-go" aria-hidden>＋</span>}
        {seeded && <span className="side-todo-wip">in progress</span>}
      </>
    );
    if (picking) {
      return (
        <button
          key={key}
          className={"side-todo side-todo-btn" + (isPicked ? " side-todo-picked" : "")}
          aria-pressed={isPicked}
          onClick={() =>
            setSelected((prev) => {
              const next = new Set(prev);
              if (next.has(it.seed_key!)) next.delete(it.seed_key!);
              else next.add(it.seed_key!);
              return next;
            })
          }
          title="Select for Start N"
        >
          {inner}
        </button>
      );
    }
    if (actionable) {
      return (
        <button
          key={key}
          className="side-todo side-todo-btn"
          onClick={() =>
            onStartTodo!(
              it.text,
              // Append a pointer to the source backlog file (repo-relative, so it
              // opens straight in the worktree) — lets the agent read the
              // surrounding headings/notes the seed body doesn't carry.
              `${it.body || it.text}\n\nReference: ${active!.path}`,
              it.seed_key,
            )
          }
          title="Start a workspace for this task"
        >
          {inner}
        </button>
      );
    }
    if (seeded && onOpenWorkspace) {
      return (
        <button
          key={key}
          className="side-todo side-todo-btn side-todo-wip-btn"
          onClick={() => onOpenWorkspace(it.seeded_workspace!, it.stage)}
          title="A workspace for this task is already in progress. Open it"
        >
          {inner}
        </button>
      );
    }
    return (
      <div
        key={key}
        className={
          "side-todo" +
          (it.done ? " side-todo-done" : "") +
          (seeded ? " side-todo-wip-row" : "")
        }
      >
        {inner}
      </div>
    );
  }

  // The raw-markdown editor — creation only now (see the `creating` state comment).
  // The raw-markdown editor (shared by Edit + New file). `pathInput` renders the
  // filename field only in the new-file flow (an existing file's path is fixed).
  const editorBody = (path: string, pathInput: boolean, saveLabel: string) => (
    <div className="backlog-editor">
      {pathInput && (
        <input
          className="backlog-newpath"
          value={newPath}
          onChange={(e) => setNewPath(e.target.value)}
          placeholder="backlog/my-feature.md"
          spellCheck={false}
          aria-label="New backlog file path"
        />
      )}
      <textarea
        className="backlog-editor-area"
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        spellCheck={false}
        aria-label="Backlog markdown"
      />
      <div className="backlog-editor-hint dim">
        Use <code>- [ ] Title — detail</code> for a clickable task; any other text is
        kept as notes.
      </div>
      {saveErr && <div className="backlog-editor-err">{saveErr}</div>}
      <div className="backlog-editor-actions">
        <button
          className="backlog-editor-save"
          disabled={saving || !path.trim()}
          onClick={() => saveFile(path.trim(), draft)}
        >
          {saving ? "Saving…" : saveLabel}
        </button>
        <button
          className="backlog-editor-cancel"
          disabled={saving}
          onClick={() => {
            setEditing(false);
            setCreating(false);
            setSaveErr(null);
          }}
        >
          Cancel
        </button>
      </div>
    </div>
  );

  const totalDone = files.reduce((n, f) => n + f.done, 0);
  const totalItems = files.reduce((n, f) => n + f.items.length, 0);
  // Already scoped to the active state tab server-side (issueFilter/mineOnly
  // trigger a refetch above) — search/label narrow further, client-side, over
  // that one fetch. No cross-tab counts: a second fetch per tab isn't worth
  // paying just to badge the tabs you're not looking at.
  const issueList = issues?.issues ?? [];
  const labelCounts = useMemo(() => labelCountsOf(issueList), [issueList]);
  const iq = issueQuery.trim().toLowerCase();
  const shownIssues = useMemo(() => {
    const searched = issueList.filter((it) => issueMatchesQuery(it, iq));
    return labelFilter
      ? searched.filter((it) => it.labels.includes(labelFilter))
      : searched;
  }, [issueList, iq, labelFilter]);
  const issuesFilteredOut = issueList.length > 0 && shownIssues.length === 0;
  const groupedIssues = useMemo(
    () => (groupByLabel ? groupIssuesByLabel(shownIssues, labelCounts.map(([l]) => l)) : []),
    [groupByLabel, shownIssues, labelCounts],
  );

  // One issue row → reuses the todo pending ○ / seeded ◐ states. A *closed* issue
  // shows a dimmed ✔ + "closed" badge but stays clickable-to-seed (backtrack a
  // resolved issue) — closed is a visual state here, not a lock like a done todo.
  function issueRow(it: IssueItem, i: number) {
    const seeded = !!it.seeded_workspace;
    const closed = it.state === "closed";
    // Open and closed are both seedable; only a live seeded workspace blocks a new one.
    const actionable = !!onStartTodo && !seeded;
    const box = stageGlyph(closed, it.stage, seeded);
    const inner = (
      <>
        <span className="side-todo-box">{box}</span>
        <span className="side-todo-text">
          <span className="issue-num">#{it.number}</span> {renderInline(it.title)}
          {it.labels.length > 0 && (
            <span className="issue-labels">
              {it.labels.map((l) => (
                <span
                  key={l}
                  className={"issue-label" + (labelFilter === l ? " issue-label-active" : "")}
                >
                  {l}
                </span>
              ))}
            </span>
          )}
        </span>
        {closed && !seeded && <span className="issue-closed-badge">closed</span>}
        {actionable && !closed && (
          <span className="side-todo-go" aria-hidden>
            ＋
          </span>
        )}
        {seeded && <span className="side-todo-wip">in progress</span>}
      </>
    );
    if (seeded && onOpenWorkspace) {
      return (
        <button
          key={i}
          className="side-todo side-todo-btn side-todo-wip-btn"
          onClick={() => onOpenWorkspace(it.seeded_workspace!, it.stage)}
          title="A workspace for this issue is already in progress. Open it"
        >
          {inner}
        </button>
      );
    }
    if (actionable) {
      // The seeded task: issue body as the brief, plus a Reference line so the agent
      // can `gh issue view <n>` for the live comments / resolution (body is a snapshot).
      const task = `${it.body || it.title}\n\nReference: #${it.number}`;
      return (
        <button
          key={i}
          className={"side-todo side-todo-btn" + (closed ? " side-todo-closed-btn" : "")}
          onClick={() => onStartTodo!(issueSeedName(it.title), task, it.seed_key)}
          title={
            closed
              ? "Pick this closed issue back up in a new workspace"
              : "Start a workspace for this issue"
          }
        >
          {inner}
        </button>
      );
    }
    return (
      <div
        key={i}
        className={"side-todo" + (seeded ? " side-todo-wip-row" : closed ? " side-todo-done" : "")}
      >
        {inner}
      </div>
    );
  }

  const asOf = issues?.stale && issues.fetched_at ? fmtTime(issues.fetched_at) : null;

  // A GitHub-style Open / Closed / All segmented filter. Each tab is its own fetch
  // (see the effect above), so only the ACTIVE tab has a live count — an inactive
  // tab's count would be stale the moment you last looked at it, worse than none.
  const issueFilterBar = (
    <div className="issue-filter" role="tablist" aria-label="Filter issues by state">
      {(
        [
          ["open", "Open"],
          ["closed", "Closed"],
          ["all", "All"],
        ] as [IssueFilter, string][]
      ).map(([key, label]) => (
        <button
          key={key}
          role="tab"
          aria-selected={issueFilter === key}
          className={"issue-filter-btn" + (issueFilter === key ? " issue-filter-on" : "")}
          onClick={() => setIssueFilter(key)}
        >
          {label}
          {issueFilter === key && <span className="issue-filter-n">{issueList.length}</span>}
        </button>
      ))}
      <button
        role="tab"
        aria-selected={mineOnly}
        className={"issue-filter-btn issue-filter-mine" + (mineOnly ? " issue-filter-on" : "")}
        onClick={() => setMineOnly((v) => !v)}
        title={
          mineOnly
            ? "Showing only issues assigned to you"
            : "Showing issues for any assignee (overrides the project's configured default)"
        }
      >
        {mineOnly ? "Mine" : "All assignees"}
      </button>
    </div>
  );

  const copyGhLogin = () => {
    navigator.clipboard?.writeText("gh auth login").then(
      () => {
        setCopiedGhLogin(true);
        setTimeout(() => setCopiedGhLogin(false), 1200);
      },
      () => {},
    );
  };

  // Free-text search over the issues + a group-by-label toggle. Search mirrors the
  // todo rail's input; the toggle only earns its place once ≥2 labels exist.
  const issueControls = (
    <div className="issue-controls">
      <div className="backlog-search issue-search">
        <SearchIcon />
        <input
          className="backlog-search-input"
          value={issueQuery}
          onChange={(e) => setIssueQuery(e.target.value)}
          placeholder="Search issues…"
          spellCheck={false}
          aria-label="Search issues by number, title or label"
        />
        {issueQuery && (
          <button
            className="backlog-search-clear"
            onClick={() => setIssueQuery("")}
            title="Clear search"
            aria-label="Clear search"
          >
            <X />
          </button>
        )}
      </div>
      {labelCounts.length > 1 && (
        <button
          className={"issue-group-toggle" + (groupByLabel ? " issue-group-on" : "")}
          aria-pressed={groupByLabel}
          onClick={() => setGroupByLabel((v) => !v)}
          title="Group issues by label"
        >
          Group by label
        </button>
      )}
    </div>
  );

  // Clickable label chips = the label filter. Single-select toggle; a "clear" chip
  // appears once a filter is active. Counts come from the current state view so an
  // empty label simply doesn't show. (Assignee chips are intentionally omitted: the
  // fetch is `--assignee @me`, so every row is the same assignee — pure noise.)
  const labelChipsBar = labelCounts.length > 0 && (
    <div className="issue-labels-bar" role="group" aria-label="Filter issues by label">
      {labelFilter && (
        <button
          className="issue-label-chip issue-label-chip-clear"
          onClick={() => setLabelFilter(null)}
          title="Clear label filter"
        >
          <X /> clear
        </button>
      )}
      {labelCounts.map(([l, n]) => (
        <button
          key={l}
          className={"issue-label-chip" + (labelFilter === l ? " issue-label-chip-on" : "")}
          aria-pressed={labelFilter === l}
          onClick={() => setLabelFilter(labelFilter === l ? null : l)}
        >
          {l} <span className="issue-label-chip-n">{n}</span>
        </button>
      ))}
    </div>
  );

  // One issue → its seed row + expand chevron + (when open) inline detail. Reused by
  // both the flat and grouped renderers; keyed by issue number so it survives reorder.
  function renderIssueEntry(it: IssueItem, i: number) {
    const open = expandedIssue === it.number;
    return (
      <Fragment key={it.number}>
        <div className="issue-row">
          {issueRow(it, i)}
          <button
            className="issue-expand"
            aria-expanded={open}
            aria-label={open ? "Hide issue detail" : "Read body & comments"}
            title={open ? "Hide detail" : "Read body & comments"}
            onClick={() => setExpandedIssue(open ? null : it.number)}
          >
            <Chevron open={open} />
          </button>
        </div>
        {open && projectId && <IssueDetail projectId={projectId} number={it.number} />}
      </Fragment>
    );
  }

  const issuesPanel = (
    <div className="backlog-detail backlog-issues-detail">
      <div className="backlog-detail-head backlog-cat-issues">
        <span className="backlog-detail-name">GitHub Issues</span>
        {asOf && <span className="backlog-asof dim">as of {asOf}</span>}
        <button
          className="backlog-refresh"
          onClick={refreshIssues}
          disabled={issuesRefreshing}
          title="Refresh issues"
          aria-label="Refresh issues"
        >
          <span className={issuesRefreshing ? "backlog-refresh-spin" : ""}><Refresh /></span>
        </button>
      </div>
      {issues?.available && issueList.length > 0 && (
        <>
          {issueFilterBar}
          {issueControls}
          {labelChipsBar}
          {issues.truncated && (
            <div className="side-backlog-note dim">
              Showing first {issueList.length} — narrow the filter or raise{" "}
              <code>[backlog] issue_limit</code> to see more.
            </div>
          )}
        </>
      )}
      <div className="backlog-items">
        {!issues ? (
          <div className="side-backlog-empty dim">Loading issues…</div>
        ) : !issues.available && issues.reason !== "no-remote" ? (
          // Covers both "no-gh" (binary missing) and every other gh failure this
          // early (typically "installed but not logged in") — `gh auth login` is
          // the fix either way, so it's the one action worth surfacing here.
          <div className="side-backlog-empty dim">
            {issues.reason === "no-gh"
              ? "Install the GitHub CLI, then run"
              : "The GitHub CLI couldn't fetch issues — try"}
            <div className="backlog-empty-actions">
              <button className="backlog-new-btn" onClick={copyGhLogin}>
                {copiedGhLogin ? "Copied" : "Copy: gh auth login"}
              </button>
            </div>
          </div>
        ) : !issues.available ? (
          <div className="side-backlog-empty dim">{issuesEmptyMsg(issues.reason)}</div>
        ) : issueList.length === 0 ? (
          <div className="side-backlog-empty dim">
            {mineOnly ? "No issues assigned to you." : "No issues found for this project."}
          </div>
        ) : issuesFilteredOut ? (
          <div className="side-backlog-empty dim">No issues match these filters.</div>
        ) : shownIssues.length === 0 ? (
          <div className="side-backlog-empty dim">
            {issueFilter === "open" ? "No open issues." : "No closed issues."}
          </div>
        ) : groupByLabel ? (
          groupedIssues.map(([label, group]) => (
            <Fragment key={label || " unlabeled"}>
              <div className="side-backlog-group">
                {label || "No label"}
                <span className="issue-group-n">{group.length}</span>
              </div>
              {group.map((it, i) => renderIssueEntry(it, i))}
            </Fragment>
          ))
        ) : (
          shownIssues.map((it, i) => renderIssueEntry(it, i))
        )}
      </div>
    </div>
  );

  const list = (
    <div className="backlog-rail">
      <div className="backlog-rail-top">
        <div className="backlog-search">
          <SearchIcon />
          <input
            className="backlog-search-input"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search backlog files…"
            spellCheck={false}
            aria-label="Search backlog files by name"
          />
          {query && (
            <button
              className="backlog-search-clear"
              onClick={() => setQuery("")}
              title="Clear search"
              aria-label="Clear search"
            >
              <X />
            </button>
          )}
        </div>
        {onStartMany && (
          <button
            className={"backlog-new-btn backlog-new-btn-icon" + (selectMode ? " backlog-select-on" : "")}
            onClick={() => {
              setSelectMode((v) => !v);
              setSelected(new Set());
            }}
            title={selectMode ? "Cancel selecting" : "Select multiple tasks to start at once"}
            aria-label={selectMode ? "Cancel selecting" : "Select tasks to start"}
            aria-pressed={selectMode}
          >
            {selectMode ? "✕" : "☑"}
          </button>
        )}
        <button
          className="backlog-new-btn backlog-new-btn-icon"
          onClick={startNewFile}
          title="Create a new backlog file"
          aria-label="Create a new backlog file"
        >
          ＋
        </button>
      </div>
      {selectMode &&
        (() => {
          // A selected seed_key can go stale between picking it and clicking
          // Start — the item was ticked, or a workspace picked it up in the
          // meantime — itemsBySeedKey already drops those; surface the gap
          // instead of silently starting fewer than the count shown.
          const live = [...selected].filter((k) => itemsBySeedKey.has(k)).length;
          const stale = selected.size - live;
          return (
            <div className="backlog-select-bar">
              <span className="dim">
                {selected.size} selected
                {stale > 0 && ` (${stale} no longer startable)`}
              </span>
              <button className="backlog-new-btn" onClick={startSelected} disabled={live === 0}>
                Start {live || ""}
              </button>
            </div>
          );
        })()}

      <div className="backlog-files">
        {CATEGORY_ORDER.map((cat) => {
          const group = filtered.filter((f) => categoryOf(f) === cat);
          if (group.length === 0) return null;
          return (
            <div className="backlog-cat" key={cat}>
              <div className={"backlog-cat-head backlog-cat-" + cat}>
                <span className="backlog-cat-dot" aria-hidden />
                <span className="backlog-cat-label">{CATEGORY[cat]}</span>
                <span className="backlog-cat-n">{group.length}</span>
              </div>
              {group.map((f) => {
                const total = f.items.length;
                return (
                  <button
                    key={f.path}
                    className={
                      "backlog-file backlog-file-" +
                      cat +
                      (f.path === active?.path ? " backlog-file-on" : "")
                    }
                    onClick={() => setActivePath(f.path)}
                    title={f.path}
                  >
                    <span className="backlog-file-dot" aria-hidden />
                    <span className="backlog-file-name">{f.label}</span>
                    {total > 0 && (
                      <span className="backlog-file-count">
                        {f.done}/{total}
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          );
        })}
        {files.length > 0 && filtered.length === 0 && (
          <div className="backlog-noresult dim">No backlog files match “{query}”.</div>
        )}
      </div>
    </div>
  );

  const detail = (
    <div className="backlog-detail">
      {creating ? (
        <>
          <div className="backlog-detail-head backlog-cat-todo">
            <span className="backlog-detail-name">Paste a plan</span>
          </div>
          {editorBody(newPath, true, "Create")}
        </>
      ) : !projectId ? (
        <div className="side-backlog-empty dim">Add a project to see its backlog.</div>
      ) : error ? (
        <div className="side-backlog-empty dim">Couldn't read backlog files · {error}</div>
      ) : todo && files.length === 0 ? (
        <div className="side-backlog-empty dim">
          No backlog files in {projectName ?? "this repo"} yet.
          <div className="backlog-empty-actions">
            <button className="backlog-new-btn" onClick={createDefaultTodo} disabled={saving}>
              ＋ Create backlog/TODO.md
            </button>
            <button className="backlog-new-btn" onClick={startNewFile}>
              Paste a plan
            </button>
          </div>
        </div>
      ) : active ? (
        <>
          <div className={"backlog-detail-head backlog-cat-" + categoryOf(active)}>
            <span className="backlog-detail-name" title={active.path}>
              {active.label}
            </span>
            {items.length > 0 && (
              <span className="backlog-detail-count">
                {active.done}/{items.length} done
              </span>
            )}
            {!editing && (
              <button className="backlog-edit-btn" onClick={startEdit} title="Edit this file">
                Edit
              </button>
            )}
          </div>
          {editing ? (
            editorBody(active.path, false, "Save")
          ) : (
            <>
              {items.length > 0 && (
                <div className="backlog-progress" aria-hidden>
                  <div
                    className={"backlog-progress-fill backlog-cat-" + categoryOf(active)}
                    style={{
                      width: `${Math.round((active.done / items.length) * 100)}%`,
                    }}
                  />
                </div>
              )}
              <div className="backlog-items">
                {blocks.length === 0 ? (
                  <div className="side-backlog-empty dim">
                    <code>{active.label}</code> is empty. Click <strong>Edit</strong> to add
                    tasks or notes.
                  </div>
                ) : (
                  // Notes and `- [ ]` items rendered interleaved in document order:
                  // note blocks are read-only markdown context; item blocks are the
                  // clickable seed-to-workspace rows (unchanged mechanism).
                  blocks.map((b, i) =>
                    b.kind === "note" ? (
                      <div className="backlog-note" key={i}>
                        <FileMarkdown text={b.md} />
                      </div>
                    ) : (
                      renderTodoItem(b, i)
                    ),
                  )
                )}
              </div>
            </>
          )}
        </>
      ) : (
        <div className="side-backlog-empty dim">Select a backlog file to see it.</div>
      )}
    </div>
  );

  return (
    <>
      {full && <div className="card-backdrop" onClick={() => setFull(false)} />}
      <div
        className={
          "side-backlog" +
          (variant === "panel" ? " backlog-panel" : "") +
          (full ? " card--full" : "")
        }
      >
      <div className="side-backlog-head">
        <span>backlog</span>
        <span className="side-backlog-head-right">
          {tab === "todo" && totalItems > 0 && (
            <span className="side-backlog-count dim">
              {totalDone}/{totalItems} done · {files.length} file{files.length === 1 ? "" : "s"}
            </span>
          )}
          <button
            className="ghost btn-icon btn-full"
            onClick={() => setFull((f) => !f)}
            title={full ? "exit fullscreen (Esc)" : "fullscreen backlog"}
            aria-label={full ? "exit fullscreen" : "fullscreen backlog"}
          >
            {full ? <Minimize /> : <Maximize />}
          </button>
        </span>
      </div>
      <div className="backlog-tabs" role="tablist" aria-label="Backlog source">
        <button
          role="tab"
          aria-selected={tab === "todo"}
          className={"backlog-tab" + (tab === "todo" ? " backlog-tab-on" : "")}
          onClick={() => setTab("todo")}
        >
          Todo files
          {files.length > 0 && <span className="backlog-tab-n">{files.length}</span>}
        </button>
        <button
          role="tab"
          aria-selected={tab === "issues"}
          className={"backlog-tab backlog-tab-issues" + (tab === "issues" ? " backlog-tab-on" : "")}
          onClick={() => setTab("issues")}
        >
          GitHub Issues
          {/* Only meaningful while the Open tab is the one actually fetched — a
              stale count from a different state/assignee scope would mislead. */}
          {issues?.available && issueFilter === "open" && issueList.length > 0 && (
            <span className="backlog-tab-n">{issueList.length}</span>
          )}
        </button>
      </div>
      {tab === "todo" ? (
        <div className="backlog-split">
          {list}
          {detail}
        </div>
      ) : (
        <div className="backlog-split backlog-split-issues">{issuesPanel}</div>
      )}
      </div>
    </>
  );
}
