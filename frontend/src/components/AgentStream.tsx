import {
  createContext,
  useContext,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";
import type { AgentEvent } from "../types";
import { formatCost } from "../formatCost";
import { ThinkingLoader } from "./Loader";
import { AgentMarkdown, CopyButton, copyText, renderInline, splitFences } from "./AgentMarkdown";
import { FileIcon } from "./FileIcon";
import { Chevron } from "./Chevron";
import { X } from "./icons";
import { monacoLang } from "../lang";
import { highlightLines } from "../highlight";

/** Renders the normalized agent event stream. Each of the five event types gets
 *  a distinct, minimal treatment — prose for tokens, badges for tool activity.
 *  `queued` are follow-up tasks typed while the agent is busy; they render as a
 *  dimmed section pinned at the bottom and fire (top-first) once the agent frees up. */
export function AgentStream({
  events,
  running,
  queued = [],
  onUnqueue,
  onOpenFile,
  onRewind,
}: {
  events: AgentEvent[];
  running?: boolean;
  queued?: string[];
  onUnqueue?: (index: number) => void;
  /** Open a worktree file in the code step — used by @file mentions in the task. */
  onOpenFile?: (path: string) => void;
  /** Rewind the session to a turn boundary (the `turn` ordinal of a `user` event).
   *  When passed, each turn marker becomes a "rewind to here" button; absent, the
   *  marker is a static label. The action itself is wired by the rewind-action task. */
  onRewind?: (turn: number) => void;
}) {
  const endRef = useRef<HTMLDivElement>(null);

  // Keep the newest output (or a freshly-queued task) in view.
  useEffect(() => {
    endRef.current?.scrollIntoView({ block: "end" });
  }, [events.length, queued.length]);

  const queueBlock =
    queued.length > 0 ? <QueuedList items={queued} onUnqueue={onUnqueue} /> : null;

  // Spun up, but no tokens yet — the "Thinking…" beat before output streams.
  if (running && events.length === 0) {
    return (
      <div className="stream">
        <ThinkingLoader />
        {queueBlock}
        <div ref={endRef} />
      </div>
    );
  }

  if (events.length === 0) {
    return (
      <div className={"stream" + (queueBlock ? "" : " empty")}>
        {queueBlock ?? "No agent output yet. Give it a task ↑"}
        <div ref={endRef} />
      </div>
    );
  }

  // Merge consecutive AI token events into one markdown block (so code fences that
  // span multiple streamed chunks render as a single copyable block); other event
  // types (tool_call, file_edit, done, error, system tokens) render individually.
  // The last event is "active" (still executing) while the agent runs — used to
  // pulse the bullet on the in-flight tool, mirroring the CLI's running spinner.
  const lastIdx = events.length - 1;
  const lastEv = events[lastIdx];
  const activeTool =
    !!running && !!lastEv && (lastEv.type === "tool_call" || lastEv.type === "file_edit");

  // Rebuild "turns" out of the flat event list so each finished turn can carry a
  // Conductor-style footer (wall time · copy · ⋯ · changed-file chips). A turn runs
  // from the first content event after a `user`/`done` marker up to the next `done`.
  const items: ReactNode[] = [];
  let buf = "";
  let turnStartTs: number | null = null;
  let turnText = ""; // the assistant prose of this turn — what the copy button grabs
  let turnEdits: TurnEdit[] = []; // files touched this turn, deduped + summed
  const resetTurn = () => {
    turnStartTs = null;
    turnText = "";
    turnEdits = [];
  };
  const flush = (key: string) => {
    if (buf) {
      items.push(<AgentMarkdown key={key} text={buf} />);
      buf = "";
    }
  };
  events.forEach((ev, i) => {
    // Meta-carrier tokens exist only to feed the running-model label (see
    // StreamMeta) — they hold no visible text, so never render a row for them.
    if (ev.type === "token" && ev.payload.meta) return;
    if (ev.type === "token" && !ev.payload.system) {
      if (turnStartTs == null) turnStartTs = ev.ts;
      buf += ev.payload.text ?? "";
      turnText += ev.payload.text ?? "";
      return;
    }
    flush(`md-${i}`);
    if (ev.type === "user") {
      // A new prompt starts a fresh turn — drop whatever we'd accumulated.
      items.push(<EventRow key={i} ev={ev} onOpenFile={onOpenFile} onRewind={onRewind} />);
      resetTurn();
      return;
    }
    if (ev.type !== "done" && turnStartTs == null) turnStartTs = ev.ts; // a tool/edit before any token
    if (ev.type === "file_edit") {
      const p = String(ev.payload.path ?? "");
      if (p) {
        const dl = Array.isArray(ev.payload.diff) ? (ev.payload.diff as DiffLine[]) : [];
        const tr = !!ev.payload.diff_truncated;
        const hit = turnEdits.find((e) => e.path === p);
        if (hit) {
          hit.added += Number(ev.payload.added) || 0;
          hit.removed += Number(ev.payload.removed) || 0;
          hit.diff.push(...dl);
          hit.truncated = hit.truncated || tr;
        } else {
          turnEdits.push({
            path: p,
            added: Number(ev.payload.added) || 0,
            removed: Number(ev.payload.removed) || 0,
            diff: [...dl],
            truncated: tr,
          });
        }
      }
      items.push(<EventRow key={i} ev={ev} active={i === lastIdx && activeTool} />);
      return;
    }
    if (ev.type === "done") {
      const elapsed = turnStartTs != null ? ev.ts - turnStartTs : null;
      // A `done` with nothing before it (no tokens, no tool calls, no edits) is a run
      // that produced literally no output — e.g. a re-fired click resuming an
      // already-answered session. Rendering a normal footer for it just reads as a
      // second, empty response, so drop it instead of showing a dead 0ms row.
      if (elapsed == null && !turnText && turnEdits.length === 0) {
        resetTurn();
        return;
      }
      items.push(
        <TurnFooter key={i} ev={ev} elapsed={elapsed} text={turnText} edits={turnEdits} />
      );
      resetTurn();
      return;
    }
    items.push(<EventRow key={i} ev={ev} active={i === lastIdx && activeTool} onOpenFile={onOpenFile} />);
  });
  flush("md-end");

  return (
    <FileTipProvider>
      <div className="stream">
        {items}
        {/* general "working" beat — but not when the in-flight tool is already
            pulsing its own bullet (avoid a double indicator) */}
        {running && !activeTool && <ThinkingLoader />}
        {queueBlock}
        <div ref={endRef} />
      </div>
    </FileTipProvider>
  );
}

/** The model + effort the session is *actually* running with, shown top-right of
 *  the stream so you can confirm your model/effort pick took effect. The model is
 *  the value the CLI resolved and echoed in `system:init` (authoritative — it may
 *  differ from, or concretize, a "default" pick); effort isn't echoed by the CLI,
 *  so we surface the value we invoked it with. Before the session reports in we
 *  fall back to the requested pick (dimmed, "will use"); once init lands the label
 *  upgrades to the confirmed values. */
export function StreamMeta({
  events,
  model,
  effort,
}: {
  events: AgentEvent[];
  model?: string;
  effort?: string;
}) {
  // Last init meta wins, so the label stays fresh across resumed follow-up turns.
  let confirmed: { model?: string; effort?: string; role?: string } | null = null;
  for (let i = events.length - 1; i >= 0; i--) {
    const p = events[i].payload;
    if (events[i].type === "token" && p?.model) {
      confirmed = {
        model: p.model as string,
        effort: p.effort as string | undefined,
        role: p.role as string | undefined,
      };
      break;
    }
  }

  const norm = (v?: string) => (v && v !== "default" ? v : undefined);
  const live = !!confirmed;
  // Once the session reports in, trust only what the run used (a "default"-effort
  // run legitimately shows no effort) — don't fall back to the live picker, which
  // the user may have changed since starting this run.
  const showModel = confirmed?.model ?? norm(model);
  const showEffort = live ? norm(confirmed?.effort) : norm(effort);
  if (!showModel && !showEffort) return null;
  return (
    <span
      className={"stream-meta" + (live ? " stream-meta-live" : "")}
      title={
        live
          ? "Model the agent is actually running (from session init)" +
            (showEffort ? ` · reasoning effort: ${showEffort}` : "")
          : "Selected model/effort: confirmed once the session starts"
      }
    >
      <span className="stream-meta-dot" aria-hidden="true" />
      {/* Only set when `[roles] enabled` (runner.py stamps it on the bootstrap event) —
          the plan/build step this run is, alongside the model/effort it already shows. */}
      {confirmed?.role && <span className="stream-meta-role">{confirmed.role}</span>}
      {showModel && <span className="stream-meta-model">{showModel}</span>}
      {showEffort && <span className="stream-meta-effort">{showEffort}</span>}
    </span>
  );
}

// A clone URL / long path → keep the tail readable; targets can be long.
function truncateMid(s: string, max = 72): string {
  if (!s || s.length <= max) return s;
  const head = Math.ceil(max * 0.4);
  const tail = Math.floor(max * 0.5);
  return s.slice(0, head) + "…" + s.slice(s.length - tail);
}

type DiffLine = { sign: string; text: string };
// A file touched during a turn — path + net line delta + the concatenated diff
// hunks, summed/joined across every edit to that file in the turn.
type TurnEdit = {
  path: string;
  added: number;
  removed: number;
  diff: DiffLine[];
  truncated: boolean;
};

const basename = (p: string): string => p.split(/[\\/]/).pop() || p;

// Wall-clock for a turn, from seconds. "1m 18s" / "8.3s" / "420ms" — Conductor-style.
function formatDuration(secs: number): string {
  if (secs < 1) return `${Math.round(secs * 1000)}ms`;
  if (secs < 60) return `${secs < 10 ? secs.toFixed(1) : Math.round(secs)}s`;
  const m = Math.floor(secs / 60);
  const s = Math.round(secs % 60);
  return `${m}m ${s}s`;
}

// The diff-preview popover is CLICK-toggled (not hover): click a filename chip to
// open it — it stays until you click the same chip again, click another chip, or hit
// its ✕. A SINGLE shared popover for the whole stream, tracked by the active chip's
// id. Portalled to <body> with fixed positioning because the stream pane scrolls
// (`overflow-y: auto`, which also clips X) — an in-flow panel would be cut off.
const TIP_MAX = 80; // cap diff lines in the preview (the popover itself scrolls)

type TipData = {
  id: string; // the chip that opened it — re-clicking the same chip toggles it off
  path: string;
  added?: number;
  removed?: number;
  diff?: DiffLine[];
  truncated?: boolean;
  align: "left" | "right"; // anchor to the chip's left or right edge
  rect: DOMRect; // the chip's on-screen box at click time
};

const FileTipContext = createContext<{
  activeId: string | null;
  toggle: (d: TipData) => void;
  close: () => void;
} | null>(null);

/** Owns the one shared popover. Wraps the stream. */
function FileTipProvider({ children }: { children: ReactNode }) {
  const [data, setData] = useState<TipData | null>(null);
  // same chip → close; different chip → switch to it.
  const toggle = (d: TipData) => setData((prev) => (prev && prev.id === d.id ? null : d));
  const close = () => setData(null);
  // While open, a click anywhere outside the popover closes it — except on a chip
  // (its own click toggles/switches) or inside the popover (so you can scroll it).
  // The opening click already fired before this listener attaches, so it's safe.
  useEffect(() => {
    if (!data) return;
    const onDown = (e: PointerEvent) => {
      const t = e.target;
      if (t instanceof Element && t.closest(".file-tip, .file-chip")) return;
      setData(null);
    };
    document.addEventListener("pointerdown", onDown);
    return () => document.removeEventListener("pointerdown", onDown);
  }, [data]);
  return (
    <FileTipContext.Provider value={{ activeId: data?.id ?? null, toggle, close }}>
      {children}
      <FileTipView data={data} onClose={close} />
    </FileTipContext.Provider>
  );
}

// Tokenize the shown diff lines with Monaco (reusing the bundled tokenizer, see
// highlight.ts) so the preview reads like the editor — coloured, not flat black.
// Returns per-line HTML aligned to `shown`, or null while it loads / for unknown
// languages, in which case the caller renders plain text. Keyed on the file path +
// its diff text so re-highlighting only fires when the previewed content changes.
function useHighlightedDiff(shown: DiffLine[], path: string): string[] | null {
  const [html, setHtml] = useState<string[] | null>(null);
  // The app writes the family to data-theme and the light/dark ground to data-mode
  // (see App.tsx); rebuild the "<family>-<mode>" prop so the preview colours track the
  // current theme. Reading data-theme AS the mode was the light-mode readability bug.
  const el = document.documentElement;
  const themeProp =
    (el.dataset.theme || "haro") + "-" + (el.dataset.mode === "light" ? "light" : "dark");
  const key = path + " " + shown.map((d) => d.text).join("\n");
  useEffect(() => {
    setHtml(null);
    if (!shown.length) return;
    let live = true;
    highlightLines(shown.map((d) => d.text).join("\n"), monacoLang(path), themeProp).then((lines) => {
      // Only apply if the tokenizer returned one line per source line — otherwise a
      // mismatch would misalign colours onto the wrong +/- rows.
      if (live && lines && lines.length === shown.length) setHtml(lines);
    });
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return html;
}

/** The single popover. Re-measures + repositions whenever `data` changes (a
 *  different chip was clicked), so there's only ever one on screen. */
function FileTipView({ data, onClose }: { data: TipData | null; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<CSSProperties>({ visibility: "hidden" });
  useLayoutEffect(() => {
    if (!data || !ref.current) return;
    const t = ref.current.getBoundingClientRect();
    const { rect, align } = data;
    const above = rect.top > t.height + 12; // prefer above; flip below if no room
    let top = above ? rect.top - 6 - t.height : rect.bottom + 6;
    let left = align === "right" ? rect.right - t.width : rect.left;
    left = Math.max(8, Math.min(left, window.innerWidth - t.width - 8));
    top = Math.max(8, Math.min(top, window.innerHeight - t.height - 8));
    setPos({ top, left, visibility: "visible" });
  }, [data]);

  const diff = data?.diff;
  const hasDiff = Array.isArray(diff) && diff.length > 0;
  const shown = hasDiff ? diff!.slice(0, TIP_MAX) : [];
  const highlighted = useHighlightedDiff(shown, data?.path ?? "");

  if (!data) return null;
  const { path, added, removed, truncated } = data;
  const more = hasDiff ? diff!.length - shown.length : 0;
  return createPortal(
    <div className="file-tip" ref={ref} style={{ top: 0, left: 0, ...pos }} role="dialog">
      <div className="file-tip-head">
        <span className="file-tip-path">{path}</span>
        <span className="file-tip-head-right">
          {(added || removed) && (
            <span className="file-tip-stat">
              {added ? <span className="ev-add">+{added}</span> : null}
              {removed ? <span className="ev-del">−{removed}</span> : null}
            </span>
          )}
          <button className="file-tip-close" onClick={onClose} title="Close" aria-label="Close">
            <X />
          </button>
        </span>
      </div>
      {hasDiff ? (
        <div className="file-tip-diff">
          {shown.map((d, i) => (
            <div key={i} className={"cht-line " + (d.sign === "+" ? "cht-add" : "cht-del")}>
              <span className="cht-sign">{d.sign}</span>
              {highlighted ? (
                <span className="cht-text" dangerouslySetInnerHTML={{ __html: highlighted[i] || " " }} />
              ) : (
                <span className="cht-text">{d.text || " "}</span>
              )}
            </div>
          ))}
          {(more > 0 || truncated) && (
            <div className="cht-more">
              {more > 0 ? `… ${more} more line${more === 1 ? "" : "s"}` : "… diff truncated"}
            </div>
          )}
        </div>
      ) : (
        <div className="file-tip-empty">line-level diff not captured</div>
      )}
    </div>,
    document.body
  );
}

// A VS Code-flavoured file pill: type icon + basename + net +/-. Click it to toggle
// the shared diff popover (see FileTipProvider) — it renders no popover itself.
function FileChip({
  path,
  added,
  removed,
  diff,
  truncated,
  align = "left",
}: {
  path: string;
  added?: number;
  removed?: number;
  diff?: DiffLine[];
  truncated?: boolean;
  align?: "left" | "right";
}) {
  const ref = useRef<HTMLSpanElement>(null);
  const id = useId();
  const tip = useContext(FileTipContext);
  const open = tip?.activeId === id;
  const toggle = (e: { stopPropagation: () => void }) => {
    e.stopPropagation(); // don't also toggle a parent edit-row's inline diff
    if (tip && ref.current) {
      tip.toggle({
        id,
        path,
        added,
        removed,
        diff,
        truncated,
        align,
        rect: ref.current.getBoundingClientRect(),
      });
    }
  };
  return (
    <span
      className={"file-chip file-chip-btn" + (open ? " file-chip-open" : "")}
      ref={ref}
      role="button"
      tabIndex={0}
      aria-expanded={open}
      title={open ? "Hide changes" : "Show changes"}
      onClick={toggle}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          toggle(e);
        }
      }}
    >
      <FileIcon path={path} />
      <span className="file-chip-name">{basename(path)}</span>
      {(added || removed) && (
        <span className="file-chip-stat">
          {added ? <span className="ev-add">+{added}</span> : null}
          {removed ? <span className="ev-del">−{removed}</span> : null}
        </span>
      )}
    </span>
  );
}

const CopyIcon = () => (
  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <rect x="9" y="9" width="11" height="11" rx="2" />
    <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
  </svg>
);
const CheckIcon = () => (
  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M20 6 9 17l-5-5" />
  </svg>
);

// The footer that closes a finished turn — wall time · copy the message · a ⋯
// overflow menu (token/cost detail + copy actions) · the changed-file chips.
function TurnFooter({
  ev,
  elapsed,
  text,
  edits,
}: {
  ev: AgentEvent;
  elapsed: number | null;
  text: string;
  edits: TurnEdit[];
}) {
  const [copied, setCopied] = useState(false);
  const [menu, setMenu] = useState(false);
  const moreRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const [menuPos, setMenuPos] = useState<CSSProperties | null>(null);
  const tokIn = ev.payload.tokens_in ?? 0;
  const tokOut = ev.payload.tokens_out ?? 0;
  const cost = ev.payload.cost_usd;
  const copy = async (s: string) => {
    if (!s) return;
    await copyText(s);
  };

  // Position the (portalled, fixed) menu next to the ⋯ button, flipping above it
  // when there isn't room below — so a footer near the pane's bottom doesn't push
  // the menu off-screen.
  useLayoutEffect(() => {
    if (!menu || !moreRef.current || !menuRef.current) return;
    const b = moreRef.current.getBoundingClientRect();
    const m = menuRef.current.getBoundingClientRect();
    const below = b.bottom + m.height + 8 <= window.innerHeight;
    const top = below ? b.bottom + 4 : b.top - 4 - m.height;
    const left = Math.max(8, Math.min(b.left, window.innerWidth - m.width - 8));
    setMenuPos({ top: Math.max(8, top), left, visibility: "visible" });
  }, [menu]);
  return (
    <div className="turn-foot">
      {elapsed != null && (
        <span className="turn-time" title="wall time for this turn">
          {formatDuration(elapsed)}
        </span>
      )}
      <button
        type="button"
        className={"turn-btn" + (copied ? " turn-btn-ok" : "")}
        title={text ? "Copy this message" : "Nothing to copy"}
        disabled={!text}
        onClick={async () => {
          await copy(text);
          setCopied(true);
          setTimeout(() => setCopied(false), 1300);
        }}
      >
        {copied ? <CheckIcon /> : <CopyIcon />}
      </button>
      <div className="turn-more-wrap">
        <button
          ref={moreRef}
          type="button"
          className="turn-btn"
          title="More"
          aria-haspopup="menu"
          aria-expanded={menu}
          onClick={() => setMenu((m) => !m)}
        >
          ⋯
        </button>
        {menu &&
          createPortal(
            <>
              <div className="turn-more-backdrop" onClick={() => setMenu(false)} />
              <div
                className="turn-more-menu"
                ref={menuRef}
                role="menu"
                style={{ top: 0, left: 0, visibility: "hidden", ...menuPos }}
              >
                <div className="turn-more-info">
                  {tokIn} in / {tokOut} out
                  {cost != null ? ` · ${formatCost(cost)}` : ""}
                </div>
                <button
                  type="button"
                  role="menuitem"
                  onClick={async () => {
                    await copy(text);
                    setMenu(false);
                  }}
                >
                  Copy message
                </button>
                {edits.length > 0 && (
                  <button
                    type="button"
                    role="menuitem"
                    onClick={async () => {
                      await copy(edits.map((e) => `${e.path} +${e.added} −${e.removed}`).join("\n"));
                      setMenu(false);
                    }}
                  >
                    Copy changed files
                  </button>
                )}
              </div>
            </>,
            document.body
          )}
      </div>
      {edits.length > 0 && (
        <div className="turn-files">
          {edits.map((e, i) => (
            <FileChip
              key={i}
              path={e.path}
              added={e.added}
              removed={e.removed}
              diff={e.diff}
              truncated={e.truncated}
              align="right"
            />
          ))}
        </div>
      )}
    </div>
  );
}

// A file-edit op row that expands to show the actual diff (red − / green +),
// mirroring the CLI's inline diff under an Edit. Collapsed by default.
function FileEditRow({ ev, active }: { ev: AgentEvent; active?: boolean }) {
  const { tool, path, added, removed, diff, diff_truncated } = ev.payload;
  const [open, setOpen] = useState(false);
  const hasDiff = Array.isArray(diff) && diff.length > 0;
  return (
    <div className="ev-op-wrap">
      <div
        className={"ev-op" + (hasDiff ? " ev-op-click" : "")}
        onClick={hasDiff ? () => setOpen((o) => !o) : undefined}
        role={hasDiff ? "button" : undefined}
        title={hasDiff ? (open ? "Hide diff" : "Show diff") : undefined}
      >
        <span className={"ev-op-dot" + (active ? " ev-op-dot-run" : " ev-op-dot-done")} />
        <span className="ev-op-name">{tool}</span>
        {path ? (
          <FileChip
            path={String(path)}
            added={added}
            removed={removed}
            diff={diff as DiffLine[] | undefined}
            truncated={diff_truncated}
          />
        ) : (
          (added != null || removed != null) && (
            <span className="ev-op-stat">
              {added ? <span className="ev-add">+{added}</span> : null}
              {removed ? <span className="ev-del">−{removed}</span> : null}
            </span>
          )
        )}
        {hasDiff && <Chevron open={open} className="ev-op-chev" />}
      </div>
      {open && hasDiff && (
        <pre className="ev-diff">
          {(diff as { sign: string; text: string }[]).map((d, i) => (
            <div
              key={i}
              className={"ev-diff-line " + (d.sign === "+" ? "ev-diff-add" : "ev-diff-del")}
            >
              <span className="ev-diff-sign">{d.sign}</span>
              <span className="ev-diff-text">{d.text || " "}</span>
            </div>
          ))}
          {diff_truncated && <div className="ev-diff-more dim">… diff truncated</div>}
        </pre>
      )}
    </div>
  );
}

/** Follow-up tasks waiting their turn — dimmed, numbered, each removable. */
function QueuedList({ items, onUnqueue }: { items: string[]; onUnqueue?: (i: number) => void }) {
  return (
    <div className="stream-queue">
      <div className="stream-queue-head dim">
        queued · {items.length} {items.length === 1 ? "task" : "tasks"} · sends when the agent frees up
      </div>
      {items.map((text, i) => (
        <div className="ev-queued" key={i}>
          <span className="ev-queued-num">{i + 1}</span>
          <span className="ev-queued-text">{text}</span>
          {onUnqueue && (
            <button
              type="button"
              className="ev-queued-x"
              title="Remove from queue"
              onClick={() => onUnqueue(i)}
            >
              <X />
            </button>
          )}
        </div>
      ))}
    </div>
  );
}

// Render the echo of a prompt the user sent: markdown formatting + clickable `@file`
// mentions. Three concerns, deliberately layered outside-in so each is handled where it
// belongs:
//
//   1. FENCES first (`splitFences`). A ``` block is rendered as a real code block, and
//      crucially nothing inside it is touched afterwards — an `@decorator` in pasted
//      Python must not become a file link, and `**` inside code is not bold.
//   2. `@file` mentions in the prose between fences (the composer's `@` trigger), as
//      clickable chips that open the file in ② code.
//   3. INLINE markdown on what is left, via the very same `renderInline` the agent's own
//      output uses. Sharing that renderer is the point: the two halves of one transcript
//      cannot drift on what `**bold**` means.
//
// Note this is display only. The text sent to the agent is byte-identical either way, and
// markdown in a prompt was never a problem for the model — it reads it natively. This is
// about YOUR transcript being readable, nothing else.
export function renderTaskText(text: string, onOpenFile?: (path: string) => void): ReactNode[] {
  return splitFences(text).flatMap((part, pi): ReactNode[] =>
    part.type === "code"
      ? [
          <div className="code-block" key={`pc-${pi}`}>
            {part.lang && <span className="code-lang">{part.lang}</span>}
            <CopyButton text={part.content} />
            <pre>
              <code>{part.content}</code>
            </pre>
          </div>,
        ]
      : renderPromptProse(part.content, `pp-${pi}`, onOpenFile)
  );
}

// Step 2 + 3: `@file` chips, with inline markdown applied to everything between them.
// Boundary rules match the composer: only `@` at the start or after whitespace counts
// (so emails aren't caught).
function renderPromptProse(
  text: string,
  keyBase: string,
  onOpenFile?: (path: string) => void
): ReactNode[] {
  if (!onOpenFile) return renderInline(text, keyBase);
  const out: ReactNode[] = [];
  let buf = "";
  let i = 0;
  let k = 0;
  const flush = () => {
    if (buf) {
      out.push(...renderInline(buf, `${keyBase}-${out.length}`));
      buf = "";
    }
  };
  while (i < text.length) {
    const boundary = i === 0 || /\s/.test(text[i - 1]);
    if (text[i] === "@" && boundary) {
      const m = /^@(\S+)/.exec(text.slice(i));
      if (m) {
        // Peel trailing punctuation that reads as prose, not part of the path
        // (a comma/paren after the mention). A dot is kept — it's a real extension.
        const trail = /[),;:!?]+$/.exec(m[1])?.[0] ?? "";
        const path = trail ? m[1].slice(0, -trail.length) : m[1];
        if (path) {
          flush();
          out.push(
            <button
              key={`${keyBase}-f${k++}`}
              type="button"
              className="ev-file-ref"
              title={`Open ${path} in the code step`}
              onClick={() => onOpenFile(path)}
            >
              @{path}
            </button>
          );
          if (trail) out.push(trail);
          i += m[0].length;
          continue;
        }
      }
    }
    buf += text[i];
    i += 1;
  }
  flush();
  return out;
}

