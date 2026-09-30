// Pure trigger-detection + filtering logic for the "run agent" task composer.
//
// The composer supports two kinds of inline autocomplete:
//   - `/` at the START of the input  → Claude Code slash commands
//   - `@` anywhere (at a word boundary) → worktree file paths
//
// Everything here is UI-free and side-effect-free so it can be unit-tested
// directly (see composerAutocomplete.test.ts). The React composer wires these
// into a textarea + dropdown.

import type { FileNode } from "./types";

export type TriggerKind = "slash" | "at";

export interface Trigger {
  kind: TriggerKind;
  /** Text typed after the trigger char, up to the caret (the filter query). */
  query: string;
  /** Index of the trigger char (`/` or `@`) in the source text. */
  start: number;
  /** Caret position — end of the token being completed. */
  end: number;
}

export interface SlashCommand {
  name: string; // includes the leading slash, e.g. "/review"
  description: string;
}

// The Claude Code slash commands we surface (order = display order).
export const SLASH_COMMANDS: SlashCommand[] = [
  { name: "/mcp", description: "Manage MCP servers" },
  { name: "/clear", description: "Clear conversation history" },
  { name: "/compact", description: "Summarize & compact the conversation" },
  { name: "/review", description: "Review a pull request" },
  { name: "/init", description: "Generate a CLAUDE.md for the repo" },
  { name: "/help", description: "Show available commands" },
  { name: "/model", description: "Change the model" },
];

const isSpace = (ch: string | undefined): boolean =>
  ch === " " || ch === "\t" || ch === "\n" || ch === "\r";

/**
 * Detect the active `/` or `@` token at the caret, or `null` if none.
 *
 * `@` wins over `/` when both could match, because `/` is only ever a trigger
 * at the very start of the input (a slash command), whereas `@` file paths may
 * themselves contain `/`.
 */
export function detectTrigger(text: string, caret: number): Trigger | null {
  const pos = Math.max(0, Math.min(caret, text.length));

  // @ trigger — scan backward from the caret to a boundary `@`. Whitespace
  // before reaching one means we're not inside an @-token.
  for (let i = pos - 1; i >= 0; i--) {
    const ch = text[i];
    if (isSpace(ch)) break;
    if (ch === "@") {
      const before = i === 0 ? undefined : text[i - 1];
      // Only a word-boundary `@` counts (not the `@` in an email like a@b).
      if (i === 0 || isSpace(before)) {
        return { kind: "at", query: text.slice(i + 1, pos), start: i, end: pos };
      }
      break;
    }
  }

  // slash trigger — only when the input begins with `/` and the caret is still
  // inside that first (whitespace-free) token.
  if (text[0] === "/") {
    const head = text.slice(0, pos);
    if (!/\s/.test(head)) {
      return { kind: "slash", query: text.slice(1, pos), start: 0, end: pos };
    }
  }

  return null;
}

/** Filter slash commands by the text typed after `/` (case-insensitive substring). */
export function filterSlashCommands(query: string): SlashCommand[] {
  const q = query.trim().toLowerCase();
  if (!q) return SLASH_COMMANDS;
  return SLASH_COMMANDS.filter((c) => c.name.slice(1).toLowerCase().includes(q));
}

/** Flatten a worktree file tree into a sorted list of file paths (dirs dropped). */
export function flattenFiles(nodes: FileNode[]): string[] {
  const out: string[] = [];
  const walk = (ns: FileNode[]) => {
    for (const n of ns) {
      if (n.dir) {
        if (n.children) walk(n.children);
      } else {
        out.push(n.path);
      }
    }
  };
  walk(nodes);
  return out;
}

const basename = (p: string): string => {
  const i = p.lastIndexOf("/");
  return i === -1 ? p : p.slice(i + 1);
};

// Higher = better match. Prefer basename hits over deep-path hits, and prefixes
// over mid-string matches, so `App` surfaces `App.tsx` before `components/App…`.
function score(path: string, q: string): number {
  const p = path.toLowerCase();
  const base = basename(p);
  if (base === q) return 5;
  if (base.startsWith(q)) return 4;
  if (base.includes(q)) return 3;
  if (p.startsWith(q)) return 2;
  return 1; // somewhere in the path
}

/**
 * Filter file paths by the text typed after `@`. Empty query returns the head
 * of the list. Results are ranked (basename matches first) and capped.
 */
export function filterFiles(paths: string[], query: string, limit = 50): string[] {
  const q = query.trim().toLowerCase();
  if (!q) return paths.slice(0, limit);
  return paths
    .filter((p) => p.toLowerCase().includes(q))
    .sort((a, b) => score(b, q) - score(a, q))
    .slice(0, limit);
}

/** A GitHub PR/issue reference found in the composer text (`PR #12` or `#12`). */
export interface PrRef {
  /** The PR/issue number. */
  number: number;
  /** The matched source text, e.g. `"PR #12"` or `"#131"`. */
  raw: string;
  /** Start index of the match in the source text. */
  start: number;
  /** End index (exclusive). */
  end: number;
}

// `#` followed by digits, with an optional leading `PR` word. Applied per-slice
// (see findPrRefs) so boundaries are validated in code, not with lookbehind
// (kept out for older-Safari safety, matching the manual-scan style elsewhere).
const PR_TOKEN = /^(?:PR\s+)?#(\d+)/i;

/**
 * Scan prose for GitHub PR/issue references (`PR #12`, `pr #12`, or a bare `#12`).
 *
 * A match must sit at a word boundary — preceded by start-of-text or whitespace,
 * and not immediately followed by a word char — so a markdown heading (`# Title`,
 * space after `#`), a mid-word `foo#1`, or `#12abc` do NOT match. Deliberately
 * pure + boundary-checked in code so it stays trivially unit-testable.
 */
export function findPrRefs(text: string): PrRef[] {
  const out: PrRef[] = [];
  for (let i = 0; i < text.length; i++) {
    const before = i === 0 ? undefined : text[i - 1];
    if (before !== undefined && !isSpace(before)) continue;
    const m = PR_TOKEN.exec(text.slice(i));
    if (!m) continue;
    const end = i + m[0].length;
    const after = text[end];
    if (after !== undefined && /\w/.test(after)) {
      // e.g. "#12abc" — not a clean reference; skip past it.
      i = end - 1;
      continue;
    }
    out.push({ number: parseInt(m[1], 10), raw: m[0], start: i, end });
    i = end - 1;
  }
  return out;
}

/**
 * Replace the active trigger token with `insert` (the full `/command` or
 * `@path`), append a trailing space, and return the new text + caret position.
 */
export function applyCompletion(
  text: string,
  trigger: Trigger,
  insert: string
): { text: string; caret: number } {
  const before = text.slice(0, trigger.start);
  const after = text.slice(trigger.end);
  const insertion = `${insert} `;
  return { text: before + insertion + after, caret: before.length + insertion.length };
}
