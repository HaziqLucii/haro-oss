import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { api } from "../api";
import {
  applyCompletion,
  detectTrigger,
  filterFiles,
  filterSlashCommands,
  findPrRefs,
  flattenFiles,
  SLASH_COMMANDS,
  type PrRef,
  type Trigger,
} from "../composerAutocomplete";
import { shouldAttachPaste } from "../attachments";
import { GitHubMark, ExternalLink } from "./icons";

const COMMAND_NAMES = new Set(SLASH_COMMANDS.map((c) => c.name));

// Same PR/issue reference token as findPrRefs, anchored for per-slice matching in
// the highlighter. Kept in lockstep with composerAutocomplete's PR_TOKEN.
const PR_HL = /^(?:PR\s+)?#\d+/i;

// Voice dictation is handled by the OS, not the browser: macOS Fn-Fn, Windows Win+H,
// and most Linux DEs all type dictated text straight into whatever field has focus.
// That's local (no audio leaves the device, unlike the Chrome Web Speech API this
// replaced, which shipped captured audio to Google for transcription) and needs no
// recognition code here — just a way to focus the textarea, plus a hint so people
// who don't know their OS shortcut can find it.
function osDictationHint(): string {
  const p = (navigator.platform || navigator.userAgent || "").toLowerCase();
  if (p.includes("mac")) return "press Fn twice to dictate";
  if (p.includes("win")) return "press Win + H to dictate";
  return "use your OS's dictation shortcut";
}
export const DICTATION_HINT =
  typeof navigator !== "undefined" ? osDictationHint() : "use your OS's dictation shortcut";

// Highlight the inline tokens on a single prose line:
//   • a leading /command that matches a known command (only on the first line)
//   • @file mentions at a word boundary (start or after whitespace — not emails)
//   • PR/issue references (`PR #12` or a bare `#12`) at a word boundary
// Rendered into an overlay behind a transparent-text textarea, so it MUST be
// width-safe: token spans change only color/background, never font-weight, padding,
// or letter-spacing — otherwise the overlay drifts out of sync with the caret.
function highlightLine(line: string, isFirst: boolean, keyBase: number): ReactNode[] {
  const out: ReactNode[] = [];
  let buf = "";
  let i = 0;
  let k = keyBase * 1000;
  const flush = () => {
    if (buf) {
      out.push(buf);
      buf = "";
    }
  };
  while (i < line.length) {
    const ch = line[i];
    const boundary = i === 0 || /\s/.test(line[i - 1]);
    if (ch === "/" && i === 0 && isFirst) {
      const m = /^\/\S+/.exec(line.slice(i));
      if (m && COMMAND_NAMES.has(m[0])) {
        flush();
        out.push(
          <span key={k++} className="ctok ctok-cmd">
            {m[0]}
          </span>
        );
        i += m[0].length;
        continue;
      }
    }
    if (ch === "@" && boundary) {
      const m = /^@\S+/.exec(line.slice(i));
      if (m) {
        flush();
        out.push(
          <span key={k++} className="ctok ctok-file">
            {m[0]}
          </span>
        );
        i += m[0].length;
        continue;
      }
    }
    if (boundary) {
      const m = PR_HL.exec(line.slice(i));
      // Reject a trailing word char (#12abc) so it matches findPrRefs exactly.
      if (m && !/\w/.test(line[i + m[0].length] ?? "")) {
        flush();
        out.push(
          <span key={k++} className="ctok ctok-pr">
            {m[0]}
          </span>
        );
        i += m[0].length;
        continue;
      }
    }
    buf += ch;
    i += 1;
  }
  flush();
  return out;
}

