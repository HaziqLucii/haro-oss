// Kuro motion system — the ~30 lines of TS side of notes/kuro-motion-plan.md.
// Everything else is CSS custom properties + native View Transitions; no
// animation dependency.

import { flushSync } from "react-dom";

function reducedMotion(): boolean {
  return typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
}

/** Wrap a state update in a same-document View Transition when the browser
 *  supports it and the viewer hasn't asked for reduced motion; otherwise runs
 *  `update` immediately. `flushSync` forces the DOM to reflect `update` before
 *  the transition captures its "new" snapshot (React's default async commit
 *  would otherwise let the browser snapshot the stale DOM). Kept behind a
 *  `typeof` guard even though both shipping runtimes (Chrome app-mode, Electron
 *  33) support startViewTransition: Firefox/Safari hitting the Vite dev server
 *  must still get an instant swap, not a crash. */
export function withViewTransition(update: () => void): void {
  const doc = document as Document & { startViewTransition?: (cb: () => void) => unknown };
  if (typeof doc.startViewTransition !== "function" || reducedMotion()) {
    update();
    return;
  }
  doc.startViewTransition(() => flushSync(update));
}

// ---- boot splash shim ----
// The boot script (frontend/index.html) defines window.__haroBoot before React
// loads and owns all join/timing logic itself; React only ever reports facts.
// No-op when the splash isn't present (tests, a prod build that skipped it,
// or after done() has already run and ignores further stage() calls).

interface HaroBoot {
  stage(key: string, value: string): void;
}

declare global {
  interface Window {
    __haroBoot?: HaroBoot;
  }
}

export const boot = {
  stage(key: string, value: string): void {
    try {
      window.__haroBoot?.stage(key, value);
    } catch {
      /* splash already torn down or malformed — never let boot reporting break the app */
    }
  },
};
