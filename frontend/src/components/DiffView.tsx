import { useEffect, useMemo, useRef, useState } from "react";
import type { DiffResponse, VerifiedFile, VerifiedHunksResponse } from "../types";
import { Chevron } from "./Chevron";
import {
  collapsesByDefault,
  hunkBadge,
  hunkProof,
  indexProof,
  lineDot,
  mergeProof,
  residueCount,
  unexecutedCount,
  type HunkProof,
} from "../verifiedHunks";

/** Structured unified-diff renderer: groups the raw git diff into collapsible
 *  per-file blocks with line-number gutters and add/del counts, so devs can
 *  scan each changed file as its own tidy section. Click an added/removed line
 *  to attach a review comment that round-trips to the agent (v1.3).
 *
 *  **Verified Hunks** (backlog/verified-hunks.md §3): when the optional `verified`
 *  prop carries the last green gate's per-line coverage map, the diff stops being a
 *  flat wall of text and becomes triage — each hunk badged "executed by the green
 *  suite" or "K of M added lines never executed", a gutter dot per added line,
 *  untested hunks sorted first, and fully-executed files collapsed by default.
 *  Omit the prop and this renders exactly as it did before.
 *
 *  What that collapse is actually FOR, measured on real agent diffs 2026-07-25: the
 *  residue is bimodal, not gradual. An agent that writes tests for its own work executes
 *  every coverable line it added (0% residue, 3/3 runs); one that doesn't executes none
 *  (100%). So this is rarely "triage a big diff down to a smaller one" — it is an ALARM
 *  that fires on the case no other guard catches: a *green* gate over code the suite
 *  never ran. Collapsing everything is the correct, quiet answer the rest of the time.
 *
 *  The word "executed" is not decoration. An executed line is not an *asserted* line,
 *  and every label here says so — see `verifiedHunks.ts`. */
