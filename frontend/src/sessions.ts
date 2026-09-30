// Pure helpers for the agent-stream session switcher (like the shell-tab strip). A
// workspace hosts N agent sessions, each with its own transcript + Claude --resume
// thread (backend: transcript keyed by (workspace_id, session_id); DEFAULT_SESSION =
// "main"). The switcher is client-owned — App.tsx keeps the ordered id list and the
// active tab — so this module holds the id/label logic it needs, kept pure + tested.

// The primary session id — mirrors backend/haro/store.py DEFAULT_SESSION. The first
// tab, always present, and the id an omitted session_id falls back to on the wire.
export const DEFAULT_SESSION = "main";

// Fold an incoming session id into the known list (append once, preserve order). Used
// when a live agent envelope names a session the switcher hasn't seen yet, and when
// hydrating the persisted set on workspace open.
export function mergeSession(list: string[], sid: string): string[] {
  return list.includes(sid) ? list : [...list, sid];
}

// Union a fetched/persisted set into the current list, keeping the primary session first
// and first-seen order otherwise. Dedupes; never drops an already-open (unsaved) tab.
export function mergeSessions(list: string[], incoming: string[]): string[] {
  let out = list;
  for (const sid of incoming) out = mergeSession(out, sid);
  return out;
}

// The next fresh non-primary session id: "s2", "s3", … — the highest existing `s<n>`
// (or the primary, counted as 1) plus one. Ids are stable + never reused within a
// workspace, so a new tab and its backend transcript agree.
export function nextSessionId(list: string[]): string {
  let max = 1; // the primary session counts as #1
  for (const sid of list) {
    const m = /^s(\d+)$/.exec(sid);
    if (m) max = Math.max(max, Number(m[1]));
  }
  return `s${max + 1}`;
}

// The tab's on-screen label — "session N" by position (the raw ids "main"/"s2" are
// backend keys, not user-facing). Falls back to the raw id if it isn't in the list.
export function sessionLabel(list: string[], sid: string): string {
  const i = list.indexOf(sid);
  return i === -1 ? sid : `session ${i + 1}`;
}
