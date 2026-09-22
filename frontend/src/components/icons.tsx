// Shared inline SVG icons (Feather-style) so controls look identical everywhere.
const base = {
  viewBox: "0 0 24 24",
  width: 14,
  height: 14,
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 2,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

/** Enter fullscreen — arrows pointing outward to the corners. */
export const Maximize = () => (
  <svg {...base}>
    <path d="M8 3H5a2 2 0 0 0-2 2v3M21 8V5a2 2 0 0 0-2-2h-3M3 16v3a2 2 0 0 0 2 2h3M16 21h3a2 2 0 0 0 2-2v-3" />
  </svg>
);

/** Exit fullscreen — arrows pointing inward (the reverse of Maximize). */
export const Minimize = () => (
  <svg {...base}>
    <path d="M8 3v3a2 2 0 0 1-2 2H3M21 8h-3a2 2 0 0 1-2-2V3M3 16h3a2 2 0 0 1 2 2v3M16 21v-3a2 2 0 0 1 2-2h3" />
  </svg>
);

/** Open in a new window/tab — the standard external-link glyph. */
export const ExternalLink = () => (
  <svg {...base}>
    <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
    <polyline points="15 3 21 3 21 9" />
    <line x1="10" y1="14" x2="21" y2="3" />
  </svg>
);

/** GitHub octocat mark (filled) — badges a project linked to a github.com remote. */
export const GitHubMark = ({ size = 14 }: { size?: number }) => (
  <svg viewBox="0 0 24 24" width={size} height={size} fill="currentColor" aria-hidden>
    <path d="M12 .5C5.73.5.5 5.73.5 12c0 5.09 3.29 9.4 7.86 10.93.58.11.79-.25.79-.56 0-.28-.01-1.02-.02-2-3.2.7-3.88-1.54-3.88-1.54-.52-1.33-1.28-1.68-1.28-1.68-1.05-.72.08-.7.08-.7 1.16.08 1.77 1.2 1.77 1.2 1.03 1.76 2.7 1.25 3.36.96.1-.75.4-1.26.73-1.55-2.55-.29-5.24-1.28-5.24-5.69 0-1.26.45-2.29 1.19-3.09-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.18 1.18a11.1 11.1 0 0 1 5.79 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.8 1.19 1.83 1.19 3.09 0 4.42-2.69 5.39-5.25 5.68.41.36.78 1.06.78 2.14 0 1.55-.01 2.8-.01 3.18 0 .31.21.68.8.56A11.51 11.51 0 0 0 23.5 12C23.5 5.73 18.27.5 12 .5z" />
  </svg>
);

/** haro's own mark for the wordmark lockup — "stack" treatment from the Kuro icon
 * exploration: three horizontal bands resolving from a sparse dither, through a
 * checkerboard half-tone, to solid bone, echoing the dithered-halftone accent the
 * rest of the brand uses. Chosen over the app icon's plain "H." slab because it
 * matches the theme's dithered-asset motif instead of just repeating the icon. */
export const HaroMark = ({ size = 18 }: { size?: number }) => (
  // A live SVG <pattern> only reads as dither at the design canvas's own
  // ~62px display size — shrunk to icon size the tile is sub-pixel and every
  // renderer just blurs it into a flat wash. `haro-mark-stack.png` is baked
  // pixel-for-pixel from the same pattern math at 400x400 (brand/haro_mark_stack.py),
  // so the browser's own image downscale does one clean area-average instead.
  <img
    src="/brand/haro-mark-stack.png"
    width={size}
    height={size}
    alt=""
    aria-hidden
    style={{ display: "block", flex: "none" }}
  />
);

/** Generic remote/link glyph — for non-GitHub remotes (gitlab, self-hosted, …). */
export const LinkIcon = () => (
  <svg {...base}>
    <path d="M10 13a5 5 0 0 0 7.07 0l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
    <path d="M14 11a5 5 0 0 0-7.07 0l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
  </svg>
);

/** Down arrow — pull (bringing commits down into the local branch). */
export const ArrowDown = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <line x1="12" y1="5" x2="12" y2="19" />
    <polyline points="19 12 12 19 5 12" />
  </svg>
);

/** Up arrow — push (sending local commits up to the remote). */
export const ArrowUp = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <line x1="12" y1="19" x2="12" y2="5" />
    <polyline points="5 12 12 5 19 12" />
  </svg>
);

/** Refresh — sync/fast-forward from origin (two arrows chasing a circle). */
export const Refresh = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <polyline points="23 4 23 10 17 10" />
    <polyline points="1 20 1 14 7 14" />
    <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15" />
  </svg>
);

/** Pencil — edit an existing value in place. */
export const Pencil = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <path d="M12 20h9" />
    <path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />
  </svg>
);

/** Git branch — precedes a branch name so it reads as a ref at a glance. */
export const GitBranch = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <line x1="6" y1="3" x2="6" y2="15" />
    <circle cx="18" cy="6" r="3" />
    <circle cx="6" cy="18" r="3" />
    <path d="M18 9a9 9 0 0 1-9 9" />
  </svg>
);

/** Gear — per-project settings (opens the project-settings surface). */
export const Gear = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <circle cx="12" cy="12" r="3" />
    <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
  </svg>
);

/** Play — the run affordance (dev server / run app), replacing the ▸ text glyph. */
export const Play = ({ size = 12 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
    <path d="M8 5v14l11-7z" />
  </svg>
);

/** Monitor — the Display settings tab. */
export const Monitor = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <rect x="2" y="3" width="20" height="14" rx="2" ry="2" />
    <line x1="8" y1="21" x2="16" y2="21" />
    <line x1="12" y1="17" x2="12" y2="21" />
  </svg>
);