export function DiffView({
  diff,
  onAddComment,
  verified = null,
  onReviewResidue,
}: {
  diff: DiffResponse | null;
  onAddComment?: (file: string, lineText: string) => void;
  // The last green gate's per-line proof for THIS diff. Pass it only for the
  // branch-vs-base diff — a single commit's patch has different line numbers, so the
  // map would be describing other lines.
  verified?: VerifiedHunksResponse | null;
  // Batch the never-executed files into the agent composer (the v1.3 comment round-trip).
  onReviewResidue?: () => void;
}) {
  const files = useMemo(() => (diff ? parseDiff(diff.diff) : []), [diff]);
  const proof = useMemo(() => indexProof(verified), [verified]);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [collapsedHunks, setCollapsedHunks] = useState<Set<string>>(new Set());
  const [mode, setMode] = useState<"unified" | "split">(() => readMode());
  const [untestedFirst, setUntestedFirst] = useState<boolean>(() => readUntestedFirst());

  // Seed the collapse sets from the proof, ONCE per (diff, proof) pair — keyed so a manual
  // expand survives an unrelated re-render but a fresh gate run re-seeds. Without the key a
  // reviewer who opened a collapsed file would watch it snap shut again on the next render.
  const seededRef = useRef<string>("");
  useEffect(() => {
    const key = `${diff?.diff.length ?? 0}:${verified?.gate_sha ?? ""}:${verified?.files.length ?? 0}`;
    if (seededRef.current === key) return;
    seededRef.current = key;
    if (!proof) {
      setCollapsed(new Set());
      setCollapsedHunks(new Set());
      return;
    }
    const nextFiles = new Set<string>();
    const nextHunks = new Set<string>();
    for (const f of files) {
      const path = f.newPath || f.oldPath;
      if (collapsesByDefault(proof, path)) {
        nextFiles.add(f.key);
        continue;
      }
      // Inside a file that still needs reading, the hunks whose every coverable line ran
      // fold away too — that's where the 1,200 → ~200 reduction actually comes from.
      const pf = proof.get(path);
      if (!pf) continue;
      f.hunks.forEach((h, hi) => {
        const p = hunkProof(pf, addedLineNos(h));
        if (p && p.kind === "executed") nextHunks.add(`${f.key}#${hi}`);
      });
    }
    setCollapsed(nextFiles);
    setCollapsedHunks(nextHunks);
  }, [files, proof, diff, verified]);

  const ordered = useMemo(() => {
    if (!untestedFirst || !proof) return files;
    // Stable: only files we KNOW have untested lines move up; everything else keeps the
    // diff's own order, so a file with no proof is never presented as if it were clean.
    return files
      .map((f, i) => ({ f, i, n: unexecutedCount(proof, f.newPath || f.oldPath) }))
      .sort((a, b) => b.n - a.n || a.i - b.i)
      .map((x) => x.f);
  }, [files, proof, untestedFirst]);

  if (!diff) {
    return <div className="diff empty">Run the agent, then refresh to see changes.</div>;
  }
  if (!diff.diff.trim() || files.length === 0) {
    return <div className="diff empty">No changes in this worktree yet.</div>;
  }

  const totalAdd = files.reduce((n, f) => n + f.additions, 0);
  const totalDel = files.reduce((n, f) => n + f.deletions, 0);
  const allCollapsed = collapsed.size === files.length;
  const residue = residueCount(verified);

  const toggle = (key: string) =>
    setCollapsed((prev) => {
      const next = new Set(prev);
      next.has(key) ? next.delete(key) : next.add(key);
      return next;
    });

  const toggleHunk = (key: string) =>
    setCollapsedHunks((prev) => {
      const next = new Set(prev);
      next.has(key) ? next.delete(key) : next.add(key);
      return next;
    });

  const toggleAll = () =>
    setCollapsed(allCollapsed ? new Set() : new Set(files.map((f) => f.key)));

  const pickMode = (m: "unified" | "split") => {
    setMode(m);
    writePref(MODE_KEY, m);
  };

  const pickUntestedFirst = (on: boolean) => {
    setUntestedFirst(on);
    writePref(SORT_KEY, on ? "1" : "0");
  };

  return (
    <div className="diff">
      <div className="diff-toolbar">
        <span className="diff-toolbar-stat">
          <b>{files.length}</b> file{files.length === 1 ? "" : "s"} changed
        </span>
        {totalAdd > 0 && <span className="diff-stat-add">+{totalAdd}</span>}
        {totalDel > 0 && <span className="diff-stat-del">−{totalDel}</span>}
        {proof && (
          <label className="diff-sort-toggle" title="Show the files the suite never executed first">
            <input
              type="checkbox"
              className="switch"
              checked={untestedFirst}
              onChange={(e) => pickUntestedFirst(e.target.checked)}
            />
            untested first
          </label>
        )}
        <span className="diff-mode-toggle" role="group" aria-label="diff view mode">
          <button
            className={"diff-mode-btn" + (mode === "unified" ? " is-active" : "")}
            onClick={() => pickMode("unified")}
          >
            Unified
          </button>
          <button
            className={"diff-mode-btn" + (mode === "split" ? " is-active" : "")}
            onClick={() => pickMode("split")}
          >
            Split
          </button>
        </span>
        <button className="link-btn diff-collapse-all" onClick={toggleAll}>
          {allCollapsed ? "expand all" : "collapse all"}
        </button>
      </div>

      {/* The proof line. Present even when it only has bad news to report (every file moved
          since the gate ran), because a silent surface reads as "nothing to flag" — which is
          the worst possible summary of "we have no evidence about any of this". */}
      {verified?.note && (
        <div className={"diff-proof" + (verified.stale ? " is-stale" : "")}>
          <span className="diff-proof-note">{verified.note}</span>
          {verified.stale && (
            <span className="diff-proof-stale" title="re-run the full gate to annotate this diff">
              the gate ran on an older tree
            </span>
          )}
          {residue > 0 && onReviewResidue && (
            <button className="link-btn diff-proof-send" onClick={onReviewResidue}>
              review the residue → agent ({residue})
            </button>
          )}
        </div>
      )}

      {ordered.map((file) => {
        const isCollapsed = collapsed.has(file.key);
        const pf = proof?.get(file.newPath || file.oldPath);
        const fileProof = pf
          ? mergeProof(file.hunks.map((h) => hunkProof(pf, addedLineNos(h))))
          : null;
        return (
          <div className={"diff-file-block" + (isCollapsed ? " is-collapsed" : "")} key={file.key}>
            <button className="diff-file-header" onClick={() => toggle(file.key)}>
              <Chevron open={!isCollapsed} />
              <FilePath display={file.display} />
              {file.tag && <span className={`diff-file-tag tag-${file.tag}`}>{file.tag}</span>}
              {/* The summary stays on the header so a collapsed file is still legible —
                  collapsing without it would just be hiding. */}
              <ProofBadge proof={fileProof} />
              <span className="diff-file-counts">
                {file.additions > 0 && <span className="diff-stat-add">+{file.additions}</span>}
                {file.deletions > 0 && <span className="diff-stat-del">−{file.deletions}</span>}
              </span>
            </button>

            {!isCollapsed &&
              (file.isBinary ? (
                <div className="diff-binary">Binary file · not shown</div>
              ) : file.hunks.length === 0 ? (
                <div className="diff-binary">No line changes.</div>
              ) : mode === "split" ? (
                <div className="diff-hunks diff-hunks-split">
                  {orderHunks(file, pf, untestedFirst).map(({ hunk, hi }) => {
                    const hp = pf ? hunkProof(pf, addedLineNos(hunk)) : null;
                    const hKey = `${file.key}#${hi}`;
                    const hidden = collapsedHunks.has(hKey);
                    return (
                      <div className="diff-hunk-block" key={hi}>
                        <div className="diff-hunk-header split">
                          <HunkLabel
                            hunk={hunk}
                            proof={hp}
                            collapsed={hidden}
                            onToggle={hp ? () => toggleHunk(hKey) : undefined}
                          />
                        </div>
                        {!hidden &&
                          buildSplitRows(hunk).map((row, ri) => (
                            <div className="diff-split-row" key={ri}>
                              <SplitCell
                                line={row.left}
                                side="old"
                                file={file}
                                proof={pf}
                                onAddComment={onAddComment}
                              />
                              <SplitCell
                                line={row.right}
                                side="new"
                                file={file}
                                proof={pf}
                                onAddComment={onAddComment}
                              />
                            </div>
                          ))}
                      </div>
                    );
                  })}
                </div>
              ) : (
                <div className="diff-hunks">
                  {orderHunks(file, pf, untestedFirst).map(({ hunk, hi }) => {
                    const hp = pf ? hunkProof(pf, addedLineNos(hunk)) : null;
                    const hKey = `${file.key}#${hi}`;
                    const hidden = collapsedHunks.has(hKey);
                    return (
                      <div className="diff-hunk-block" key={hi}>
                        <div className="diff-hunk-header">
                          {pf && <span className="diff-dot" />}
                          <span className="diff-gutter" />
                          <span className="diff-gutter" />
                          <HunkLabel
                            hunk={hunk}
                            proof={hp}
                            collapsed={hidden}
                            onToggle={hp ? () => toggleHunk(hKey) : undefined}
                          />
                        </div>
                        {!hidden &&
                          hunk.lines.map((l, li) => {
                            const commentable = !!onAddComment && l.cls !== "";
                            const sign = l.cls === "diff-add" ? "+" : l.cls === "diff-del" ? "−" : " ";
                            return (
                              <div
                                key={li}
                                className={"diff-row " + l.cls + (commentable ? " diff-commentable" : "")}
                                title={commentable ? "click to comment → agent" : undefined}
                                onClick={
                                  commentable
                                    ? () => onAddComment!(file.newPath || file.oldPath, sign + l.text)
                                    : undefined
                                }
                              >
                                {pf && <LineDot file={pf} line={l} />}
                                <span className="diff-gutter">{l.oldNo ?? ""}</span>
                                <span className="diff-gutter">{l.newNo ?? ""}</span>
                                <span className="diff-mark">{sign}</span>
                                <span className="diff-code">{l.text || " "}</span>
                              </div>
                            );
                          })}
                      </div>
                    );
                  })}
                </div>
              ))}
          </div>
        );
      })}
    </div>
  );
}

