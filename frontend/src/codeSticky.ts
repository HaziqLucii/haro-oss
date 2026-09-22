// Per-workspace "sticky" editor state: which files are open, which tab is active,
// each file's cursor position, and its markdown code/preview mode — persisted to
// localStorage so reopening a worktree lands you exactly where you left off
// instead of re-hunting for the file you were editing. Buffer contents are NOT
// stored (they're re-read from disk on restore); this remembers *where you were*,
// not unsaved edits. Pure serialize/parse live here (out of CodePanel) so the
// shape + storage key are unit-testable in the node vitest env without the DOM.

export interface StickyCursor {
  lineNumber: number;
  column: number;
}

export interface StickyTab {
  path: string;
  /** markdown files: was it in rendered-preview (vs source) mode. */
  mdPreview?: boolean;
  cursor?: StickyCursor;
}

export interface StickyState {
  tabs: StickyTab[];
  /** path of the tab that was on screen; null when none was focused. */
  active: string | null;
}

const PREFIX = "haro-editor-";

export const stickyKey = (workspaceId: string): string => PREFIX + workspaceId;

/** Build the minimal persisted snapshot from the live tabs, the active path, and
 *  the latest cursor per path. Only restore-worth fields — never buffer content
 *  or transient guard/base/diff caches. */
export function serializeSticky(
  tabs: { path: string; mdPreview?: boolean }[],
  activePath: string | null,
  cursors: Map<string, StickyCursor>,
): StickyState {
  return {
    tabs: tabs.map((t) => {
      const s: StickyTab = { path: t.path };
      if (t.mdPreview) s.mdPreview = true;
      const c = cursors.get(t.path);
      if (c) s.cursor = { lineNumber: c.lineNumber, column: c.column };
      return s;
    }),
    active: activePath && tabs.some((t) => t.path === activePath) ? activePath : null,
  };
}

/** Parse a stored snapshot defensively — anything malformed (or from an older
 *  shape) yields null, so a corrupt entry just means "no sticky state", never a
 *  crash. */
export function parseSticky(raw: string | null): StickyState | null {
  if (!raw) return null;
  try {
    const v = JSON.parse(raw) as unknown;
    if (!v || typeof v !== "object" || !Array.isArray((v as { tabs?: unknown }).tabs)) return null;
    const src = v as { tabs: unknown[]; active?: unknown };
    const tabs: StickyTab[] = [];
    for (const t of src.tabs) {
      if (!t || typeof t !== "object") continue;
      const rt = t as { path?: unknown; mdPreview?: unknown; cursor?: unknown };
      if (typeof rt.path !== "string" || !rt.path) continue;
      const st: StickyTab = { path: rt.path };
      if (rt.mdPreview === true) st.mdPreview = true;
      const c = rt.cursor as { lineNumber?: unknown; column?: unknown } | undefined;
      if (c && typeof c.lineNumber === "number" && typeof c.column === "number") {
        st.cursor = { lineNumber: c.lineNumber, column: c.column };
      }
      tabs.push(st);
    }
    const active =
      typeof src.active === "string" && tabs.some((t) => t.path === src.active)
        ? src.active
        : null;
    return { tabs, active };
  } catch {
    return null;
  }
}

export function loadSticky(workspaceId: string): StickyState | null {
  try {
    return parseSticky(localStorage.getItem(stickyKey(workspaceId)));
  } catch {
    return null;
  }
}

export function saveSticky(workspaceId: string, state: StickyState): void {
  try {
    if (state.tabs.length === 0) localStorage.removeItem(stickyKey(workspaceId));
    else localStorage.setItem(stickyKey(workspaceId), JSON.stringify(state));
  } catch {
    /* localStorage full/blocked — sticky state just won't persist */
  }
}
