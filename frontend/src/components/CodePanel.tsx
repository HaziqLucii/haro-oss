import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { editor } from "monaco-editor";
import { api } from "../api";
import { Maximize, Minimize, Refresh } from "./icons";
import { Chevron } from "./Chevron";
import { FileMarkdown } from "./FileMarkdown";
import { FileIcon } from "./FileIcon";
import { GoToFile } from "./GoToFile";
import { Terminal } from "./Terminal";
import { monacoLang } from "../lang";
import { closeTab, isDirty, tabLabel, type CodeTab } from "../codeTabs";
import { loadSticky, saveSticky, serializeSticky, type StickyCursor } from "../codeSticky";
import { flattenFiles } from "../fuzzy";
import type { FileNode, GitCommit } from "../types";

// Monaco pulls in the VS Code editor engine + its web workers — lazy-load so it
// only downloads once a file is actually opened (keeps first paint light).
const MonacoEditor = lazy(() => import("./MonacoEditor"));
// Same lazy chunk (named export) — the per-file working-vs-base diff view.
const MonacoDiffEditor = lazy(() =>
  import("./MonacoEditor").then((m) => ({ default: m.MonacoDiffEditor })),
);

function isMarkdown(path: string): boolean {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return ext === "md" || ext === "markdown";
}

// Drag-to-resize bounds for the file tree pane (px).
const TREE_MIN = 140;
const TREE_MAX = 560;

const IMAGE_EXTS = new Set(["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp", "ico"]);