/** Bell — the Notifications settings tab. */
export const Bell = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" />
    <path d="M13.73 21a2 2 0 0 1-3.46 0" />
  </svg>
);

/** Sliders — the System settings tab. */
export const Sliders = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <line x1="4" y1="21" x2="4" y2="14" />
    <line x1="4" y1="10" x2="4" y2="3" />
    <line x1="12" y1="21" x2="12" y2="12" />
    <line x1="12" y1="8" x2="12" y2="3" />
    <line x1="20" y1="21" x2="20" y2="16" />
    <line x1="20" y1="12" x2="20" y2="3" />
    <line x1="1" y1="14" x2="7" y2="14" />
    <line x1="9" y1="8" x2="15" y2="8" />
    <line x1="17" y1="16" x2="23" y2="16" />
  </svg>
);

/** Gauge — the Usage settings tab (subscription rate-limit meter). */
export const Gauge = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <path d="M12 14 15.5 9.5" />
    <path d="M4.5 18a9 9 0 1 1 15 0" />
    <circle cx="12" cy="14" r="1.4" fill="currentColor" stroke="none" />
  </svg>
);

/** Star — the Agent settings tab. */
export const Star = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
  </svg>
);

/** Filled star — badges the "Insight" callout (a fun-fact highlight the agent
 *  surfaces mid-stream). Filled (not the outline `Star`) so it reads as a badge. */
export const StarFilled = ({ size = 14 }: { size?: number }) => (
  <svg viewBox="0 0 24 24" width={size} height={size} fill="currentColor" aria-hidden="true">
    <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
  </svg>
);

/** Key — the Environment (.env seed) settings tab. */
export const Key = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4" />
  </svg>
);

/** X — close buttons, error/fail marks (replaces the ✕ glyph). */
export const X = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <line x1="18" y1="6" x2="6" y2="18" />
    <line x1="6" y1="6" x2="18" y2="18" />
  </svg>
);

/** Plus — "new shell" affordance in the terminal tab strip. */
export const Plus = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <line x1="12" y1="5" x2="12" y2="19" />
    <line x1="5" y1="12" x2="19" y2="12" />
  </svg>
);

/** Square — the "stop" affordance for the dev server (replaces the ■ glyph). */
export const Square = ({ size = 12 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
    <rect x="5" y="5" width="14" height="14" rx="2" />
  </svg>
);

/** Archive — the box-with-a-lid teardown affordance (single + bulk archive). */
export const Archive = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <rect x="3" y="4" width="18" height="4" rx="1" />
    <path d="M5 8v11a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8" />
    <line x1="10" y1="13" x2="14" y2="13" />
  </svg>
);

/** AlertTriangle — "this throws work away" on the bulk-archive confirm. */
export const AlertTriangle = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <path d="M10.3 3.6 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.6a2 2 0 0 0-3.4 0Z" />
    <line x1="12" y1="9" x2="12" y2="13" />
    <line x1="12" y1="17" x2="12.01" y2="17" />
  </svg>
);

/** Zap — suspected-flaky marker (replaces the ⚡ glyph). */
export const Zap = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2" />
  </svg>
);

/** Folder — a plain (non-git) directory in the folder picker. */
export const Folder = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
  </svg>
);

/** Keyboard — opens the keyboard-shortcuts help (⌨ glyph renders tiny; use an SVG). */
export const Keyboard = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <rect x="2" y="6" width="20" height="12" rx="2" ry="2" />
    <line x1="6" y1="10" x2="6" y2="10" />
    <line x1="10" y1="10" x2="10" y2="10" />
    <line x1="14" y1="10" x2="14" y2="10" />
    <line x1="18" y1="10" x2="18" y2="10" />
    <line x1="8" y1="14" x2="16" y2="14" />
  </svg>
);

/** Paperclip — attach a file / image / media to the composer. */
export const Paperclip = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
  </svg>
);

/** Mic — focus the composer for OS-level voice dictation. */
export const Mic = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
    <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
    <line x1="12" y1="19" x2="12" y2="23" />
    <line x1="8" y1="23" x2="16" y2="23" />
  </svg>
);

/** Copy — duplicate a value to the clipboard (two overlapping sheets). */
export const Copy = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
    <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
  </svg>
);

/** Check — success/confirmation tick (e.g. "copied"). */
export const Check = ({ size = 14 }: { size?: number }) => (
  <svg {...base} width={size} height={size}>
    <polyline points="20 6 9 17 4 12" />
  </svg>
);

// Keycap symbols — rendered as SVGs (not the ⌘/⌃/↵ unicode glyphs) so hotkey
// hints stay crisp and legibly sized inside a `.kbd` chip. Default 11px to sit
// on the keycap's 10px mono baseline; they inherit color via currentColor.

/** ⌘ — the Command/Meta key (Super/Win on Linux). Lucide "command" outline. */
export const Command = ({ size = 11 }: { size?: number }) => (
  <svg {...base} width={size} height={size} aria-hidden="true">
    <path d="M15 6v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3" />
  </svg>
);

/** ⌃ — the Control key, drawn as its caret (chevron-up). */
export const Control = ({ size = 11 }: { size?: number }) => (
  <svg {...base} width={size} height={size} aria-hidden="true">
    <polyline points="18 15 12 9 6 15" />
  </svg>
);

/** ↵ — the Return/Enter key. Lucide "corner-down-left" arrow. */
export const Return = ({ size = 11 }: { size?: number }) => (
  <svg {...base} width={size} height={size} aria-hidden="true">
    <polyline points="9 10 4 15 9 20" />
    <path d="M20 4v7a4 4 0 0 1-4 4H4" />
  </svg>
);
