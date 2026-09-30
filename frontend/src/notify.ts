// Agent-done sound notification: a short sound when an agent finishes emitting
// output in *any* workspace, so you're aware without watching. Preferences live
// in localStorage (a purely client-side, per-browser concern); the cross-workspace
// trigger is the backend's coarse `notify` event on the global feed.
//
// Defaults are *synthesized* via the Web Audio API (no bundled assets, works
// offline), and the user can drop in their own .mp3 instead.

export type BuiltinSound = "chime" | "beep" | "blip" | "arcade" | "glass";

export interface NotifyPrefs {
  enabled: boolean;
  sound: BuiltinSound | "custom";
  customName: string | null; // display name of the chosen file
  customData: string | null; // data: URL of the uploaded audio
  volume: number; // 0..1
  // OS-level desktop notification (Web Notifications API → libnotify on Linux via
  // the browser). Unlike the beep, it surfaces even when the window is backgrounded
  // — but only fires when unfocused (a focused window already has the beep + UI),
  // and only once the user has granted the browser permission.
  desktop: boolean;
}

export const BUILTIN_SOUNDS: BuiltinSound[] = ["chime", "beep", "blip", "arcade", "glass"];

const KEY = "haro.notify.v1";
const DEFAULTS: NotifyPrefs = {
  enabled: true,
  sound: "chime",
  customName: null,
  customData: null,
  volume: 0.5,
  desktop: false,
};

export function loadPrefs(): NotifyPrefs {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return { ...DEFAULTS };
    return { ...DEFAULTS, ...(JSON.parse(raw) as Partial<NotifyPrefs>) };
  } catch {
    return { ...DEFAULTS };
  }
}

export function savePrefs(prefs: NotifyPrefs): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(prefs));
  } catch {
    /* localStorage full/blocked — the sound just won't persist */
  }
}

// One shared AudioContext, created lazily on first playback. Browsers gate audio
// behind a user gesture; we resume() before each play (a prior click — e.g. the
// Test button, or any app interaction — unlocks it).
let ctx: AudioContext | null = null;
function audioCtx(): AudioContext | null {
  try {
    const Ctor = window.AudioContext || (window as any).webkitAudioContext;
    if (!Ctor) return null;
    if (!ctx) ctx = new Ctor();
    return ctx;
  } catch {
    return null;
  }
}

// A synthesized tone: a sequence of (freq, start, dur) notes through a gain
// envelope so it fades instead of clicking.
type Note = { freq: number; at: number; dur: number };
const TONES: Record<BuiltinSound, { notes: Note[]; type: OscillatorType }> = {
  // a gentle two-note rise
  chime: { type: "sine", notes: [{ freq: 660, at: 0, dur: 0.14 }, { freq: 880, at: 0.12, dur: 0.22 }] },
  // a single clean beep
  beep: { type: "triangle", notes: [{ freq: 880, at: 0, dur: 0.18 }] },
  // a quick high blip
  blip: { type: "sine", notes: [{ freq: 1240, at: 0, dur: 0.09 }] },
  // an original chiptune "gate green" victory jingle — a square-wave pulse arp
  // rising through a C-major triad and resolving up an octave (NES-flavoured, no
  // game-audio rip). Pairs with the 8-bit theme but is a standalone opt-in tone.
  arcade: {
    type: "square",
    notes: [
      { freq: 523.25, at: 0, dur: 0.1 }, // C5
      { freq: 659.25, at: 0.1, dur: 0.1 }, // E5
      { freq: 783.99, at: 0.2, dur: 0.1 }, // G5
      { freq: 1046.5, at: 0.3, dur: 0.28 }, // C6 — held finish
    ],
  },
  // an icy glass chime — three high staggered sines in an open E-A-E voicing
  // with long decays, like tapping an icicle. A standalone opt-in tone, unrelated
  // to any theme.
  glass: {
    type: "sine",
    notes: [
      { freq: 1318.5, at: 0, dur: 0.35 }, // E6 — the tap
      { freq: 1760.0, at: 0.09, dur: 0.45 }, // A6 — the ring
      { freq: 2637.0, at: 0.18, dur: 0.6 }, // E7 — the shimmer, held
    ],
  },
};

