import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Check, Copy, GitBranch } from "./icons";

/** The branch ref in the shell/dev-log card header. It used to render the full
 *  branch name inline, which wrapped the header onto two lines for long names
 *  (e.g. `feat/per-workspace-notes-context-handoff-folder`). Instead it's now a
 *  compact git-branch keycap (same design as the appbar theme/settings toggles);
 *  clicking it opens a popover with the full name and a copy action. The popover
 *  is position:fixed (anchored to the trigger's rect) so the card never clips it. */
export function BranchBadge({ branch }: { branch: string }) {
  const btnRef = useRef<HTMLButtonElement>(null);
  const popRef = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const [pos, setPos] = useState<{ top: number; right: number } | null>(null);

  // Anchor the fixed popover under the trigger, opening leftward (the keycap
  // sits at the header's right edge). The top is aligned to the card-head's
  // bottom border rather than the button, so the popover hangs flush from that
  // line (its top edge is borderless — see .branch-pop). Re-measured on open.
  useLayoutEffect(() => {
    if (!open || !btnRef.current) return;
    const r = btnRef.current.getBoundingClientRect();
    const head = btnRef.current.closest(".card-head")?.getBoundingClientRect();
    setPos({ top: head ? head.bottom : r.bottom + 6, right: window.innerWidth - r.right });
  }, [open]);

  // Close on any outside press, scroll, or Escape.
  useEffect(() => {
    if (!open) return;
    const dismiss = () => setOpen(false);
    const onDown = (e: MouseEvent) => {
      const t = e.target as Node;
      if (btnRef.current?.contains(t) || popRef.current?.contains(t)) return;
      dismiss();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") dismiss();
    };
    window.addEventListener("mousedown", onDown, true);
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("scroll", dismiss, true);
    return () => {
      window.removeEventListener("mousedown", onDown, true);
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("scroll", dismiss, true);
    };
  }, [open]);

  const copy = () => {
    navigator.clipboard?.writeText(branch).then(
      () => {
        setCopied(true);
        setTimeout(() => setCopied(false), 1200);
      },
      () => {},
    );
  };

  return (
    <>
      <button
        ref={btnRef}
        className="ghost theme-toggle branch-key"
        aria-label={`branch: ${branch}`}
        aria-expanded={open}
        title={branch}
        onClick={() => setOpen((o) => !o)}
      >
        <GitBranch size={14} />
      </button>

      {open && pos && (
        <div ref={popRef} className="branch-pop" style={{ top: pos.top, right: pos.right }} role="dialog">
          <span className="branch-pop-label dim">branch</span>
          <code className="branch-pop-name">{branch}</code>
          <button className="ghost btn-icon branch-pop-copy" onClick={copy} title="copy branch name">
            {copied ? <Check size={14} /> : <Copy size={14} />}
          </button>
        </div>
      )}
    </>
  );
}