// The per-turn marker pinned to the right of a `user` prompt row — the visible turn
// boundary. When `onRewind` is wired (the rewind-action task) it's a "rewind to here"
// button; until then it's a static "turn N" label, so the boundaries are still marked.
function TurnMark({ turn, onRewind }: { turn: number; onRewind?: (turn: number) => void }) {
  if (onRewind) {
    return (
      <button
        type="button"
        className="ev-turn-rewind"
        title={`Rewind the session to turn ${turn} and re-prompt from here`}
        onClick={() => onRewind(turn)}
      >
        ⤺ rewind to here
      </button>
    );
  }
  return (
    <span className="ev-turn-mark" title={`Turn ${turn}`}>
      turn {turn}
    </span>
  );
}

export function EventRow({
  ev,
  active,
  onOpenFile,
  onRewind,
}: {
  ev: AgentEvent;
  active?: boolean;
  onOpenFile?: (path: string) => void;
  onRewind?: (turn: number) => void;
}) {
  switch (ev.type) {
    case "user":
      return (
        <div className="ev-user">
          <span className="ev-user-mark">›</span>
          <span className="ev-user-text">
            {renderTaskText(String(ev.payload.text ?? ""), onOpenFile)}
          </span>
          {typeof ev.turn === "number" && <TurnMark turn={ev.turn} onRewind={onRewind} />}
        </div>
      );
    case "token":
      return (
        <pre className={"ev-token" + (ev.payload.system ? " ev-system" : "")}>
          {ev.payload.text}
        </pre>
      );
    case "tool_call": {
      // CLI-style op line: ● Tool(target). A sub-agent delegation (haro's own
      // scout, Phase 2 — notes/workflow-roles-plan.md) renders its summary as
      // "↳ <subagent>: <description>" (see claude_code.py's _delegate_summary) —
      // dim and indent it so it reads as "handed off", not another tool call.
      const summary = ev.payload.summary ? String(ev.payload.summary) : "";
      const isDelegate = summary.startsWith("↳");
      return (
        <div className={"ev-op" + (isDelegate ? " ev-delegate" : "")}>
          <span className={"ev-op-dot" + (active ? " ev-op-dot-run" : " ev-op-dot-done")} />
          {isDelegate ? (
            <span className="ev-op-target">{truncateMid(summary)}</span>
          ) : (
            <>
              <span className="ev-op-name">{ev.payload.tool}</span>
              {summary && <span className="ev-op-target">({truncateMid(summary)})</span>}
            </>
          )}
        </div>
      );
    }
    case "file_edit":
      return <FileEditRow ev={ev} active={active} />;
    case "done":
      return (
        <div className="ev-done">
          ◆ done · {ev.payload.tokens_in ?? 0} in / {ev.payload.tokens_out ?? 0} out
          {ev.payload.cost_usd != null ? ` · ${formatCost(ev.payload.cost_usd)}` : ""}
        </div>
      );
    case "error":
      return <div className="ev-error"><X /> {ev.payload.message}</div>;
    default:
      return null;
  }
}
