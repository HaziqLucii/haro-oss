import { useEffect, useMemo, useRef, useState } from "react";
import { fuzzyFind } from "../fuzzy";
import { FileIcon } from "./FileIcon";

/** Split a path into a highlighted-span list given the matched char indices,
 *  so the fuzzy hits glow while the rest stays dim. */
function highlight(path: string, positions: number[]) {
  const hit = new Set(positions);
  const spans: { text: string; on: boolean }[] = [];
  for (let i = 0; i < path.length; i++) {
    const on = hit.has(i);
    const last = spans[spans.length - 1];
    if (last && last.on === on) last.text += path[i];
    else spans.push({ text: path[i], on });
  }
  return spans;
}

/** Go-to-file (⌘P) fuzzy open — type part of any worktree path, arrow-select,
 *  Enter to open it in the editor. In-editor sibling of the ⌘K command palette. */
export function GoToFile({
  open,
  files,
  onClose,
  onOpen,
}: {
  open: boolean;
  files: string[];
  onClose: () => void;
  onOpen: (path: string) => void;
}) {
  const [q, setQ] = useState("");
  const [sel, setSel] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    setQ("");
    setSel(0);
    const t = setTimeout(() => inputRef.current?.focus(), 0);
    return () => clearTimeout(t);
  }, [open]);

  const results = useMemo(() => fuzzyFind(q, files), [q, files]);

  useEffect(() => setSel(0), [q]);

  // Keep the selected row scrolled into view as you arrow through a long list.
  useEffect(() => {
    listRef.current?.querySelector(".cmdk-sel")?.scrollIntoView({ block: "nearest" });
  }, [sel]);

  if (!open) return null;

  const choose = (path?: string) => {
    if (!path) return;
    onClose();
    onOpen(path);
  };

  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSel((s) => Math.min(s + 1, results.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSel((s) => Math.max(s - 1, 0));
    } else if (e.key === "Enter") {
      e.preventDefault();
      choose(results[sel]?.path);
    } else if (e.key === "Escape") {
      e.preventDefault();
      onClose();
    }
  };

  return (
    <div className="cmdk-backdrop" onClick={onClose}>
      <div className="cmdk gtf" onClick={(e) => e.stopPropagation()}>
        <input
          ref={inputRef}
          className="cmdk-input"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={onKey}
          placeholder="Go to file… type part of a path"
        />
        <div className="cmdk-list" ref={listRef}>
          {results.length === 0 && <div className="cmdk-empty dim">no matching files</div>}
          {results.map((r, i) => (
            <button
              key={r.path}
              className={"cmdk-item gtf-item" + (i === sel ? " cmdk-sel" : "")}
              onMouseEnter={() => setSel(i)}
              onClick={() => choose(r.path)}
              title={r.path}
            >
              <FileIcon path={r.path} />
              <span className="gtf-path">
                {highlight(r.path, r.positions).map((s, j) =>
                  s.on ? <b key={j}>{s.text}</b> : <span key={j}>{s.text}</span>,
                )}
              </span>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