function playTone(kind: BuiltinSound, volume: number): void {
  const ac = audioCtx();
  if (!ac) return;
  void ac.resume?.();
  const spec = TONES[kind];
  const now = ac.currentTime;
  for (const n of spec.notes) {
    const osc = ac.createOscillator();
    const gain = ac.createGain();
    osc.type = spec.type;
    osc.frequency.value = n.freq;
    const start = now + n.at;
    const end = start + n.dur;
    gain.gain.setValueAtTime(0.0001, start);
    gain.gain.exponentialRampToValueAtTime(Math.max(0.0002, volume), start + 0.01);
    gain.gain.exponentialRampToValueAtTime(0.0001, end);
    osc.connect(gain).connect(ac.destination);
    osc.start(start);
    osc.stop(end + 0.02);
  }
}

function playCustom(dataUrl: string, volume: number): void {
  try {
    const audio = new Audio(dataUrl);
    audio.volume = Math.min(1, Math.max(0, volume));
    void audio.play().catch(() => {
      /* autoplay blocked until a user gesture — silently skip */
    });
  } catch {
    /* invalid data URL — skip */
  }
}

/** Play the currently-configured notification sound once. Respects `enabled`. */
export function playNotify(prefs: NotifyPrefs): void {
  if (!prefs.enabled) return;
  if (prefs.sound === "custom") {
    if (prefs.customData) playCustom(prefs.customData, prefs.volume);
    else playTone("chime", prefs.volume); // fall back if no file chosen yet
    return;
  }
  playTone(prefs.sound, prefs.volume);
}

// ---- OS-level desktop notifications (Web Notifications API) ----
// On Linux, Chrome routes `new Notification(...)` through the OS notification
// daemon (libnotify / the freedesktop spec), so there's no native dependency to
// bundle — the browser API *is* the libnotify path. It works the same in the
// chromeless `--app` window we ship.

export type DesktopPermission = NotificationPermission | "unsupported";

export function desktopSupported(): boolean {
  return typeof window !== "undefined" && "Notification" in window;
}

export function desktopPermission(): DesktopPermission {
  if (!desktopSupported()) return "unsupported";
  return Notification.permission;
}

/** Prompt the browser for notification permission (a no-op if already decided or
 *  unsupported). Must be called from a user gesture. */
export async function requestDesktopPermission(): Promise<DesktopPermission> {
  if (!desktopSupported()) return "unsupported";
  try {
    return await Notification.requestPermission();
  } catch {
    return Notification.permission;
  }
}

export interface DesktopNote {
  title: string;
  body?: string;
  /** Collapses repeat notifications for the same subject (e.g. one per workspace). */
  tag?: string;
}

/** Pure decision: should we raise an OS notification right now? Kept separate from
 *  the DOM/Notification side effects so it's unit-testable. The window being
 *  *focused* suppresses it — the in-app beep + live UI already cover that case;
 *  the whole point of a desktop notification is the backgrounded window. */
export function shouldShowDesktop(
  prefs: NotifyPrefs,
  ctx: { supported: boolean; permission: DesktopPermission; focused: boolean }
): boolean {
  return prefs.desktop && ctx.supported && ctx.permission === "granted" && !ctx.focused;
}

/** Raise an OS-level notification for `note`, gated on prefs, permission and focus.
 *  Silent no-op when any gate fails, so callers can fire it unconditionally. */
export function showDesktop(prefs: NotifyPrefs, note: DesktopNote): void {
  const focused = typeof document !== "undefined" && document.hasFocus();
  if (!shouldShowDesktop(prefs, { supported: desktopSupported(), permission: desktopPermission(), focused }))
    return;
  try {
    const n = new Notification(note.title, { body: note.body, tag: note.tag });
    // Click the toast → bring the haro window forward.
    n.onclick = () => {
      try {
        window.focus();
      } catch {
        /* focus blocked — closing is enough */
      }
      n.close();
    };
  } catch {
    /* construction can throw on some platforms — treat as best-effort */
  }
}