/** Reviewer prefs that outlive a session. The Unified/Split choice was never persisted
 *  before — persisting both here means a reviewer's layout survives a reload, which matters
 *  more once the diff is a triage surface you return to. */
const MODE_KEY = "haro-diff-mode";
const SORT_KEY = "haro-diff-untested-first";

function readMode(): "unified" | "split" {
  try {
    return localStorage.getItem(MODE_KEY) === "split" ? "split" : "unified";
  } catch {
    return "unified";
  }
}

function readUntestedFirst(): boolean {
  try {
    // Defaults ON: sorting the residue to the top IS the feature. With no proof the sort is
    // a no-op (every count is 0 and the sort is stable), so this can't reorder anything the
    // gate hasn't measured.
    return localStorage.getItem(SORT_KEY) !== "0";
  } catch {
    return true;
  }
}

function writePref(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* private mode / quota — a lost preference is not worth an error */
  }
}

/** The added-line numbers a hunk renders — what a per-hunk tally must be computed from. */
function addedLineNos(hunk: Hunk): number[] {
  const out: number[] = [];
  for (const l of hunk.lines) if (l.cls === "diff-add" && l.newNo != null) out.push(l.newNo);
  return out;
}

/** Hunk order within a file: untested-first when asked, otherwise the file's own order. */
function orderHunks(
  file: DiffFile,
  pf: VerifiedFile | undefined,
  untestedFirst: boolean,
): { hunk: Hunk; hi: number }[] {
  const rows = file.hunks.map((hunk, hi) => ({ hunk, hi }));
  if (!untestedFirst || !pf) return rows;
  return rows
    .map((r) => ({ ...r, n: hunkProof(pf, addedLineNos(r.hunk))?.unexecuted ?? 0 }))
    .sort((a, b) => b.n - a.n || a.hi - b.hi);
}