// Human-readable byte size for the too-large guard message.
function fmtBytes(n?: number): string {
  if (!n && n !== 0) return "";
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

// Non-text files the code view previews inline (instead of the editor).
function previewKind(path: string): "image" | "pdf" | null {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  if (IMAGE_EXTS.has(ext)) return "image";
  if (ext === "pdf") return "pdf";
  return null;
}

interface Match {
  file: string;
  line: number;
  col: number;
  text: string;
}

/** The "code" view: browse OR search the worktree and edit files in-app — so
 *  tweaking the agent's output never means leaving haro. */
export function CodePanel({
  workspaceId,
  theme,
  onSaved,
  fullscreen,
  onToggleFullscreen,
  openRequest,
  refreshSignal,
  viewActive,
}: {
  workspaceId: string;
  theme: string;
  onSaved?: () => void;
  fullscreen?: boolean;
  onToggleFullscreen?: () => void;
  /** Whether the code view is the one currently on screen — gates the ⌘P
   *  go-to-file hotkey so it doesn't fire (and swallow browser print) from
   *  the agent/gate/git views. */
  viewActive?: boolean;
  /** External request to open a file (e.g. an @mention click in the agent stream).
   *  `nonce` bumps on each request so re-clicking the same path re-fires. */
  openRequest?: { path: string; line?: number; nonce: number } | null;
  /** Bumps whenever the backend's filesystem watcher reports a change in this
   *  worktree (agent edit, git pull, terminal edit…) — reload the tree so the file
   *  list + change marks stay live without the ⟳ button. */
  refreshSignal?: number;
}) {
  // Which editor the code step shows: Monaco (tree + tabs) or nvim (a PTY in the
  // worktree, for the Linux crowd who live in it). A per-client UI choice,
  // persisted globally; the backend's `[editor] nvim` decides WHICH nvim config.
  const [editorKind, setEditorKind] = useState<"monaco" | "nvim">(
    () => (localStorage.getItem("haro-code-editor") === "nvim" ? "nvim" : "monaco"),
  );
  // Mount the nvim pane lazily on first switch, then keep it mounted (display
  // toggled) so flipping back to Monaco doesn't kill the nvim session + its
  // unsaved buffers. It only truly closes when the workspace changes (unmount).
  const [nvimMounted, setNvimMounted] = useState(editorKind === "nvim");
  useEffect(() => {
    localStorage.setItem("haro-code-editor", editorKind);
    if (editorKind === "nvim") setNvimMounted(true);
  }, [editorKind]);

  const [tree, setTree] = useState<FileNode[]>([]);
  const [open, setOpen] = useState<Record<string, boolean>>({});
  // Changed files (path → "added"|"modified"|"deleted") so the tree can highlight
  // them — and their parent folders — VS Code style, to pinpoint what the agent touched.
  const [changed, setChanged] = useState<Record<string, "added" | "modified" | "deleted">>({});
  // Open editor tabs (multi-file). `activePath` is the visible one; each tab
  // carries its own buffer + saved snapshot so switching never loses edits.
  const [tabs, setTabs] = useState<CodeTab[]>([]);
  const [activePath, setActivePath] = useState<string | null>(null);
  const [mode, setMode] = useState<"files" | "search">("files");
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Match[]>([]);
  const [searching, setSearching] = useState(false);
  const [gotoOpen, setGotoOpen] = useState(false);
  // Per-file diff review controls. `splitDiff` is a global reviewer preference
  // (side-by-side vs inline), persisted like the tree width. `commits` is the
  // branch's own commits, for the commit-by-commit selector — loaded lazily when
  // the diff lens is first opened and reset per workspace.
  const [splitDiff, setSplitDiff] = useState<boolean>(
    () => localStorage.getItem("haro.diffSplit") !== "0",
  );
  const [commits, setCommits] = useState<GitCommit[]>([]);
  useEffect(() => {
    localStorage.setItem("haro.diffSplit", splitDiff ? "1" : "0");
  }, [splitDiff]);
  useEffect(() => {
    setCommits([]);
  }, [workspaceId]);
  // Tree right-click context menu. `node === null` is a right-click on empty tree
  // space (operates on the worktree root).
  const [ctx, setCtx] = useState<{ x: number; y: number; node: FileNode | null } | null>(null);
  // The worktree's tsconfig compilerOptions (or null when it has none) — fed to Monaco
  // so its language service parses files the project's way (jsx/target/decorators),
  // making the inline syntax squiggles trustworthy. `undefined` = not yet fetched.
  const [tsOptions, setTsOptions] = useState<Record<string, unknown> | null | undefined>(undefined);
  const edRef = useRef<editor.IStandaloneCodeEditor | null>(null);
  const treeRef = useRef<HTMLDivElement | null>(null);

  // ---- Resizable file tree (drag the divider; persisted across sessions) -----
  const [treeWidth, setTreeWidth] = useState<number>(() => {
    const v = Number(localStorage.getItem("haro.codeTreeWidth"));
    return v >= TREE_MIN && v <= TREE_MAX ? v : 220;
  });
  const [resizing, setResizing] = useState(false);
  useEffect(() => {
    localStorage.setItem("haro.codeTreeWidth", String(treeWidth));
  }, [treeWidth]);
  const startResize = useCallback(
    (e: React.PointerEvent) => {
      e.preventDefault();
      const startX = e.clientX;
      const startW = treeWidth;
      setResizing(true);
      document.body.style.cursor = "col-resize";
      document.body.style.userSelect = "none";
      const onMove = (ev: PointerEvent) => {
        setTreeWidth(Math.min(TREE_MAX, Math.max(TREE_MIN, startW + ev.clientX - startX)));
      };
      const onUp = () => {
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", onUp);
        document.body.style.cursor = "";
        document.body.style.userSelect = "";
        setResizing(false);
      };
      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onUp);
    },
    [treeWidth],
  );

  // ---- Sticky editor state (persist open files + cursor per workspace) -------
  // Latest cursor per open path — a ref (not state) so cursor moves never re-render
  // the whole panel; the persisted snapshot reads it on demand.
  const cursorsRef = useRef<Map<string, StickyCursor>>(new Map());
  // Mirror tabs/active into refs so the debounced cursor-persist reads the freshest
  // values without re-subscribing on every keystroke.
  const tabsRef = useRef(tabs);
  tabsRef.current = tabs;
  const activeRef = useRef(activePath);
  activeRef.current = activePath;
  // Gate persistence until the workspace's stored state has been (re)hydrated, so
  // the transient empty tab list while switching workspaces can't clobber the saved
  // snapshot under the new workspace's key.
  const hydratedRef = useRef(false);
  const persistTimer = useRef<number | null>(null);

  const persistSticky = useCallback(() => {
    if (!hydratedRef.current) return;
    saveSticky(workspaceId, serializeSticky(tabsRef.current, activeRef.current, cursorsRef.current));
  }, [workspaceId]);

  const schedulePersist = useCallback(() => {
    if (persistTimer.current) window.clearTimeout(persistTimer.current);
    persistTimer.current = window.setTimeout(persistSticky, 400);
  }, [persistSticky]);

  // Flat corpus for the ⌘P fuzzy finder — every file path in the worktree tree.
  const flatFiles = useMemo(() => flattenFiles(tree), [tree]);

  const active = tabs.find((t) => t.path === activePath) ?? null;
  const path = active?.path ?? null;
  const content = active?.content ?? "";
  const dirty = active ? isDirty(active) : false;
  const note = active?.note ?? null;
  const mdPreview = active?.mdPreview ?? false;
  const diffView = active?.diff ?? false;
  const guard = active?.guard ?? null;

  // Resolve the two diff panes for the current review mode. `loading` while a
  // commit's sides are still being fetched; `error` when a side isn't diffable
  // (binary at that ref). Working-vs-base uses the cached base + live buffer;
  // a selected commit uses its cached before/after.
  const diffSides = useMemo((): {
    original?: string;
    modified?: string;
    error?: string | null;
    loading?: boolean;
  } | null => {
    if (!active || !active.diff) return null;
    const sel = active.diffCommit ?? null;
    if (sel) {
      const s = active.commitSides?.[sel];
      if (!s) return { loading: true };
      return { original: s.original, modified: s.modified, error: s.error ?? null };
    }
    if (active.baseError) return { error: active.baseError };
    if (active.base === undefined) return { loading: true };
    return { original: active.base, modified: active.content };
  }, [active]);

  // Patch a single tab in place (content edits, save snapshots, md-mode, notes).
  const patchTab = useCallback(
    (p: string, patch: Partial<CodeTab>) =>
      setTabs((ts) => ts.map((t) => (t.path === p ? { ...t, ...patch } : t))),
    [],
  );

  // The branch's own commits (newest first) for the commit-by-commit selector.
  // Cheap (one `git log`); refreshed each time the lens is opened so it stays live
  // as the agent commits more work mid-review.
  const loadCommits = useCallback(() => {
    api
      .gitLog(workspaceId)
      .then((r) => setCommits(r.commits.filter((c) => c.own)))
      .catch(() => setCommits([]));
  }, [workspaceId]);

  // Toggle the per-file diff lens for the active file, lazily fetching its base_ref
  // content (the original side) the first time it's turned on and caching it on the
  // tab. Markdown drops out of rendered-preview so the diff shows source-vs-source.
  const toggleDiff = useCallback(
    async (p: string) => {
      const t = tabs.find((x) => x.path === p);
      if (!t) return;
      const next = !t.diff;
      patchTab(p, { diff: next, mdPreview: false });
      if (next) loadCommits();
      if (next && t.base === undefined) {
        const r = await api.readFileBase(workspaceId, p).catch(() => null);
        patchTab(p, { base: r?.content ?? "", baseError: r?.error ?? null });
      }
    },
    [tabs, patchTab, workspaceId, loadCommits],
  );

  // Pick which change the diff lens shows: null = working-tree-vs-base (uses the
  // cached base + the live working buffer), or a commit sha = that one commit's
  // before/after (`<sha>^` vs `<sha>`), fetched once and cached on the tab.
  const selectDiffCommit = useCallback(
    async (p: string, sha: string | null) => {
      patchTab(p, { diffCommit: sha });
      if (!sha) return; // working-vs-base needs no extra fetch
      if (tabs.find((x) => x.path === p)?.commitSides?.[sha]) return; // cached
      const [orig, mod] = await Promise.all([
        api.readFileBase(workspaceId, p, `${sha}^`).catch(() => null),
        api.readFileBase(workspaceId, p, sha).catch(() => null),
      ]);
      const side = {
        original: orig?.content ?? "",
        modified: mod?.content ?? "",
        error: mod?.error ?? orig?.error ?? null,
      };
      // Merge inside the functional update so a concurrent selection can't clobber
      // another commit's cached sides (the closed-over `tabs` is stale after await).
      setTabs((ts) =>
        ts.map((t) =>
          t.path === p ? { ...t, commitSides: { ...(t.commitSides ?? {}), [sha]: side } } : t,
        ),
      );
    },
    [tabs, patchTab, workspaceId],
  );

  // Changed files vs what's committed (dirty tree = what the agent edited). Drives
  // the tree highlighting. Refreshed on open, on the ⟳ button, and after a save.
  const loadChanges = useCallback(() => {
    api
      .gitStatus(workspaceId)
      .then((s) => {
        const m: Record<string, "added" | "modified" | "deleted"> = {};
        for (const f of s.files) {
          const w = f.work || f.index;
          m[f.path] = w === "added" || w === "untracked" ? "added" : w === "deleted" ? "deleted" : "modified";
        }
        setChanged(m);
      })
      .catch(() => setChanged({}));
  }, [workspaceId]);

  const refreshTree = useCallback(() => {
    api.listFiles(workspaceId).then((r) => setTree(r.tree)).catch(() => {});
    loadChanges();
  }, [workspaceId, loadChanges]);

  useEffect(() => {
    refreshTree();
  }, [refreshTree]);

  // Fetch the worktree tsconfig once per workspace (cheap, cached in state). Failure →
  // null, so Monaco just uses its safe defaults (TSX still parses).
  useEffect(() => {
    let live = true;
    api
      .getTsconfig(workspaceId)
      .then((r) => live && setTsOptions(r.compilerOptions))
      .catch(() => live && setTsOptions(null));
    return () => {
      live = false;
    };
  }, [workspaceId]);

  // Live worktree changes (from the backend fs watcher) → reload the tree + change
  // marks. Starts at 0 (falsy) so this doesn't double-fetch on mount; each bump is
  // a real change signal. Deliberately does NOT touch the open editor buffer, so an
  // agent edit can't clobber your unsaved changes.
  useEffect(() => {
    if (refreshSignal) refreshTree();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshSignal]);

  // Ancestor folders of any changed file — so a collapsed folder still signals it
  // contains changes (VS Code style).
  const changedDirs = useMemo(() => {
    const s = new Set<string>();
    for (const p of Object.keys(changed)) {
      const parts = p.split("/");
      for (let i = 1; i < parts.length; i++) s.add(parts.slice(0, i).join("/"));
    }
    return s;
  }, [changed]);

  const scrollToLine = (line: number) => {
    const ed = edRef.current;
    if (!ed) return;
    const total = ed.getModel()?.getLineCount() ?? 1;
    const l = Math.min(Math.max(line, 1), total);
    ed.revealLineInCenter(l);
    ed.setPosition({ lineNumber: l, column: 1 });
    ed.focus();
  };

  const openFile = async (p: string, line?: number) => {
    // Already open → just focus its tab (and jump to the line if asked).
    if (tabs.some((t) => t.path === p)) {
      setActivePath(p);
      if (line) {
        patchTab(p, { mdPreview: false });
        setTimeout(() => scrollToLine(line), 60);
      }
      return;
    }
    // Images / PDFs are previewed from the raw endpoint — no text to fetch/edit.
    if (previewKind(p)) {
      setTabs((ts) => [...ts, { path: p, content: "", saved: "", note: null, mdPreview: false }]);
      setActivePath(p);
      return;
    }
    const r = await api.readFile(workspaceId, p).catch(() => null);
    if (!r) return;
    setTabs((ts) => [
      ...ts,
      {
        path: p,
        content: r.content,
        saved: r.content,
        note: null,
        // Guarded (too large / binary): show a download panel, never Monaco — and
        // never rendered-markdown, since there's no content to render.
        guard: r.error ? { reason: r.error, size: r.size } : null,
        // Open markdown in rendered view by default (jumping to a line implies editing).
        mdPreview: isMarkdown(p) && !line && !r.error,
      },
    ]);
    setActivePath(p);
    if (line) setTimeout(() => scrollToLine(line), 60);
  };

  // Rebuild a tab from a persisted sticky entry — mirrors openFile's fetch, minus
  // the focus/line side effects. Returns null if the file is gone (dropped from
  // the restored set). Cursor/mdPreview are applied by the caller.
  const hydrateTab = useCallback(
    async (p: string, mdPreview: boolean): Promise<CodeTab | null> => {
      if (previewKind(p)) return { path: p, content: "", saved: "", note: null, mdPreview: false };
      const r = await api.readFile(workspaceId, p).catch(() => null);
      if (!r) return null;
      return {
        path: p,
        content: r.content,
        saved: r.content,
        note: null,
        guard: r.error ? { reason: r.error, size: r.size } : null,
        mdPreview: mdPreview && isMarkdown(p) && !r.error,
      };
    },
    [workspaceId],
  );

  // On workspace switch (and first mount): restore that worktree's open files,
  // active tab, cursors, and markdown modes from localStorage. Declared BEFORE the
  // persist effect so it resets `hydrated` first — the persist effect then no-ops
  // until the restore completes, never overwriting good state with a stale one.
  useEffect(() => {
    hydratedRef.current = false;
    cursorsRef.current = new Map();
    const st = loadSticky(workspaceId);
    if (!st || st.tabs.length === 0) {
      setTabs([]);
      setActivePath(null);
      hydratedRef.current = true;
      return;
    }
    for (const s of st.tabs) if (s.cursor) cursorsRef.current.set(s.path, s.cursor);
    let cancelled = false;
    (async () => {
      const restored: CodeTab[] = [];
      for (const s of st.tabs) {
        const t = await hydrateTab(s.path, !!s.mdPreview);
        if (t) restored.push(t);
      }
      if (cancelled) return;
      const alive = new Set(restored.map((t) => t.path));
      setTabs(restored);
      setActivePath(st.active && alive.has(st.active) ? st.active : restored[0]?.path ?? null);
      hydratedRef.current = true;
      persistSticky(); // prune any entries whose files no longer exist
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspaceId]);

  // Persist whenever the open set or active tab changes (open/close/switch). Cursor
  // moves persist on their own debounce (schedulePersist) since they don't touch state.
  useEffect(() => {
    persistSticky();
  }, [tabs, activePath, persistSticky]);

  // Flush any pending debounced cursor write when the panel unmounts.
  useEffect(
    () => () => {
      if (persistTimer.current) window.clearTimeout(persistTimer.current);
    },
    [],
  );

  // Close a tab (the × on the tab). Guards a dirty buffer so an accidental click
  // can't silently drop unsaved edits; then falls to a neighbouring tab.
  const closeTabAt = (p: string) => {
    const t = tabs.find((x) => x.path === p);
    if (t && isDirty(t) && !window.confirm("Discard unsaved changes?")) return;
    const res = closeTab(tabs, p, activePath);
    setTabs(res.tabs);
    setActivePath(res.activePath);
  };

  // ---- Tree file ops (right-click: new file / folder, rename, delete) --------
  const dirOf = (p: string) => {
    const i = p.lastIndexOf("/");
    return i < 0 ? "" : p.slice(0, i);
  };
  // The folder a "new file/folder" lands in: inside a dir node, else the file's
  // parent, else the worktree root (empty-space right-click).
  const targetDir = (node: FileNode | null) => (!node ? "" : node.dir ? node.path : dirOf(node.path));

  // Expand a folder and all its ancestors so a freshly-created entry is visible.
  const expandTo = (dir: string, self?: string) =>
    setOpen((o) => {
      const next = { ...o };
      let acc = "";
      for (const seg of dir.split("/")) {
        if (!seg) continue;
        acc = acc ? `${acc}/${seg}` : seg;
        next[acc] = true;
      }
      if (self) next[self] = true;
      return next;
    });

  const newEntry = async (node: FileNode | null, isDir: boolean) => {
    setCtx(null);
    const name = window.prompt(isDir ? "New folder name" : "New file name");
    if (!name || !name.trim()) return;
    const dir = targetDir(node);
    const p = dir ? `${dir}/${name.trim()}` : name.trim();
    try {
      await api.createEntry(workspaceId, p, isDir);
    } catch (e) {
      window.alert(`Could not create: ${(e as Error).message}`);
      return;
    }
    expandTo(dir, isDir ? p : undefined);
    refreshTree();
    if (!isDir) openFile(p);
  };

  // Rewrite open tabs when a path is renamed/moved (files by exact match, dirs by
  // prefix) so the editor keeps pointing at the moved buffer.
  const remapTabs = (oldPath: string, newPath: string, isDir: boolean) => {
    const moved = (tp: string) =>
      tp === oldPath ? newPath : isDir && tp.startsWith(oldPath + "/") ? newPath + tp.slice(oldPath.length) : null;
    setTabs((ts) => ts.map((t) => ({ ...t, path: moved(t.path) ?? t.path })));
    setActivePath((ap) => (ap ? moved(ap) ?? ap : ap));
    // Carry each moved path's remembered cursor to its new key.
    for (const [p, c] of [...cursorsRef.current]) {
      const to = moved(p);
      if (to) {
        cursorsRef.current.delete(p);
        cursorsRef.current.set(to, c);
      }
    }
  };

  const renameEntry = async (node: FileNode) => {
    setCtx(null);
    const to = window.prompt("Rename / move to (path relative to the worktree)", node.path);
    if (!to || !to.trim() || to.trim() === node.path) return;
    const dst = to.trim();
    try {
      await api.renameEntry(workspaceId, node.path, dst);
    } catch (e) {
      window.alert(`Could not rename: ${(e as Error).message}`);
      return;
    }
    remapTabs(node.path, dst, !!node.dir);
    expandTo(dirOf(dst));
    refreshTree();
  };

  const deleteEntry = async (node: FileNode) => {
    setCtx(null);
    const msg = node.dir
      ? `Delete folder ${node.path}/ and everything in it? This cannot be undone.`
      : `Delete ${node.path}? This cannot be undone.`;
    if (!window.confirm(msg)) return;
    try {
      await api.deleteEntry(workspaceId, node.path);
    } catch (e) {
      window.alert(`Could not delete: ${(e as Error).message}`);
      return;
    }
    // Close tabs for the deleted file / anything under a deleted folder.
    const gone = (tp: string) => tp === node.path || (!!node.dir && tp.startsWith(node.path + "/"));
    setTabs((ts) => ts.filter((t) => !gone(t.path)));
    setActivePath((ap) => (ap && gone(ap) ? null : ap));
    refreshTree();
  };

  // Dismiss the context menu on any outside interaction / Escape.
  useEffect(() => {
    if (!ctx) return;
    const close = () => setCtx(null);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setCtx(null);
    window.addEventListener("mousedown", close);
    window.addEventListener("resize", close);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", close);
      window.removeEventListener("resize", close);
      window.removeEventListener("keydown", onKey);
    };
  }, [ctx]);

  // Reveal a folder from the breadcrumb header: switch to the tree, expand it
  // and all its ancestors, then scroll the row into view — so the path header
  // is a live index into the file tree, not just a label.
  const revealDir = (dir: string) => {
    setMode("files");
    setOpen((o) => {
      const next = { ...o };
      let acc = "";
      for (const seg of dir.split("/")) {
        acc = acc ? `${acc}/${seg}` : seg;
        next[acc] = true;
      }
      return next;
    });
    setTimeout(() => {
      treeRef.current
        ?.querySelector(`[data-ftdir="${CSS.escape(dir)}"]`)
        ?.scrollIntoView({ block: "nearest" });
    }, 60);
  };

  // Path split into breadcrumb segments; each carries its cumulative dir path so
  // a click can expand exactly that folder in the tree.
  const crumbs = useMemo(() => {
    if (!path) return null;
    const parts = path.split("/");
    return parts.map((name, i) => ({
      name,
      dir: parts.slice(0, i + 1).join("/"),
      last: i === parts.length - 1,
    }));
  }, [path]);

  // Deselect the active tab — on mobile this returns from the full-width editor
  // to the full-width file tree (the master-detail "back" gesture). Tabs stay
  // open (nothing is discarded), so tapping a file re-enters the editor.
  const closeFile = () => setActivePath(null);

  // Open a file on an external request (an @mention click routes here via App).
  // Keyed on `nonce` so clicking the same mention twice re-opens it.
  useEffect(() => {
    if (!openRequest?.path) return;
    setMode("files");
    openFile(openRequest.path, openRequest.line);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [openRequest?.nonce]);

  const runSearch = async () => {
    const q = query.trim();
    if (!q) {
      setResults([]);
      return;
    }
    setSearching(true);
    const r = await api.searchFiles(workspaceId, q).catch(() => null);
    setResults(r?.matches ?? []);
    setSearching(false);
  };

  // Transiently show "saved" on a tab, then clear it (only if still "saved").
  const flashSaved = useCallback((paths: string[]) => {
    const hit = new Set(paths);
    setTimeout(
      () => setTabs((ts) => ts.map((t) => (hit.has(t.path) && t.note === "saved" ? { ...t, note: null } : t))),
      1500,
    );
  }, []);

  const save = useCallback(async () => {
    const t = tabs.find((x) => x.path === activePath);
    if (!t || !isDirty(t)) return;
    await api.writeFile(workspaceId, t.path, t.content);
    patchTab(t.path, { saved: t.content, note: "saved" });
    onSaved?.();
    loadChanges(); // a save may add/clear a changed-file mark in the tree
    flashSaved([t.path]);
  }, [workspaceId, tabs, activePath, patchTab, onSaved, loadChanges, flashSaved]);

  // Persist every dirty tab in one shot (⇧⌘S / the "save all" button).
  const saveAll = useCallback(async () => {
    const dirtyTabs = tabs.filter(isDirty);
    if (!dirtyTabs.length) return;
    await Promise.all(dirtyTabs.map((t) => api.writeFile(workspaceId, t.path, t.content)));
    const saved = new Set(dirtyTabs.map((t) => t.path));
    setTabs((ts) => ts.map((t) => (saved.has(t.path) ? { ...t, saved: t.content, note: "saved" } : t)));
    onSaved?.();
    loadChanges();
    flashSaved([...saved]);
  }, [workspaceId, tabs, onSaved, loadChanges, flashSaved]);

  const dirtyCount = tabs.filter(isDirty).length;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && (e.key === "s" || e.key === "S")) {
        e.preventDefault();
        if (e.shiftKey) saveAll();
        else save();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [save, saveAll]);

  // ⌘P / Ctrl+P → the fuzzy go-to-file palette (only while the code view is on
  // screen, so it doesn't hijack browser print from the other steps).
  useEffect(() => {
    if (!viewActive) return;
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && !e.shiftKey && (e.key === "p" || e.key === "P")) {
        e.preventDefault();
        setGotoOpen(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [viewActive]);

  // Esc exits fullscreen (only while expanded, so it doesn't swallow other Escs).
  useEffect(() => {
    if (!fullscreen || !onToggleFullscreen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onToggleFullscreen();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [fullscreen, onToggleFullscreen]);

  const renderNodes = (nodes: FileNode[], depth = 0) =>
    nodes.map((n) =>
      n.dir ? (
        <div key={n.path}>
          <button
            className={"ft-row ft-dir" + (changedDirs.has(n.path) ? " ft-changed ft-changed-dir" : "")}
            data-ftdir={n.path}
            style={{ paddingLeft: 8 + depth * 12 }}
            onClick={() => setOpen((o) => ({ ...o, [n.path]: !o[n.path] }))}
            onContextMenu={(e) => {
              e.preventDefault();
              e.stopPropagation();
              setCtx({ x: e.clientX, y: e.clientY, node: n });
            }}
          >
            <Chevron open={open[n.path]} />
            <FileIcon path={n.path} folder open={open[n.path]} />
            {n.name}
          </button>
          {open[n.path] && n.children && renderNodes(n.children, depth + 1)}
        </div>
      ) : (
        <button
          key={n.path}
          className={
            "ft-row ft-file" +
            (path === n.path ? " ft-sel" : "") +
            (changed[n.path] ? ` ft-changed ft-changed-${changed[n.path]}` : "")
          }
          style={{ paddingLeft: 8 + depth * 12 + 12 }}
          onClick={() => openFile(n.path)}
          onContextMenu={(e) => {
            e.preventDefault();
            e.stopPropagation();
            setCtx({ x: e.clientX, y: e.clientY, node: n });
          }}
        >
          <FileIcon path={n.path} />
          {n.name}
        </button>
      )
    );

  return (
    <div className="code-wrap">
      <div className="code-topbar">
        <span className="code-kind" title="edit with Monaco or Neovim">
          <button
            className={"seg2" + (editorKind === "monaco" ? " on" : "")}
            onClick={() => setEditorKind("monaco")}
          >
            Monaco
          </button>
          <button
            className={"seg2" + (editorKind === "nvim" ? " on" : "")}
            onClick={() => setEditorKind("nvim")}
            title="open the worktree in Neovim"
          >
            nvim
          </button>
        </span>
      </div>
      <div
        className={"code" + (path != null ? " code--file-open" : "")}
        style={{ display: editorKind === "monaco" ? "flex" : "none" }}
      >
      <GoToFile
        open={gotoOpen}
        files={flatFiles}
        onClose={() => setGotoOpen(false)}
        onOpen={(p) => {
          setMode("files");
          openFile(p);
        }}
      />
      {ctx && (
        <div
          className="ctx-menu"
          style={{ left: ctx.x, top: ctx.y }}
          onMouseDown={(e) => e.stopPropagation()}
        >
          <button className="ctx-item" onClick={() => newEntry(ctx.node, false)}>
            New file
          </button>
          <button className="ctx-item" onClick={() => newEntry(ctx.node, true)}>
            New folder
          </button>
          {ctx.node && (
            <>
              <div className="ctx-sep" />
              <button className="ctx-item" onClick={() => renameEntry(ctx.node!)}>
                Rename
              </button>
              <button className="ctx-item ctx-danger" onClick={() => deleteEntry(ctx.node!)}>
                Delete
              </button>
            </>
          )}
        </div>
      )}
      <div className="ft" style={{ ["--ft-w" as string]: `${treeWidth}px` }}>
        <div className="ft-head">
          <span className="ft-modes">
            <button className={"seg2" + (mode === "files" ? " on" : "")} onClick={() => setMode("files")}>
              files
            </button>
            <button className={"seg2" + (mode === "search" ? " on" : "")} onClick={() => setMode("search")}>
              search
            </button>
          </span>
          {mode === "files" && (
            <button
              className="ghost"
              onClick={refreshTree}
              title="refresh file tree"
            >
              <Refresh />
            </button>
          )}
        </div>
        {mode === "search" && (
          <div className="ft-search">
            <input
              value={query}
              autoFocus
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && runSearch()}
              placeholder="find in worktree…"
            />
          </div>
        )}
        <div
          className="ft-scroll"
          ref={treeRef}
          onContextMenu={
            mode === "files"
              ? (e) => {
                  e.preventDefault();
                  setCtx({ x: e.clientX, y: e.clientY, node: null });
                }
              : undefined
          }
        >
          {mode === "files"
            ? renderNodes(tree)
            : results.length === 0
              ? <div className="side-empty dim">{searching ? "searching…" : "type a query, press Enter"}</div>
              : results.map((m, i) => (
                  <button key={i} className="ft-row sr" onClick={() => openFile(m.file, m.line)}>
                    <span className="sr-loc dim">
                      {m.file}:{m.line}
                    </span>
                    <span className="sr-text">{m.text.trim()}</span>
                  </button>
                ))}
        </div>
      </div>
      <div
        className={"ft-resize" + (resizing ? " dragging" : "")}
        onPointerDown={startResize}
        title="drag to resize the file tree"
      />
      <div className="ed">
        {tabs.length > 0 && (
          <div className="ed-tabs" role="tablist">
            {tabs.map((t) => {
              const d = isDirty(t);
              return (
                <div
                  key={t.path}
                  className={"ed-tab" + (t.path === activePath ? " on" : "")}
                  role="tab"
                  aria-selected={t.path === activePath}
                >
                  <button
                    className="ed-tab-open"
                    onClick={() => setActivePath(t.path)}
                    title={t.path}
                  >
                    <FileIcon path={t.path} />
                    <span className="ed-tab-name">{tabLabel(t.path)}</span>
                  </button>
                  <button
                    className={"ed-tab-close" + (d ? " dirty" : "")}
                    onClick={() => closeTabAt(t.path)}
                    title={d ? "unsaved changes · close" : "close"}
                    aria-label={`close ${tabLabel(t.path)}`}
                  >
                    <span className="ed-tab-x">×</span>
                    <span className="ed-tab-dot" />
                  </button>
                </div>
              );
            })}
          </div>
        )}
        <div className="ed-head">
          <button
            className="ghost ed-back"
            onClick={closeFile}
            title="back to files"
            aria-label="back to files"
          >
            ‹ files
          </button>
          {crumbs == null ? (
            <span className="ed-path dim">select a file</span>
          ) : (
            <span className="ed-path ed-crumbs" title={path ?? undefined}>
              {crumbs.map((c, i) => (
                <span key={c.dir} className="ed-crumb">
                  {i > 0 && <span className="ed-crumb-sep">/</span>}
                  {c.last ? (
                    <span className="ed-crumb-file">{c.name}</span>
                  ) : (
                    <button
                      className="ed-crumb-dir"
                      onClick={() => revealDir(c.dir)}
                      title={`reveal ${c.dir}/ in the file tree`}
                    >
                      {c.name}
                    </button>
                  )}
                </span>
              ))}
            </span>
          )}
          {note && <span className="dim ed-note">{note}</span>}
          {dirty && <span className="ed-dirty">● unsaved</span>}
          {path && isMarkdown(path) && !guard && (
            <span className="ed-mdtoggle" title="view markdown as source or rendered">
              <button
                className={"seg2" + (!mdPreview ? " on" : "")}
                onClick={() => patchTab(path, { mdPreview: false })}
              >
                code
              </button>
              <button
                className={"seg2" + (mdPreview ? " on" : "")}
                onClick={() => patchTab(path, { mdPreview: true })}
              >
                preview
              </button>
            </span>
          )}
          {path && !previewKind(path) && !guard && (
            <button
              className={"ghost ed-diff-toggle" + (diffView ? " on" : "")}
              onClick={() => toggleDiff(path)}
              title="toggle working-vs-base diff"
              aria-pressed={diffView}
            >
              diff
            </button>
          )}
          {path && diffView && !previewKind(path) && !guard && (
            <>
              {/* commit-by-commit: step through the branch one commit at a time
                  instead of the full squashed working-vs-base diff. */}
              <select
                className="ed-diff-commit"
                value={active?.diffCommit ?? ""}
                onChange={(e) => selectDiffCommit(path, e.target.value || null)}
                title="which change to review"
              >
                <option value="">working tree (all changes)</option>
                {commits.map((c) => (
                  <option key={c.sha} value={c.sha}>
                    {c.short} · {c.subject}
                  </option>
                ))}
              </select>
              {/* split (side-by-side) vs unified (inline) — a reviewer view option. */}
              <span className="ed-diff-layout" title="side-by-side or inline diff">
                <button
                  className={"seg2" + (splitDiff ? " on" : "")}
                  onClick={() => setSplitDiff(true)}
                >
                  split
                </button>
                <button
                  className={"seg2" + (!splitDiff ? " on" : "")}
                  onClick={() => setSplitDiff(false)}
                >
                  unified
                </button>
              </span>
            </>
          )}
          <button className="ghost" onClick={save} disabled={!dirty} title="save (Ctrl+S)">
            save
          </button>
          {dirtyCount > 1 && (
            <button
              className="ghost"
              onClick={saveAll}
              title="save all files (Ctrl+Shift+S)"
            >
              save all{" "}
              <span className="ed-saveall-n">{dirtyCount}</span>
            </button>
          )}
          {onToggleFullscreen && (
            <button
              className="ghost btn-icon btn-full"
              onClick={onToggleFullscreen}
              title={fullscreen ? "exit fullscreen (Esc)" : "fullscreen editor"}
              aria-label={fullscreen ? "exit fullscreen" : "fullscreen editor"}
            >
              {fullscreen ? <Minimize /> : <Maximize />}
            </button>
          )}
        </div>
        <div className="ed-body">
          {path == null ? (
            <div className="empty">Pick a file to edit, or use search to find one.</div>
          ) : previewKind(path) === "image" ? (
            <div className="ed-preview ed-preview-img">
              {/* eslint-disable-next-line jsx-a11y/alt-text */}
              <img src={api.rawUrl(workspaceId, path)} alt={path} />
            </div>
          ) : previewKind(path) === "pdf" ? (
            <iframe className="ed-preview-pdf" src={api.rawUrl(workspaceId, path)} title={path} />
          ) : guard ? (
            <div className="ed-guard">
              <div className="ed-guard-title">Preview not available</div>
              <div className="ed-guard-msg dim">
                {guard.reason === "file too large to edit"
                  ? `This file is too large to open in the editor${
                      guard.size ? ` (${fmtBytes(guard.size)})` : ""
                    }.`
                  : "This looks like a binary file, so it can't be shown as text."}
              </div>
              <a className="ed-guard-dl" href={api.downloadUrl(workspaceId, path)} download>
                Download file
              </a>
            </div>
          ) : diffView ? (
            diffSides?.error ? (
              <div className="empty">this version isn't diffable ({diffSides.error}).</div>
            ) : !diffSides || diffSides.loading ? (
              <div className="empty">loading diff…</div>
            ) : (
              <Suspense fallback={<div className="empty">loading editor…</div>}>
                {/* Working-vs-base (original = base_ref, modified = the working
                    buffer with unsaved edits) or one commit's before/after, per the
                    selector. Keyed by file + selected commit so a mode switch loads
                    fresh content; split/unified flips live (no remount). */}
                <MonacoDiffEditor
                  key={path + " " + (active?.diffCommit ?? "")}
                  original={diffSides.original ?? ""}
                  modified={diffSides.modified ?? ""}
                  language={monacoLang(path)}
                  theme={theme}
                  renderSideBySide={splitDiff}
                />
              </Suspense>
            )
          ) : isMarkdown(path) && mdPreview ? (
            <div className="ed-md-preview">
              <FileMarkdown text={content} wsId={workspaceId} basePath={path} />
            </div>
          ) : (
            <Suspense fallback={<div className="empty">loading editor…</div>}>
              {/* key by path → each tab gets its own editor model, so switching
                  tabs never bleeds one file's undo history / cursor into another. */}
              <MonacoEditor
                key={path}
                value={content}
                path={path}
                compilerOptions={tsOptions}
                language={monacoLang(path)}
                theme={theme}
                onMount={(ed) => {
                  edRef.current = ed;
                  // Restore this file's last cursor (unless an explicit line jump is
                  // pending via openRequest, which reveals its own line shortly after).
                  const c = cursorsRef.current.get(path);
                  if (c) {
                    ed.setPosition(c);
                    ed.revealLineInCenter(c.lineNumber);
                  }
                  // Track the cursor so it survives tab switches and reloads.
                  ed.onDidChangeCursorPosition((e) => {
                    cursorsRef.current.set(path, {
                      lineNumber: e.position.lineNumber,
                      column: e.position.column,
                    });
                    schedulePersist();
                  });
                }}
                onChange={(v) => patchTab(path, { content: v })}
              />
            </Suspense>
          )}
        </div>
      </div>
      </div>
      {/* nvim pane — mounted once opened, then just hidden, so toggling back to
          Monaco keeps the nvim session (and its unsaved buffers) alive. */}
      {nvimMounted && (
        <div
          className="code-nvim"
          style={{ display: editorKind === "nvim" ? "flex" : "none" }}
        >
          <Terminal
            workspaceId={workspaceId}
            shellId="editor"
            path={`/ws/workspaces/${workspaceId}/editor`}
            theme={theme}
            autoFocus={editorKind === "nvim"}
          />
        </div>
      )}
    </div>
  );
}
