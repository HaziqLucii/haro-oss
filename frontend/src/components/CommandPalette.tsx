import { useEffect, useMemo, useRef, useState } from "react";

export interface Command {
  id: string;
  label: string;
  group?: string;
  run: () => void;
}

/** Ctrl/Cmd+K command palette — drive haro from the keyboard: switch
 *  workspaces, change views, run the gate, merge, toggle theme. */
export function CommandPalette({
  open,
  commands,
  onClose,
}: {
  open: boolean;
  commands: Command[];
  onClose: () => void;
}) {
  const [q, setQ] = useState("");
  const [sel, setSel] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (open) {
      setQ("");
      setSel(0);
      const t = setTimeout(() => inputRef.current?.focus(), 0);
      return () => clearTimeout(t);
    }
  }, [open]);

  const filtered = useMemo(() => {
    const s = q.trim().toLowerCase();
    if (!s) return commands;
    return commands.filter((c) => (c.label + " " + (c.group ?? "")).toLowerCase().includes(s));
  }, [q, commands]);

  useEffect(() => setSel(0), [q]);

  if (!open) return null;

  const run = (c?: Command) => {
    if (!c) return;
    onClose();
    c.run();
  };

  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSel((s) => Math.min(s + 1, filtered.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSel((s) => Math.max(s - 1, 0));
    } else if (e.key === "Enter") {
      e.preventDefault();
      run(filtered[sel]);
    } else if (e.key === "Escape") {
      e.preventDefault();
      onClose();
    }
  };

  return (
    <div className="cmdk-backdrop" onClick={onClose}>
      <div className="cmdk" onClick={(e) => e.stopPropagation()}>
        <input
          ref={inputRef}
          className="cmdk-input"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={onKey}
          placeholder="Type a command… workspaces · views · gate · app"
        />
        <div className="cmdk-list">
          {filtered.length === 0 && <div className="cmdk-empty dim">no matches</div>}
          {filtered.map((c, i) => (
            <button
              key={c.id}
              className={"cmdk-item" + (i === sel ? " cmdk-sel" : "")}
              onMouseEnter={() => setSel(i)}
              onClick={() => run(c)}
            >
              <span className="cmdk-label">{c.label}</span>
              {c.group && <span className="cmdk-group dim">{c.group}</span>}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