/** The per-hunk / per-file proof badge. Renders nothing without proof, so a diff with no
 *  gate measurement behind it looks exactly as it always did. */
function ProofBadge({ proof }: { proof: HunkProof | null }) {
  const badge = hunkBadge(proof);
  if (!badge) return null;
  return (
    <span className={"diff-proof-badge tone-" + badge.tone} title={badge.title}>
      {badge.label}
    </span>
  );
}

/** A hunk header: the `@@` label plus its badge, clickable to fold a fully-executed hunk. */
function HunkLabel({
  hunk,
  proof,
  collapsed,
  onToggle,
}: {
  hunk: Hunk;
  proof: HunkProof | null;
  collapsed: boolean;
  onToggle?: () => void;
}) {
  const label = `@@ ${hunk.section || `−${hunk.oldStart} +${hunk.newStart}`}`;
  if (!onToggle) return <span className="diff-hunk-label">{label}</span>;
  return (
    <button className="diff-hunk-toggle" onClick={onToggle}>
      <Chevron open={!collapsed} />
      <span className="diff-hunk-label">{label}</span>
      <ProofBadge proof={proof} />
    </button>
  );
}

/** The gutter dot: filled = executed under the passing suite, hollow = coverable and never
 *  executed, nothing at all = not coverable (or nothing we can attribute). The empty case is
 *  deliberate — a dot is a claim, and there is no claim to make about a blank line. */
