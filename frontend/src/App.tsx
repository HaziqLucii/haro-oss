import { Fragment, lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api, openGlobalSocket, openWorkspaceSocket } from "./api";
import { AgentStream, StreamMeta } from "./components/AgentStream";
import { Dashboard } from "./components/Dashboard";
import { ProjectDashboard } from "./components/ProjectDashboard";
import { Backlog } from "./components/Backlog";
import { GatePanel } from "./components/GatePanel";
import { LookAtChip } from "./components/LookAtChip";
import { AgentManagerCard } from "./components/AgentManagerCard";
import { Sidebar } from "./components/Sidebar";
import { type TerminalHandle } from "./components/Terminal";
import { TaskComposer, DICTATION_HINT } from "./components/TaskComposer";
import { attachmentStat, composeWithAttachments, fileToBase64, type Attachment } from "./attachments";
import { boot, withViewTransition } from "./motion";
import { FileIcon } from "./components/FileIcon";
import { ContextMeter } from "./components/ContextMeter";
import { AddProjectModal } from "./components/AddProjectModal";
import { InitRepoModal } from "./components/InitRepoModal";
import { StackProposalModal } from "./components/StackProposalModal";
import { NewWorkspaceModal } from "./components/NewWorkspaceModal";
import { RenameWorkspaceModal } from "./components/RenameWorkspaceModal";
import { UpdateBanner } from "./components/UpdateBanner";
import { HotkeysModal } from "./components/HotkeysModal";
import { type ProjectSettingsTab } from "./components/ProjectSettingsModal";
import { runArgs, stripSteps } from "./roles";
import { Command as CommandKey, Control, ExternalLink, Gear, HaroMark, Keyboard, Maximize, Mic, Minimize, Paperclip, Play, Plus, Refresh, Return, Square, X } from "./components/icons";
import { BranchBadge } from "./components/BranchBadge";
import { loadPrefs, playNotify, savePrefs, showDesktop, type NotifyPrefs } from "./notify";
import { ToastHost } from "./components/ToastHost";
import {
  loadToastPrefs,
  saveToastPrefs,
  type Toast,
  type ToastKind,
  type ToastPrefs,
} from "./toast";
import { CommandPalette, type Command } from "./components/CommandPalette";
import { ArchiveQueuePanel } from "./components/ArchiveQueuePanel";
import { archiveFeedEffects, mergeArchiveRun } from "./archiveQueue";
import { bulkArchiveActions } from "./archiveActions";
import { raceButtonState, raceHeadline } from "./races";
import { DEFAULT_SESSION, mergeSession, mergeSessions, nextSessionId, sessionLabel } from "./sessions";
import type {
  AgentEvent,
  ArchiveQueueRun,
  Cell,
  CoverageResponse,
  DiffResponse,
  FlakyResponse,
  BlameResponse,
  ImpactResponse,
  Project,
  RacePreflight,
  RaceRun,
  ReviewComment,
  ScriptsConfig,
  SetupState,
  StackDetection,
  TamperFinding,
  MutationResponse,
  MutationSurvivor,
  TestRun,
  TrustFix,
  TrustReport,
  Workspace,
  WSMessage,
  UncheckedRow,
  VerifiedHunksResponse,
  ReceiptResponse,
  GateConfig,
  RolesConfig,
  ReviewMustFix,
} from "./types";
import {
  casesToCells, failureReviewItems, mutationReviewItems, qualityReviewItems, reviewMustFixItems, tamperReviewItems,
  watchSummary, watchVerdict, type QualityFindingRow,
} from "./gate";
import { lookAt, lookAtReviewItems, type LookAtItem } from "./verdict";
import { residueReviewItems } from "./verifiedHunks";
import { flowSteps, connectorDone, stepTarget, focusesFailures, type GateFocus } from "./flow";
import { composerButtonLabel, shouldClientQueue } from "./composerButton";

// Lazy-loaded: each is a big/rare-per-render-cycle surface (a terminal emulator
// with xterm, a git/PR panel, review comments, settings modals) that doesn't
// need to sit in the root chunk every workspace pays for on first paint — the
// same pattern components/CodePanel.tsx already uses for Monaco. None of these
// have a default export, so unwrap the named one manually.
//
// Backlog is NOT here even though App.tsx also renders it as a rare overlay
// panel: ProjectDashboard.tsx renders it unconditionally as the project-home
// view's always-visible right column, and ProjectDashboard itself is a static,
// first-paint import — so Backlog is already forced into the root chunk from
// that path, and a dynamic import here would just be a no-op wrapper (confirmed
// by Rollup's own `[INEFFECTIVE_DYNAMIC_IMPORT]` warning when this was tried).
const Terminal = lazy(() => import("./components/Terminal").then((m) => ({ default: m.Terminal })));
const CodePanel = lazy(() => import("./components/CodePanel").then((m) => ({ default: m.CodePanel })));
const GitPanel = lazy(() => import("./components/GitPanel").then((m) => ({ default: m.GitPanel })));
const ReviewPanel = lazy(() => import("./components/ReviewPanel").then((m) => ({ default: m.ReviewPanel })));
const SettingsModal = lazy(() => import("./components/SettingsModal").then((m) => ({ default: m.SettingsModal })));
const ProjectSettingsModal = lazy(() =>
  import("./components/ProjectSettingsModal").then((m) => ({ default: m.ProjectSettingsModal }))
);
import { Chevron } from "./components/Chevron";
import { DEFAULT_THEME, type ThemeId, type Mode } from "./themes";

// Stable empty transcript for a session with no events yet — a module const so the
// `events` derivation keeps referential identity (avoids re-render churn / effect refires).
const EMPTY_EVENTS: AgentEvent[] = [];

// The terminal card's "claude" menu. Slash commands like /mcp and /usage only
// exist inside claude's interactive REPL — the agent stream runs claude headless
// (`-p --output-format stream-json`), so they can't live in the composer. Instead
// we drop the right shell command on the workspace shell's prompt (no auto-Enter;
// the dev reviews and hits Enter). `repl` items open the interactive session where
// the dev then types the slash command; the others are verified CLI subcommands
// that print and exit (verified against claude v2.x — there is NO `claude config`).
const CLAUDE_CMDS: { label: string; hint: string; insert: string; repl?: boolean }[] = [
  { label: "/mcp", hint: "list MCP servers", insert: "claude mcp list" },
  { label: "/doctor", hint: "installation health", insert: "claude doctor" },
  { label: "update", hint: "check for updates", insert: "claude update" },
  { label: "Claude session", hint: "/usage · /login · /config · …", insert: "claude", repl: true },
];

// Encode the composer's (backend, model) pair as one <select> value, so backend +
// model live in a single grouped dropdown ("cc:sonnet" | "local:qwen3.5:9b"). When the
// local server has no usable list, the value is a stable sentinel and the tag is typed
// in the adjacent text field instead.
function comboValue(backend: string, model: string, localModel: string, hasLocalList: boolean): string {
  if (backend === "local") return hasLocalList ? `local:${localModel}` : "local:__manual__";
  return `cc:${model}`;
}

// Coding fonts offered by the picker — all bundled locally in public/fonts.
// The first entry is the default (JetBrains Mono, the current editor face).
const MONO_FONTS = [
  { family: "JetBrains Mono", label: "JetBrains Mono" },
  { family: "Fira Code", label: "Fira Code" },
  { family: "IBM Plex Mono", label: "IBM Plex Mono" },
  { family: "Ubuntu Mono", label: "Ubuntu Mono" },
  { family: "Space Mono", label: "Space Mono" },
];

