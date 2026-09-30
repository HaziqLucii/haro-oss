// Intentionally minimal. contextIsolation is on and the renderer is the haro SPA
// loaded over http://localhost — it needs no privileged bridge into Electron.
// Kept as a named preload so we have a seam if the app ever needs one (e.g. a
// native "open folder" dialog) without loosening isolation.

// Tag the document with the desktop platform so the SPA can adapt to the native
// shell — notably padding the top bar clear of the macOS traffic-light buttons,
// which float over our content once the OS title bar is hidden (see main.js).
// Runs in the isolated world but shares the DOM; a no-op in a plain browser.
//
// Tagged as early as possible (top-level, not just on DOMContentLoaded): the
// boot splash's inline script (frontend/index.html) reads this attribute
// synchronously while the body is still parsing, to pre-fill the BACKEND row
// as "ready" instead of breathing dots — main.js only ever loadURL()s here
// after its own /health poll already succeeded, so the attribute being present
// at all means the backend is known-good. The DOMContentLoaded copy stays as a
// safety net in case document.documentElement isn't available this early.
function tagDesktop() {
  try {
    document.documentElement.dataset.desktop =
      process.platform === "darwin" ? "mac" : process.platform;
  } catch {
    /* document.documentElement or process may be unavailable this early/under
       a strict sandbox — the DOMContentLoaded listener below covers it */
  }
}
tagDesktop();
window.addEventListener("DOMContentLoaded", tagDesktop);
