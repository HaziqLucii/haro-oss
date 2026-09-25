// Fuzzy file matching for the go-to-file (⌘P) palette — a small fzf-style
// subsequence scorer, kept pure so it's unit-testable without React. Greedy
// (not full DP) on purpose: file lists are small and typed queries are short,
// so a single left-to-right pass is fast and good enough for the "jump to a
// file" feel. Boundary/consecutive bonuses do the heavy lifting for ranking.

import type { FileNode } from "./types";

export interface FuzzyResult {
  path: string;
  score: number;
  /** Indices in `path` that matched a query char — for highlight rendering. */
  positions: number[];
}

// A match right after one of these reads as the start of a new "word" — the
// character the eye lands on, so weight it heavily (path segments, snake/kebab
// parts, extension dot).
const BOUNDARY = new Set(["/", "_", "-", ".", " "]);

/** Score a fuzzy subsequence match of `query` within `target` (case-insensitive).
 *  Returns null when `query` is not a subsequence of `target` at all. Higher
 *  score = better match. */
export function fuzzyMatch(query: string, target: string): { score: number; positions: number[] } | null {
  if (!query) return { score: 0, positions: [] };
  const q = query.toLowerCase();
  const t = target.toLowerCase();
  const positions: number[] = [];
  let score = 0;
  let qi = 0;
  let prevMatch = -2;
  for (let ti = 0; ti < t.length && qi < q.length; ti++) {
    if (t[ti] !== q[qi]) continue;
    positions.push(ti);
    let bonus = 0;
    if (ti === prevMatch + 1) bonus += 8; // consecutive run
    const prev = target[ti - 1];
    if (ti === 0) bonus += 12; // very start of the path
    else if (prev === "/") bonus += 10; // start of a path segment
    else if (BOUNDARY.has(prev)) bonus += 8; // word part / extension
    else if (prev === prev.toLowerCase() && target[ti] !== t[ti]) bonus += 7; // camelCase hump
    score += 1 + bonus;
    prevMatch = ti;
    qi++;
  }
  if (qi < q.length) return null; // ran out of target before matching all of query
  score -= positions[0] * 0.15; // prefer matches that start earlier
  score -= target.length * 0.02; // ...and shorter paths, all else equal
  return { score, positions };
}

/** Rank `paths` against `query`, best first. Empty query → paths in given order
 *  (already sorted by the tree walk), so ⌘P opens to a usable list. */
export function fuzzyFind(query: string, paths: string[], limit = 50): FuzzyResult[] {
  const q = query.trim();
  if (!q) return paths.slice(0, limit).map((path) => ({ path, score: 0, positions: [] }));
  const out: FuzzyResult[] = [];
  for (const path of paths) {
    const m = fuzzyMatch(q, path);
    if (m) out.push({ path, score: m.score, positions: m.positions });
  }
  out.sort((a, b) => b.score - a.score || a.path.length - b.path.length || a.path.localeCompare(b.path));
  return out.slice(0, limit);
}

/** Depth-first flatten of the worktree tree into file paths only (dirs dropped) —
 *  the corpus the ⌘P matcher searches. */
export function flattenFiles(tree: FileNode[]): string[] {
  const out: string[] = [];
  const walk = (nodes: FileNode[]) => {
    for (const n of nodes) {
      if (n.dir) {
        if (n.children) walk(n.children);
      } else {
        out.push(n.path);
      }
    }
  };
  walk(tree);
  return out;
}
