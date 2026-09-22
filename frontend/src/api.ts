import type {
  AgentConfig,
  RolesConfig,
  LocalModelsResponse,
  InstructionsConfig,
  RemoteConfig,
  AgentEvent,
  AgentRun,
  ArchiveQueueRun,
  BlameResponse,
  CoverageResponse,
  DiffResponse,
  EnvConfig,
  FileNode,
  FlakyResponse,
  FsListing,
  GitCommit,
  GitStatusResponse,
  ImpactResponse,
  GateConfig,
  MergeQueueResult,
  MergeResult,
  PrStatusResponse,
  Project,
  RacePreflight,
  RaceRun,
  ReviewResult,
  ReviewVerdict,
  ScriptsConfig,
  StackDetection,
  TodoResponse,
  IssuesResponse,
  IssueDetailResponse,
  FirewallPosture,
  FirewallResult,
  SetupState,
  TestRun,
  TestScope,
  TrustReport,
  WatchState,
  TurnMarker,
  RewindResponse,
  UpdateStatus,
  UpdateProgress,
  UsageResponse,
  VerifiedHunksResponse,
  MutationResponse,
  ReceiptResponse,
  WorkflowConfig,
  Workspace,
} from "./types";

async function json<T>(res: Response): Promise<T> {
  if (!res.ok) {
    const body = await res.json().catch(() => ({ detail: res.statusText }));
    // FastAPI errors are usually {detail: "..."} but a 422 makes `detail` an ARRAY
    // of {loc,msg,type} — `new Error(array)` stringifies to "[object Object]", which
    // is what surfaced in the toast. Coerce anything non-string to a readable message.
    const d = body?.detail ?? body?.message;
    const msg =
      typeof d === "string"
        ? d
        : Array.isArray(d)
          ? d.map((e) => e?.msg || JSON.stringify(e)).join("; ")
          : d
            ? JSON.stringify(d)
            : `HTTP ${res.status}`;
    throw new Error(msg);
  }
  return res.json() as Promise<T>;
}

