import { useEffect, type ReactNode } from "react";
import { Command, Return, X } from "./icons";

// The app-level shortcuts, grouped. ⌘ is the Meta key (Super/Win on Linux, since
// haro is Linux-first), rendered as the <Command/> SVG (not the tiny ⌘ glyph);
// Control is spelled out as "Ctrl". Keep this list in sync with the actual keydown
// handlers in App.tsx / CodePanel.tsx / the composer.
const GROUPS: { title: string; items: { keys: ReactNode; desc: string }[] }[] = [
  {
    title: "Focus & navigate",
    items: [
      { keys: <><Command /> + K</>, desc: "Command palette" },
      { keys: <><Command /> + I</>, desc: "Focus the task prompt" },
      { keys: "Ctrl + `", desc: "Focus the shell" },
      { keys: <><Command /> + P</>, desc: "Go to file (code view)" },
    ],
  },
  {
    title: "Actions",
    items: [
      { keys: <><Command /> + R</>, desc: "Run the app (dev server)" },
      { keys: <><Command /> + S</>, desc: "Save the current file (code view)" },
      { keys: <><Command /> + <Return /></>, desc: "Send the task / checkpoint commit" },
    ],
  },
  {
    title: "General",
    items: [{ keys: "Esc", desc: "Close a dialog / exit fullscreen" }],
  },
];

export function HotkeysModal({ onClose }: { onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="hotkeys-scrim" onMouseDown={onClose}>
      <div
        className="hotkeys-modal"
        role="dialog"
        aria-label="keyboard shortcuts"
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="hotkeys-head">
          <span>Keyboard shortcuts</span>
          <button className="ghost btn-icon" onClick={onClose} title="close (Esc)">
            <X />
          </button>
        </div>
        <div className="hotkeys-body">
          {GROUPS.map((g) => (
            <div className="hotkeys-group" key={g.title}>
              <div className="hotkeys-group-title dim">{g.title}</div>
              {g.items.map((it) => (
                <div className="hotkeys-row" key={it.desc}>
                  <span className="hotkeys-desc">{it.desc}</span>
                  <span className="kbd">{it.keys}</span>
                </div>
              ))}
            </div>
          ))}
        </div>
        <div className="hotkeys-foot dim">
          <span className="kbd"><Command /></span> is the Super/Win key on Linux.
        </div>
      </div>
    </div>
  );
}