// Render the composer's text into the highlight overlay. On top of the inline
// /command + @file tokens, this recognises Slack-style triple-backtick fences:
// everything from a line beginning with ``` up to the matching closing ``` (or
// end of input) gets the `.hlrow-code` background so pasted code reads as a code
// block, not prose.
//
// ALIGNMENT: every source line becomes one full-width block row (`.hlrow`). Block
// rows carry the line breaks (no interleaved "\n"), share the textarea's exact
// font / size / line-height / wrapping, and add NO padding, margin, border, or
// letter-spacing — so a row wraps at the same column as the transparent textarea
// and the caret stays glyph-aligned. Full-width rows also let a code background
// span the whole line (fixing the ragged, per-glyph "staircase" an inline span
// produced); consecutive code rows abut into one clean rectangle, with only the
// block's outer corners rounded (see `.hlrow-code` in styles.css).
function highlightComposer(text: string): ReactNode[] {
  const lines = text.split("\n");
  const rows: ReactNode[] = [];
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const isFence = /^```/.test(line);
    let cls = "hlrow";
    let content: ReactNode;
    if (isFence) {
      // the fence marker line is part of the code box and flips the state
      cls += " hlrow-code hlrow-code-fence";
      content = line;
      inFence = !inFence;
    } else if (inFence) {
      cls += " hlrow-code";
      content = line;
    } else {
      content = highlightLine(line, i === 0, i);
    }
    rows.push(
      <div key={i} className={cls}>
        {content}
      </div>
    );
  }
  return rows;
}

// One row in the autocomplete dropdown, normalized across the two trigger kinds.
interface Item {
  insert: string; // the text placed into the composer (e.g. "/review", "@src/App.tsx")
  label: string; // primary text
  hint?: string; // secondary/dim text (command description)
}

/**
 * The "run agent" task composer: a textarea with inline autocomplete.
 *   - `/` at the start  → Claude Code slash commands
 *   - `@` anywhere       → worktree file paths (fetched lazily, then cached)
 * Keyboard-first: ↑/↓ move, Enter/Tab insert at the caret, Esc dismisses.
 * The trigger-detection + filtering lives in ../composerAutocomplete (pure + tested);
 * this component is just the wiring + dropdown UI.
 */
export function TaskComposer({
  value,
  onChange,
  onSubmit,
  disabled,
  workspaceId,
  placeholder,
  rows = 5,
  onAttachPaste,
  onAttachFiles,
  prBaseUrl,
  dictateFocusRef,
}: {
  value: string;
  onChange: (v: string) => void;
  onSubmit?: () => void; // ⌘/Ctrl+Enter — run or queue the task
  disabled?: boolean;
  workspaceId: string;
  placeholder?: string;
  rows?: number;
  // Browsable repo base (https://host/owner/repo) — when set, typed `PR #N`
  // references surface as clickable chips that deep-link to `${prBaseUrl}/pull/N`.
  prBaseUrl?: string | null;
  // A large pasted block is diverted to a file attachment instead of being inserted.
  onAttachPaste?: (text: string) => void;
  // Pasted images / files (from the clipboard) are diverted to .context/ attachments.
  onAttachFiles?: (files: File[]) => void;
  // OS-level dictation types into whatever field has focus; the mic BUTTON is
  // rendered by the parent so it can sit beside the other composer controls, so we
  // hand it a focus function via this ref.
  dictateFocusRef?: React.MutableRefObject<(() => void) | null>;
}) {
  const taRef = useRef<HTMLTextAreaElement>(null);
  const hlRef = useRef<HTMLDivElement>(null);
  const [trigger, setTrigger] = useState<Trigger | null>(null);
  const [sel, setSel] = useState(0);
  // Dismissed while this exact token (kind:start:query) is active; typing more reopens it.
  const [dismissed, setDismissed] = useState<string | null>(null);
  // Worktree file paths, fetched on the first `@` and cached per workspace.
  const [files, setFiles] = useState<string[] | null>(null);
  const pendingCaret = useRef<number | null>(null);

  // Hand the parent a focus function (reassigned each render) so clicking the mic
  // affordance focuses this field for OS dictation.
  if (dictateFocusRef) dictateFocusRef.current = () => taRef.current?.focus();

  // Reset the file cache when the workspace changes.
  useEffect(() => {
    setFiles(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspaceId]);

  // Lazily fetch the file list the first time an `@` trigger appears.
  useEffect(() => {
    if (trigger?.kind !== "at" || files !== null) return;
    let alive = true;
    api
      .listFiles(workspaceId)
      .then((r) => alive && setFiles(flattenFiles(r.tree)))
      .catch(() => alive && setFiles([]));
    return () => {
      alive = false;
    };
  }, [trigger?.kind, files, workspaceId]);

  const triggerKey = trigger ? `${trigger.kind}:${trigger.start}:${trigger.query}` : null;
  const open = trigger !== null && triggerKey !== dismissed;

  const items: Item[] = useMemo(() => {
    if (!trigger) return [];
    if (trigger.kind === "slash") {
      return filterSlashCommands(trigger.query).map((c) => ({
        insert: c.name,
        label: c.name,
        hint: c.description,
      }));
    }
    if (files === null) return []; // still loading
    return filterFiles(files, trigger.query).map((p) => ({ insert: `@${p}`, label: p }));
  }, [trigger, files]);

  // Distinct PR/issue references in the current text, in first-seen order — the
  // clickable chip strip below the composer. Only shown when we have a repo web
  // base to link to (a remote exists); local-only workspaces just get the inline
  // highlight, since there's no PR page to open.
  const prChips: PrRef[] = useMemo(() => {
    if (!prBaseUrl) return [];
    const seen = new Set<number>();
    const chips: PrRef[] = [];
    for (const ref of findPrRefs(value)) {
      if (seen.has(ref.number)) continue;
      seen.add(ref.number);
      chips.push(ref);
    }
    return chips;
  }, [value, prBaseUrl]);

  // Keep the selection valid + reset it as the query/items change.
  useEffect(() => setSel(0), [triggerKey]);

  // Restore the caret after inserting a completion (value is controlled).
  useEffect(() => {
    if (pendingCaret.current == null) return;
    const el = taRef.current;
    if (el) {
      el.focus();
      el.setSelectionRange(pendingCaret.current, pendingCaret.current);
    }
    pendingCaret.current = null;
  }, [value]);

  // Recompute the active trigger from the live caret + value.
  const sync = () => {
    const el = taRef.current;
    if (!el) return;
    setTrigger(detectTrigger(el.value, el.selectionStart ?? el.value.length));
  };

  // Keep the highlight overlay scrolled in lockstep with the textarea.
  const syncScroll = () => {
    const ta = taRef.current;
    const hl = hlRef.current;
    if (ta && hl) {
      hl.scrollTop = ta.scrollTop;
      hl.scrollLeft = ta.scrollLeft;
    }
  };

  const choose = (item?: Item) => {
    if (!item || !trigger) return;
    const res = applyCompletion(value, trigger, item.insert);
    pendingCaret.current = res.caret;
    onChange(res.text);
    setTrigger(null);
    setDismissed(null);
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // ⌘/Ctrl+Enter submits (runs, or queues if the agent is busy) regardless of
    // the autocomplete state — a plain Enter still inserts a newline.
    // stopPropagation so the app-level window ⌘+Enter listener (App.tsx) doesn't
    // also fire and double-submit while the prompt is focused.
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && onSubmit) {
      e.preventDefault();
      e.stopPropagation();
      setTrigger(null);
      onSubmit();
      return;
    }
    if (!open || items.length === 0) {
      // Still let Esc clear a stale/loading trigger.
      if (e.key === "Escape" && trigger) {
        setTrigger(null);
      }
      return;
    }
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSel((s) => Math.min(s + 1, items.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSel((s) => Math.max(s - 1, 0));
    } else if (e.key === "Enter" || e.key === "Tab") {
      e.preventDefault();
      choose(items[sel]);
    } else if (e.key === "Escape") {
      e.preventDefault();
      setDismissed(triggerKey);
    }
  };

  return (
    <div className="composer-input">
      {open && (
        <div className="ac-menu" role="listbox">
          {items.length === 0 ? (
            <div className="ac-empty dim">
              {trigger?.kind === "at" && files === null ? "loading files…" : "no matches"}
            </div>
          ) : (
            items.map((it, i) => (
              <button
                key={it.insert}
                type="button"
                role="option"
                aria-selected={i === sel}
                className={"ac-item" + (i === sel ? " ac-sel" : "")}
                // Use mousedown so the textarea doesn't blur before the click lands.
                onMouseDown={(e) => {
                  e.preventDefault();
                  choose(it);
                }}
                onMouseEnter={() => setSel(i)}
                ref={i === sel ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
              >
                <span className="ac-label">{it.label}</span>
                {it.hint && <span className="ac-hint dim">{it.hint}</span>}
              </button>
            ))
          )}
        </div>
      )}
      <div className="composer-ta-wrap">
        {/* overlay behind the transparent-text textarea; renders the same text with
            /command + @file tokens colored so they read apart from normal prose */}
        <div className="composer-hl" ref={hlRef} aria-hidden="true">
          {highlightComposer(value)}
        </div>
        <textarea
          id="agent-input"
          className="composer-ta"
          ref={taRef}
          value={value}
          onChange={(e) => {
            onChange(e.target.value);
            setTrigger(detectTrigger(e.target.value, e.target.selectionStart ?? e.target.value.length));
          }}
          onKeyDown={onKeyDown}
          onPaste={(e) => {
            // A pasted image (screenshot) or file lands in clipboardData.files —
            // divert it to a .context/ attachment instead of the (empty) text paste.
            const files = Array.from(e.clipboardData.files ?? []);
            if (files.length && onAttachFiles) {
              e.preventDefault();
              onAttachFiles(files);
              return;
            }
            if (!onAttachPaste) return;
            const text = e.clipboardData.getData("text");
            if (shouldAttachPaste(text)) {
              e.preventDefault();
              onAttachPaste(text);
            }
          }}
          onClick={sync}
          onScroll={syncScroll}
          onKeyUp={(e) => {
            // Arrow/Home/End move the caret without changing the value.
            if (e.key.startsWith("Arrow") || e.key === "Home" || e.key === "End") sync();
          }}
          onBlur={() => setTrigger(null)}
          placeholder={placeholder}
          rows={rows}
          disabled={disabled}
        />
      </div>
      {prChips.length > 0 && (
        <div className="composer-pr-chips" aria-label="referenced pull requests">
          {prChips.map((ref) => (
            <a
              key={ref.number}
              className="composer-pr-chip"
              href={`${prBaseUrl}/pull/${ref.number}`}
              target="_blank"
              rel="noopener noreferrer"
              title={`Open PR #${ref.number} on GitHub (if it exists)`}
            >
              <GitHubMark size={12} />
              <span className="composer-pr-chip-num">#{ref.number}</span>
              <ExternalLink />
            </a>
          ))}
        </div>
      )}
    </div>
  );
}
