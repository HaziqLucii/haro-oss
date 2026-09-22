import { useEffect, useState, type CSSProperties } from "react";
import { Check, X } from "./icons";
import type { Toast, ToastPosition, ToastPrefs } from "../toast";

// The fixed overlay that stacks live toasts in the user's chosen corner. Each
// toast owns its own lifecycle (dwell → slide-out → removal) so a burst of them
// animates independently. The host is pointer-events:none; only the pills catch
// clicks (to dismiss early).
export function ToastHost({
  toasts,
  prefs,
  onDismiss,
}: {
  toasts: Toast[];
  prefs: ToastPrefs;
  onDismiss: (id: number) => void;
}) {
  if (toasts.length === 0) return null;
  return (
    <div className="toast-host" data-pos={prefs.position} role="region" aria-label="notifications">
      {toasts.map((t) => (
        <ToastItem key={t.id} toast={t} prefs={prefs} onDismiss={onDismiss} />
      ))}
    </div>
  );
}

// The transform a toast enters from / leaves toward — driven by which edge the
// host sits on. Corners and side-anchored positions slide horizontally; the
// centered positions slide vertically off the nearest edge.
function offsetFor(position: ToastPosition): string {
  if (position.endsWith("right")) return "translateX(120%)";
  if (position.endsWith("left")) return "translateX(-120%)";
  return position.startsWith("top") ? "translateY(-140%)" : "translateY(140%)";
}

function ToastItem({
  toast,
  prefs,
  onDismiss,
}: {
  toast: Toast;
  prefs: ToastPrefs;
  onDismiss: (id: number) => void;
}) {
  // Two-phase exit: after the dwell timer we flip to `leaving`, which swaps the
  // enter animation for the slide-out. onAnimationEnd then evicts it from state.
  const [leaving, setLeaving] = useState(false);

  useEffect(() => {
    const t = window.setTimeout(() => setLeaving(true), prefs.durationMs);
    return () => window.clearTimeout(t);
  }, [prefs.durationMs]);

  return (
    <div
      className={`toast toast-${toast.kind} ${leaving ? "toast-leave" : "toast-enter"}`}
      style={{ "--toast-off": offsetFor(prefs.position) } as CSSProperties}
      role={toast.kind === "error" ? "alert" : "status"}
      onClick={() => setLeaving(true)}
      onAnimationEnd={() => {
        if (leaving) onDismiss(toast.id);
      }}
      title="dismiss"
    >
      <span className="toast-icon">{toast.kind === "error" ? <X /> : <Check />}</span>
      <span className="toast-msg">{toast.message}</span>
    </div>
  );
}