function LineDot({ file, line }: { file: VerifiedFile; line: DiffLine }) {
  const d = line.cls === "diff-add" ? lineDot(file, line.newNo) : "";
  return (
    <span
      className={"diff-dot" + (d ? " dot-" + d : "")}
      title={
        d === "hit"
          ? "executed under the passing suite (executed ≠ asserted)"
          : d === "cold"
            ? "never executed by the suite"
            : undefined
      }
    />
  );
}

/** Path label that keeps the filename fully visible, ellipsizing only the
 *  leading directory. Renames ("old → new") are shown verbatim. */
function FilePath({ display }: { display: string }) {
  if (display.includes(" → ")) {
    return (
      <span className="diff-file-path is-rename" title={display}>
        {display}
      </span>
    );
  }
  const slash = display.lastIndexOf("/");
  const dir = slash >= 0 ? display.slice(0, slash + 1) : "";
  const name = slash >= 0 ? display.slice(slash + 1) : display;
  return (
    <span className="diff-file-path" title={display}>
      {dir && <span className="diff-file-dir">{dir}</span>}
      <span className="diff-file-name">{name}</span>
    </span>
  );
}

interface DiffLine {
  cls: "diff-add" | "diff-del" | "";
  text: string;
  oldNo: number | null;
  newNo: number | null;
}

interface Hunk {
  section: string;
  oldStart: number;
  newStart: number;
  lines: DiffLine[];
}

interface DiffFile {
  key: string;
  oldPath: string;
  newPath: string;
  display: string;
  tag: "" | "new" | "deleted" | "renamed";
  isBinary: boolean;
  additions: number;
  deletions: number;
  hunks: Hunk[];
}

interface SplitRow {
  left: DiffLine | null;
  right: DiffLine | null;
}

/** Pair a hunk's lines into GitHub-style split (side-by-side) rows: consecutive
 *  removed/added runs are zipped left/right (padding the shorter side with a
 *  blank cell), context lines span both sides unchanged. Built entirely from
 *  the already-parsed hunk — no extra fetch needed to show old vs new. */
function buildSplitRows(hunk: Hunk): SplitRow[] {
  const rows: SplitRow[] = [];
  let delBuf: DiffLine[] = [];
  let addBuf: DiffLine[] = [];
  const flush = () => {
    const n = Math.max(delBuf.length, addBuf.length);
    for (let i = 0; i < n; i++) rows.push({ left: delBuf[i] ?? null, right: addBuf[i] ?? null });
    delBuf = [];
    addBuf = [];
  };
  for (const l of hunk.lines) {
    if (l.cls === "diff-del") delBuf.push(l);
    else if (l.cls === "diff-add") addBuf.push(l);
    else {
      flush();
      rows.push({ left: l, right: l });
    }
  }
  flush();
  return rows;
}

/** One side of a split-view row: either the old (left) or new (right) line,
 *  or an empty filler cell when the other side has no counterpart. */
function SplitCell({
  line,
  side,
  file,
  proof,
  onAddComment,
}: {
  line: DiffLine | null;
  side: "old" | "new";
  file: DiffFile;
  proof?: VerifiedFile;
  onAddComment?: (file: string, lineText: string) => void;
}) {
  if (!line) return <div className="diff-split-side diff-split-empty" />;
  const no = side === "old" ? line.oldNo : line.newNo;
  const commentable = !!onAddComment && line.cls !== "";
  const sign = line.cls === "diff-add" ? "+" : line.cls === "diff-del" ? "−" : " ";
  return (
    <div
      className={"diff-split-side diff-row " + line.cls + (commentable ? " diff-commentable" : "")}
      title={commentable ? "click to comment → agent" : undefined}
      onClick={commentable ? () => onAddComment!(file.newPath || file.oldPath, sign + line.text) : undefined}
    >
      {/* Only the NEW side carries a dot: an added line's proof belongs to the line number it
          has after the change, which is the only side that has one. */}
      {proof && (side === "new" ? <LineDot file={proof} line={line} /> : <span className="diff-dot" />)}
      <span className="diff-gutter">{no ?? ""}</span>
      <span className="diff-mark">{sign}</span>
      <span className="diff-code">{line.text || " "}</span>
    </div>
  );
}