export function App() {
  // navigation (multi-project)
  const [projects, setProjects] = useState<Project[]>([]);
  const [wsByProject, setWsByProject] = useState<Record<string, Workspace[]>>({});
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const [workspace, setWorkspace] = useState<Workspace | null>(null); // selected
  // The project whose dashboard is showing when no workspace is selected. A
  // workspace always takes precedence (it renders the bento); this drives the
  // pre-workspace "project home" view (triage cards + backlog). Null → the
  // cross-project global dashboard.
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);
  // Browsable repo base (https://host/owner/repo) for the selected workspace's
  // project — lets the composer deep-link typed `PR #N` references. Null when
  // local-only / no recognizable remote.
  const [prBaseUrl, setPrBaseUrl] = useState<string | null>(null);

  // selected-workspace view state
  // Multi-session agent streams (like the shell-tab strip): `sessions` is the ordered
  // switcher tab ids (client-owned, hydrated from GET /sessions on open), `sessionTab`
  // the active tab, `sessionEvents` each session's transcript keyed by id so concurrent
  // streams route independently (the `agent` WS envelope carries `session_id`).
  const [sessions, setSessions] = useState<string[]>([DEFAULT_SESSION]);
  const [sessionTab, setSessionTab] = useState<string>(DEFAULT_SESSION);
  const sessionTabRef = useRef(sessionTab); // latest active tab for stable-closure callbacks
  sessionTabRef.current = sessionTab;
  const [sessionEvents, setSessionEvents] = useState<Record<string, AgentEvent[]>>({});
  // `events` = the ACTIVE session's transcript (what the stream renders). `setEvents`
  // targets the active session via the ref, so every existing call-site keeps working
  // unchanged; the WS handler + selectWorkspace write specific sessions directly instead.
  const events = sessionEvents[sessionTab] ?? EMPTY_EVENTS;
  const setEvents = useCallback(
    (updater: AgentEvent[] | ((prev: AgentEvent[]) => AgentEvent[])) => {
      const sid = sessionTabRef.current;
      setSessionEvents((prev) => {
        const cur = prev[sid] ?? [];
        const next = typeof updater === "function" ? updater(cur) : updater;
        return { ...prev, [sid]: next };
      });
    },
    [],
  );
  const [diff, setDiff] = useState<DiffResponse | null>(null);
  // Verified Hunks (backlog/verified-hunks.md): the last green gate's per-line proof for the
  // ④ ship diff. Null ⇒ the diff renders exactly as it always did.
  const [verified, setVerified] = useState<VerifiedHunksResponse | null>(null);
  // Gate Receipt (usp-critique-plan.md idea 1): the exportable evidence packet for the
  // ④ ship step. Null ⇒ ReceiptPanel renders nothing (no gate run to report on yet).
  const [receipt, setReceipt] = useState<ReceiptResponse | null>(null);
  const [test, setTest] = useState<TestRun | null>(null);
  const [cells, setCells] = useState<Cell[]>([]);
  const [history, setHistory] = useState<TestRun[]>([]);
  const [trust, setTrust] = useState<TrustReport | null>(null); // autonomy-ladder checklist
  const [impact, setImpact] = useState<ImpactResponse | null>(null);
  const [blame, setBlame] = useState<BlameResponse | null>(null);
  const [coverage, setCoverage] = useState<CoverageResponse | null>(null);
  const [flaky, setFlaky] = useState<FlakyResponse | null>(null);
  // Mutation scoring, lifted here (notes/verify-redesign-plan.md Phase 3) from
  // GatePanel's own local state so its survivors can feed the rail's look-at count,
  // not just the ③ page's — the same reason coverage/flaky already live at this level.
  const [mutation, setMutation] = useState<MutationResponse | null>(null);
  const [mutationError, setMutationError] = useState<string | null>(null);
  const [analyzing, setAnalyzing] = useState<string | null>(null);
  const [comments, setComments] = useState<ReviewComment[]>([]);
  const [wsStatus, setWsStatus] = useState<string>("idle");
  // Latest status for stable-closure callbacks (sendTask is memoized with []), so a
  // failed start can roll the optimistic flip back to whatever it really was.
  const wsStatusRef = useRef(wsStatus);
  wsStatusRef.current = wsStatus;
  // Same trick for the selected workspace: the global-feed handler is memoized, and a
  // bulk archive can tear down the very workspace you're looking at.
  const workspaceRef = useRef<Workspace | null>(workspace);
  workspaceRef.current = workspace;
  const [setup, setSetup] = useState<SetupState | null>(null); // "deps" gate chip
  const [scripts, setScripts] = useState<ScriptsConfig | null>(null); // effective (inherited) [scripts] config, read-only
  // Live per-run state, keyed by run id — a workspace can run several named
  // commands (web/worker/test) at once. The app strip tracks the default run.
  const [runStates, setRunStates] = useState<
    Record<string, { running: boolean; url: string | null; error: string | null }>
  >({});
  const [runMenuOpen, setRunMenuOpen] = useState(false);
  const [runLog, setRunLog] = useState<string[]>([]); // dev-server output (Dev log tab)
  // The named run commands + which one the app strip binds to (its default). The
  // strip's run/stop/open + ⌘R + the command palette all track the default run; the Run
  // menu drives every run independently.
  const runList = scripts?.runs ?? [];
  const defaultRunId = runList.find((r) => r.default)?.id ?? runList[0]?.id ?? "app";
  const defaultRun = runStates[defaultRunId];
  const appRunning = defaultRun?.running ?? false;
  const appUrl = defaultRun?.url ?? null;
  const runError = defaultRun?.error ?? null;
  const anyRunning = Object.values(runStates).some((s) => s.running);
  // Store the scripts config and seed live run state from the server, so a run
  // still going after a reload shows correctly in the menu (preserving any
  // locally-known crash error).
  const applyScripts = (cfg: ScriptsConfig) => {
    setScripts(cfg);
    setRunStates((prev) => {
      const next: Record<string, { running: boolean; url: string | null; error: string | null }> = {};
      for (const r of cfg.runs ?? []) {
        next[r.id] = { running: r.running, url: r.url, error: prev[r.id]?.error ?? null };
      }
      return next;
    });
  };
  // The terminal card hosts several concurrent shells plus the dev log. `shells`
  // is the ordered list of shell ids; `termTab` is the active pane — either a
  // shell id or "log". Ids are monotonic (never reused) so a respawned shell
  // gets a fresh React key → the Terminal remounts onto a brand-new PTY.
  const shellSeq = useRef(1);
  const newShellId = () => `shell-${shellSeq.current++}`;
  const [shells, setShells] = useState<string[]>(["shell-0"]);
  const [termTab, setTermTab] = useState<string>("shell-0");
  // The one shell allowed to grab focus when its PTY connects (the "+"/restart
  // flows). null on a fresh workspace so the composer — not the auto-connecting
  // terminal — wins focus on open.
  const [focusShellOnOpen, setFocusShellOnOpen] = useState<string | null>(null);
  const shellsRef = useRef(shells); // latest shells for stale-closure-free key handlers
  shellsRef.current = shells;
  const termTabRef = useRef(termTab);
  termTabRef.current = termTab;
  const devLogRef = useRef<HTMLDivElement>(null);
  // One imperative handle per live shell — the "claude" menu / focus hotkey drive
  // whichever shell is active.
  const termHandles = useRef<Map<string, TerminalHandle>>(new Map());
  const [claudeMenuOpen, setClaudeMenuOpen] = useState(false);
  const claudeMenuRef = useRef<HTMLSpanElement>(null);
  const [mainView, setMainViewRaw] = useState<"agent" | "code" | "git" | "gate">("agent");
  // A step swap crossfades the whole stage via a View Transition instead of a jump
  // cut (notes/kuro-motion-plan.md). No-op on a same-view call so a repeat click
  // never restarts the fade. Guarded on a ref, not the closed-over `mainView`: some
  // callers (e.g. the ⌘I effect below, deps [workspace?.id]) hold a stale render's
  // setMainView across multiple mainView changes, and comparing against a stale
  // value silently ate the jump the one time it actually needed to switch views.
  const mainViewRef = useRef(mainView);
  mainViewRef.current = mainView;
  const setMainView = (v: "agent" | "code" | "git" | "gate") =>
    v === mainViewRef.current ? undefined : withViewTransition(() => setMainViewRaw(v));
  // Where the ③ verify page should snap the eye to, and a nonce to re-trigger the
  // same target on a repeat click (notes/verify-redesign-plan.md). Replaces the old
  // scalar nonce, which could only say "something happened", never which zone.
  const [gateFocus, setGateFocus] = useState<GateFocus>({ target: "blockers", nonce: 0 });
  // On a phone the desktop bento can't show everything at once, so a bottom tab bar
  // switches which surface fills the screen: the flow column (agent/code/gate/ship)
  // or the side panels (preview / terminal). No effect on desktop — the grid shows
  // both columns and .mobile-nav is display:none.
  const [mobilePane, setMobilePane] = useState<"flow" | "terminal">("flow");
  // A file to open in the code step, requested from elsewhere (an @mention click in
  // the agent stream). `nonce` bumps on each request so the same path re-fires.
  const [codeOpen, setCodeOpen] = useState<{ path: string; line?: number; nonce: number } | null>(
    null
  );
  const [codeFull, setCodeFull] = useState(false); // editor fullscreen "focus mode" overlay
  const [termFull, setTermFull] = useState(false); // terminal/shell fullscreen overlay
  const [streamFull, setStreamFull] = useState(false); // agent-stream fullscreen overlay
  // Live Gate (backlog/live-gate.md) — the rail's advisory verdict. Kept in state
  // SEPARATE from `cells`/`test` (the authoritative gate's) on purpose: they arrive on
  // different channels and must never overwrite each other, or a watch run would clobber
  // the real verdict mid-review.
  // Project gate config, for the rail's code-to-check pane (its `code_to_check` mode
  // decides between the off empty-state and the row list).
  const [gateCfg, setGateCfg] = useState<GateConfig | null>(null);
  const [watchEnabled, setWatchEnabled] = useState(false);
  const [watchCells, setWatchCells] = useState<Cell[]>([]);
  const [watchRun, setWatchRun] = useState<TestRun | null>(null);
  const [codeNonce, setCodeNonce] = useState(0); // bump (fs watcher) to reload the code file tree
  // Per-project backlog refetch signals — bumped when the fs watcher reports a
  // committed todo-*.md change for that project (keyed by id so an unrelated
  // project's change doesn't refetch the one you're viewing).
  const [backlogNonces, setBacklogNonces] = useState<Record<string, number>>({});
  // Winner-only fan-out (backlog/winner-fanout.md): races per project, plus the §0
  // pre-flight for the selected project. The pre-flight is fetched, not guessed, so
  // the composer's race button can be disabled *with a reason* before a dollar is
  // spent — an uncapped race refused after three worktrees exist already cost money.
  const [races, setRaces] = useState<Record<string, RaceRun[]>>({});
  const [racePreflight, setRacePreflight] = useState<RacePreflight | null>(null);
  const [racing, setRacing] = useState(false);
  const [purgingRace, setPurgingRace] = useState<string | null>(null);
  // Bulk archive (backlog/bulk-archive.md): ONE piece of state for both halves — the
  // dry-run plan the confirm dialog renders and the live queue it becomes. They are
  // the same model, so the dialog can't promise something the queue doesn't do.
  const [archiveRun, setArchiveRun] = useState<ArchiveQueueRun | null>(null);
  const archiveRunRef = useRef<ArchiveQueueRun | null>(archiveRun);
  archiveRunRef.current = archiveRun;
  const [archiveBusy, setArchiveBusy] = useState(false);
  //: What the user picked, kept so "include the risky ones" can re-plan the same set.
  const archivePickRef = useRef<{ projectId: string; ids: string[] } | null>(null);
  //: How many items each run had finished last time we resynced — a queue removes
  //: workspaces behind the UI's back, so the sidebar has to follow it item by item.
  const archiveSeenRef = useRef<{ id: string; done: number }>({ id: "", done: 0 });
  const [cmdkOpen, setCmdkOpen] = useState(false);
  const [pickerOpen, setPickerOpen] = useState(false); // "add project" folder browser
  const [initFor, setInitFor] = useState<string | null>(null); // non-git folder pending `git init`
  const [initBusy, setInitBusy] = useState(false);
  // Propose-and-confirm: after a project is added, sniff its stack and offer the
  // detected gate preset for inspection/confirm before anything is written.
  const [stackFor, setStackFor] = useState<
    { projectId: string; projectName: string; detection: StackDetection } | null
  >(null);
  const [newWsFor, setNewWsFor] = useState<string | null>(null); // "new workspace" modal (project id)
  // When a backlog todo is clicked, prefill the modal name + seed the agent task.
  const [newWsSeed, setNewWsSeed] = useState<
    { name: string; task: string; seedKey?: string } | null
  >(null);
  // A workspace whose composer was just seeded from a backlog todo and hasn't been
  // run yet — drives a faint focus glow on the task card so the dev notices the
  // prompt is prefilled (and can tweak it) before hitting "run agent". Cleared on
  // the first submit.
  const [seededWsId, setSeededWsId] = useState<string | null>(null);
  // A one-shot version of the seeded glow, fired when ⌘I focuses the composer, so
  // the same faint green-gate border briefly confirms where the cursor landed.
  const [composerFlash, setComposerFlash] = useState(false);
  const composerFlashTimer = useRef<number>();
  // Same one-shot glow for the terminal card, fired when Ctrl+` jumps to the shell.
  const [termFlash, setTermFlash] = useState(false);
  const termFlashTimer = useRef<number>();

  // All transient success/error feedback now flows through toasts (bottom-right
  // by default, position + dwell time configurable in Settings › Notifications).
  // `setError`/`setNotice` are kept as thin shims over `pushToast` so the many
  // existing call sites read unchanged; a null argument (old "clear the banner"
  // calls) is simply a no-op since toasts self-dismiss.
  const [toasts, setToasts] = useState<Toast[]>([]);
  const toastSeq = useRef(0);
  const pushToast = useCallback((kind: ToastKind, message: string | null) => {
    if (!message) return;
    const id = (toastSeq.current += 1);
    setToasts((t) => [...t, { id, kind, message }]);
  }, []);
  const dismissToast = useCallback(
    (id: number) => setToasts((t) => t.filter((x) => x.id !== id)),
    []
  );
  const setError = useCallback((m: string | null) => pushToast("error", m), [pushToast]);
  const setNotice = useCallback((m: string | null) => pushToast("success", m), [pushToast]);
  const [task, setTask] = useState("");
  // Composer attachments per workspace: large pasted blocks promoted to .context/
  // files (paste-to-file), folded into the task as @mentions on submit.
  const [attachments, setAttachments] = useState<Record<string, Attachment[]>>({});
  // Per-workspace composer drafts: the task text is scoped to a workspace, not
  // shared across them. Kept in a ref (no re-render needed).
  const draftsRef = useRef<Record<string, string>>({});
  // Which workspaces hold an unsent composer draft (non-empty text, not yet run).
  // A client-derived "draft" overlay for the sidebar — deliberately NOT a backend
  // WorkspaceStatus: there's no ground truth for "typed but not submitted" (it lives
  // only in the browser), so a persisted status would be clobbered by the reconciler.
  const [draftIds, setDraftIds] = useState<Set<string>>(() => new Set());
  // Mirror the live composer into the current workspace's draft on every change,
  // so it survives navigation to ANY view (project home / dashboard / another
  // workspace), and a submit or manual clear (task → "") persists. Without this,
  // the draft only updated when switching workspaces, so a seeded prompt that was
  // run or deleted would resurrect itself when you re-selected the workspace.
  useEffect(() => {
    if (!workspace) return;
    draftsRef.current[workspace.id] = task;
    setDraftIds((prev) => {
      const has = task.trim().length > 0;
      if (has === prev.has(workspace.id)) return prev; // no change → keep ref stable
      const next = new Set(prev);
      if (has) next.add(workspace.id);
      else next.delete(workspace.id);
      return next;
    });
  }, [task, workspace]);
  // Hidden <input type=file> behind the composer paperclip button.
  const fileInputRef = useRef<HTMLInputElement>(null);
  // Per-workspace follow-up queue: tasks submitted while the agent is busy wait
  // here and fire (oldest first) once the workspace frees up. Keyed by workspace
  // id so queues don't bleed across workspaces, and rendered dimmed in the stream.
  // Persisted to localStorage so a page refresh doesn't drop pending tasks — this
  // is per-session UI state, so the frontend is its natural home (no backend/broker).
  const [queues, setQueues] = useState<Record<string, string[]>>(() => {
    try {
      const raw = localStorage.getItem("haro-queues");
      return raw ? (JSON.parse(raw) as Record<string, string[]>) : {};
    } catch {
      return {};
    }
  });
  useEffect(() => {
    localStorage.setItem("haro-queues", JSON.stringify(queues));
  }, [queues]);
  // Claude Code run options, surfaced below the composer. "default" means we omit
  // the CLI flag entirely and let Claude Code use its own configured default.
  // Persisted so the choice sticks across sessions; mirrored to a ref so the
  // memoized sendTask reads the latest values without being recreated.
  const [model, setModel] = useState<string>(() => localStorage.getItem("haro-model") || "default");
  const [effort, setEffort] = useState<string>(() => localStorage.getItem("haro-effort") || "default");
  // Per-run agent backend: "claude-code" (model+effort) or "local" (Ollama/llama.cpp,
  // model tag only). Persisted like model/effort; the project's `[agent] adapter` is the
  // default but this per-run pick wins.
  const [backend, setBackend] = useState<string>(() => localStorage.getItem("haro-backend") || "claude-code");
  const [localModel, setLocalModel] = useState<string>(() => localStorage.getItem("haro-local-model") || "");
  // Plan Mode toggle ("Plan first"): the run proposes a plan and edits nothing until
  // the dev approves it. Per-run + persisted like the model/effort pickers; Claude
  // Code only (a local model has no plan mode). See the approval bar below the stream.
  const [planFirst, setPlanFirst] = useState<boolean>(() => localStorage.getItem("haro-plan") === "1");
  // Fast Mode toggle ("Fast"): "speed over depth" for narrow edits / quick follow-ups.
  // Per-run + persisted like the pickers; Claude Code only. Mutually exclusive with
  // "Plan first" in the composer — fast ≠ careful planning (see the toggle handlers).
  const [fastMode, setFastMode] = useState<boolean>(() => localStorage.getItem("haro-fast") === "1");
  // Live model list from the current project's local server (populated when backend=local).
  // `reachable:false` ⇒ server down → the composer falls back to a free-text tag field.
  const [localModels, setLocalModels] = useState<{ reachable: boolean; models: string[] }>({
    reachable: true,
    models: [],
  });
  // Transient cumulative-cost warning banner (fires when a workspace crosses its
  // configured `cost_warn_usd`). Dismissable; auto-clears on the next crossing.
  const [costWarn, setCostWarn] = useState<{ name: string; total: number; threshold: number } | null>(null);
  // `[roles] enabled` project config (notes/workflow-roles-plan.md): when set, the
  // composer shows a role strip (plan · build · review, next step highlighted)
  // instead of the model/effort pickers — the trap those pickers set up (approve a
  // plan, forget to flip two dropdowns, build at the plan's pricier model/effort).
  // Declared before optsRef below, which reads it.
  const [roles, setRoles] = useState<RolesConfig | null>(null);
  const optsRef = useRef({ model, effort, backend, localModel, planFirst, fastMode, rolesEnabled: false });
  useEffect(() => {
    optsRef.current = {
      model, effort, backend, localModel, planFirst, fastMode,
      // Roles state loads async (GET /projects/{id}/roles); until it lands this is
      // false, same as roles being off — never a false positive that would suppress
      // the real model/effort while roles aren't actually confirmed on.
      rolesEnabled: !!roles?.enabled,
    };
    localStorage.setItem("haro-model", model);
    localStorage.setItem("haro-effort", effort);
    localStorage.setItem("haro-backend", backend);
    localStorage.setItem("haro-local-model", localModel);
    localStorage.setItem("haro-plan", planFirst ? "1" : "0");
    localStorage.setItem("haro-fast", fastMode ? "1" : "0");
  }, [model, effort, backend, localModel, planFirst, fastMode, roles]);
  // Seed the composer's per-run backend/model/effort from the SELECTED project's
  // configured `[agent]` default (Agent tab). Without this the pickers only ever
  // read a GLOBAL localStorage value that bleeds across projects: a stale explicit
  // pick is sent verbatim to `start_agent`, whose `req.model or project_default`
  // fallback then never consults the project default — so the configured model/effort
  // silently "reverts" to whatever was last picked anywhere. Re-seeding on project
  // switch makes the Agent tab the source of truth; a per-run change still overrides
  // until you switch projects (tracked via the ref so same-project workspace switches
  // don't clobber an override). Also invoked on Agent-tab save (see onAgentChanged).
  const seededAgentProject = useRef<string | null>(null);
  const seedAgentConfig = useCallback((pid: string) => {
    seededAgentProject.current = pid;
    api
      .getAgent(pid)
      .then((cfg) => {
        if (seededAgentProject.current !== pid) return; // a newer project won the race
        if (cfg.adapter === "local") {
          setBackend("local");
          if (cfg.local_model) setLocalModel(cfg.local_model);
        } else {
          setBackend("claude-code");
          setModel(cfg.default_model);
          setEffort(cfg.default_effort || "default");
        }
      })
      .catch(() => {});
  }, []);
  useEffect(() => {
    const pid = workspace?.project_id;
    if (!pid || seededAgentProject.current === pid) return;
    seedAgentConfig(pid);
  }, [workspace?.project_id, seedAgentConfig]);
  const seededRolesProject = useRef<string | null>(null);
  const seedRolesConfig = useCallback((pid: string) => {
    seededRolesProject.current = pid;
    api
      .getRoles(pid)
      .then((cfg) => {
        if (seededRolesProject.current !== pid) return; // a newer project won the race
        setRoles(cfg);
      })
      .catch(() => {});
  }, []);
  useEffect(() => {
    const pid = workspace?.project_id;
    if (!pid || seededRolesProject.current === pid) return;
    seedRolesConfig(pid);
  }, [workspace?.project_id, seedRolesConfig]);
  // When the Local backend is picked, pull the current project's installed models for the
  // composer dropdown (refetch on project switch). Auto-select one if the current pick isn't
  // in the list. Unreachable ⇒ the composer falls back to a free-text tag field.
  useEffect(() => {
    if (backend !== "local" || !workspace) return;
    let live = true;
    api
      .getLocalModels(workspace.project_id)
      .then((r) => {
        if (!live) return;
        setLocalModels({ reachable: r.reachable, models: r.models });
        if (r.reachable && r.models.length)
          setLocalModel((cur) => (r.models.includes(cur) ? cur : r.models[0]));
      })
      .catch(() => live && setLocalModels({ reachable: false, models: [] }));
    return () => {
      live = false;
    };
  }, [backend, workspace?.project_id]);
  // OS-level dictation (see TaskComposer) needs the composer focused; the mic
  // keycap is rendered here (beside the paperclip) and focuses it via this ref.
  const micToggleRef = useRef<(() => void) | null>(null);
  // Desktop starts with the sidebar docked; a phone starts with it closed so the
  // drawer doesn't cover the app on first paint (the ☰ toggle opens it as an overlay).
  const [sidebarOpen, setSidebarOpen] = useState(
    () => typeof window === "undefined" || window.innerWidth > 720
  );
  // haro has unified on a SINGLE trademark theme. The family is locked to the
  // trademark regardless of any stale persisted value (a user who had picked a
  // since-deleted skin before is migrated back), so the family picker is hidden
  // (see SettingsModal). setTheme is retained for that one-card picker; it can only
  // ever re-select the trademark.
  const [theme, setTheme] = useState<ThemeId>(DEFAULT_THEME);
  // Single committed dark look — light mode was retired when haro unified on one
  // trademark theme, so there's no mode toggle any more; the value is a constant the
  // palette (and the editor/terminal `${theme}-${mode}` prop) reads.
  const mode: Mode = "dark";
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    document.documentElement.dataset.mode = mode;
    localStorage.setItem("haro-theme", theme);
    localStorage.setItem("haro-mode", mode);
  }, [theme, mode]);
  // Agent-done sound settings. The ref lets the once-mounted global socket read
  // the latest prefs without re-subscribing on every change.
  const [notifPrefs, setNotifPrefs] = useState<NotifyPrefs>(() => loadPrefs());
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [settingsTab, setSettingsTab] = useState<"display" | "usage" | undefined>(undefined);
  // Open settings on its default (Display) tab; openUsage jumps straight to Usage.
  // The modal reads initialTab on mount and it's remounted each open, so the tab
  // must be reset here rather than lingering from the previous open.
  const openSettings = () => {
    setSettingsTab(undefined);
    setSettingsOpen(true);
  };
  const openUsage = () => {
    setSettingsTab("usage");
    setSettingsOpen(true);
  };
  const [hotkeysOpen, setHotkeysOpen] = useState(false);
  // The backlog overlay — reachable from inside a workspace via ⌘K, not just the
  // project home (backlog/backlog-v2.md Move 1, C6). The project home already
  // shows the backlog inline in ProjectDashboard, so this only needs to cover the
  // "a workspace is open" case.
  const [showBacklogPanel, setShowBacklogPanel] = useState(false);
  const [projectSettingsFor, setProjectSettingsFor] = useState<string | null>(null);
  const [projectSettingsTab, setProjectSettingsTab] = useState<ProjectSettingsTab>("git");
  const notifPrefsRef = useRef(notifPrefs);
  useEffect(() => {
    notifPrefsRef.current = notifPrefs;
    savePrefs(notifPrefs);
  }, [notifPrefs]);
  // Toast position + dwell time (Settings › Notifications), persisted per-device.
  const [toastPrefs, setToastPrefs] = useState<ToastPrefs>(() => loadToastPrefs());
  useEffect(() => {
    saveToastPrefs(toastPrefs);
  }, [toastPrefs]);
  // Coding-font picker — overrides the editor/code face (--code). All options are
  // bundled locally (see styles.css @font-face), so the choice works offline.
  const [monoFont, setMonoFont] = useState<string>(
    () => localStorage.getItem("haro-mono") || MONO_FONTS[0].family
  );
  useEffect(() => {
    document.documentElement.style.setProperty(
      "--code",
      `"${monoFont}", "JetBrains Mono", "IBM Plex Mono", ui-monospace, monospace`
    );
    localStorage.setItem("haro-mono", monoFont);
  }, [monoFont]);
  // Ctrl/Cmd+K toggles the command palette
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && (e.key === "k" || e.key === "K")) {
        e.preventDefault();
        setCmdkOpen((o) => !o);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // dev-only: lets tests/console seed synthetic agent events (dead-code-eliminated
  // in production builds, where import.meta.env.DEV is false).
  useEffect(() => {
    if (!import.meta.env.DEV) return;
    const w = window as unknown as {
      __seedEvents?: (e: AgentEvent[]) => void;
      __setRunning?: (b: boolean) => void;
    };
    w.__seedEvents = setEvents;
    w.__setRunning = (b: boolean) => setWsStatus(b ? "agent_running" : "idle");
  }, []);

  const socketRef = useRef<WebSocket | null>(null);
  const busy =
    wsStatus === "agent_running" || wsStatus === "tests_running" || wsStatus === "setting_up";
  // `busy` folds in `setting_up` so it gates run-app buttons and disables mutating
  // actions while a fresh worktree installs deps. It is NOT what decides whether a
  // submit is client-queued: submitting during setup POSTs straight through and the
  // BACKEND holds the run as `queued` (see runComposer). Only a genuinely running
  // agent/test run queues client-side, which is also what the button label reads off
  // — see composerButtonLabel / shouldClientQueue.

  const guard = <A extends unknown[]>(fn: (...a: A) => Promise<void>) => {
    let inFlight = false;
    return async (...a: A) => {
      if (inFlight) return; // drop a double-click/re-fire instead of racing the same action
      inFlight = true;
      setError(null);
      setNotice(null);
      try {
        await fn(...a);
      } catch (e: any) {
        setError(e.message ?? String(e));
      } finally {
        inFlight = false;
      }
    };
  };

  // ---- navigation loaders ----
  const loadAll = useCallback(async () => {
    // Boot-splash reporting (notes/kuro-motion-plan.md): a no-op once the splash
    // is gone, so re-invoking loadAll from a later feed event never touches it.
    let projs: Awaited<ReturnType<typeof api.listProjects>>;
    try {
      projs = await api.listProjects();
      boot.stage("backend", "ready");
    } catch (e) {
      boot.stage("backend", "unreachable");
      throw e;
    }
    setProjects(projs);
    const map: Record<string, Workspace[]> = {};
    // Races load alongside workspaces because the global triage view groups lanes by
    // race: without them, a fan-out's siblings would render as N loose cards for the
    // first render — the exact pile the feature exists to remove.
    const raceMap: Record<string, RaceRun[]> = {};
    // A bulk archive that's still draining is reattached here, so a reload mid-queue
    // reopens the panel instead of leaving a destructive batch running unwatched.
    const draining: ArchiveQueueRun[] = [];
    await Promise.all(
      projs.map(async (p) => {
        map[p.id] = await api.listWorkspaces(p.id).catch(() => []);
        raceMap[p.id] = await api.getRaces(p.id).catch(() => []);
        const arq = await api.getArchiveQueue(p.id).catch(() => null);
        if (arq && arq.state === "running") draining.push(arq);
      })
    );
    setWsByProject(map);
    const totalWs = Object.values(map).reduce((n, list) => n + list.length, 0);
    boot.stage(
      "workspaces",
      `${projs.length} project${projs.length === 1 ? "" : "s"} · ${totalWs} workspace${totalWs === 1 ? "" : "s"}`
    );
    setRaces(raceMap);
    if (draining.length) setArchiveRun((prev) => prev ?? draining[0]);
  }, []);

  useEffect(() => {
    loadAll().catch((e) => setError(e.message));
  }, [loadAll]);

  // Global live feed: keep every workspace's status badge current (dashboard +
  // sidebar), even for workspaces that aren't the selected one.
  useEffect(() => {
    const sock = openGlobalSocket();
    // StrictMode remounts this effect in dev, so the first socket closes while
    // still CONNECTING — that fires onerror early on a connection nothing is
    // actually wrong with. `dead` (set only in the cleanup) keeps a torn-down
    // socket from reporting a stale "offline" over the real one's "live".
    let dead = false;
    sock.onopen = () => {
      if (!dead) boot.stage("feed", "live");
    };
    sock.onerror = () => {
      if (!dead) boot.stage("feed", "offline");
    };
    sock.onmessage = (raw) => {
      const msg = JSON.parse(raw.data);
      if (msg.channel === "notify" && msg.kind === "agent_done") {
        // an agent finished in *some* workspace → beep (ref = latest prefs) +
        // an OS desktop notification when the window is backgrounded
        playNotify(notifPrefsRef.current);
        showDesktop(notifPrefsRef.current, {
          title: "Agent finished",
          body: msg.workspace_name,
          tag: `agent-${msg.workspace_id}`,
        });
        return;
      }
      if (msg.channel === "notify" && msg.kind === "cost_warning") {
        // a workspace crossed its cumulative-spend threshold → beep + banner
        playNotify(notifPrefsRef.current);
        showDesktop(notifPrefsRef.current, {
          title: "Spend threshold crossed",
          body: `${msg.workspace_name} · $${msg.total_usd} (limit $${msg.threshold_usd})`,
          tag: `cost-${msg.workspace_id}`,
        });
        setCostWarn({ name: msg.workspace_name, total: msg.total_usd, threshold: msg.threshold_usd });
        return;
      }
      if (msg.channel === "notify" && (msg.kind === "gate_green" || msg.kind === "gate_red")) {
        // the test gate resolved in *some* workspace → OS desktop notification
        // when backgrounded (the gate panel already shows it when you're looking)
        const green = msg.kind === "gate_green";
        // Adopted worktrees are agentless — they never emit `agent_done`, so the
        // gate flip *is* their completion moment. Beep on it so foreign work lights
        // up exactly like native does on agent-done (managed already beeped there,
        // so we don't double-fire them here).
        if (msg.workspace_kind === "adopted") playNotify(notifPrefsRef.current);
        showDesktop(notifPrefsRef.current, {
          title: green ? "✓ Gate green" : "✕ Gate red",
          body: green
            ? `${msg.workspace_name} · ${msg.passed}/${msg.total} passed`
            : `${msg.workspace_name} · ${msg.failed} failing`,
          tag: `gate-${msg.workspace_id}`,
        });
        return;
      }
      if (msg.channel === "notify" && msg.kind === "rung") {
        // The autonomy ladder acted on a green gate (backlog/autonomy-ladder.md §3).
        // An unattended auto-PR you didn't notice is indistinguishable from a bug, so a
        // fired rung beeps, raises a desktop notification and leaves a toast behind.
        const label = "Auto-PR";
        if (msg.state === "fired") {
          playNotify(notifPrefsRef.current);
          showDesktop(notifPrefsRef.current, {
            title: `⇧ ${label}`,
            body: `${msg.workspace_name} · ${msg.detail}`,
            tag: `rung-${msg.workspace_id}`,
          });
          pushToast("success", `${label}: ${msg.workspace_name} — ${msg.detail}`);
        } else if (msg.state === "failed") {
          pushToast("error", `${label} failed: ${msg.workspace_name} — ${msg.detail}`);
        } else {
          // Held: the rung is armed and waiting on the reason to clear. Quiet (no beep) —
          // it's an answer to "why didn't it fire", not an event in its own right.
          pushToast("error", `${label} held: ${msg.workspace_name} — ${msg.detail}`);
        }
        return;
      }
      if (msg.channel === "notify" && typeof msg.kind === "string" && msg.kind.startsWith("race_")) {
        // Winner-only fan-out lifecycle (backlog/winner-fanout.md §1). The whole
        // RaceRun rides the event, so the scorecard re-renders with no fetch-per-race
        // — the same denormalize-onto-the-feed rule the gate/trust summaries follow.
        const race: RaceRun = msg.race;
        setRaces((prev) => {
          const list = prev[race.project_id] ?? [];
          const i = list.findIndex((r) => r.id === race.id);
          const next = i >= 0 ? list.map((r) => (r.id === race.id ? race : r)) : [race, ...list];
          return { ...prev, [race.project_id]: next };
        });
        // A race spawns/retires worktrees behind your back, so the sidebar has to
        // resync — otherwise soft-archived losers linger as clickable dead rows.
        if (msg.kind === "race_started" || msg.kind === "race_archived" || msg.kind === "race_purged") {
          loadAll().catch(() => {});
        }
        if (msg.kind === "race_done") {
          // The verdict is the moment the human is needed again: one diff to review,
          // or an honest tie/refusal that still wants their eyes. Same treatment as a
          // fired rung — an unattended decision you didn't notice is worse than noise.
          playNotify(notifPrefsRef.current);
          const head = raceHeadline(race);
          showDesktop(notifPrefsRef.current, {
            title: head.tone === "won" ? "🏁 Race decided" : "🏁 Race finished",
            body: head.text,
            tag: `race-${race.id}`,
          });
          pushToast(head.tone === "won" ? "success" : "error", `Race: ${head.text}`);
        }
        if (msg.kind === "race_budget" && msg.detail) {
          // Never silent: stopping lanes for money is exactly the thing a user must
          // not discover later from a bill.
          pushToast("error", msg.detail);
        }
        return;
      }
      if (msg.channel === "notify" && msg.kind === "archive_queue") {
        // A bulk archive is tearing down worktrees one at a time (backlog/bulk-archive.md).
        // The whole run rides the event, so the panel re-renders with no fetch — and a
        // reload mid-queue reconnects through `api.getArchiveQueue` to this same run.
        const run: ArchiveQueueRun = msg.run;
        setArchiveRun((prev) => mergeArchiveRun(prev, run));
        // What to DO about it (resync the sidebar per completed item, drop a workspace
        // the queue just archived under you, toast the outcome) is decided by the pure
        // helper — see `archiveQueue.archiveFeedEffects`.
        const fx = archiveFeedEffects(
          archiveSeenRef.current,
          run,
          workspaceRef.current?.id ?? null
        );
        archiveSeenRef.current = fx.seen;
        if (fx.reload) loadAll().catch(() => {});
        if (fx.clearSelected) {
          setTask("");
          setWorkspace(null);
        }
        if (fx.toast) pushToast(fx.toast.kind, fx.toast.text);
        return;
      }
      if (msg.channel === "notify" && msg.kind === "backlog_changed" && msg.project_id) {
        // the fs watcher saw a committed todo-*.md change (e.g. a `git pull`) →
        // nudge that project's backlog to refetch (no manual refresh needed)
        setBacklogNonces((prev) => ({
          ...prev,
          [msg.project_id]: (prev[msg.project_id] ?? 0) + 1,
        }));
        return;
      }
      if (msg.channel === "status" && msg.workspace_id) {
        setWsByProject((prev) => {
          for (const pid in prev) {
            const i = prev[pid].findIndex((w) => w.id === msg.workspace_id);
            if (i >= 0) {
              const list = prev[pid].slice();
              // A gate-completion status also carries the fresh gate summary + trust
              // report — merge them so the dashboard's glance view (N failing) and the
              // per-card trust meter stay live off the same coarse feed. `msg.trust` is
              // the full TrustReport (a superset of the compact TrustSummary the card reads).
              list[i] = {
                ...list[i],
                ...(msg.status ? { status: msg.status } : {}),
                ...(msg.gate !== undefined ? { gate: msg.gate } : {}),
                ...(msg.trust !== undefined ? { trust: msg.trust } : {}),
              };
              return { ...prev, [pid]: list };
            }
          }
          return prev;
        });
      }
    };
    return () => {
      dead = true;
      sock.close();
    };
  }, [loadAll]);

  const reloadWorkspaces = useCallback(async (projectId: string) => {
    const list = await api.listWorkspaces(projectId).catch(() => []);
    setWsByProject((prev) => ({ ...prev, [projectId]: list }));
    return list;
  }, []);

  // ---- realtime: one multiplexed socket for the selected workspace ----
  const refreshDiff = useCallback(async () => {
    if (!workspace) return;
    try {
      setDiff(await api.getDiff(workspace.id));
    } catch (e: any) {
      setError(e.message);
    }
  }, [workspace]);
  // Per-line proof for the ship diff. Reads the map the last green gate cached — it never
  // runs a suite, so this is safe to call on every gate verdict alongside the diff itself.
  // Failures are swallowed: an annotation that can't load must leave a plain, working diff.
  const refreshVerified = useCallback(async () => {
    if (!workspace) return;
    try {
      setVerified(await api.getVerifiedHunks(workspace.id));
    } catch {
      setVerified(null);
    }
  }, [workspace]);
  // Gate Receipt: reads facts the gate already computed, so it's safe to refetch on
  // every verdict alongside the diff and the verified-hunks annotation.
  const refreshReceipt = useCallback(async () => {
    if (!workspace) return;
    try {
      setReceipt(await api.getReceipt(workspace.id));
    } catch {
      setReceipt(null);
    }
  }, [workspace]);
  // Jump to the code step and open a file — routed from an @mention click in the
  // agent stream. Bumping `nonce` lets CodePanel re-open even the same path.
  const openInCode = useCallback((path: string, line?: number) => {
    setMainView("code");
    setCodeOpen((prev) => ({ path, line, nonce: (prev?.nonce ?? 0) + 1 }));
  }, []);
  const refreshHistory = useCallback(async () => {
    if (!workspace) return;
    try {
      setHistory(await api.getHistory(workspace.id));
    } catch {
      /* non-fatal */
    }
  }, [workspace]);
  const refreshImpact = useCallback(async () => {
    if (!workspace) return;
    try {
      setImpact(await api.getImpact(workspace.id));
    } catch (e: any) {
      setError(e.message);
    }
  }, [workspace]);
  // Failure → blame: only meaningful on a red gate, so we fetch it when the gate
  // goes red and clear it otherwise (a non-critical insight — swallow errors).
  const refreshBlame = useCallback(async () => {
    if (!workspace) return;
    try {
      setBlame(await api.getBlame(workspace.id));
    } catch {
      /* non-fatal */
    }
  }, [workspace]);

  useEffect(() => {
    if (!workspace) return;
    const pid = workspace.project_id;
    const sock = openWorkspaceSocket(workspace.id);
    socketRef.current = sock;
    sock.onmessage = (raw) => {
      const msg: WSMessage = JSON.parse(raw.data);
      if (msg.channel === "fs") {
        // the backend fs watcher saw a change in this worktree (agent edit, git
        // pull, terminal edit…) → reload the code file tree + change marks live
        setCodeNonce((n) => n + 1);
      } else if (msg.channel === "agent") {
        // Route the event to its session's transcript (the envelope carries session_id;
        // absent ⇒ the primary session). Register a not-yet-seen session in the switcher
        // so a run started from another client/tab still surfaces here.
        const sid = msg.session_id || DEFAULT_SESSION;
        setSessionEvents((prev) => ({ ...prev, [sid]: [...(prev[sid] ?? []), msg.event] }));
        setSessions((prev) => mergeSession(prev, sid));
        if (msg.event.type === "done" || msg.event.type === "error") refreshDiff();
      } else if (msg.channel === "test") {
        if (msg.kind === "run_started") setCells([]);
        else if (msg.kind === "cell") {
          const cell = msg.cell;
          setCells((prev) => {
            const i = prev.findIndex((c) => c.id === cell.id);
            if (i === -1) return [...prev, cell];
            const next = prev.slice();
            next[i] = cell;
            return next;
          });
        } else if (msg.kind === "snapshot") setTest(msg.test);
      } else if (msg.channel === "watch") {
        // The Live Gate's advisory stream (backlog/live-gate.md). Same envelope shape as
        // `test` but a separate channel and separate state — it must never touch `cells`
        // or `test`, which carry the verdict a merge is allowed to rest on.
        if (msg.kind === "run_started") setWatchCells([]);
        else if (msg.kind === "cell") {
          const cell = msg.cell;
          setWatchCells((prev) => {
            const i = prev.findIndex((c) => c.id === cell.id);
            if (i === -1) return [...prev, cell];
            const next = prev.slice();
            next[i] = cell;
            return next;
          });
        } else if (msg.kind === "snapshot") setWatchRun(msg.test);
      } else if (msg.channel === "run") {
        const rid = msg.run_id ?? "app";
        if (msg.line !== undefined) {
          // a dev-server log line → Dev log tab (kept out of the agent stream)
          setRunLog((prev) => {
            const next = [...prev, msg.line as string];
            return next.length > 800 ? next.slice(-800) : next;
          });
          return;
        }
        setRunStates((prev) => ({
          ...prev,
          [rid]: {
            running: !!msg.running,
            url: msg.url ?? null,
            error: msg.running ? null : (msg.error ?? prev[rid]?.error ?? null),
          },
        }));
        if (msg.running) setRunLog([]); // fresh run
      } else if (msg.channel === "status") {
        if (msg.setup) setSetup(msg.setup); // a setup-only status message
        // A gate-completion status carries the fresh trust report — refresh the
        // ④-ship checklist live without a fetch (backlog/autonomy-ladder.md).
        if (msg.trust) setTrust(msg.trust);
        const status = msg.status;
        if (!status) return;
        setWsStatus(status);
        // keep the sidebar dot in sync with live status (+ the gate summary if the
        // message carries one, so a returning dashboard glance is already current)
        setWsByProject((prev) => {
          const list = prev[pid];
          if (!list) return prev;
          return {
            ...prev,
            [pid]: list.map((w) =>
              w.id === msg.workspace_id
                ? { ...w, status, ...(msg.gate !== undefined ? { gate: msg.gate } : {}) }
                : w
            ),
          };
        });
        if (["gate_green", "gate_red", "idle"].includes(status)) {
          refreshDiff();
          refreshVerified();
          refreshReceipt();
          refreshHistory();
          refreshImpact();
          if (status === "gate_red") refreshBlame();
          else setBlame(null);
        }
      }
    };
    return () => sock.close();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspace?.id]);

  // ---- navigation actions ----
  const toggleProject = (pid: string) => setExpanded((prev) => ({ ...prev, [pid]: !prev[pid] }));

  // Open a project's home dashboard (drops any selected workspace so the project
  // view takes over the main column).
  // On a phone the sidebar is an overlay drawer; collapse it once the user picks a
  // destination so the chosen view isn't hidden behind it.
  const closeDrawerOnMobile = () => {
    if (typeof window !== "undefined" && window.matchMedia("(max-width: 720px)").matches) {
      setSidebarOpen(false);
    }
  };

  const selectProject = (pid: string) => {
    setWorkspace(null);
    setSelectedProjectId(pid);
    closeDrawerOnMobile();
  };

  // Back to the cross-project triage (all workspaces, every project).
  const goHome = () => {
    setWorkspace(null);
    setSelectedProjectId(null);
  };

  // Resolve the project's PR web base whenever the selected workspace's project
  // changes (once per switch, cheap). Failure just disables the PR chips.
  useEffect(() => {
    const pid = workspace?.project_id;
    if (!pid) {
      setPrBaseUrl(null);
      return;
    }
    let alive = true;
    api
      .getRemote(pid)
      .then((r) => alive && setPrBaseUrl(r.web_url ?? null))
      .catch(() => alive && setPrBaseUrl(null));
    return () => {
      alive = false;
    };
  }, [workspace?.project_id]);

  // The project whose home dashboard is showing (null once it's been removed).
  const selectedProject = projects.find((p) => p.id === selectedProjectId) ?? null;

  // ---- winner-only fan-out (backlog/winner-fanout.md) ----
  // The project in context: the open workspace's, else the selected project's home.
  const raceProjectId = workspace?.project_id ?? selectedProjectId ?? null;
  useEffect(() => {
    if (!raceProjectId) {
      setRacePreflight(null);
      return;
    }
    let alive = true;
    api.getRaces(raceProjectId).then(
      (list) => alive && setRaces((prev) => ({ ...prev, [raceProjectId]: list })),
      () => {},
    );
    // Re-fetched per project because §0's answer is per project — a budget ceiling set
    // on one repo says nothing about another, and a stale "ok" would enable a button
    // that's about to 400.
    api.racePreflight(raceProjectId).then(
      (pf) => alive && setRacePreflight(pf),
      () => alive && setRacePreflight(null),
    );
    return () => {
      alive = false;
    };
  }, [raceProjectId]);

  const raceBtn = raceButtonState(racePreflight);
  const projectRaces = raceProjectId ? races[raceProjectId] ?? [] : [];

  // Fan the composer's current task across the project's lane grid. Deliberately does
  // NOT clear the composer optimistically before the call: a §0 refusal comes back as a
  // 400, and losing the typed task to a refusal would be a rotten trade.
  const raceTask = guard(async () => {
    if (!workspace || racing) return;
    const composed = composeWithAttachments(task, attachments[workspace.id] ?? []);
    if (!composed.trim()) return;
    setRacing(true);
    try {
      const run = await api.startRace(workspace.project_id, composed);
      setRaces((prev) => ({
        ...prev,
        [run.project_id]: [run, ...(prev[run.project_id] ?? []).filter((r) => r.id !== run.id)],
      }));
      setTask("");
      setAttachments((prev) => ({ ...prev, [workspace.id]: [] }));
      await loadAll();
      // Send them to the project home: the race's story is told by the scorecard, and
      // the currently-open workspace is not one of its lanes.
      setSelectedProjectId(run.project_id);
      setWorkspace(null);
      pushToast("success", `Racing ${run.lanes.length} lanes — the gate picks the winner.`);
    } finally {
      setRacing(false);
    }
  });

  const purgeRaceLosers = guard(async (raceId: string) => {
    setPurgingRace(raceId);
    try {
      await api.purgeRaceLosers(raceId);
      const updated = await api.getRace(raceId);
      setRaces((prev) => ({
        ...prev,
        [updated.project_id]: (prev[updated.project_id] ?? []).map((r) =>
          r.id === updated.id ? updated : r,
        ),
      }));
      await loadAll();
    } finally {
      setPurgingRace(null);
    }
  });

  const stopRace = guard(async (raceId: string) => {
    await api.stopRace(raceId);
  });

  // ---- bulk archive (backlog/bulk-archive.md) -------------------------- //
  // The flow is always plan → confirm → drain, and the sequence itself lives in
  // `archiveActions.ts` (injected deps, unit-tested) — it ends in deleted worktrees, so
  // "which ids, with which force flag" is not something to leave in a closure. The
  // client never decides *admission*: every plan is the backend's answer, the same way
  // the merge queue's admission lives server-side.
  const archiveActions = bulkArchiveActions({
    api,
    pick: () => archivePickRef.current,
    setPick: (pick) => {
      archivePickRef.current = pick;
    },
    // Read through the ref, not the state variable: `start` must send the force flag of
    // the plan currently ON SCREEN, and this handler is rebuilt every render anyway.
    run: () => archiveRunRef.current,
    setRun: setArchiveRun,
    setBusy: setArchiveBusy,
  });
  const planBulkArchive = (projectId: string, workspaceIds: string[]) =>
    guard(() => archiveActions.plan(projectId, workspaceIds))();
  const replanBulkArchive = (force: boolean) => guard(() => archiveActions.replan(force))();
  const startBulkArchive = () => guard(() => archiveActions.start())();
  const stopBulkArchive = () => guard(() => archiveActions.stop())();

  // Best-effort: sniff the just-added project's stack and open the
  // propose-and-confirm modal. Detection failing must never block onboarding.
  const proposeStack = async (project: Project) => {
    try {
      const detection = await api.detectStack(project.id);
      setStackFor({ projectId: project.id, projectName: project.name, detection });
    } catch {
      /* no proposal — the dev configures the gate manually later */
    }
  };

  const addProject = guard(async () => {}); // replaced below (needs arg)
  const onAddProject = (path: string) =>
    guard(async () => {
      const p = await api.createProject(path);
      await loadAll();
      setExpanded((prev) => ({ ...prev, [p.id]: true }));
      await proposeStack(p);
    })();

  // "Create new project" from AddProjectModal: `git init` a fresh folder (creating
  // it), optionally link a remote, then register. Not guard()-wrapped — it rethrows
  // so the form can surface the error and stay open; resolves ⇒ the parent closes it.
  const onCreateNew = async (path: string, name: string, remoteUrl: string) => {
    const p = await api.createProject(path, { init: true, name, remoteUrl });
    await loadAll();
    setExpanded((prev) => ({ ...prev, [p.id]: true }));
    setPickerOpen(false);
    await proposeStack(p);
  };

  // Confirm from the InitRepoModal: `git init` a non-git folder (optionally linking
  // a remote), then register it. Busy-tracked so the modal shows a loader.
  const confirmInit = (remoteUrl: string) =>
    guard(async () => {
      if (!initFor) return;
      setInitBusy(true);
      try {
        const p = await api.createProject(initFor, { init: true, remoteUrl });
        await loadAll();
        setExpanded((prev) => ({ ...prev, [p.id]: true }));
        setInitFor(null);
        await proposeStack(p);
      } finally {
        setInitBusy(false);
      }
    })();

  const onNewWorkspace = (
    projectId: string,
    name: string,
    baseRef?: string,
    branch?: string,
    seedTask?: string,
    seedKey?: string,
  ) =>
    guard(async () => {
      const ws = await api.createWorkspace(projectId, name, baseRef, branch, seedKey);
      // The backend auto-renames a duplicate title (same slug → same branch/worktree)
      // by suffixing a counter. Surface it so the dev knows this task existed before
      // and is now a distinct workspace on branch <name>-N, not a no-op.
      if (ws.name !== name) {
        setNotice(`"${name}" already exists. Created "${ws.name}" on ${ws.branch}`);
      }
      setExpanded((prev) => ({ ...prev, [projectId]: true }));
      await reloadWorkspaces(projectId);
      // Seed the composer draft so a workspace started from a backlog todo lands
      // with the agent prompt ready (selectWorkspace reads draftsRef for its task).
      if (seedTask?.trim()) {
        draftsRef.current[ws.id] = seedTask.trim();
        setSeededWsId(ws.id); // glow the composer until the dev runs it
      }
      selectWorkspace(ws);
    })();

  // The lead phrase before a dash, cut at a *word boundary* (never mid-word) so an
  // item without a " — " separator still gives a clean slug instead of a phrase
  // sliced through a word. Shared by the single-item (modal) and "start N" (direct)
  // workspace-creation paths below.
  const slugTitle = (title: string): string => {
    const lead = title.replace(/[`*]/g, "").replace(/\s+/g, " ").trim();
    let name = lead.split(/\s+[—–-]\s+/)[0] || lead;
    if (name.length > 48) {
      const cut = name.slice(0, 48);
      const sp = cut.lastIndexOf(" ");
      name = (sp > 16 ? cut.slice(0, sp) : cut).trim();
    }
    return name;
  };

  // Backlog todo → open the new-workspace modal. `title` (compact prose) yields the
  // workspace/branch name; `task` (the full item, code examples included) is seeded
  // verbatim as the agent brief.
  const startTodoWorkspace = (
    projectId: string,
    title: string,
    task: string,
    seedKey?: string,
  ) => {
    setNewWsSeed({ name: slugTitle(title), task: task.trim(), seedKey });
    setNewWsFor(projectId);
  };

  // "Start next N" (backlog/backlog-v2.md Move 3): N prompts x 1 lane, one action —
  // skips the per-item review modal (that's the single-click path above) and calls
  // onNewWorkspace directly for each selected item. Each create already goes
  // through the existing [agent] max_parallel queue server-side.
  const startManyTodoWorkspaces = async (
    projectId: string,
    items: { title: string; task: string; seedKey?: string }[],
  ) => {
    // Sequential, not fired concurrently: the backend's duplicate-name auto-rename
    // (`foo` → `foo-2`) reads the CURRENT branch/worktree list at create time, so N
    // in-flight creates sharing a slug all see it free and only one survives — a
    // review reproduced 1 workspace + N-1 hard git errors from firing these in
    // parallel. Awaiting each one also makes the final `selectWorkspace` land on a
    // deterministic (the last-requested) workspace instead of whichever settled last.
    for (const it of items) {
      await onNewWorkspace(projectId, slugTitle(it.title), undefined, undefined, it.task, it.seedKey);
    }
  };

  // `stageHint` is the backlog item's derived stage (backlog/backlog-v2.md Move 2)
  // when this selection came from clicking a backlog row: routes straight to the
  // step that stage is about — green to ④ ship, red to ③ verify — instead of
  // always landing on the default ① agent / ② code view.
  const selectWorkspace = (ws: Workspace, stageHint?: string) => {
    setError(null);
    setNotice(null);
    // Stash the current workspace's draft and restore the target's (empty if none),
    // so composer text follows the workspace instead of leaking across all of them.
    if (workspace && ws.id !== workspace.id) draftsRef.current[workspace.id] = task;
    setTask(ws.id === workspace?.id ? task : draftsRef.current[ws.id] ?? "");
    setWorkspace(ws);
    // Remember the parent project so closing/archiving this workspace returns to
    // its project home rather than the global dashboard.
    const parentPid = Object.keys(wsByProject).find((pid) =>
      (wsByProject[pid] ?? []).some((w) => w.id === ws.id)
    );
    if (parentPid) {
      setSelectedProjectId(parentPid);
      // Expand the parent so the selected workspace is visible in the tree.
      setExpanded((prev) => ({ ...prev, [parentPid]: true }));
    }
    setWsStatus(ws.status);
    // Reset the session switcher to just the primary tab, then hydrate the persisted set
    // + the active session's transcript below (write specific sessions directly — setEvents
    // targets sessionTab, which is only "main" after this render, so it can't stale-clobber).
    setSessions([DEFAULT_SESSION]);
    setSessionTab(DEFAULT_SESSION);
    setSessionEvents({});
    setCells([]);
    setComments([]);
    setTest(null);
    setDiff(null);
    setVerified(null);
    setHistory([]);
    setTrust(null);
    setImpact(null);
    setBlame(null);
    setCoverage(null);
    setFlaky(null);
    setMutation(null);
    setMutationError(null);
    // GatePanel remounts fresh per workspace (key={workspace.id}), so its GateFocus
    // effect always fires once on mount regardless of the nonce's value — a STALE
    // non-default target left over from the PREVIOUS workspace (e.g. "see the ribbon"
    // on workspace A) would otherwise force-open Details/pulse the ribbon on whichever
    // workspace is opened next. Resetting to the default target makes that mount-fire
    // a harmless scroll instead of an unwanted state change.
    setGateFocus({ target: "blockers", nonce: 0 });
    setRunStates({});
    setRunMenuOpen(false);
    setSetup(null);
    setScripts(null);
    setRunLog([]);
    // Fresh shell for the newly-selected workspace (PTYs are per-worktree, so
    // they don't carry across a switch — matches the old single-terminal reset).
    termHandles.current.clear();
    const first = newShellId();
    setShells([first]);
    setTermTab(first);
    // The initial shell must not steal focus on connect — the composer is the
    // primary action for a freshly-opened workspace (esp. one seeded from a
    // backlog item, where the task is prefilled and the dev just needs ⌘↵).
    setFocusShellOnOpen(null);
    // Adopted worktrees are agentless — the ① agent step (and its pane) is hidden — so
    // open on ② code instead of an empty agent stream. backlog/merge-firewall.md §1.
    // A backlog stage hint (green/red) overrides both defaults.
    setMainView(
      stageHint === "green" ? "git" : stageHint === "red" ? "gate"
        : ws.kind === "adopted" ? "code" : "agent",
    );
    setMobilePane("flow");
    closeDrawerOnMobile();
    setCodeFull(false);
    setTermFull(false);
    // The Live Gate is per-worktree — a previous workspace's advisory verdict must not
    // linger in the rail while the new one's first run is still pending.
    setWatchCells([]);
    setWatchRun(null);
    setWatchEnabled(false);
    setGateCfg(null);
    api.getGate(ws.project_id).then(setGateCfg).catch(() => {});
    api
      .getWatch(ws.id)
      .then((w) => {
        setWatchEnabled(w.enabled);
        setWatchRun(w.run);
        setWatchCells(w.run ? casesToCells(w.run.cases) : []);
      })
      .catch(() => {});
    // Load persisted state; the socket also replays recent live events. Seed the
    // grid from the last gate snapshot so it isn't blank until the next run
    // (a replayed run_started will reset it if live cells arrive).
    api.getDiff(ws.id).then(setDiff).catch(() => {});
    api.getVerifiedHunks(ws.id).then(setVerified).catch(() => {});
    setReceipt(null);
    api.getReceipt(ws.id).then(setReceipt).catch(() => {});
    // Primary session's durable transcript (write the "main" bucket directly, not via
    // setEvents, to dodge the sessionTab-closure race on switch). This GET can resolve
    // AFTER the socket has already appended live events for a run that started right
    // as the workspace opened (e.g. a task queued immediately on select) — a bare
    // overwrite would silently discard those, since the REST snapshot was captured
    // before they existed server-side. Keep anything already in state that's newer
    // than the snapshot's own latest event (`ts` is a server-assigned time.time() at
    // append, so it orders correctly across the two sources).
    api.getEvents(ws.id).then((r) => setSessionEvents((p) => {
      const live = p[DEFAULT_SESSION] ?? [];
      const snapshotMaxTs = r.events.reduce((m, e) => Math.max(m, e.ts), 0);
      const newerLive = live.filter((e) => e.ts > snapshotMaxTs);
      return { ...p, [DEFAULT_SESSION]: [...r.events, ...newerLive] };
    })).catch(() => {});
    // Hydrate the full session set so the switcher shows every persisted conversation,
    // and bump the id counter past any existing s<n> so a new tab won't collide.
    api.getSessions(ws.id).then((r) => {
      setSessions(mergeSessions([DEFAULT_SESSION], r.sessions));
    }).catch(() => {});
    api.getSetup(ws.id).then(setSetup).catch(() => {});
    api.getScripts(ws.id).then(applyScripts).catch(() => {});
    api
      .getTests(ws.id)
      .then((t) => {
        setTest(t);
        if (t && t.cases.length) {
          setCells(
            t.cases.map((c, i) => ({
              id: `${c.file}::${c.name}::${i}`,
              file: c.file,
              name: c.name,
              status: c.status,
              duration_ms: c.duration_ms,
              message: c.message,
            }))
          );
        }
      })
      .catch(() => {});
    api.getHistory(ws.id).then(setHistory).catch(() => {});
    api.getTrust(ws.id).then(setTrust).catch(() => {});
    // Seed failure → blame when landing on an already-red gate (live transitions
    // are handled by the status socket handler).
    if (ws.status === "gate_red") api.getBlame(ws.id).then(setBlame).catch(() => {});
    // Land focus on the prompt composer so the dev can fire the (often prefilled)
    // task with ⌘↵ immediately. Deferred a frame so the agent view has painted;
    // the terminal no longer competes for focus (focusShellOnOpen is null above).
    requestAnimationFrame(() => {
      (document.getElementById("agent-input") as HTMLTextAreaElement | null)?.focus();
    });
  };

  // ---- agent + gate ----
  // Fire a task at the agent now: echo it into the stream and start the run.
  // Flips status to agent_running synchronously so the drain effect won't re-fire.
  const sendTask = useCallback(async (ws: Workspace, text: string, plan?: boolean, role?: string) => {
    const t = text.trim();
    if (!t) return;
    // echo the prompt into the stream so the transcript reads as a conversation
    setEvents((prev) => [
      ...prev,
      { run_id: "user", workspace_id: ws.id, ts: Date.now() / 1000, type: "user", payload: { text: t } },
    ]);
    // Optimistic: flip busy before the POST so the drain effect won't re-fire and the
    // composer locks immediately. If the POST FAILS there is no status event coming to
    // unstick it, so the catch below must put it back — otherwise the composer wedges
    // "busy" forever and the only cure is a reload.
    const prior = wsStatusRef.current;
    setWsStatus("agent_running");
    // Resolve the picked backend → startAgent args. Local: the model tag, no effort.
    // Claude: "default" → omit the flag so Claude Code uses its own configured default.
    const opts = optsRef.current;
    const { adapter, model, effort } = runArgs(opts);
    // Roles force the claude-code adapter (the composer hides the backend switch
    // entirely while `[roles]` is on — see the composer JSX), so a "local" backend
    // left over from before roles were enabled must not disable plan/fast here.
    const effectiveBackend = opts.rolesEnabled ? "claude-code" : opts.backend;
    // `plan` is an explicit override (approve = false, feedback = true); when unset a
    // normal submit follows the composer's "Plan first" toggle. Local backend can't plan.
    const usePlan = (plan ?? opts.planFirst) && effectiveBackend !== "local";
    // Fast Mode follows the composer's "Fast" toggle. Plan wins if somehow both are on
    // (the toggles are mutually exclusive in the UI; this is the defensive backstop).
    const useFast = opts.fastMode && !usePlan && effectiveBackend !== "local";
    // Which step of the plan→scout→build→refute loop this run is. An explicit
    // `role` (the approve-plan handoff) always wins — that's what lets "approve"
    // resolve to the BUILD role even though the plan turn it's approving ran
    // under the plan role; otherwise it follows this send's own plan/build mode.
    // Harmless to send when `[roles]` is off server-side (main.py ignores it).
    const runRole = role ?? (usePlan ? "plan" : "build");
    // Run in the active switcher session (read via ref — sendTask is memoized with []).
    try {
      await api.startAgent(
        ws.id, t, adapter, model, effort, usePlan, useFast, sessionTabRef.current, runRole,
      );
    } catch (e) {
      setWsStatus(prior); // nothing started, so nothing will ever say "idle" again
      throw e;
    }
  }, []);

  // Divert a large pasted block to a .context/ file attachment (paste-to-file). The
  // composer only shows a chip; the block reaches the agent as an @mention on submit.
  const attachPaste = async (text: string) => {
    if (!workspace) return;
    try {
      const a = await api.attachContext(workspace.id, text);
      setAttachments((prev) => ({ ...prev, [workspace.id]: [...(prev[workspace.id] ?? []), a] }));
    } catch (e) {
      setError(e instanceof Error ? e.message : "could not attach paste");
    }
  };
  // Paste an image or attach a file/media via the paperclip: it's uploaded to a
  // .context/ file (base64) and shown as a chip, exactly like paste-to-file — but
  // an image chip previews a thumbnail and opens in the code step, and Claude Code
  // reads it via the same @mention on submit. Handles several files at once.
  const attachFiles = async (files: File[]) => {
    if (!workspace || files.length === 0) return;
    const wsId = workspace.id;
    for (const file of files) {
      try {
        const b64 = await fileToBase64(file);
        const a = await api.uploadContext(wsId, file.name || "upload", file.type || "", b64);
        setAttachments((prev) => ({ ...prev, [wsId]: [...(prev[wsId] ?? []), a] }));
      } catch (e) {
        setError(e instanceof Error ? e.message : "could not attach file");
      }
    }
  };
  const removeAttachment = (path: string) => {
    if (!workspace) return;
    setAttachments((prev) => ({
      ...prev,
      [workspace.id]: (prev[workspace.id] ?? []).filter((a) => a.path !== path),
    }));
  };

  // Run the composed task — or, if the workspace is busy, queue it as a follow-up.
  // `plan` overrides the composer's "Plan first" toggle for this send (the plan
  // feedback action forces another plan turn); undefined ⇒ follow the toggle.
  const runComposer = async (plan?: boolean) => {
    if (!workspace) return;
    const atts = attachments[workspace.id] ?? [];
    const composed = composeWithAttachments(task, atts);
    if (!composed.trim()) return;
    setTask("");
    setSeededWsId((id) => (id === workspace.id ? null : id)); // the seed has been run — drop the glow
    setAttachments((prev) => ({ ...prev, [workspace.id]: [] }));
    // Client-queue ONLY behind a real agent/test run (the deliberate
    // follow-up-while-busy feature). Deliberately NOT behind `setting_up`: that path
    // filed the task into a localStorage queue whose only drainer is an effect scoped
    // to the SELECTED workspace, so "create from the backlog → run → switch away"
    // stranded it forever. Setup is the backend's wait to own now — POST immediately
    // and the run sits server-side as `queued` until the worktree is provisioned.
    if (shouldClientQueue(wsStatus)) {
      setQueues((prev) => ({ ...prev, [workspace.id]: [...(prev[workspace.id] ?? []), composed] }));
      return;
    }
    await sendTask(workspace, composed, plan);
  };
  // NOTE: keep this arg-free — it's wired straight to onClick/onSubmit, whose event
  // arg would otherwise land in `runComposer`'s `plan` slot (a truthy event).
  const submitTask = guard(async () => {
    await runComposer();
  });
  // Live pointer to submitTask so the window-level ⌘+Enter handler always runs the
  // CURRENT prompt/queue state, not a closure captured when its effect mounted
  // (submitTask closes over `task`/`busy`, which change on every keystroke).
  const submitTaskRef = useRef(submitTask);
  submitTaskRef.current = submitTask;

  // ---- plan approval ----
  // Move focus to the composer textarea (used when "Give feedback" is clicked with an
  // empty prompt — the dev needs to type before it can re-plan).
  const focusComposer = () => {
    requestAnimationFrame(() =>
      (document.getElementById("agent-input") as HTMLTextAreaElement | null)?.focus()
    );
  };
  // A plan run finished and nothing has superseded it: the stream's last terminal
  // event is a plan `done`. Drives the approve / feedback bar below the stream. Reads
  // off the persisted transcript, so it survives a reload of a workspace mid-plan.
  const awaitingPlan = useMemo(() => {
    if (busy) return false;
    for (let i = events.length - 1; i >= 0; i--) {
      const ev = events[i];
      if (ev.type === "done") return !!ev.payload?.plan;
      if (ev.type === "error") return false; // a plan run that errored has no plan
    }
    return false;
  }, [events, busy]);
  // Approve the proposed plan: re-run the SAME session (--resume, via the persisted
  // last_session_id) in auto-edit mode to implement it. No auto-run — the dev clicked
  // approve, mirroring the "no auto-run" rule the conflict handoff follows.
  const approvePlan = guard(async () => {
    if (!workspace || busy) return;
    await sendTask(
      workspace,
      "The plan above is approved. Implement it now. Make the changes in this worktree.",
      false,
      "build",
    );
  });
  // Give feedback on the plan: another plan-mode turn refining the approach. Sends the
  // composer text (forced plan mode); if it's empty, just focus the composer to type.
  const feedbackPlan = guard(async () => {
    if (!workspace) return;
    if (!task.trim()) {
      focusComposer();
      return;
    }
    await runComposer(true);
  });

  // Drain the queue: as soon as the selected workspace frees up, send the oldest
  // queued task (which flips it busy again, so items go one at a time, in order).
  // A send that fails surfaces the error and drops that item; `sendTask` rolls the
  // optimistic busy flip back itself, so the composer doesn't wedge. (Re-queueing the
  // failed item instead would spin: this effect re-fires the moment `queues` changes.)
  useEffect(() => {
    if (!workspace || busy) return;
    const q = queues[workspace.id];
    if (!q || q.length === 0) return;
    const [next, ...rest] = q;
    setQueues((prev) => ({ ...prev, [workspace.id]: rest }));
    sendTask(workspace, next).catch((e) => setError(e.message ?? String(e)));
  }, [busy, workspace, queues, sendTask]);
  const stopAgent = guard(async () => {
    if (workspace) await api.stopAgent(workspace.id);
  });
  const runGate = guard(async () => {
    if (!workspace) return;
    setWsStatus("tests_running");
    await api.runTests(workspace.id, "all");
  });
  const runImpacted = guard(async () => {
    if (!workspace) return;
    setWsStatus("tests_running");
    await api.runTests(workspace.id, "impacted");
  });
  const runFailed = guard(async () => {
    if (!workspace) return;
    setWsStatus("tests_running");
    await api.runTests(workspace.id, "failed");
  });

  // Merge is a multi-second round-trip (push → PR create → PR merge). Track it so
  // the button can show a loader and disable itself — without this the user gets no
  // feedback and re-clicks, which is exactly what spawned duplicate PRs.
  const [merging, setMerging] = useState(false);
  const merge = guard(async () => {
    if (!workspace || merging) return;
    const pid = workspace.project_id;
    setMerging(true);
    try {
      const res = await api.merge(workspace.id);
      setNotice(res.pr_url ? `✓ merged via ${res.method} · ${res.pr_url}` : `✓ ${res.detail}`);
      delete draftsRef.current[workspace.id];
      setQueues((prev) => ({ ...prev, [workspace.id]: [] }));
      setTask("");
      // GitHub-style: mark merged (purple) and keep the workspace — the user
      // archives on their own terms. Don't deselect; the ship button shows "merged".
      setWsStatus("merged");
      setWorkspace((w) => (w ? { ...w, status: "merged" } : w));
      await reloadWorkspaces(pid);
    } finally {
      setMerging(false);
    }
  });

  // Land on ③ verify and snap the eye to one of its zones — the deep-link every
  // "go look at the gate" action in the app routes through, so they all speak the
  // same vocabulary as GateFocus's target union.
  const focusGate = (target: GateFocus["target"]) => {
    setMainView("gate");
    setGateFocus((f) => ({ target, nonce: f.nonce + 1 }));
  };

  // Trust-row deep-link from the ④ ship step's merge-blocked checklist. The fixes all
  // live on the ③ gate step, so route there: a guard toggle opens the project's Gate
  // settings; "run full" hops to the gate and runs the whole suite (Details auto-opens
  // on its own once the run is streaming, so no explicit focus target is needed);
  // "ribbon"/"tamper" map directly onto GateFocus's own target union.
  const shipTrustFix = (fix: TrustFix) => {
    if (!workspace) return;
    if (fix === "gate_settings") {
      setProjectSettingsTab("gate");
      setProjectSettingsFor(workspace.project_id);
      return;
    }
    if (fix === "run_full") {
      setMainView("gate");
      runGate();
      return;
    }
    focusGate(fix);
  };

  // Continue a merged workspace on a fresh branch — same worktree + chat. Keeps the
  // event stream (the agent --resumes), flips back to the agent step, and threads the
  // merged PR into the next one (Follow-up to #N.).
  const [continuing, setContinuing] = useState(false);
  const continueWork = guard(async () => {
    if (!workspace || continuing) return;
    const pid = workspace.project_id;
    setContinuing(true);
    try {
      const res = await api.continueWorkspace(workspace.id);
      setWorkspace((w) => (w ? { ...w, ...res.workspace } : w));
      setWsStatus("idle");
      setNotice(`✓ PR merged · ${res.detail}`);
      setMainView("agent");
      await reloadWorkspaces(pid);
    } finally {
      setContinuing(false);
    }
  });

  // ---- rename workspace (display name + git branch) ----
  const [renamingWs, setRenamingWs] = useState(false);
  const startRenameWs = () => {
    if (workspace) setRenamingWs(true);
  };
  const saveRenameWs = async (name: string, branch: string) => {
    if (!workspace) return;
    setError(null);
    const patch: { name?: string; branch?: string } = {};
    if (name !== workspace.name) patch.name = name;
    if (branch !== workspace.branch) patch.branch = branch;
    if (Object.keys(patch).length) {
      const updated = await api.renameWorkspace(workspace.id, patch);
      setWorkspace(updated);
      await reloadWorkspaces(workspace.project_id);
    }
    setRenamingWs(false);
  };

  // ---- v1.3 review-comment round-trip ----
  const addComment = (target: string, context: string | null = null) => {
    setError(null);
    const id = `${Date.now().toString(36)}-${Math.floor(Math.random() * 1e6).toString(36)}`;
    setComments((prev) => [...prev, { id, target, context, text: "" }]);
  };
  // "Send to backlog" sibling of addComment (backlog/backlog-v2.md Move 3): defer a
  // failing test instead of routing it to the current agent right now.
  const sendTestToBacklog = (target: string, context: string | null = null) => {
    if (!workspace) return;
    // First line only — a full vitest assertion diff can run several hundred
    // characters and would otherwise become one giant parenthetical.
    const evidence = context?.split("\n")[0] ?? "";
    api
      .addTodoItem(workspace.project_id, target, evidence)
      .then(() => pushToast("success", "Sent to backlog/follow-ups.md"))
      .catch((e) => setError(e?.message ?? "failed to send to backlog"));
  };
  // Fix-all: batch every failing test into the review composer in one shot (the
  // red→green loop for a whole gate run), then surface the queue on the agent view.
  const fixAllFailures = (cells: Cell[]) => {
    const items = failureReviewItems(cells);
    if (items.length === 0) return;
    setError(null);
    const stamp = Date.now().toString(36);
    setComments((prev) => [
      ...prev,
      ...items.map((it, i) => ({ id: `fix-${stamp}-${i}`, target: it.target, context: it.context, text: "" })),
    ]);
    setMainView("agent");
    setNotice(`${items.length} failing test${items.length > 1 ? "s" : ""} queued for the agent. Add a note if you like, then send`);
  };
  // green* → agent: the tamper alarm's twin of fix-all. Same one-shot batch into the
  // review composer, with one difference — each item arrives with its restore
  // instruction already written (a finding like ".only added" *is* the ask), so the
  // dev can send as-is instead of typing a note per row.
  // The rail's LookAtChip count — the live run only (never a time-travelled past run;
  // that view lives entirely inside GatePanel). Includes mutation survivors once
  // scored, now that mutation state is lifted here too, so the chip and the ③ page's
  // own count can't disagree by construction.
  const lookAtCount = useMemo(
    () =>
      lookAt({
        status: wsStatus,
        run: test,
        cells,
        checkedKeys: workspace?.checked_rows ?? [],
        survivors: mutation?.survivors ?? null,
        codeToCheck: { enabled: gateCfg?.code_to_check !== "off" },
        adopted: workspace?.kind === "adopted",
      }).pending.length,
    [wsStatus, test, cells, workspace?.checked_rows, mutation, gateCfg?.code_to_check, workspace?.kind],
  );

  // ③ Zone 3 "things to look at" → the composer. `lookAtReviewItems` routes each kind
  // through its own prefilled builder, so the batch is sendable without typing
  // regardless of source (code-to-check row, warn-mode tamper finding, plan gap, …).
  const sendLookAt = (items: LookAtItem[]) => {
    const reviewItems = lookAtReviewItems(items);
    if (reviewItems.length === 0) return;
    setError(null);
    const stamp = Date.now().toString(36);
    setComments((prev) => [
      ...prev,
      ...reviewItems.map((it, i) => ({
        id: `lookat-${stamp}-${i}`,
        target: it.target,
        context: it.context,
        text: it.text,
      })),
    ]);
    setMainView("agent");
    setNotice(
      `${reviewItems.length} thing${reviewItems.length > 1 ? "s" : ""} queued for the agent. The notes are prefilled, edit or send`,
    );
  };

  // "Send to backlog" sibling of sendLookAt above (backlog/backlog-v2.md Move 3):
  // the same items, queued as follow-ups instead of re-tasking the current agent.
  // `target` (short WHAT+WHERE, e.g. "a.ts:12") is the title; `context` (the full
  // path + reason, e.g. "src/pricing/a.ts:12 · mutation survived: …") is the
  // evidence — NOT `text`, which is a fixed per-kind fix instruction identical
  // across every item of that kind (using it as the title made every survivor's
  // backlog line read the same, and let two items collide onto one seed_key).
  // allSettled (not all): one failed POST must not make the ones that DID land
  // look like they didn't, and the count reported must match what's actually
  // in the file.
  const sendLookAtToBacklog = (items: LookAtItem[]) => {
    if (!workspace) return;
    const reviewItems = lookAtReviewItems(items);
    if (reviewItems.length === 0) return;
    Promise.allSettled(
      reviewItems.map((it) => api.addTodoItem(workspace.project_id, it.target, it.context ?? "")),
    ).then((results) => {
      const ok = results.filter((r) => r.status === "fulfilled").length;
      if (ok > 0) pushToast("success", `${ok} of ${results.length} sent to backlog/follow-ups.md`);
      if (ok < results.length) setError(`${results.length - ok} failed to send to backlog`);
    });
  };

  // Tick a "code to check" row off, or put it back (backlog/code-to-check.md).
  //
  // Optimistic, because the tick is the user's own judgement and should land the instant
  // they make it; the POST only persists it. A failure rolls the row back and surfaces the
  // error rather than leaving a tick that exists on screen and nowhere else — a checklist
  // that quietly forgets is worse than one that never offered.
  const toggleRowChecked = (row: UncheckedRow, checked: boolean) => {
    if (!workspace) return;
    const wsId = workspace.id;
    const before = workspace.checked_rows ?? [];
    const rest = before.filter((k) => k !== row.key);
    const next = checked ? [...rest, row.key] : rest;
    const apply = (keys: string[]) =>
      setWorkspace((w) => (w && w.id === wsId ? { ...w, checked_rows: keys } : w));
    apply(next);
    api
      .setRowChecked(wsId, row.key, checked)
      .then((res) => apply(res.checked_rows))
      .catch((e) => {
        apply(before);
        setError(e.message ?? String(e));
      });
  };

  // "review the residue → agent" (backlog/verified-hunks.md §3): the never-executed files
  // from the ship diff, batched into the same composer round-trip as fix-all / code-to-check.
  // Prefilled with "add tests OR justify", because sometimes the honest answer is that a
  // line can't be covered — a signal that accepts only one answer gets gamed into accepting
  // anything.
  const reviewResidue = () => {
    const items = residueReviewItems(verified);
    if (items.length === 0) return;
    setError(null);
    const stamp = Date.now().toString(36);
    setComments((prev) => [
      ...prev,
      ...items.map((it, i) => ({
        id: `residue-${stamp}-${i}`,
        target: it.target,
        context: it.context,
        text: it.text,
      })),
    ]);
    setMainView("agent");
    setNotice(
      `${items.length} file${items.length > 1 ? "s" : ""} the gate never executed queued for the agent. The notes are prefilled, edit or send`,
    );
  };

  const restoreWeakenedTests = (findings: TamperFinding[]) => {
    const items = tamperReviewItems(findings);
    if (items.length === 0) return;
    setError(null);
    const stamp = Date.now().toString(36);
    setComments((prev) => [
      ...prev,
      ...items.map((it, i) => ({
        id: `tamper-${stamp}-${i}`,
        target: it.target,
        context: it.context,
        text: it.text,
      })),
    ]);
    setMainView("agent");
    setNotice(
      `${items.length} weakened test${items.length > 1 ? "s" : ""} queued for the agent. The restore notes are prefilled, edit or send`,
    );
  };
  /** Quality-red → agent (backlog/double-gate.md §2). The Double Gate's twin of
   *  `restoreWeakenedTests`, so a secret or a security finding routes to a fix by exactly
   *  the same path a failing test does. Only BLOCKING findings are batched: below the
   *  project's severity threshold nothing is owed, and hauling advisory nits into a
   *  fix-everything task is how a quality gate becomes noise people learn to dismiss. */
  const fixQualityFindings = (findings: QualityFindingRow[]) => {
    const items = qualityReviewItems(findings);
    if (items.length === 0) return;
    setError(null);
    const stamp = Date.now().toString(36);
    setComments((prev) => [
      ...prev,
      ...items.map((it, i) => ({
        id: `quality-${stamp}-${i}`,
        target: it.target,
        context: it.context,
        text: it.text,
      })),
    ]);
    setMainView("agent");
    setNotice(
      `${items.length} quality finding${items.length > 1 ? "s" : ""} queued for the agent. The fix notes are prefilled, edit or send`,
    );
  };
  /** Refuter must-fix → agent (Phase 3 of notes/workflow-roles-plan.md). The refuter's
   *  twin of `fixQualityFindings`: every must-fix reaching here already survived the
   *  backend's cite-or-drop guardrail, so nothing here is a guess. */
  const fixReviewFindings = (mustFix: ReviewMustFix[]) => {
    const items = reviewMustFixItems(mustFix);
    if (items.length === 0) return;
    setError(null);
    const stamp = Date.now().toString(36);
    setComments((prev) => [
      ...prev,
      ...items.map((it, i) => ({
        id: `review-${stamp}-${i}`,
        target: it.target,
        context: it.context,
        text: it.text,
      })),
    ]);
    setMainView("agent");
    setNotice(
      `${items.length} must-fix finding${items.length > 1 ? "s" : ""} queued for the agent. The fix notes are prefilled, edit or send`,
    );
  };
  // Kill-the-survivors loop (usp-critique-plan.md idea 4) — the mutation score's
  // twin of fix-all/restore-weakened-tests/fix-quality: batch every surviving
  // mutant into the composer as "write a test that fails on this", so the gate
  // doesn't just judge the suite's strength, it closes the loop and improves it.
  const killSurvivors = (survivors: MutationSurvivor[]) => {
    const items = mutationReviewItems(survivors);
    if (items.length === 0) return;
    setError(null);
    const stamp = Date.now().toString(36);
    setComments((prev) => [
      ...prev,
      ...items.map((it, i) => ({
        id: `survivor-${stamp}-${i}`,
        target: it.target,
        context: it.context,
        text: it.text,
      })),
    ]);
    setMainView("agent");
    setNotice(
      `${items.length} surviving mutant${items.length > 1 ? "s" : ""} queued for the agent. The test-writing notes are prefilled, edit or send`,
    );
  };

  // "Send to backlog" sibling of killSurvivors above (backlog/backlog-v2.md Move 3).
  // See sendLookAtToBacklog above for why `target`/`context` (not `text`) are the
  // right title/evidence, and why allSettled over all.
  const sendSurvivorsToBacklog = (survivors: MutationSurvivor[]) => {
    if (!workspace) return;
    const items = mutationReviewItems(survivors);
    if (items.length === 0) return;
    Promise.allSettled(
      items.map((it) => api.addTodoItem(workspace.project_id, it.target, it.context ?? "")),
    ).then((results) => {
      const ok = results.filter((r) => r.status === "fulfilled").length;
      if (ok > 0) pushToast("success", `${ok} of ${results.length} sent to backlog/follow-ups.md`);
      if (ok < results.length) setError(`${results.length - ok} failed to send to backlog`);
    });
  };
  // Ship-step conflict → agent handoff: the ④ ship panel detects a base conflict
  // and hands us a ready-made resolve-conflicts prompt. We drop it into the ①
  // prompt composer and switch to the agent view, but DON'T run it — the dev
  // reviews/edits and clicks run agent himself.
  const resolveConflictWithAI = (context: string) => {
    if (!workspace) return;
    setError(null);
    draftsRef.current[workspace.id] = context;
    setTask(context);
    setMainView("agent");
    setNotice("Conflict-resolution prompt added to the composer. Review it, then click run agent to let the agent resolve the conflicts.");
  };
  // Rewind to a turn marker (the ⤺ button on a `user` prompt row): drop the transcript
  // at/after that turn and re-prompt from it. The worktree is reconciled by a safety
  // checkpoint commit first (the dropped turns' edits stay recoverable in the Git panel),
  // and the same Claude session is kept (last_session_id) so the next run continues from
  // here. Like the conflict handoff, it prefills the composer but never auto-runs.
  const rewindTo = async (turn: number) => {
    if (!workspace) return;
    if (busy) {
      setError("Stop the running agent before rewinding.");
      return;
    }
    const ok = window.confirm(
      `Rewind to turn ${turn}?\n\nEverything after it is removed from the conversation and the ` +
        `composer is prefilled to re-prompt. Uncommitted worktree changes are saved as a ` +
        `checkpoint commit first, so nothing is lost (recover them from the Git panel).`
    );
    if (!ok) return;
    setError(null);
    const sid = sessionTabRef.current;
    try {
      const res = await api.rewind(workspace.id, turn, true, sid);
      // Re-sync the active session's transcript from the (now-truncated) backend rather than
      // trusting the local copy, so the stream matches exactly what a reload would show.
      const r = await api.getEvents(workspace.id, sid);
      setEvents(r.events);
      setTask(res.prompt);
      draftsRef.current[workspace.id] = res.prompt;
      setMainView("agent");
      focusComposer();
      setNotice(
        `Rewound to turn ${turn} · ${res.dropped} event${res.dropped === 1 ? "" : "s"} dropped` +
          (res.checkpoint ? `, changes checkpointed (${res.checkpoint.slice(0, 7)})` : "") +
          ". Edit the prompt and run agent to continue."
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : "rewind failed");
    }
  };
  // ---- agent session switcher (like the shell-tab strip) ----
  // Switch the visible stream to another session tab; lazy-load its transcript the first
  // time it's opened (cached in sessionEvents after). Live events arrive over the socket
  // tagged with the session, so an already-loaded tab stays current without a refetch.
  const selectSession = (sid: string) => {
    setSessionTab(sid);
    if (workspace && sessionEvents[sid] === undefined) {
      api
        .getEvents(workspace.id, sid)
        .then((r) => setSessionEvents((p) => ({ ...p, [sid]: r.events })))
        .catch(() => {});
    }
  };
  // Open a fresh agent session in this workspace — a new conversation on the same
  // worktree/branch with its own --resume thread. Client-owned until the first run
  // creates it backend-side (the run's session_id is what persists the transcript).
  const addSession = () => {
    const id = nextSessionId(sessions);
    setSessions((prev) => mergeSession(prev, id));
    setSessionEvents((prev) => ({ ...prev, [id]: [] }));
    setSessionTab(id);
    focusComposer();
  };

  const updateComment = (id: string, text: string) =>
    setComments((prev) => prev.map((c) => (c.id === id ? { ...c, text } : c)));
  const removeComment = (id: string) => setComments((prev) => prev.filter((c) => c.id !== id));
  // "Send to backlog" (backlog/backlog-v2.md Move 3): queue a review comment as a
  // follow-up item instead of re-tasking the current agent right now.
  const sendCommentToBacklog = (c: ReviewComment) => {
    if (!workspace) return;
    const title = c.text.trim() || c.target;
    const evidence = [c.target, c.context?.split("\n")[0]].filter(Boolean).join(": ");
    api
      .addTodoItem(workspace.project_id, title, evidence)
      .then(() => {
        removeComment(c.id);
        pushToast("success", "Sent to backlog/follow-ups.md");
      })
      .catch((e) => setError(e?.message ?? "failed to send to backlog"));
  };
  const sendReview = guard(async () => {
    if (!workspace || comments.length === 0) return;
    const body = comments
      .map((c, i) => {
        let s = `${i + 1}. [${c.target}] ${c.text.trim() || "(fix this)"}`;
        if (c.context) s += `\n   context: ${c.context.split("\n")[0]}`;
        return s;
      })
      .join("\n");
    const composed = `Address these review comments by editing files in this worktree, then make sure the tests pass:\n\n${body}`;
    setComments([]);
    // Echo the composed prompt into the stream instead of wiping it: the agent
    // resumes the same session (last_session_id), so the transcript should
    // continue as a conversation, not reset to blank. (Mirrors sendTask.)
    setEvents((prev) => [
      ...prev,
      { run_id: "user", workspace_id: workspace.id, ts: Date.now() / 1000, type: "user", payload: { text: composed } },
    ]);
    setWsStatus("agent_running");
    const { adapter, model, effort } = runArgs(optsRef.current);
    // Follow-up implementation turn (no plan); still honour the composer's Fast toggle.
    // Roles force claude-code regardless of a stale "local" backend pick (same reasoning
    // as sendTask's effectiveBackend — the composer hides the backend switch while on).
    const effectiveBackend = optsRef.current.rolesEnabled ? "claude-code" : optsRef.current.backend;
    const useFast = optsRef.current.fastMode && effectiveBackend !== "local";
    await api.startAgent(
      workspace.id, composed, adapter, model, effort, false, useFast, undefined, "build",
    );
  });

  const measureCoverage = guard(async () => {
    if (!workspace) return;
    setAnalyzing("coverage");
    try {
      setCoverage(await api.getCoverage(workspace.id));
    } finally {
      setAnalyzing(null);
    }
  });
  const checkFlaky = guard(async () => {
    if (!workspace) return;
    setAnalyzing("flaky");
    try {
      setFlaky(await api.runFlaky(workspace.id, 5));
    } finally {
      setAnalyzing(null);
    }
  });

  // Mutation scoring joins the same `analyzing` flag coverage/flaky use, but keeps its
  // OWN error state rather than `guard()`'s global banner: GatePanel's contextual
  // "scoring didn't run" card (with the actual message) is worth more than a generic
  // top-of-page error for a tool this deep in the ③ page.
  const runMutation = async () => {
    if (!workspace) return;
    setAnalyzing("mutation");
    setMutationError(null);
    try {
      setMutation(await api.runMutation(workspace.id));
    } catch (e) {
      setMutationError(e instanceof Error ? e.message : String(e));
    } finally {
      setAnalyzing(null);
    }
  };
  // A new gate run invalidates a stale score — same rule the old GatePanel-local
  // state applied, just lifted here so it also invalidates the rail's look-at count.
  useEffect(() => {
    setMutation(null);
    setMutationError(null);
  }, [test?.workspace_id, test?.ended_at]);

  // On-demand refuter re-run (Phase 3, Zone 4's "refute now"): joins the same
  // `analyzing` flag coverage/flaky/mutation use. Advisory only — it updates the
  // displayed `test.review` verdict but never `review_blocked`, which only a real
  // gate run (gate.run_gate) can set; re-running this can't retroactively unblock
  // (or block) a ship the gate already decided. A "couldn't run" result (CLI missing,
  // empty diff, unparseable output) surfaces through the same top-of-page banner every
  // other action uses (via `guard`), since there's no dedicated result panel for it
  // the way coverage/flaky/mutation each have.
  const runRefuter = guard(async () => {
    if (!workspace) return;
    setAnalyzing("refuter");
    try {
      const result = await api.runReview(workspace.id);
      if ("verdict" in result) {
        setTest((t) => (t ? { ...t, review: result } : t));
        if (result.error) throw new Error(result.error);
      } else if (result.error) {
        throw new Error(result.error);
      }
    } finally {
      setAnalyzing(null);
    }
  });


  // No runId → the default run (⌘R / command palette / preview button); a runId
  // starts/stops that named run from the Run menu.
  const runApp = guard(async (runId?: string) => {
    if (!workspace) return;
    await api.runApp(workspace.id, runId);
  });
  const stopApp = guard(async (runId?: string) => {
    if (!workspace) return;
    await api.stopApp(workspace.id, runId);
  });
  const rerunSetup = guard(async () => {
    if (!workspace) return;
    setSetup({ status: "running", exit: null, note: null });
    await api.rerunSetup(workspace.id);
  });

  // Win/⌘+R — run/stop the dev server, unless typing in a field.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey && (e.key === "r" || e.key === "R"))) return;
      const el = document.activeElement as HTMLElement | null;
      const typing =
        !!el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable);
      if (typing || !workspace) return;
      e.preventDefault();
      if (appRunning) stopApp();
      else runApp();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [appRunning, workspace?.id]);

  // Win/⌘+I — jump to the agent view and focus the "run agent" input.
  // (Not ⌘L — Linux window managers grab Super+L for screen-lock.)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey && (e.key === "i" || e.key === "I"))) return;
      if (!workspace) return;
      e.preventDefault();
      setMainView("agent");
      // Restart the one-shot glow: clear the class this frame, re-add next frame so
      // the CSS animation replays even on repeated presses. The composer is hidden
      // (not unmounted) off the agent view, so focus after the switch paints too.
      window.clearTimeout(composerFlashTimer.current);
      setComposerFlash(false);
      requestAnimationFrame(() => {
        const ta = document.getElementById("agent-input") as HTMLTextAreaElement | null;
        ta?.focus();
        setComposerFlash(true);
        composerFlashTimer.current = window.setTimeout(() => setComposerFlash(false), 1800);
      });
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspace?.id]);

  // Win/⌘+Enter — run (or queue) the current task from ANYWHERE, not just while
  // the prompt is focused (⌘I focuses it; ⌘↵ fires it). Mirrors the composer's own
  // ⌘/Ctrl+Enter, which stops propagation so this window listener never double-fires
  // when the prompt already has focus. Plain Enter stays a newline in the textarea.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey && e.key === "Enter")) return;
      if (!workspace) return;
      e.preventDefault();
      submitTaskRef.current();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspace?.id]);

  // Ctrl+` — jump to the shell (VS Code's terminal shortcut; ⌘` is reserved by
  // macOS for window-cycling). Mirrors ⌘I: switch to the shell tab, focus the
  // xterm input, and flash the same green-gate glow so the eye finds where focus
  // landed. Restart the one-shot glow (clear this frame, re-add next) so repeated
  // presses replay the animation.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.ctrlKey && e.key === "`")) return;
      if (!workspace) return;
      e.preventDefault();
      const target = activeShellId();
      setTermTab(target);
      window.clearTimeout(termFlashTimer.current);
      setTermFlash(false);
      requestAnimationFrame(() => {
        termHandles.current.get(target)?.focus();
        setTermFlash(true);
        termFlashTimer.current = window.setTimeout(() => setTermFlash(false), 1800);
      });
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspace?.id]);

  // The shell the "claude" menu / focus hotkey should drive: the active one, or
  // the first shell when the dev-log pane is showing.
  const activeShellId = (): string => {
    const cur = termTabRef.current;
    return cur !== "log" && shellsRef.current.includes(cur) ? cur : shellsRef.current[0];
  };

  const addShell = () => {
    const id = newShellId();
    setShells((s) => [...s, id]);
    setTermTab(id);
    setFocusShellOnOpen(id); // user opened this shell on purpose — let it grab focus
  };

  // Closing the last shell never leaves the workspace shell-less: it respawns a
  // fresh PTY in place (new id → the Terminal remounts). Otherwise drop it and
  // fall back to the previous tab.
  const closeShell = (id: string) => {
    termHandles.current.delete(id);
    setShells((prev) => {
      if (prev.length <= 1) {
        const fresh = newShellId();
        setTermTab(fresh);
        setFocusShellOnOpen(fresh); // restarting the shell in place — keep focus here
        return [fresh];
      }
      const idx = prev.indexOf(id);
      const next = prev.filter((x) => x !== id);
      setTermTab((cur) => (cur === id ? next[Math.max(0, idx - 1)] : cur));
      return next;
    });
  };

  // "claude" menu → drop a command on the shell prompt. Switch to a shell tab
  // first (the PTY is always mounted but hidden on the dev-log tab, so it can't
  // take focus until visible), then a frame later type the command in.
  const runClaudeCmd = (insert: string) => {
    setClaudeMenuOpen(false);
    const target = activeShellId();
    setTermTab(target);
    requestAnimationFrame(() => termHandles.current.get(target)?.insert(insert));
  };

  // close the "claude" menu on an outside click
  useEffect(() => {
    if (!claudeMenuOpen) return;
    const onDown = (e: MouseEvent) => {
      if (!claudeMenuRef.current?.contains(e.target as Node)) setClaudeMenuOpen(false);
    };
    window.addEventListener("mousedown", onDown);
    return () => window.removeEventListener("mousedown", onDown);
  }, [claudeMenuOpen]);

  // keep the Dev log pinned to the newest line
  useEffect(() => {
    if (termTab === "log" && devLogRef.current) {
      devLogRef.current.scrollTop = devLogRef.current.scrollHeight;
    }
  }, [runLog, termTab]);

  // Esc exits terminal / stream fullscreen (only while one is expanded)
  useEffect(() => {
    if (!termFull && !streamFull) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      setTermFull(false);
      setStreamFull(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [termFull, streamFull]);

  // Esc closes the backlog overlay (separate effect: it's a modal over the whole
  // app, not scoped to the terminal/stream fullscreen case above).
  useEffect(() => {
    if (!showBacklogPanel) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setShowBacklogPanel(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [showBacklogPanel]);

  // Archive any workspace (not just the selected one — the sidebar ⋯ menu can
  // target any). Clears the main view only if the archived one was selected.
  const archiveWorkspace = (ws: Workspace) =>
    guard(async () => {
      await api.archiveWorkspace(ws.id);
      delete draftsRef.current[ws.id];
      setQueues((prev) => {
        const next = { ...prev };
        delete next[ws.id];
        return next;
      });
      if (workspace?.id === ws.id) {
        setTask("");
        setWorkspace(null);
      }
      await reloadWorkspaces(ws.project_id);
    })();

  // Untrack a project: backend archives all its worktrees, we drop it from view.
  const removeProject = (project: Project) =>
    guard(async () => {
      if (workspace?.project_id === project.id) {
        setTask("");
        setWorkspace(null);
      }
      await api.removeProject(project.id);
      await loadAll();
    })();

  // appbar / command-palette "archive": always acts on the selected workspace
  const archive = () => {
    if (workspace) archiveWorkspace(workspace);
  };

  // Repair a `broken` workspace (desynced worktree): archive the husk, then open
  // the new-workspace dialog for the same project so the user can recreate it.
  const archiveAndRecreate = guard(async () => {
    if (!workspace) return;
    const pid = workspace.project_id;
    await api.archiveWorkspace(workspace.id);
    delete draftsRef.current[workspace.id];
    setQueues((prev) => ({ ...prev, [workspace.id]: [] }));
    setTask("");
    setWorkspace(null);
    await reloadWorkspaces(pid);
    setNewWsFor(pid);
  });

  void addProject; // (unused placeholder kept out of the way)

  // command palette entries (rebuilt each render so they reflect current state)
  const commands: Command[] = [];
  commands.push({
    id: "settings",
    label: "Open settings",
    group: "app",
    run: () => openSettings(),
  });
  commands.push({
    id: "hotkeys",
    label: "Keyboard shortcuts",
    group: "app",
    run: () => setHotkeysOpen(true),
  });
  commands.push({
    id: "sidebar",
    label: sidebarOpen ? "Hide sidebar" : "Show sidebar",
    group: "app",
    run: () => setSidebarOpen((o) => !o),
  });
  if (selectedProject) {
    commands.push({
      id: "backlog",
      label: "Backlog",
      group: "project",
      run: () => setShowBacklogPanel(true),
    });
    commands.push({
      id: "backlog-next",
      label: "Start next backlog item",
      group: "project",
      run: () => {
        const pid = selectedProject.id;
        api
          .getTodo(pid)
          .then((t) => {
            const pending = t.files
              .flatMap((f) => f.items.map((it) => ({ ...it, file: f.path })))
              .find((it) => !it.done && !it.seeded_workspace);
            if (pending) {
              startTodoWorkspace(
                pid,
                pending.text,
                `${pending.body || pending.text}\n\nReference: ${pending.file}`,
                pending.seed_key,
              );
            } else {
              setShowBacklogPanel(true); // nothing obviously next — let them pick
            }
          })
          .catch(() => setShowBacklogPanel(true));
      },
    });
  }
  MONO_FONTS.forEach((f) =>
    commands.push({
      id: "font-" + f.family,
      label: `Coding font: ${f.label}${monoFont === f.family ? " ✓" : ""}`,
      group: "app",
      run: () => setMonoFont(f.family),
    })
  );
  if (workspace) {
    commands.push({ id: "v-agent", label: "Go to agent view", group: "view", run: () => setMainView("agent") });
    commands.push({
      id: "v-agent-full",
      label: "Toggle agent stream fullscreen",
      group: "view",
      run: () => {
        setMainView("agent");
        setStreamFull((f) => !f);
      },
    });
    commands.push({ id: "v-code", label: "Go to code view", group: "view", run: () => setMainView("code") });
    commands.push({
      id: "v-code-full",
      label: "Toggle editor fullscreen",
      group: "view",
      run: () => {
        setMainView("code");
        setCodeFull((f) => !f);
      },
    });
    commands.push({ id: "v-gate", label: "Go to gate view", group: "view", run: () => setMainView("gate") });
    commands.push({ id: "v-git", label: "Go to ship view", group: "view", run: () => setMainView("git") });
    commands.push({ id: "gate-all", label: "Run gate (all tests)", group: "gate", run: () => runGate() });
    commands.push({ id: "gate-impacted", label: "Run impacted tests", group: "gate", run: () => runImpacted() });
    commands.push({ id: "gate-failed", label: "Re-run failed tests only", group: "gate", run: () => runFailed() });
    if (wsStatus === "gate_green")
      commands.push({ id: "merge", label: "Merge (gate is green)", group: "ship", run: () => merge() });
    commands.push({
      id: "app",
      label: appRunning ? "Stop app" : "Run app",
      group: "app",
      run: () => (appRunning ? stopApp() : runApp()),
    });
    commands.push({ id: "archive", label: "Archive workspace", group: "workspace", run: () => archive() });
  }
  projects.forEach((p) =>
    (wsByProject[p.id] ?? []).forEach((w) =>
      commands.push({ id: "go-" + w.id, label: `Open ${w.name}`, group: p.name, run: () => selectWorkspace(w) })
    )
  );

  // The task-flow stepper (agent › code › ship). Its home is the agent-stream card
  // header (same row as the label + the model/effort badge); on the other views it
  // also renders as a slim standalone row so cross-view nav still works. Gate is
  // filtered out (it's the strip's gate stat, not a step) but stays in the flow.ts
  // truth model so the ship step still reads blocked/ready off it.
  const renderFlow = () => {
    const steps = flowSteps({
      status: wsStatus,
      hasEvents: events.length > 0,
      filesChanged: diff?.files_changed ?? 0,
      passed: test?.passed ?? 0,
      failed: test?.failed ?? 0,
      kind: workspace?.kind,
      // The Double Gate's second signal on ③ (backlog/double-gate.md §2). Read off the
      // run itself, tri-state preserved: `undefined` (no quality gate on this run) must
      // NOT collapse to "clean", so the step stays silent rather than claiming a pass.
      qualityStatus:
        test?.quality_findings == null
          ? null
          : test.quality_findings.length
            ? "findings"
            : "clean",
      qualityBlocking: (test?.quality_findings ?? []).filter((f) => f.blocking).length,
      // The rich inputs: the verify badge now reads the full run (a starred green, a
      // gate-error "didn't run", live x/y while running) via verdict.ts instead of a
      // bare pass/fail tally.
      run: test,
      cells,
    });
    return steps.map((s, i) => {
      const viewed = s.key === mainView;
      const title = s.badge ? `${s.label}: ${s.badge.text}` : s.label;
      return (
        <Fragment key={s.key}>
          <button
            className={"flow-step flow-" + s.state + (viewed ? " flow-viewed" : "")}
            aria-current={viewed ? "step" : undefined}
            title={title}
            onClick={() => {
              if (focusesFailures(s)) {
                focusGate("blockers");
              } else {
                setMainView(stepTarget(s));
              }
            }}
          >
            <span className="flow-num">{i + 1}</span>
            <span className="flow-label">{s.label}</span>
            {s.badge && <span className={"flow-badge tone-" + s.badge.tone}>{s.badge.text}</span>}
            {s.extra && <span className={"flow-badge tone-" + s.extra.tone}>{s.extra.text}</span>}
          </button>
          {i < steps.length - 1 && (
            <span
              className={"flow-conn" + (connectorDone(s) ? " flow-conn-done" : "")}
              aria-hidden="true"
            />
          )}
        </Fragment>
      );
    });
  };

  return (
    <div className="app">
      {costWarn && (
        <div className="cost-warn-banner" role="alert">
          <span>
            ⚠ <strong>{costWarn.name}</strong> has spent ${costWarn.total.toFixed(2)} on agents,
            over the ${costWarn.threshold.toFixed(2)} warning threshold.
          </span>
          <button className="ghost btn-icon" onClick={() => setCostWarn(null)} title="dismiss">
            <X />
          </button>
        </div>
      )}
      <header className="appbar">
        <button
          className="ghost side-toggle"
          onClick={() => setSidebarOpen((o) => !o)}
          title={sidebarOpen ? "hide sidebar" : "show sidebar"}
        >
          ☰
        </button>
        <button className="brand" onClick={goHome} title="All workspaces · cross-project triage">
          <HaroMark size={26} />
          haro.
        </button>
        <div className="north-star">no agent's work is mergeable until the gate is green</div>
        <div className="appbar-right">
          <UpdateBanner />
          <button
            className="ghost theme-toggle"
            onClick={() => setHotkeysOpen(true)}
            title="keyboard shortcuts"
            aria-label="keyboard shortcuts"
          >
            <Keyboard size={16} />
          </button>
          <button
            className="ghost theme-toggle"
            onClick={openSettings}
            title="settings · display, notifications, usage"
          >
            <Gear size={16} />
          </button>
        {workspace && (
          <div className="ws-crumb">
            <span className="ws-name">{workspace.name}</span>
            <span className="dim"> · {workspace.branch}</span>
            <button className="ghost" onClick={startRenameWs} title="rename workspace / branch">
              rename
            </button>
            <button className="ghost" onClick={archive}>
              archive
            </button>
          </div>
        )}
        </div>
      </header>

      {workspace && wsStatus === "broken" && (
        <div className="broken-banner">
          <span>
            ⚠ This workspace's worktree is broken (missing <code>.git</code>) but its branch
            still has unmerged work. It can't run agents or merge until repaired.
          </span>
          <button className="ghost" onClick={archiveAndRecreate}>
            Archive &amp; recreate
          </button>
        </div>
      )}

      <div className={"shell" + (sidebarOpen ? "" : " shell-collapsed")}>
        {sidebarOpen && (
          <div
            className="drawer-backdrop"
            onClick={() => setSidebarOpen(false)}
            aria-hidden="true"
          />
        )}
        {sidebarOpen && (
          <Sidebar
            projects={projects}
            wsByProject={wsByProject}
            expanded={expanded}
            selectedId={workspace?.id ?? null}
            selectedProjectId={selectedProjectId}
            draftIds={draftIds}
            onToggle={toggleProject}
            onSelectProject={selectProject}
            onSelect={selectWorkspace}
            onOpenPicker={() => setPickerOpen(true)}
            onNewWorkspace={(pid) => setNewWsFor(pid)}
            onArchiveWorkspace={archiveWorkspace}
            onRenameWorkspace={startRenameWs}
            onRemoveProject={removeProject}
            onOpenProjectSettings={(pid) => {
              setProjectSettingsTab("git");
              setProjectSettingsFor(pid);
              closeDrawerOnMobile();
            }}
            onOpenBacklog={(pid) => {
              selectProject(pid);
              setShowBacklogPanel(true);
              closeDrawerOnMobile();
            }}
            onOpenSettings={() => {
              openSettings();
              closeDrawerOnMobile();
            }}
          />
        )}

        {!workspace ? (
          selectedProject ? (
            <ProjectDashboard
              project={selectedProject}
              workspaces={wsByProject[selectedProject.id] ?? []}
              onSelectWorkspace={selectWorkspace}
              onNewWorkspace={() => setNewWsFor(selectedProject.id)}
              onStartTodo={(title, task, seedKey) =>
                startTodoWorkspace(selectedProject.id, title, task, seedKey)
              }
              onStartMany={(items) => startManyTodoWorkspaces(selectedProject.id, items)}
              onRemoteChanged={(url) =>
                setProjects((ps) =>
                  ps.map((p) => (p.id === selectedProject.id ? { ...p, remote_url: url } : p))
                )
              }
              backlogNonce={backlogNonces[selectedProject.id] ?? 0}
              races={races[selectedProject.id] ?? []}
              onPurgeRaceLosers={purgeRaceLosers}
              onStopRace={stopRace}
              purgingRace={purgingRace}
              onBulkArchive={planBulkArchive}
            />
          ) : (
            <Dashboard
              workspaces={projects.flatMap((p) =>
                (wsByProject[p.id] ?? []).map((w) => ({ ...w, projectName: p.name }))
              )}
              onSelect={selectWorkspace}
              onOpenUsage={openUsage}
              // Global triage sees every project's races, so a fan-out you kicked off
              // and navigated away from still reports its verdict where you'll look.
              races={Object.values(races).flat()}
              onPurgeRaceLosers={purgeRaceLosers}
              onStopRace={stopRace}
              purgingRace={purgingRace}
              onBulkArchive={planBulkArchive}
            />
          )
        ) : (
          <div className={"bento bento-pane-" + mobilePane + (wsStatus === "merged" ? " bento-merged" : "")}>
            {/* TOP — workspace identity + deps (the gate's precondition). The gate
                verdict/count now lives on the ③ verify step in the flow stepper, so
                it's no longer duplicated here. */}
            <div className="stats-strip">
              {/* name · branch — the desktop home of the crumb (on mobile the strip
                  is hidden and the appbar crumb carries this instead). */}
              <span className="strip-ws" title={`${workspace.name} · ${workspace.branch}`}>
                <span className="ws-name">{workspace.name}</span>
              </span>
              {/* This workspace is a race lane — say so, and offer the way back to the
                  scorecard. You're looking at the winner precisely because a judge
                  picked it, so "why did this win?" has to be one click away
                  (backlog/winner-fanout.md §3). */}
              {(() => {
                const laneRace = projectRaces.find((r) => r.id === workspace.race_id);
                if (!laneRace) return null;
                const head = raceHeadline(laneRace);
                return (
                  <button
                    className={"race-chip race-chip-" + head.tone + " clickable"}
                    onClick={() => {
                      setWorkspace(null);
                      setSelectedProjectId(workspace.project_id);
                    }}
                    title={`${head.text} — open the scorecard`}
                  >
                    {laneRace.winner_id === workspace.id ? "race winner" : "race lane"} ↗
                  </button>
                );
              })()}
              <span className="stat-div" />
              {/* deps (setup) — the gate's precondition. A red gate from missing
                  deps is diagnosable here; click to re-run setup. */}
              <span
                className={
                  "stat stat-setup setup-" +
                  (setup?.status ?? "unknown") +
                  (setup?.status !== "running" && !busy ? " clickable" : "")
                }
                title={
                  setup?.status === "ok"
                    ? "Dependencies are ready: setup ran cleanly. Click to re-run."
                    : setup?.status === "failed"
                      ? `Setup failed${setup.exit != null ? ` (exit ${setup.exit})` : ""}${
                          setup.note ? ` · ${setup.note}` : ""
                        }. A red gate may be due to missing deps. Click to re-run.`
                      : setup?.status === "running"
                        ? "Setting up the workspace (installing dependencies)…"
                        : "Setup hasn't run yet. Click to run it."
                }
                onClick={setup?.status === "running" || busy ? undefined : rerunSetup}
              >
                <span className="stat-k">deps</span>
                <span className="stat-v">
                  {setup?.status === "ok" ? (
                    <>
                      <span className="stat-dot">●</span>ready
                    </>
                  ) : setup?.status === "failed" ? (
                    <>
                      <span className="stat-dot">●</span>failed <Refresh size={11} />
                    </>
                  ) : setup?.status === "running" ? (
                    "setting up…"
                  ) : (
                    "—"
                  )}
                </span>
              </span>
              <span className="strip-actions">
                <button className="ghost" onClick={startRenameWs} title="Rename this workspace and its git branch.">
                  rename
                </button>
                <button className="ghost strip-archive" onClick={archive} title="Archive this workspace. Tears down its worktree.">
                  archive
                </button>
              </span>
            </div>

            {/* MAIN — the task flow: agent › code › gate › ship. A stepper, not a
                wizard: every step is freely clickable. Each step's state reflects
                *real* workspace truth (agent output, diff, gate verdict) — see
                flow.ts — so the flow only looks resolved once the gate is green;
                which step is on-screen is a separate "viewed" marker. */}
            <div className="area-main">
              {/* The whole main column is ONE bordered surface (.main-stage): a
                  shared top steps band + the active step's body. Clicking a step
                  swaps only the body — the stepper stays put as a seamless top band,
                  so agent/code/gate/ship read as one continuous grid rather than
                  separate cards with the stepper floating above them. */}
              <div className="main-stage">
                <div className="stage-steps">
                  <div className="task-flow">
                    {renderFlow()}
                    {/* Post-merge "keep going" shortcut, mirrored out of the ④ ship
                        view so a merged workspace can branch again without navigating
                        back to step ④. Same handler as GitPanel's button. */}
                    {wsStatus === "merged" && (
                      <button
                        className="flow-continue"
                        onClick={continueWork}
                        disabled={continuing}
                        title="continue on a new branch off the updated base, keeping this chat"
                      >
                        {continuing ? (
                          <>
                            <span className="spinner" aria-hidden /> Continuing…
                          </>
                        ) : (
                          <>
                            <svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor" aria-hidden>
                              <path d="M9.5 3.25a2.25 2.25 0 1 1 3 2.122V6A2.5 2.5 0 0 1 10 8.5H6a1 1 0 0 0-1 1v1.128a2.251 2.251 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.5 0v1.836A2.493 2.493 0 0 1 6 7h4a1 1 0 0 0 1-1v-.628A2.25 2.25 0 0 1 9.5 3.25ZM4.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5ZM3.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Zm8.25-.75a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z" />
                            </svg>
                            Continue on a new branch
                          </>
                        )}
                      </button>
                    )}
                  </div>
                </div>
                <div className="stage-body">

              {/* agent view: stream, review, prompt folded into ONE surface
                  (.agent-console), sectioned by hairline dividers instead of three
                  separate floating cards (minimalist). */}
              <div className="main-view main-agent" style={{ display: mainView === "agent" ? "flex" : "none" }}>
                {streamFull && <div className="card-backdrop" onClick={() => setStreamFull(false)} />}
                <div className={"agent-console" + (streamFull ? " card--full" : "")}>
                <section className="console-sec stream-card">
                  {/* label on the left; model·effort badge + running pulse on the
                      right. The stepper is no longer in this header — it's the shared
                      top band of the stage now. */}
                  <div className="card-head">
                    {/* Session switcher (like the shell-tab strip): each tab is a
                        separate agent conversation on the same worktree; "+" opens a
                        fresh one. Live streams route here by the envelope's session_id. */}
                    <span className="stream-sessions">
                      {sessions.map((id) => (
                        <button
                          key={id}
                          className={"seg2 stream-session-tab" + (sessionTab === id ? " on" : "")}
                          onClick={() => selectSession(id)}
                          title={`switch to ${sessionLabel(sessions, id)}`}
                        >
                          {sessionLabel(sessions, id)}
                        </button>
                      ))}
                      <button
                        className="seg2 stream-session-add"
                        onClick={addSession}
                        title="new agent session · same worktree, separate conversation"
                        aria-label="new agent session"
                      >
                        <Plus size={13} />
                      </button>
                    </span>
                    <span className="card-head-right">
                      <StreamMeta events={events} model={model} effort={effort} />
                      {wsStatus === "agent_running" && <span className="pulse">running…</span>}
                      <button
                        className="ghost btn-icon btn-full"
                        onClick={() => setStreamFull((f) => !f)}
                        title={streamFull ? "exit fullscreen (Esc)" : "fullscreen agent stream"}
                        aria-label={streamFull ? "exit fullscreen" : "fullscreen agent stream"}
                      >
                        {streamFull ? <Minimize /> : <Maximize />}
                      </button>
                    </span>
                  </div>
                  <AgentStream
                    events={events}
                    running={wsStatus === "agent_running"}
                    queued={queues[workspace.id] ?? []}
                    onOpenFile={openInCode}
                    onRewind={rewindTo}
                    onUnqueue={(i) =>
                      setQueues((prev) => ({
                        ...prev,
                        [workspace.id]: (prev[workspace.id] ?? []).filter((_, j) => j !== i),
                      }))
                    }
                  />
                </section>
                {/* Plan approval — a finished plan run is the review gate before any
                    file edit. Approve re-runs the same session in auto-edit; feedback
                    is another plan turn. Never auto-runs (mirrors the conflict handoff). */}
                {awaitingPlan && (
                  <section className="plan-approve">
                    <div className="plan-approve-lead">
                      <span className="plan-approve-badge">plan</span>
                      <span className="plan-approve-text">
                        Review the plan above, then approve to implement it (re-runs this
                        session with edits enabled), or send feedback to refine it first.
                      </span>
                    </div>
                    <div className="plan-approve-actions">
                      <button className="ghost" onClick={feedbackPlan} title="Send a follow-up in plan mode to refine the approach (uses the prompt below)">
                        Give feedback
                      </button>
                      <button className="primary" onClick={approvePlan} title="Implement the plan. Re-runs this session with file edits enabled">
                        Approve → implement
                      </button>
                    </div>
                  </section>
                )}
                <Suspense fallback={null}>
                  <ReviewPanel
                    comments={comments}
                    busy={busy}
                    onUpdate={updateComment}
                    onRemove={removeComment}
                    onSend={sendReview}
                    onSendToBacklog={sendCommentToBacklog}
                  />
                </Suspense>
                <section
                  className={
                    "composer console-sec" +
                    (seededWsId === workspace.id ? " composer-seeded" : "") +
                    (composerFlash ? " composer-flash" : "")
                  }
                >
                  <div className="card-head">
                    <span>prompt</span>
                    <span className="dim">
                      runs in this worktree <span className="kbd"><CommandKey />I</span> to focus
                    </span>
                  </div>
                  {(attachments[workspace.id]?.length ?? 0) > 0 && (
                    <div className="composer-attachments">
                      {(attachments[workspace.id] ?? []).map((a) => (
                        <span key={a.path} className={"file-chip attach-chip" + (a.kind === "image" ? " attach-chip-img" : "")}>
                          <button
                            type="button"
                            className="attach-open"
                            onClick={() => openInCode(a.path)}
                            title={`open ${a.path}`}
                          >
                            {a.kind === "image" ? (
                              <img className="attach-thumb" src={api.rawUrl(workspace.id, a.path)} alt={a.name} />
                            ) : (
                              <FileIcon path={a.path} size={14} />
                            )}
                            <span className="file-chip-name">{a.name}</span>
                            <span className="file-chip-stat attach-lines">{attachmentStat(a)}</span>
                          </button>
                          <button
                            type="button"
                            className="attach-x"
                            onClick={() => removeAttachment(a.path)}
                            title="remove attachment"
                          >
                            ×
                          </button>
                        </span>
                      ))}
                    </div>
                  )}
                  <TaskComposer
                    value={task}
                    onChange={setTask}
                    onSubmit={submitTask}
                    workspaceId={workspace.id}
                    onAttachPaste={attachPaste}
                    onAttachFiles={attachFiles}
                    prBaseUrl={prBaseUrl}
                    dictateFocusRef={micToggleRef}
                    placeholder="Describe a task for the agent…  (/ for commands, @ for files, ``` for a code block, ⌘↵ to send · paste text or an image to attach it as a file, or use 📎 · it edits the worktree; the gate runs when it's done)"
                    rows={5}
                  />
                  <div className="composer-actions">
                    {/* Config row — everything that decides HOW the run happens
                        (model/roles, plan-vs-fast, race). Grouped above the io row so
                        the two questions ("how is this run configured" vs "go") don't
                        compete at the same visual weight. */}
                    <div className="composer-config-row">
                      {roles?.enabled ? (
                        // Role strip (notes/workflow-roles-plan.md): replaces the model/effort
                        // pickers so approving a plan can't silently build at the plan's model —
                        // the picker-forgetting trap this feature exists to close. Click → Roles tab.
                        <button
                          type="button"
                          className="composer-opt composer-role-strip"
                          onClick={() => {
                            setProjectSettingsTab("roles");
                            setProjectSettingsFor(workspace.project_id);
                          }}
                          title="Roles are on — model/effort come from the Roles tab, not this picker. Click to edit."
                        >
                          {stripSteps(roles, planFirst).map((s, i) => (
                            <span
                              key={s.step}
                              className={"role-strip-step" + (s.active ? " role-strip-step-active" : "")}
                            >
                              {i > 0 && <span className="role-strip-sep" aria-hidden="true">›</span>}
                              {s.step} <span className="role-strip-label">{s.label}</span>
                            </span>
                          ))}
                        </button>
                      ) : (
                        <>
                          {(() => {
                            const hasLocalList = localModels.reachable && localModels.models.length > 0;
                            return (
                              <select
                                className="composer-opt"
                                value={comboValue(backend, model, localModel, hasLocalList)}
                                onChange={(e) => {
                                  const v = e.target.value;
                                  if (v.startsWith("local:")) {
                                    setBackend("local");
                                    const tag = v.slice("local:".length);
                                    if (tag && tag !== "__manual__") setLocalModel(tag);
                                  } else {
                                    setBackend("claude-code");
                                    setModel(v.slice("cc:".length));
                                  }
                                }}
                                title="Model to run this task. Pick a Claude Code model (cloud) or a local model (Ollama / llama.cpp). The model determines the backend."
                              >
                                <optgroup label="Claude Code">
                                  <option value="cc:default">auto (sonnet)</option>
                                  <option value="cc:opus">opus</option>
                                  <option value="cc:sonnet">sonnet</option>
                                  <option value="cc:haiku">haiku</option>
                                  <option value="cc:fable">fable</option>
                                </optgroup>
                                <optgroup label="Local · Ollama · llama.cpp">
                                  {hasLocalList ? (
                                    localModels.models.map((m) => (
                                      <option key={m} value={`local:${m}`}>
                                        {m}
                                      </option>
                                    ))
                                  ) : (
                                    <option value="local:__manual__">type a tag…</option>
                                  )}
                                </optgroup>
                              </select>
                            );
                          })()}
                          {backend === "local" && !(localModels.reachable && localModels.models.length > 0) && (
                            <input
                              className="composer-opt"
                              type="text"
                              value={localModel}
                              onChange={(e) => setLocalModel(e.target.value)}
                              placeholder="model tag (e.g. qwen2.5-coder)"
                              title="Local model tag: the server couldn't be reached, so type the tag manually"
                            />
                          )}
                          {backend === "claude-code" && (
                            <select
                              className="composer-opt"
                              value={effort}
                              onChange={(e) => setEffort(e.target.value)}
                              title="Reasoning-effort budget for the session"
                            >
                              <option value="default">effort: default</option>
                              <option value="low">low</option>
                              <option value="medium">medium</option>
                              <option value="high">high</option>
                              <option value="xhigh">xhigh</option>
                              <option value="max">max</option>
                            </select>
                          )}
                        </>
                      )}
                      {(backend === "claude-code" || roles?.enabled) && (
                        <>
                          {/* Plan first — the run proposes a plan and edits nothing
                              until approved. Claude Code only (local has no plan mode).
                              Mutually exclusive with Fast (enabling one clears the other). */}
                          <button
                            type="button"
                            className={"composer-opt composer-plan" + (planFirst ? " composer-plan-on" : "")}
                            onClick={() => setPlanFirst((p) => { if (!p) setFastMode(false); return !p; })}
                            aria-pressed={planFirst}
                            title="Plan first: the agent proposes a plan and edits nothing until you approve it. The plan is the review gate before any file edit."
                          >
                            <span className="composer-plan-dot" aria-hidden="true" />
                            plan first
                          </button>
                          {/* Fast — "speed over depth" for narrow edits / quick follow-ups.
                              Claude Code only; mutually exclusive with Plan first. */}
                          <button
                            type="button"
                            className={"composer-opt composer-fast" + (fastMode ? " composer-fast-on" : "")}
                            onClick={() => setFastMode((f) => { if (!f) setPlanFirst(false); return !f; })}
                            aria-pressed={fastMode}
                            title="Fast: speed over depth for narrow edits and quick follow-ups (runs Opus in fast mode). Mutually exclusive with Plan first."
                          >
                            <span className="composer-fast-dot" aria-hidden="true" />
                            fast
                          </button>
                        </>
                      )}
                      {/* Race ×N — fan this exact prompt across the project's lane grid
                          and let the merge-blocking gate rank the winner, so you review
                          ONE diff plus a scorecard (backlog/winner-fanout.md §3). It sits
                          beside the model/effort pickers because a race IS a sweep over
                          those two knobs. Disabled — with the §0 refusal as its tooltip —
                          until the project can actually afford to race. */}
                      <button
                        type="button"
                        className="composer-opt composer-race"
                        onClick={() => raceTask()}
                        disabled={raceBtn.disabled || racing || busy || backend === "local"}
                        title={
                          backend === "local"
                            ? // Lanes are (model, reasoning effort) points — a Claude concept. Racing a
                              // local model against itself would measure sampling noise, and silently
                              // running three CLOUD lanes for someone who picked the no-cloud backend
                              // would be a cost surprise. So: disabled, and it says why.
                              "races run Claude Code lanes (model × reasoning effort); switch the backend off Local to race this task"
                            : busy
                            ? "an agent is running in this workspace: a race seeds its own sibling workspaces, so let this one settle first"
                            : raceBtn.title
                        }
                      >
                        <span className="composer-race-dot" aria-hidden="true" />
                        {racing ? "racing…" : raceBtn.label}
                      </button>
                    </div>
                    {/* Io row — attach/dictate on the left, budget + go on the right.
                        Kept separate from the config row above so "what this run will
                        do" doesn't visually compete with "how it's configured". */}
                    <div className="composer-io-row">
                      <input
                        ref={fileInputRef}
                        type="file"
                        multiple
                        hidden
                        onChange={(e) => {
                          const picked = Array.from(e.target.files ?? []);
                          if (picked.length) attachFiles(picked);
                          e.target.value = ""; // let the same file be re-picked
                        }}
                      />
                      <button
                        className="composer-opt composer-clip"
                        onClick={() => fileInputRef.current?.click()}
                        title="attach a file, image, or media for the agent to read"
                        aria-label="attach a file"
                      >
                        <Paperclip />
                      </button>
                      <button
                        className="composer-opt composer-mic"
                        onClick={() => micToggleRef.current?.()}
                        title={`voice dictation is your OS's, not haro's: ${DICTATION_HINT}`}
                        aria-label="focus the composer for voice dictation"
                      >
                        <Mic />
                      </button>
                      <span className="composer-spacer" />
                      {(backend === "claude-code" || roles?.enabled) && (
                        <ContextMeter events={events} model={model} />
                      )}
                      {wsStatus === "agent_running" && (
                        <button className="danger" onClick={stopAgent}>
                          stop
                        </button>
                      )}
                      <button
                        className="primary"
                        onClick={submitTask}
                        disabled={!task.trim() && (attachments[workspace.id]?.length ?? 0) === 0}
                      >
                        {composerButtonLabel(wsStatus)} <span className="kbd"><CommandKey /><Return /></span>
                      </button>
                    </div>
                  </div>
                </section>
                </div>
              </div>

              {/* code view */}
              <div className="main-view" style={{ display: mainView === "code" ? "flex" : "none" }}>
                {codeFull && <div className="card-backdrop" onClick={() => setCodeFull(false)} />}
                <section className={"card code-card" + (codeFull ? " card--full" : "")}>
                  <Suspense fallback={null}>
                    <CodePanel
                      workspaceId={workspace.id}
                      theme={`${theme}-${mode}`}
                      onSaved={refreshDiff}
                      fullscreen={codeFull}
                      onToggleFullscreen={() => setCodeFull((f) => !f)}
                      openRequest={codeOpen}
                      refreshSignal={codeNonce}
                      viewActive={mainView === "code"}
                    />
                  </Suspense>
                </section>
              </div>

              {/* git view */}
              <div className="main-view" style={{ display: mainView === "git" ? "flex" : "none" }}>
                <section className="card git-card">
                  <div className="card-head">
                    <span>ship</span>
                    <span className="dim">pull request</span>
                  </div>
                  <Suspense fallback={null}>
                    <GitPanel
                      key={workspace.id}
                      workspaceId={workspace.id}
                      onCommitted={refreshDiff}
                      gateStatus={wsStatus}
                      onMerge={merge}
                      merging={merging}
                      onContinue={continueWork}
                      continuing={continuing}
                      priorPrs={workspace.prior_prs ?? []}
                      seedKey={workspace.seed_key}
                      diff={diff}
                      onRefreshDiff={refreshDiff}
                      onAddComment={addComment}
                      onResolveConflict={resolveConflictWithAI}
                      trust={trust}
                      onTrustFix={shipTrustFix}
                      verified={verified}
                      onReviewResidue={reviewResidue}
                      receipt={receipt}
                    />
                  </Suspense>
                </section>
              </div>

              {/* gate view — the "verify" step and the whole point: the test gate
                  (live grid, impact map, coverage, flaky, regression ribbon). The
                  flow resolves here; ④ ship stays blocked until it's green. */}
              <div className="main-view main-gate" style={{ display: mainView === "gate" ? "flex" : "none" }}>
                <GatePanel
                  key={workspace.id}
                  test={test}
                  cells={cells}
                  history={history}
                  impact={impact}
                  blame={blame}
                  coverage={coverage}
                  flaky={flaky}
                  analyzing={analyzing}
                  status={wsStatus}
                  busy={busy}
                  onRunGate={runGate}
                  onRunImpacted={runImpacted}
                  onRunFailed={runFailed}
                  onRefreshImpact={refreshImpact}
                  onCoverage={measureCoverage}
                  onFlaky={checkFlaky}
                  onAddComment={addComment}
                  onSendTestToBacklog={sendTestToBacklog}
                  onFixAll={fixAllFailures}
                  onRestoreTampered={restoreWeakenedTests}
                  onFixQuality={fixQualityFindings}
                  onFixReview={fixReviewFindings}
                  onKillSurvivors={killSurvivors}
                  onSendSurvivorsToBacklog={sendSurvivorsToBacklog}
                  onOpenGateSettings={() => {
                    setProjectSettingsTab("gate");
                    setProjectSettingsFor(workspace.project_id);
                  }}
                  gateFocus={gateFocus}
                  adopted={workspace.kind === "adopted"}
                  onReRunSetup={rerunSetup}
                  checkedKeys={workspace.checked_rows ?? []}
                  codeToCheck={{ enabled: gateCfg?.code_to_check !== "off" }}
                  onToggleChecked={toggleRowChecked}
                  onOpenFile={(file) => setCodeOpen({ path: file, nonce: Date.now() })}
                  onOpenShip={() => setMainView("git")}
                  onSendLookAt={sendLookAt}
                  onSendLookAtToBacklog={sendLookAtToBacklog}
                  mutation={mutation}
                  mutationError={mutationError}
                  onRunMutation={runMutation}
                  onRunRefuter={runRefuter}
                  refuting={analyzing === "refuter"}
                  canRefute={!!(roles?.enabled && roles.review)}
                />
              </div>
                </div>
              </div>
            </div>

            {/* SIDE — the app strip (run controls; the app itself opens in a real
                browser), the Live Gate's vital sign, a worktree shell below.
                We dropped the embedded preview iframe here on purpose
                (backlog/live-gate.md): a page rendered in a pane is the one thing Chrome
                does strictly better — devtools, responsive mode, extensions, profiles —
                so it never earned half the rail, while a continuously-maintained test
                verdict is the signal that gets *better* for being local and adjacent. The
                run capability is untouched: named runs, per-workspace HARO_PORT, ⌘R, the
                dev log, the scripts editor. */}
            <div className="area-side">
              <section className="card app-strip">
                <div className="card-head">
                  <span>
                    app
                    {appRunning ? (
                      <span className="dim">
                        {" · "}
                        <span className="app-live-dot" />
                        {appUrl ?? (workspace.port != null ? `:${workspace.port}` : "running")}
                      </span>
                    ) : (
                      <span className="dim">
                        {" · idle"}
                        {workspace.port != null && ` · :${workspace.port}`}
                      </span>
                    )}
                  </span>
                  <span className="ph-actions">
                    {runList.length > 1 ? (
                      // Several named runs (web/worker/test) → a Run menu; each row
                      // starts/stops its run independently on its own port.
                      <span className="run-menu-wrap">
                        <button
                          className={"ghost btn-ico " + (anyRunning ? "btn-stop" : "btn-run")}
                          onClick={() => setRunMenuOpen((o) => !o)}
                          disabled={busy}
                          title="run menu"
                          aria-haspopup="menu"
                          aria-expanded={runMenuOpen}
                        >
                          {anyRunning ? <Square /> : <Play />} run <Chevron open={runMenuOpen} />
                        </button>
                        {runMenuOpen && (
                          <>
                            <div className="menu-backdrop" onClick={() => setRunMenuOpen(false)} />
                            <div className="ctx-menu run-menu" role="menu">
                              {runList.map((r) => {
                                const on = runStates[r.id]?.running ?? false;
                                const rurl = runStates[r.id]?.url ?? null;
                                return (
                                  <div className="run-menu-row" key={r.id}>
                                    <button
                                      className="ctx-item"
                                      role="menuitem"
                                      disabled={busy}
                                      onClick={() => (on ? stopApp(r.id) : runApp(r.id))}
                                    >
                                      {on ? <Square /> : <Play />}
                                      <span className="run-menu-name">
                                        {r.icon ? `${r.icon} ` : ""}
                                        {r.id}
                                        {r.default && <span className="dim"> · default</span>}
                                      </span>
                                      {on && <span className="run-menu-live" />}
                                    </button>
                                    {on && rurl && (
                                      <button
                                        className="ghost btn-icon"
                                        title="open in browser"
                                        aria-label="open in browser"
                                        onClick={() => window.open(rurl, "_blank", "noopener")}
                                      >
                                        <ExternalLink />
                                      </button>
                                    )}
                                  </div>
                                );
                              })}
                            </div>
                          </>
                        )}
                      </span>
                    ) : appRunning ? (
                      <button className="ghost btn-stop btn-icon" onClick={() => stopApp()} disabled={busy} title="stop (⌘R)" aria-label="stop dev server">
                        <Square />
                      </button>
                    ) : (
                      <button className="ghost btn-run btn-icon" onClick={() => runApp()} disabled={busy} title="run dev server (⌘R)" aria-label="run dev server">
                        <Play />
                      </button>
                    )}
                    {/* The app now opens in a real browser, so this is the strip's
                        primary action rather than an afterthought next to an iframe. */}
                    {appUrl && (
                      <button
                        className="ghost btn-ico btn-open-app"
                        onClick={() => window.open(appUrl, "_blank", "noopener")}
                        title="open the app in your browser"
                        aria-label="open the app in your browser"
                      >
                        <ExternalLink /> open
                      </button>
                    )}
                    {/* The Live Gate, demoted from a pane to a chip: its advisory verdict is
                        worth a glance in the hand-fix red→green loop, but it does not deserve
                        half the rail (backlog/code-to-check.md §3). Structurally cannot ship
                        anything — see gate.run_watch. */}
                    {watchEnabled && (
                      <span
                        className={"live-chip live-chip-" + watchVerdict(watchEnabled, watchCells, watchRun)}
                        title={
                          "live gate (advisory, impacted only). The ③ gate is the only verdict that can ship." +
                          (watchRun ? ` ${watchSummary(watchCells, watchRun)}` : "")
                        }
                      >
                        <span className="live-chip-dot" />
                        {watchRun ? watchSummary(watchCells, watchRun) : "watching"}
                      </span>
                    )}
                    <button
                      className="ghost btn-icon"
                      onClick={() => {
                        setProjectSettingsTab("setup");
                        setProjectSettingsFor(workspace.project_id);
                      }}
                      title="edit setup / dev commands in project settings. Every workspace inherits them"
                      aria-label="edit dev scripts"
                    >
                      <Gear size={13} />
                    </button>
                  </span>
                </div>
                {/* A strip stays one line unless there's something to say: a crashed dev
                    server, or no dev command configured yet (the discovery case). */}
                {runError ? (
                  <div className="app-strip-note run-error">
                    <strong>dev server exited</strong>
                    <span className="run-error-msg">{runError}</span>
                    <button className="link-btn" onClick={() => setTermTab("log")}>
                      open the Dev log →
                    </button>
                  </div>
                ) : !appRunning && !scripts?.run ? (
                  <div className="app-strip-note">
                    <span className="dim">No dev command set.</span>
                    <button
                      className="link-btn"
                      onClick={() => {
                        setProjectSettingsTab("setup");
                        setProjectSettingsFor(workspace.project_id);
                      }}
                    >
                      configure scripts →
                    </button>
                  </div>
                ) : null}
              </section>

              <AgentManagerCard events={events} running={wsStatus === "agent_running"} />

              {/* "Things to look at" moved into ③ itself (notes/verify-redesign-plan.md);
                  the rail keeps only a one-line deep-link back to it. */}
              <LookAtChip count={lookAtCount} onClick={() => setMainView("gate")} />
              {termFull && <div className="card-backdrop" onClick={() => setTermFull(false)} />}
              <section
                className={
                  "card term-card" + (termFull ? " card--full" : "") + (termFlash ? " term-flash" : "")
                }
              >
                <div className="card-head term-head">
                  {/* Pane tabs (grows with shells): dev log · shell 1 · shell 2 … · +.
                      Actions live on the right, contextual so the row stays calm. */}
                  <span className="term-tabs">
                    <button
                      className={"seg2" + (termTab === "log" ? " on" : "")}
                      onClick={() => setTermTab("log")}
                    >
                      dev log{appRunning ? " ●" : ""}
                    </button>
                    {shells.map((id, i) => (
                      <span
                        key={id}
                        className={"term-shell-tab" + (termTab === id ? " on" : "")}
                      >
                        <button
                          className={"seg2 term-shell-btn" + (termTab === id ? " on" : "")}
                          onClick={() => setTermTab(id)}
                        >
                          shell {i + 1}
                        </button>
                        <button
                          className="term-shell-x"
                          onClick={(e) => {
                            e.stopPropagation();
                            closeShell(id);
                          }}
                          title={shells.length > 1 ? "close shell" : "restart shell"}
                          aria-label={shells.length > 1 ? "close shell" : "restart shell"}
                        >
                          <X size={10} />
                        </button>
                      </span>
                    ))}
                    <button
                      className="seg2 term-add"
                      onClick={addShell}
                      title="new shell"
                      aria-label="new shell"
                    >
                      <Plus size={13} />
                    </button>
                  </span>
                  <span className="term-head-right">
                    {termTab !== "log" && (
                      <>
                        <span className="claude-menu" ref={claudeMenuRef}>
                          <button
                            className={"seg2 claude-menu-btn" + (claudeMenuOpen ? " on" : "")}
                            onClick={() => setClaudeMenuOpen((o) => !o)}
                            title="Run a claude command in the shell"
                            aria-haspopup="menu"
                            aria-expanded={claudeMenuOpen}
                          >
                            claude <Chevron open={claudeMenuOpen} />
                          </button>
                          {claudeMenuOpen && (
                            <div className="ctx-menu claude-pop" role="menu">
                              {CLAUDE_CMDS.map((c) => (
                                <button
                                  key={c.label}
                                  className="ctx-item claude-item"
                                  role="menuitem"
                                  onClick={() => runClaudeCmd(c.insert)}
                                >
                                  <span className="claude-item-label">{c.label}</span>
                                  <span className="claude-item-hint dim">{c.hint}</span>
                                </button>
                              ))}
                            </div>
                          )}
                        </span>
                        <span className="kbd term-focus-key" title="focus shell">
                          <Control />`
                        </span>
                      </>
                    )}
                    <BranchBadge branch={workspace.branch} />
                    <button
                      className="ghost btn-icon btn-full"
                      onClick={() => setTermFull((f) => !f)}
                      title={termFull ? "exit fullscreen (Esc)" : "fullscreen terminal"}
                      aria-label={termFull ? "exit fullscreen" : "fullscreen terminal"}
                    >
                      {termFull ? <Minimize /> : <Maximize />}
                    </button>
                  </span>
                </div>
                {/* Every shell stays mounted (its PTY persists) — inactive panes
                    are just hidden. Hosts N shells + the dev log. */}
                {shells.map((id) => (
                  <div
                    key={id}
                    className="term-body"
                    style={{ display: termTab === id ? "flex" : "none" }}
                  >
                    <Suspense fallback={null}>
                      <Terminal
                        ref={(h) => {
                          if (h) termHandles.current.set(id, h);
                          else termHandles.current.delete(id);
                        }}
                        workspaceId={workspace.id}
                        shellId={id}
                        theme={`${theme}-${mode}`}
                        autoFocus={id === focusShellOnOpen}
                      />
                    </Suspense>
                  </div>
                ))}
                <div
                  className="dev-log"
                  ref={devLogRef}
                  style={{ display: termTab === "log" ? "flex" : "none" }}
                >
                  {runLog.length ? (
                    runLog.map((l, i) => (
                      <div key={i} className="dev-log-line">
                        {l}
                      </div>
                    ))
                  ) : (
                    <div className="empty dim dev-log-empty">
                      No dev output yet. Run the app (⌘R) to stream logs here.
                    </div>
                  )}
                </div>
              </section>
            </div>
          </div>
        )}
      </div>

      {/* Mobile bottom nav — the primary way to move between surfaces on a phone,
          where the desktop bento can only show one column at a time. Hidden on
          desktop (display:none). Active tab derives from the flow view or which
          side pane is showing. */}
      {workspace && (
        <nav className="mobile-nav" aria-label="workspace views">
          {(() => {
            const active = mobilePane === "flow" ? mainView : mobilePane;
            const goFlow = (v: "agent" | "code" | "gate" | "git") => {
              setMobilePane("flow");
              setMainView(v);
            };
            // The top stats strip is hidden on mobile, so the gate glyph carries
            // the at-a-glance signal: green when the gate is passing, red when
            // failing, neutral otherwise — readable from any pane.
            const gateTone =
              wsStatus === "gate_green" ? "green" : wsStatus === "gate_red" ? "red" : "";
            const items: {
              key: string;
              label: string;
              glyph: string;
              on: boolean;
              tone?: string;
              run: () => void;
            }[] = [
              { key: "agent", label: "agent", glyph: "◇", on: active === "agent", run: () => goFlow("agent") },
              { key: "code", label: "code", glyph: "{ }", on: active === "code", run: () => goFlow("code") },
              { key: "gate", label: "gate", glyph: "●", on: active === "gate", tone: gateTone, run: () => goFlow("gate") },
              { key: "git", label: "ship", glyph: "▲", on: active === "git", run: () => goFlow("git") },
              // No "preview" tab any more (backlog/live-gate.md): the app opens in the
              // phone's own browser, and the rail's app strip + live gate ride along with
              // the terminal pane.
              { key: "terminal", label: "term", glyph: "❯", on: active === "terminal", run: () => setMobilePane("terminal") },
            ];
            return items.map((it) => (
              <button
                key={it.key}
                className={"mnav-btn" + (it.on ? " mnav-on" : "")}
                onClick={it.run}
                aria-current={it.on ? "page" : undefined}
              >
                <span
                  className={"mnav-glyph" + (it.tone ? " mnav-glyph-" + it.tone : "")}
                  aria-hidden="true"
                >
                  {it.glyph}
                </span>
                <span className="mnav-label">{it.label}</span>
              </button>
            ));
          })()}
        </nav>
      )}

      <CommandPalette open={cmdkOpen} commands={commands} onClose={() => setCmdkOpen(false)} />
      {hotkeysOpen && <HotkeysModal onClose={() => setHotkeysOpen(false)} />}
      {showBacklogPanel && selectedProject && (
        <div className="card-backdrop" onClick={() => setShowBacklogPanel(false)}>
          <div className="backlog-overlay-panel" onClick={(e) => e.stopPropagation()}>
            <button
              className="backlog-overlay-close ghost btn-icon"
              onClick={() => setShowBacklogPanel(false)}
              title="Close (Esc)"
              aria-label="Close backlog"
            >
              <X />
            </button>
            <Backlog
              projectId={selectedProject.id}
              projectName={selectedProject.name}
              statusKey={(wsByProject[selectedProject.id] ?? [])
                .map((w) => `${w.id}:${w.status}`)
                .sort()
                .join(",")}
              refreshSignal={backlogNonces[selectedProject.id] ?? 0}
              variant="panel"
              onStartTodo={(title, task, seedKey) => {
                startTodoWorkspace(selectedProject.id, title, task, seedKey);
                setShowBacklogPanel(false);
              }}
              onStartMany={(items) => {
                startManyTodoWorkspaces(selectedProject.id, items);
                setShowBacklogPanel(false);
              }}
              onOpenWorkspace={(wsId, stage) => {
                const ws = (wsByProject[selectedProject.id] ?? []).find((w) => w.id === wsId);
                if (ws) selectWorkspace(ws, stage);
                setShowBacklogPanel(false);
              }}
            />
          </div>
        </div>
      )}
      {archiveRun && (
        <ArchiveQueuePanel
          run={archiveRun}
          busy={archiveBusy}
          onToggleForce={replanBulkArchive}
          onConfirm={startBulkArchive}
          onStop={stopBulkArchive}
          onClose={() => archiveActions.close()}
        />
      )}
      <ToastHost toasts={toasts} prefs={toastPrefs} onDismiss={dismissToast} />
      {settingsOpen && (
        <Suspense fallback={null}>
          <SettingsModal
            theme={theme}
            setTheme={setTheme}
            notifPrefs={notifPrefs}
            setNotifPrefs={setNotifPrefs}
            toastPrefs={toastPrefs}
            setToastPrefs={setToastPrefs}
            initialTab={settingsTab}
            onClose={() => setSettingsOpen(false)}
          />
        </Suspense>
      )}
      {projectSettingsFor &&
        (() => {
          const proj = projects.find((p) => p.id === projectSettingsFor);
          if (!proj) return null;
          return (
            <Suspense fallback={null}>
              <ProjectSettingsModal
                project={proj}
                theme={`${theme}-${mode}`}
                initialTab={projectSettingsTab}
                onRemoteChanged={(url) =>
                  setProjects((ps) =>
                    ps.map((p) => (p.id === proj.id ? { ...p, remote_url: url } : p))
                  )
                }
                onDefaultBranchChanged={(branch) =>
                  setProjects((ps) =>
                    ps.map((p) => (p.id === proj.id ? { ...p, default_branch: branch } : p))
                  )
                }
                onAgentChanged={() => {
                  // re-seed the composer if the edited project is the one on screen
                  if (workspace && workspace.project_id === proj.id) seedAgentConfig(proj.id);
                }}
                onRolesChanged={() => {
                  if (workspace && workspace.project_id === proj.id) seedRolesConfig(proj.id);
                }}
                onClose={() => {
                  setProjectSettingsFor(null);
                  // scripts are project-level; re-read the current workspace's
                  // effective (inherited) config so the read-only preview reflects an edit.
                  if (workspace && workspace.project_id === proj.id) {
                    api.getScripts(workspace.id).then(applyScripts).catch(() => {});
                  }
                }}
              />
            </Suspense>
          );
        })()}
      {pickerOpen && (
        <AddProjectModal
          onPickExisting={(path, isGitRepo) => {
            setPickerOpen(false);
            if (isGitRepo) onAddProject(path);
            else setInitFor(path); // existing non-git folder → confirm `git init` first
          }}
          onCreateNew={onCreateNew}
          onClose={() => setPickerOpen(false)}
        />
      )}
      {initFor && (
        <InitRepoModal
          path={initFor}
          busy={initBusy}
          onConfirm={(remoteUrl) => confirmInit(remoteUrl)}
          onCancel={() => !initBusy && setInitFor(null)}
        />
      )}
      {stackFor && (
        <StackProposalModal
          projectName={stackFor.projectName}
          detection={stackFor.detection}
          onApply={async (presetId) => {
            await api.applyPreset(stackFor.projectId, presetId, "shared");
            setStackFor(null);
          }}
          onClose={() => setStackFor(null)}
        />
      )}
      {newWsFor && (
        <NewWorkspaceModal
          projectId={newWsFor}
          projectName={projects.find((p) => p.id === newWsFor)?.name ?? "project"}
          initialName={newWsSeed?.name ?? ""}
          onCreate={(name, baseRef, branch) => {
            const seedTask = newWsSeed?.task;
            const seedKey = newWsSeed?.seedKey;
            setNewWsFor(null);
            setNewWsSeed(null);
            onNewWorkspace(newWsFor, name, baseRef, branch, seedTask, seedKey);
          }}
          onClose={() => {
            setNewWsFor(null);
            setNewWsSeed(null);
          }}
        />
      )}
      {renamingWs && workspace && (
        <RenameWorkspaceModal
          workspace={workspace}
          onSave={saveRenameWs}
          onClose={() => setRenamingWs(false)}
        />
      )}
    </div>
  );
}
