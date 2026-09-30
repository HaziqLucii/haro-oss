// Pure tab-management logic for the ② code editor (CodePanel). Kept out of the
// component so the open/close/active-selection rules are unit-testable in the
// node vitest env without pulling in Monaco or the DOM.

export interface CodeTab {
  path: string;
  content: string;
  /** last loaded/saved content — dirty is content ≠ this, so undoing back to the
   *  original (Ctrl+Z) correctly clears the unsaved state. */
  saved: string;
  note: string | null;
  /** markdown files: rendered view vs source (per-tab so each remembers its mode). */
  mdPreview: boolean;
  /** per-file diff lens: show working-tree vs base_ref (red/green) instead of the
   *  plain editor. Per-tab so each file remembers whether it's in diff view. */
  diff?: boolean;
  /** cached base_ref content for the diff view (the original side). undefined =
   *  not fetched yet; a string once loaded (empty for a file new at base). */
  base?: string;
  /** base couldn't be diffed (e.g. a binary blob at base) — show a notice. */
  baseError?: string | null;
  /** commit-by-commit review: the selected branch commit sha whose before/after
   *  to show, or null/undefined for the default working-tree-vs-base view. */
  diffCommit?: string | null;
  /** cached original/modified sides per selected commit sha (commit-by-commit
   *  view), keyed by sha so re-selecting a commit doesn't refetch. */
  commitSides?: Record<string, { original: string; modified: string; error?: string | null }>;
  /** file the editor refuses to open (too large / binary) — the body shows a
   *  "preview not available / download" panel instead of Monaco, and save/diff are
   *  suppressed so an empty buffer can never clobber the real bytes. `reason` is the
   *  backend error string; `size` is the byte count (for the too-large message). */
  guard?: { reason: string; size?: number } | null;
}

export const isDirty = (t: CodeTab): boolean => t.content !== t.saved;
export const anyDirty = (tabs: CodeTab[]): boolean => tabs.some(isDirty);

/** Close the tab at `path`, returning the new tab list and which tab should
 *  become active. Closing a non-active tab leaves the active one alone; closing
 *  the active tab falls to its right neighbour, then its left, then nothing. */
export function closeTab(
  tabs: CodeTab[],
  path: string,
  activePath: string | null,
): { tabs: CodeTab[]; activePath: string | null } {
  const idx = tabs.findIndex((t) => t.path === path);
  if (idx === -1) return { tabs, activePath };
  const next = tabs.filter((t) => t.path !== path);
  if (activePath !== path) return { tabs: next, activePath };
  // after removing at idx, the element that was to the right now sits at idx.
  const neighbour = next[idx] ?? next[idx - 1] ?? null;
  return { tabs: next, activePath: neighbour ? neighbour.path : null };
}

/** The tab's display label — its basename (full path lives in the tooltip). */
export const tabLabel = (path: string): string => path.split("/").pop() || path;