/** Parse a raw git unified diff into files → hunks → lines, tracking line numbers. */
function parseDiff(raw: string): DiffFile[] {
  const files: DiffFile[] = [];
  let file: DiffFile | null = null;
  let hunk: Hunk | null = null;
  let oldNo = 0;
  let newNo = 0;
  let isNew = false;
  let isDeleted = false;
  let isRename = false;

  const finalize = () => {
    if (!file) return;
    file.tag = isRename ? "renamed" : isNew ? "new" : isDeleted ? "deleted" : "";
    file.display =
      isRename && file.oldPath !== file.newPath
        ? `${file.oldPath} → ${file.newPath}`
        : file.newPath || file.oldPath;
    file.key = `${files.length - 1}:${file.display}`;
  };

  for (const line of raw.split("\n")) {
    if (line.startsWith("diff --git")) {
      finalize();
      file = {
        key: "",
        oldPath: "",
        newPath: "",
        display: "",
        tag: "",
        isBinary: false,
        additions: 0,
        deletions: 0,
        hunks: [],
      };
      files.push(file);
      hunk = null;
      isNew = isDeleted = isRename = false;
      const m = line.match(/^diff --git a\/(.+) b\/(.+)$/);
      if (m) {
        file.oldPath = m[1];
        file.newPath = m[2];
      }
      continue;
    }
    if (!file) continue;

    if (line.startsWith("new file mode")) {
      isNew = true;
      continue;
    }
    if (line.startsWith("deleted file mode")) {
      isDeleted = true;
      continue;
    }
    if (line.startsWith("rename from ")) {
      file.oldPath = line.slice(12);
      isRename = true;
      continue;
    }
    if (line.startsWith("rename to ")) {
      file.newPath = line.slice(10);
      isRename = true;
      continue;
    }
    if (line.startsWith("Binary files")) {
      file.isBinary = true;
      continue;
    }
    if (line.startsWith("--- ")) {
      const p = line.slice(4);
      if (p !== "/dev/null" && p.startsWith("a/")) file.oldPath = p.slice(2);
      continue;
    }
    if (line.startsWith("+++ ")) {
      const p = line.slice(4);
      if (p !== "/dev/null" && p.startsWith("b/")) file.newPath = p.slice(2);
      continue;
    }
    if (
      line.startsWith("index ") ||
      line.startsWith("old mode") ||
      line.startsWith("new mode") ||
      line.startsWith("similarity index") ||
      line.startsWith("dissimilarity index") ||
      line.startsWith("copy from") ||
      line.startsWith("copy to")
    ) {
      continue;
    }
    if (line.startsWith("@@")) {
      const m = line.match(/@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)/);
      oldNo = m ? parseInt(m[1], 10) : 0;
      newNo = m ? parseInt(m[2], 10) : 0;
      hunk = { section: m ? m[3].trim() : "", oldStart: oldNo, newStart: newNo, lines: [] };
      file.hunks.push(hunk);
      continue;
    }
    if (!hunk) continue;
    if (line.startsWith("\\")) continue; // "\ No newline at end of file"

    if (line.startsWith("+")) {
      hunk.lines.push({ cls: "diff-add", text: line.slice(1), oldNo: null, newNo });
      newNo++;
      file.additions++;
    } else if (line.startsWith("-")) {
      hunk.lines.push({ cls: "diff-del", text: line.slice(1), oldNo, newNo: null });
      oldNo++;
      file.deletions++;
    } else {
      hunk.lines.push({ cls: "", text: line.startsWith(" ") ? line.slice(1) : line, oldNo, newNo });
      oldNo++;
      newNo++;
    }
  }
  finalize();
  return files;
}