export const api = {
  listProjects: () => fetch("/projects").then(json<Project[]>),

  health: () => fetch("/health").then(json<{ ok: boolean }>),

  browseFs: (path?: string) =>
    fetch(`/fs${path ? `?path=${encodeURIComponent(path)}` : ""}`).then(json<FsListing>),

  listWorkspaces: (projectId: string) =>
    fetch(`/projects/${projectId}/workspaces`).then(json<Workspace[]>),

  getTodo: (projectId: string) =>
    fetch(`/projects/${projectId}/todo`).then(json<TodoResponse>),

  // Create or overwrite a backlog markdown file (in-app editor). `path` is
  // repo-relative + backlog-eligible (under backlog/ or a todo-named doc).
  putTodo: (projectId: string, path: string, content: string) =>
    fetch(`/projects/${projectId}/todo`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path, content }),
    }).then(json<{ ok: boolean; path: string }>),

  // "Send to backlog" (backlog/backlog-v2.md Move 3): append one follow-up line
  // from a ③ verify surface (a deferred failing test, a mutation survivor, an
  // untested hunk, a refuter finding, a review comment). Defaults to the fixed
  // backlog/follow-ups.md — omit `file` unless the caller has a real reason to
  // target a different backlog doc.
  addTodoItem: (projectId: string, title: string, evidence?: string, file?: string) =>
    fetch(`/projects/${projectId}/todo/items`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title, evidence: evidence ?? "", ...(file ? { file } : {}) }),
    }).then(json<{ ok: boolean; path: string }>),

  // `state` overrides the project's `[backlog] issue_state` default for this one
  // fetch; omit it to use the project's configured default. `mine` is tri-state —
  // `true`/`false` are explicit overrides (all/@me) that win over the project's
  // `issue_assignee` regardless of what it's set to; omit the key entirely (not
  // just falsy) to fall back to that config default instead.
  getIssues: (
    projectId: string,
    opts?: { refresh?: boolean; state?: "open" | "closed" | "all"; mine?: boolean },
  ) => {
    const params = new URLSearchParams();
    if (opts?.refresh) params.set("refresh", "1");
    if (opts?.state) params.set("state", opts.state);
    if (opts && "mine" in opts) params.set("mine", opts.mine ? "1" : "0");
    const qs = params.toString();
    return fetch(`/projects/${projectId}/issues${qs ? `?${qs}` : ""}`).then(json<IssuesResponse>);
  },

  getIssueDetail: (projectId: string, number: number) =>
    fetch(`/projects/${projectId}/issues/${number}`).then(json<IssueDetailResponse>),

  createProject: (
    path: string,
    opts?: { name?: string; init?: boolean; remoteUrl?: string }
  ) =>
    fetch("/projects", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        path,
        name: opts?.name,
        init: opts?.init ?? false,
        remote_url: opts?.remoteUrl || null,
      }),
    }).then(json<Project>),

  detectStack: (projectId: string) =>
    fetch(`/projects/${projectId}/detect-stack`).then(json<StackDetection>),

  // Confirm a stack preset from the propose-and-confirm UI → writes its
  // [scripts]+[gate] into the project's settings (shared by default).
  applyPreset: (projectId: string, presetId: string, target: "local" | "shared" = "shared") =>
    fetch(`/projects/${projectId}/apply-preset`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ preset_id: presetId, target }),
    }).then(json<{ ok: boolean; preset_id: string; target: string; path: string }>),

  mkdirFs: (parent: string, name: string) =>
    fetch("/fs/mkdir", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ parent, name }),
    }).then(json<{ path: string; name: string; parent: string }>),

  listBranches: (projectId: string) =>
    fetch(`/projects/${projectId}/branches`).then(json<{ branches: string[]; default: string }>),

  setDefaultBranch: (projectId: string, branch: string) =>
    fetch(`/projects/${projectId}/default-branch`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ branch }),
    }).then(json<Project>),

  getWorkflow: (projectId: string) =>
    fetch(`/projects/${projectId}/workflow`).then(json<WorkflowConfig>),

  setWorkflow: (
    projectId: string,
    merge_mode: WorkflowConfig["merge_mode"],
    target: "local" | "shared" = "shared"
  ) =>
    fetch(`/projects/${projectId}/workflow`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ merge_mode, target }),
    }).then(json<WorkflowConfig>),

  getGate: (projectId: string) =>
    fetch(`/projects/${projectId}/gate`).then(json<GateConfig>),

  setGate: (projectId: string, cfg: GateConfig, target: "local" | "shared" = "shared") =>
    fetch(`/projects/${projectId}/gate`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...cfg, target }),
    }).then(json<GateConfig>),

  getAgent: (projectId: string) =>
    fetch(`/projects/${projectId}/agent`).then(json<AgentConfig>),

  setAgent: (projectId: string, cfg: AgentConfig, target: "local" | "shared" = "shared") =>
    fetch(`/projects/${projectId}/agent`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...cfg, target }),
    }).then(json<AgentConfig>),

  getRoles: (projectId: string) =>
    fetch(`/projects/${projectId}/roles`).then(json<RolesConfig>),

  setRoles: (projectId: string, cfg: RolesConfig, target: "local" | "shared" = "shared") =>
    fetch(`/projects/${projectId}/roles`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...cfg, target }),
    }).then(json<RolesConfig>),

  getEnv: (projectId: string) =>
    fetch(`/projects/${projectId}/env`).then(json<EnvConfig>),

  setEnv: (projectId: string, content: string) =>
    fetch(`/projects/${projectId}/env`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content }),
    }).then(json<EnvConfig>),

  getRemote: (projectId: string) =>
    fetch(`/projects/${projectId}/remote`).then(json<RemoteConfig>),

  setRemote: (projectId: string, url: string) =>
    fetch(`/projects/${projectId}/remote`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ url }),
    }).then(json<RemoteConfig>),

  // Merge Firewall (backlog/merge-firewall.md §3). Arm with a posture; disarm is a
  // body-less, idempotent DELETE — the "uninstall is one command" guarantee (pure
  // file edits, safe when nothing is installed).
  installFirewall: (projectId: string, posture: FirewallPosture, strict = false) =>
    fetch(`/projects/${projectId}/firewall`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ firewall: posture, strict, backend_url: window.location.origin }),
    }).then(json<FirewallResult>),

  uninstallFirewall: (projectId: string) =>
    fetch(`/projects/${projectId}/firewall`, { method: "DELETE" }).then(json<FirewallResult>),

  pushProject: (projectId: string) =>
    fetch(`/projects/${projectId}/push`, { method: "POST" }).then(
      json<{ pushed: boolean; branch: string; detail: string }>
    ),

  pullProject: (projectId: string) =>
    fetch(`/projects/${projectId}/pull`, { method: "POST" }).then(
      json<{ pulled: boolean; branch: string; detail: string }>
    ),

  createWorkspace: (
    projectId: string,
    name: string,
    baseRef?: string,
    branch?: string,
    seedKey?: string,
  ) =>
    fetch(`/projects/${projectId}/workspaces`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        name,
        base_ref: baseRef ?? null,
        branch: branch || null,
        seed_key: seedKey ?? null,
      }),
    }).then(json<Workspace>),

  // --- Winner-only fan-out (backlog/winner-fanout.md) --------------------- //
  // §0's hard gate as a read-only dry run: may this project race, with which lanes,
  // under what ceiling? Never rejects — a refusal comes back in the payload, so the
  // composer can grey the button out AND say why, before anything is created.
  racePreflight: (projectId: string) =>
    fetch(`/projects/${projectId}/race/preflight`).then(json<RacePreflight>),

  // Fan one task out to N lanes. Resolves as soon as the sibling workspaces exist;
  // the agents, gates, judging and ceremony run in the background and stream over the
  // global feed as `notify`/`race_*`. A §0 refusal is a 400 listing every reason.
  startRace: (projectId: string, task: string, opts?: { name?: string; seedKey?: string }) =>
    fetch(`/projects/${projectId}/races`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        task,
        name: opts?.name ?? null,
        seed_key: opts?.seedKey ?? null,
      }),
    }).then(json<RaceRun>),

  getRaces: (projectId: string) => fetch(`/projects/${projectId}/races`).then(json<RaceRun[]>),

  getRace: (raceId: string) => fetch(`/races/${raceId}`).then(json<RaceRun>),

  // Cancel the remaining lanes. The supervisor still judges whatever finished — the
  // spend already happened, so hiding the result would be the worst of both.
  stopRace: (raceId: string) =>
    fetch(`/races/${raceId}/stop`, { method: "POST" }).then(json<RaceRun>),

  // The irreversible half of the loser afterlife: delete their branches + rows. Kept a
  // separate action from the ceremony's soft-archive on purpose.
  purgeRaceLosers: (raceId: string) =>
    fetch(`/races/${raceId}/purge-losers`, { method: "POST" }).then(json<{ purged: string[] }>),

  renameWorkspace: (wsId: string, patch: { name?: string; branch?: string }) =>
    fetch(`/workspaces/${wsId}`, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(patch),
    }).then(json<Workspace>),

  // `plan` requests a Plan-Mode run: the agent plans and edits nothing until the dev
  // approves, and the gate stays idle (no diff) — the review surface before any file
  // edit. `fast` requests Fast Mode ("speed over depth"; mutually exclusive with plan).
  // Only claude-code acts on either today; other adapters ignore them server-side
  // (feature-detected, never a hard error).
  startAgent: (
    wsId: string,
    task: string,
    adapter?: string,
    model?: string,
    effort?: string,
    plan?: boolean,
    fast?: boolean,
    sessionId?: string,
    role?: string,
  ) =>
    fetch(`/workspaces/${wsId}/agent`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        task, adapter, model, effort, plan, fast, session_id: sessionId, role,
      }),
    }).then(json<AgentRun>),

  // Live model list from the project's configured local server (Local-AI dropdown).
  getLocalModels: (projectId: string) =>
    fetch(`/projects/${projectId}/agent/local-models`).then(json<LocalModelsResponse>),

  stopAgent: (wsId: string) =>
    fetch(`/workspaces/${wsId}/agent/stop`, { method: "POST" }).then(json),

  getDiff: (wsId: string, commit?: string) =>
    fetch(`/workspaces/${wsId}/diff${commit ? `?commit=${encodeURIComponent(commit)}` : ""}`).then(
      json<DiffResponse>
    ),

  listFiles: (wsId: string) =>
    fetch(`/workspaces/${wsId}/files`).then(json<{ tree: FileNode[] }>),

  readFile: (wsId: string, path: string) =>
    fetch(`/workspaces/${wsId}/file?path=${encodeURIComponent(path)}`).then(
      // `error` + `size` are set when the file is guarded (too large / binary) —
      // content is empty and the UI shows a download escape hatch instead of Monaco.
      json<{ path: string; content: string; error?: string; size?: number }>
    ),

  // Committed content of a file at `ref` (default the workspace's base_ref) — a
  // side of the editor's per-file diff. `exists:false` → the file is absent at
  // that ref (new file), so content is empty and the diff is all-additions.
  // Passing a `ref` drives the commit-by-commit view (`<sha>^` vs `<sha>`).
  readFileBase: (wsId: string, path: string, ref?: string) =>
    fetch(
      `/workspaces/${wsId}/file/base?path=${encodeURIComponent(path)}` +
        (ref ? `&ref=${encodeURIComponent(ref)}` : ""),
    ).then(json<{ content: string; exists: boolean; error?: string }>),

  // Merged tsconfig `compilerOptions` for the worktree — fed to Monaco so its TS/JS
  // language service parses files the project's way (jsx mode, target, decorators),
  // making inline syntax squiggles trustworthy instead of false noise. `null` when
  // the worktree has no tsconfig (Monaco falls back to safe defaults).
  getTsconfig: (wsId: string) =>
    fetch(`/workspaces/${wsId}/tsconfig`).then(
      json<{ compilerOptions: Record<string, unknown> | null }>
    ),

  // Raw-bytes URL for inline preview (images / PDFs) — used directly as an
  // <img>/<iframe> src (proxied to the backend by Vite).
  rawUrl: (wsId: string, path: string) =>
    `/workspaces/${wsId}/raw?path=${encodeURIComponent(path)}`,

  // Same bytes, but forced as an attachment (Content-Disposition) — the download
  // escape hatch for files the editor guards (too large / binary).
  downloadUrl: (wsId: string, path: string) =>
    `/workspaces/${wsId}/raw?path=${encodeURIComponent(path)}&download=1`,

  searchFiles: (wsId: string, q: string) =>
    fetch(`/workspaces/${wsId}/search?q=${encodeURIComponent(q)}`).then(
      json<{ matches: { file: string; line: number; col: number; text: string }[]; truncated: boolean }>
    ),

  writeFile: (wsId: string, path: string, content: string) =>
    fetch(`/workspaces/${wsId}/file`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path, content }),
    }).then(json<{ saved: string }>),

  // Tree right-click file ops. `dir:true` creates a folder, else an empty file.
  createEntry: (wsId: string, path: string, dir: boolean) =>
    fetch(`/workspaces/${wsId}/fs/create`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path, dir }),
    }).then(json<{ created: string; dir: boolean }>),

  renameEntry: (wsId: string, path: string, to: string) =>
    fetch(`/workspaces/${wsId}/fs/rename`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path, to }),
    }).then(json<{ renamed: string; to: string }>),

  deleteEntry: (wsId: string, path: string) =>
    fetch(`/workspaces/${wsId}/fs/delete`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path }),
    }).then(json<{ deleted: string }>),

  // Promote a pasted block to a git-excluded .context/ file the agent can @-mention.
  attachContext: (wsId: string, content: string, name?: string) =>
    fetch(`/workspaces/${wsId}/context`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content, name: name ?? null }),
    }).then(json<{ path: string; name: string; lines: number; kind: "text" }>),

  // Promote a pasted image / picked file to a .context/ attachment (base64 JSON,
  // no multipart dep). Returns kind ("image"|"file") + byte size for the chip.
  uploadContext: (wsId: string, name: string, contentType: string, contentB64: string) =>
    fetch(`/workspaces/${wsId}/context/upload`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content_b64: contentB64, name, content_type: contentType || null }),
    }).then(json<{ path: string; name: string; kind: "image" | "file"; size: number }>),

  runTests: (wsId: string, scope: TestScope = "all") =>
    fetch(`/workspaces/${wsId}/tests?scope=${scope}`, { method: "POST" }).then(json<TestRun>),

  getTests: (wsId: string) => fetch(`/workspaces/${wsId}/tests`).then(json<TestRun | null>),

  // Agent sessions with a transcript in this workspace — the switcher's tab set
  // (always includes the primary "main"). Each session has its own stream + resume.
  getSessions: (wsId: string) =>
    fetch(`/workspaces/${wsId}/sessions`).then(json<{ sessions: string[] }>),

  // A session's durable transcript. `session` defaults to the primary session server-side;
  // the switcher passes a tab's id to load that session's own stream.
  getEvents: (wsId: string, session?: string) =>
    fetch(`/workspaces/${wsId}/events${session ? `?session=${encodeURIComponent(session)}` : ""}`).then(
      json<{ events: AgentEvent[] }>
    ),

  // Turn boundaries — the "rewind to here" anchors (also derivable client-side from the
  // events' `turn` field via deriveTurns; this is the backend's derived summary).
  getTurns: (wsId: string, session?: string) =>
    fetch(`/workspaces/${wsId}/turns${session ? `?session=${encodeURIComponent(session)}` : ""}`).then(
      json<{ turns: TurnMarker[] }>
    ),

  // Rewind a session to a turn boundary: truncate the transcript at/after `turn` and
  // return that turn's prompt for the composer. `checkpoint` snapshots the worktree as a
  // commit first (non-destructive reconcile — recover the dropped edits from the Git panel).
  // `session` picks which session tab to rewind (defaults to the primary session).
  rewind: (wsId: string, turn: number, checkpoint = true, session?: string) =>
    fetch(`/workspaces/${wsId}/rewind`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ turn, checkpoint, session_id: session }),
    }).then(json<RewindResponse>),

  getImpact: (wsId: string) => fetch(`/workspaces/${wsId}/impact`).then(json<ImpactResponse>),

  getBlame: (wsId: string) => fetch(`/workspaces/${wsId}/blame`).then(json<BlameResponse>),

  // Per-line proof for the ④ ship diff (backlog/verified-hunks.md). Reads the map the last
  // green gate cached — it never runs a suite, so it's safe to call on every workspace open.
  // `supported: false` + a note is the normal "we cannot say" answer (off, non-vitest runner,
  // no coverage provider, no green gate yet), not an error.
  getVerifiedHunks: (wsId: string) =>
    fetch(`/workspaces/${wsId}/verified-hunks`).then(json<VerifiedHunksResponse>),

  // Gate Receipt (usp-critique-plan.md idea 1): the exportable evidence packet for the
  // ④ ship step. Reads facts the gate already computed — never runs a test, a mutation
  // pass, or a gh call, so it's safe to call on every ship-step open.
  getReceipt: (wsId: string) => fetch(`/workspaces/${wsId}/receipt`).then(json<ReceiptResponse>),

  // Posts the receipt as a PR comment via `gh` — the sink that carries the evidence to a
  // reviewer who never installed haro. An explicit action (a button), not automatic.
  postReceiptPrComment: (wsId: string) =>
    fetch(`/workspaces/${wsId}/receipt/pr-comment`, { method: "POST" }).then(
      json<{ posted: boolean; url: string | null }>
    ),

  // Mutation score for the ③ verify residue (backlog/mutation-gate.md). POST because it
  // RE-RUNS the suite once per injected fault (unlike verified-hunks, which reads a cache),
  // so it's on-demand. Advisory: `supported:false` + a note is the "we cannot say" answer
  // (off, non-vitest, no green gate yet); survivors can never block a merge.
  runMutation: (wsId: string) =>
    fetch(`/workspaces/${wsId}/mutation`, { method: "POST" }).then(json<MutationResponse>),

  // Tick a "code to check" row off, or put it back (backlog/code-to-check.md). Records that
  // a human LOOKED — never that anything was verified, and it cannot unblock a merge, since
  // the pane never gated one. Returns the workspace's full key list so the caller replaces
  // rather than patches. Keys are pruned to the live rows on every gate.
  setRowChecked: (wsId: string, key: string, checked: boolean) =>
    fetch(`/workspaces/${wsId}/checked`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key, checked }),
    }).then(json<{ checked_rows: string[] }>),

  mergeQueue: (projectId: string, dry = false) =>
    fetch(`/projects/${projectId}/merge-queue?dry=${dry}`, { method: "POST" }).then(json<MergeQueueResult>),

  // Bulk archive through the serial queue. `dry` is the preview the confirm dialog
  // renders (nothing torn down); `force` also takes the workspaces the planner holds
  // back because archiving would throw their work away.
  archiveQueue: (projectId: string, workspaceIds: string[], opts: { dry?: boolean; force?: boolean } = {}) =>
    fetch(`/projects/${projectId}/archive-queue?dry=${opts.dry ?? false}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ workspace_ids: workspaceIds, force: opts.force ?? false }),
    }).then(json<ArchiveQueueRun>),

  getArchiveQueue: (projectId: string) =>
    fetch(`/projects/${projectId}/archive-queue`).then(json<ArchiveQueueRun | null>),

  stopArchiveQueue: (runId: string) =>
    fetch(`/archive-queue/${runId}/stop`, { method: "POST" }).then(json<ArchiveQueueRun>),

  getHistory: (wsId: string) => fetch(`/workspaces/${wsId}/history`).then(json<TestRun[]>),

  getTrust: (wsId: string) => fetch(`/workspaces/${wsId}/trust`).then(json<TrustReport>),

  // The Live Gate's last advisory run + whether `[gate] watch` is on — the rail panel's
  // rehydrate-on-reload / on-workspace-switch (backlog/live-gate.md). Live updates arrive
  // on the `watch` WS channel; this is only the cold start.
  getWatch: (wsId: string) => fetch(`/workspaces/${wsId}/watch`).then(json<WatchState>),

  getCoverage: (wsId: string) => fetch(`/workspaces/${wsId}/coverage`).then(json<CoverageResponse>),

  runFlaky: (wsId: string, runs = 5) =>
    fetch(`/workspaces/${wsId}/flaky?runs=${runs}`, { method: "POST" }).then(json<FlakyResponse>),

  // Returns a ReviewVerdict (the refuter, Phase 3) when the project has `[roles]`
  // enabled with a review role configured; otherwise the older advisory ReviewResult.
  // Callers discriminate on `"verdict" in result` (ReviewVerdict's discriminant field).
  runReview: (wsId: string, model?: string) =>
    fetch(`/workspaces/${wsId}/review`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: model ?? null }),
    }).then(json<ReviewResult | ReviewVerdict>),

  runApp: (wsId: string, runId?: string) =>
    fetch(`/workspaces/${wsId}/run${runId ? `?run_id=${encodeURIComponent(runId)}` : ""}`, {
      method: "POST",
    }).then(json<{ running: boolean; url: string | null }>),

  // Omit runId to stop every run in the workspace.
  stopApp: (wsId: string, runId?: string) =>
    fetch(`/workspaces/${wsId}/run/stop${runId ? `?run_id=${encodeURIComponent(runId)}` : ""}`, {
      method: "POST",
    }).then(json<{ running: boolean }>),

  getSetup: (wsId: string) => fetch(`/workspaces/${wsId}/setup`).then(json<SetupState>),

  rerunSetup: (wsId: string) =>
    fetch(`/workspaces/${wsId}/setup`, { method: "POST" }).then(json<{ status: string }>),

  // Read-only: the workspace's *effective* (inherited) `[scripts]` config, shown
  // in the preview step. Editing is project-level (see saveProjectScripts) so
  // there's a single source of truth — no workspace-vs-project drift.
  getScripts: (wsId: string) => fetch(`/workspaces/${wsId}/scripts`).then(json<ScriptsConfig>),

  // Project-keyed scripts — used by the project Setup tab, which edits a
  // project's `[scripts]` config without needing an open workspace.
  getProjectScripts: (projectId: string) =>
    fetch(`/projects/${projectId}/scripts`).then(json<ScriptsConfig>),

  saveProjectScripts: (projectId: string, cfg: ScriptsConfig & { target: "local" | "shared" }) =>
    fetch(`/projects/${projectId}/scripts`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(cfg),
    }).then(json<ScriptsConfig>),

  getInstructions: (wsId: string) =>
    fetch(`/workspaces/${wsId}/instructions`).then(json<InstructionsConfig>),

  saveInstructions: (wsId: string, text: string, target: "local" | "shared") =>
    fetch(`/workspaces/${wsId}/instructions`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text, target }),
    }).then(json<InstructionsConfig>),

  // Project-keyed variants — used by the global Settings page, which edits a
  // project's instructions without needing an open workspace.
  getProjectInstructions: (projectId: string) =>
    fetch(`/projects/${projectId}/instructions`).then(json<InstructionsConfig>),

  saveProjectInstructions: (projectId: string, text: string, target: "local" | "shared") =>
    fetch(`/projects/${projectId}/instructions`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text, target }),
    }).then(json<InstructionsConfig>),

  gitStatus: (wsId: string) =>
    fetch(`/workspaces/${wsId}/git/status`).then(json<GitStatusResponse>),

  gitLog: (wsId: string, limit = 30) =>
    fetch(`/workspaces/${wsId}/git/log?limit=${limit}`).then(json<{ commits: GitCommit[] }>),

  gitCommit: (wsId: string, message: string) =>
    fetch(`/workspaces/${wsId}/git/commit`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message }),
    }).then(json<{ committed: string | null; nothing_to_commit: boolean }>),

  gitPr: (wsId: string) => fetch(`/workspaces/${wsId}/git/pr`).then(json<PrStatusResponse>),

  // Open a PR without merging (the team/junior "request review" path). Idempotent:
  // returns the existing PR's URL if one is already open for the branch.
  createPr: (wsId: string) =>
    fetch(`/workspaces/${wsId}/git/pr`, { method: "POST" }).then(
      json<{ created: boolean; already_exists: boolean; url: string | null }>,
    ),

  merge: (wsId: string, message?: string) =>
    fetch(`/workspaces/${wsId}/merge`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message: message ?? null }),
    }).then(json<MergeResult>),

  // Continue a merged workspace on a fresh branch (same worktree + chat). Threads
  // the merged PR into the next PR as a follow-up.
  continueWorkspace: (wsId: string) =>
    fetch(`/workspaces/${wsId}/continue`, { method: "POST" }).then(
      json<{
        workspace: Workspace;
        branch: string;
        base_ref: string;
        prior_prs: number[];
        detail: string;
      }>,
    ),

  archiveWorkspace: (wsId: string) =>
    fetch(`/workspaces/${wsId}`, { method: "DELETE" }).then(json),

  removeProject: (projectId: string) =>
    fetch(`/projects/${projectId}`, { method: "DELETE" }).then(json),

  // Desktop self-update (packaged build only).
  updateStatus: () => fetch("/update/status").then(json<UpdateStatus>),

  updateProgress: () => fetch("/update/progress").then(json<UpdateProgress | null>),

  applyUpdate: () =>
    fetch("/update/apply", { method: "POST" }).then(
      json<{ applying?: boolean; scheduled?: boolean; busyReason?: string }>,
    ),

  setUpdateMode: (mode: "manual" | "auto") =>
    fetch(`/update/settings?mode=${mode}`, { method: "PUT" }).then(
      json<{ mode: "manual" | "auto" }>,
    ),

  // Claude subscription usage (session/weekly windows + credits) — same feed as
  // Claude Desktop's Usage view, read via the local Claude Code OAuth token.
  usage: (refresh = false) =>
    fetch(`/usage${refresh ? "?refresh=1" : ""}`).then(json<UsageResponse>),
};

export function openWorkspaceSocket(wsId: string): WebSocket {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  return new WebSocket(`${proto}://${location.host}/ws/workspaces/${wsId}`);
}

/** Coarse live feed across ALL workspaces (status + gate results) for the dashboard. */
export function openGlobalSocket(): WebSocket {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  return new WebSocket(`${proto}://${location.host}/ws`);
}
