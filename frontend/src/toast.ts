// Toast notifications — the app-wide surface for transient success (green) /
// error (red) messages. These used to render as fixed banners under the appbar;
// they now slide in as toasts whose corner + dwell time the user configures in
// Settings › Notifications. Prefs live in localStorage (per-device UI state, no
// backend), mirroring notify.ts.

export type ToastKind = "success" | "error";

export type ToastPosition =
  | "top-left"
  | "top-center"
  | "top-right"
  | "bottom-left"
  | "bottom-center"
  | "bottom-right";

export interface Toast {
  id: number;
  kind: ToastKind;
  message: string;
}

export interface ToastPrefs {
  position: ToastPosition;
  // How long a toast dwells before it slides out, in milliseconds.
  durationMs: number;
}

const KEY = "haro.toast.v1";

export const DEFAULT_TOAST_PREFS: ToastPrefs = {
  position: "bottom-right",
  durationMs: 4000,
};

// Offered in the settings picker. Labels read like a compass so the choice is
// obvious without a live preview.
export const TOAST_POSITIONS: { value: ToastPosition; label: string }[] = [
  { value: "top-left", label: "Top left" },
  { value: "top-center", label: "Top center" },
  { value: "top-right", label: "Top right" },
  { value: "bottom-left", label: "Bottom left" },
  { value: "bottom-center", label: "Bottom center" },
  { value: "bottom-right", label: "Bottom right" },
];

// Clamp the dwell time to something sane — long enough to read, short enough to
// not linger. The slide-out animation runs on top of this, so the total on-screen
// time is durationMs + ~260ms.
export const MIN_DURATION_MS = 1000;
export const MAX_DURATION_MS = 20000;

export function loadToastPrefs(): ToastPrefs {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return { ...DEFAULT_TOAST_PREFS };
    const parsed = JSON.parse(raw) as Partial<ToastPrefs>;
    return {
      position: TOAST_POSITIONS.some((p) => p.value === parsed.position)
        ? (parsed.position as ToastPosition)
        : DEFAULT_TOAST_PREFS.position,
      durationMs: clampDuration(parsed.durationMs ?? DEFAULT_TOAST_PREFS.durationMs),
    };
  } catch {
    return { ...DEFAULT_TOAST_PREFS };
  }
}

export function saveToastPrefs(prefs: ToastPrefs): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(prefs));
  } catch {
    /* localStorage unavailable (private mode) — non-fatal, prefs stay in-memory */
  }
}

export function clampDuration(ms: number): number {
  if (!Number.isFinite(ms)) return DEFAULT_TOAST_PREFS.durationMs;
  return Math.min(MAX_DURATION_MS, Math.max(MIN_DURATION_MS, Math.round(ms)));
}
