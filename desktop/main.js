// haro desktop shell.
//
// Electron is a thin wrapper here: it does NOT contain any app logic. Its only
// jobs are (1) spawn the FastAPI backend on a private port, (2) wait for it to
// answer /health, (3) open a window at http://127.0.0.1:<port> — which serves
// the built SPA (see backend/haro/main.py's static mount). Because the frontend
// uses relative URLs (fetch("/projects"), new WebSocket("/ws/...")), one HTTP
// origin covers REST + WS with no CORS and no base-path rewriting.
//
// Port policy: stable-preferred, random fallback. The app must still never reuse
// a listener it didn't start — that's a bug magnet (a Docker stack, a `run.sh`
// instance, or old code that can't serve the SPA), so 8000 stays off-limits and a
// collision always falls back to a fresh OS-assigned port. But *within* that rule,
// binding the SAME port every launch (when free) keeps the SPA's origin stable
// across relaunches — Chromium scopes localStorage, the HTTP cache, and the V8
// bytecode cache per-origin, so a random port was silently wiping prefs (model,
// effort, plan-first, …) and queued tasks on every single relaunch, and defeating
// the `immutable` cache headers main.py already sends for hashed assets. The port
// number is still invisible to the SPA either way (all its URLs are relative).
//
// dev vs packaged:
//   dev      → spawn backend/.venv/bin/python -m uvicorn (this repo checkout)
//   packaged → spawn the PyInstaller-frozen binary shipped in resources/
const { app, BrowserWindow, shell, nativeTheme } = require("electron");
const { spawn, exec } = require("child_process");
const fs = require("fs");
const http = require("http");
const net = require("net");
const os = require("os");
const path = require("path");

let port = 0; // stable-preferred, random fallback — see pickPort()
let backendProc = null;
let win = null;

// Resolve the repo root in dev (desktop/ is one level below it).
function repoRoot() {
  return path.resolve(__dirname, "..");
}

// Ask the OS for a currently-free TCP port (bind :0, read it back, release).
function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const p = srv.address().port;
      srv.close(() => resolve(p));
    });
  });
}

// Try to bind a specific port; resolve true if it was free (and is now released
// again — same bind/read/release dance as freePort), false on any bind error
// (in use, permission, …) so the caller can fall back.
function tryPort(p) {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.unref();
    srv.once("error", () => resolve(false));
    srv.listen(p, "127.0.0.1", () => srv.close(() => resolve(true)));
  });
}

const DEFAULT_DESKTOP_PORT = 41417; // arbitrary, unregistered, unlikely to collide

// Prefer a fixed port (so the SPA's origin — and its localStorage/HTTP-cache/V8-
// code-cache — survives relaunch); fall back to a fresh OS-assigned one if that
// port is taken by something else.
async function pickPort() {
  const preferred = Number(process.env.HARO_DESKTOP_PORT) || DEFAULT_DESKTOP_PORT;
  if (await tryPort(preferred)) return preferred;
  return freePort();
}

// One non-blocking GET; resolves true on HTTP 200, false on any error/timeout.
function probe(url, timeoutMs = 1000) {
  return new Promise((resolve) => {
    const req = http.get(url, { timeout: timeoutMs }, (res) => {
      res.resume();
      resolve(res.statusCode === 200);
    });
    req.on("error", () => resolve(false));
    req.on("timeout", () => {
      req.destroy();
      resolve(false);
    });
  });
}

async function waitForHealth(totalMs = 45000) {
  const url = `http://127.0.0.1:${port}/health`;
  const start = Date.now();
  while (Date.now() - start < totalMs) {
    if (await probe(url)) return true;
    await new Promise((r) => setTimeout(r, 300));
  }
  return false;
}

// The user's real login-shell PATH. A GUI launch (Dock/Spotlight/Finder)
// inherits launchd's minimal PATH — no ~/.local/bin, no nvm, no Homebrew — so
// the spawned backend can't find `claude` (agents) or `npx` (the gate). Ask the
// login shell for its PATH once. The rc may print a banner (fastfetch etc.), so
// bracket the value in sentinels and extract it. Falls back to our own PATH.
//
// Async (child_process.exec, not execSync): this shell spawn takes ~1s on a
// typical rc file, and it used to run synchronously at module load — before
// `app.whenReady`, so it delayed the splash window's very first paint by that
// full second on every launch. Kicking it off here and awaiting the promise in
// startBackend() lets Electron/Chromium init and window creation overlap it
// instead, so the backend still gets the resolved PATH by the time it's spawned,
// but the splash shows up sooner.
function loginShellPath() {
  return new Promise((resolve) => {
    try {
      const sh = process.env.SHELL || "/bin/zsh";
      exec(
        `${sh} -ilc 'printf "__HARO_PATH__%s__HARO_END__" "$PATH"'`,
        { encoding: "utf8", timeout: 5000 },
        (err, stdout) => {
          if (err) return resolve(null);
          const m = String(stdout).match(/__HARO_PATH__([\s\S]*?)__HARO_END__/);
          resolve(m && m[1] ? m[1] : null);
        }
      );
    } catch (_) {
      resolve(null);
    }
  });
}
// Belt-and-suspenders around loginShellPath(). Whether the scrape succeeded or
// fell back to null (a heavy rc that blew the 5s timeout, or no login shell),
// guarantee the dirs the backend needs to find its tools: `claude` (~/.local/bin),
// `npx` (nvm dirs come from the scrape), and — the bug this closes — `nvim` for the
// code step's editor, which Homebrew installs under /opt/homebrew/bin on Apple
// Silicon (/usr/local/bin on Intel, linuxbrew on Linux). Prepending is idempotent:
// dirs already present are skipped, so a good login PATH is left untouched. Mirrors
// run.sh's explicit PATH guarantee so both launchers behave the same.
function withToolDirs(pathStr) {
  const base = pathStr || process.env.PATH || "";
  const have = new Set(base.split(":"));
  const extra = [
    path.join(process.env.HOME || "", ".local", "bin"),
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/home/linuxbrew/.linuxbrew/bin",
  ].filter((d) => d && !have.has(d));
  return extra.length ? `${extra.join(":")}:${base}` : base;
}
// Kicked off at module load (before app.whenReady) so the ~1s shell spawn
// overlaps Electron/Chromium init + window creation instead of blocking it.
const RESOLVED_PATH_P = loginShellPath().then(withToolDirs);

// How to launch the backend, differing by dev vs packaged build.
function backendCommand(resolvedPath) {
  // The backend gets HARO_PARENT_PID (this process) in startBackend so it exits
  // when we die (see backend/desktop_app.py). Env here is just paths.
  if (app.isPackaged) {
    // The frozen backend (onedir) + the built SPA are shipped as extraResources.
    // onedir means resources/backend/haro-backend/ is a DIRECTORY (exe +
    // _internal/), so launch the exe INSIDE it — not the dir itself.
    return {
      cmd: path.join(process.resourcesPath, "backend", "haro-backend", "haro-backend"),
      args: ["--port", String(port)],
      cwd: process.resourcesPath,
      env: {
        HARO_SPA_DIR: path.join(process.resourcesPath, "frontend-dist"),
        ...(resolvedPath ? { PATH: resolvedPath } : {}),
      },
    };
  }
  const root = repoRoot();
  // Dev uses the SAME entry point as the frozen build (desktop_app.py).
  return {
    cmd: path.join(root, "backend", ".venv", "bin", "python"),
    args: ["desktop_app.py", "--port", String(port)],
    cwd: path.join(root, "backend"),
    env: {
      PYTHONPATH: ".",
      HARO_SPA_DIR: path.join(root, "frontend", "dist"),
      ...(resolvedPath ? { PATH: resolvedPath } : {}),
    },
  };
}

async function startBackend() {
  const resolvedPath = await RESOLVED_PATH_P;
  const { cmd, args, cwd, env } = backendCommand(resolvedPath);
  // Log backend stdout/stderr to ~/.haro/backend.log so a failure is diagnosable
  // (the "backend didn't start" screen points here).
  const haroDir = path.join(os.homedir(), ".haro");
  fs.mkdirSync(haroDir, { recursive: true });
  const logFd = fs.openSync(path.join(haroDir, "backend.log"), "w");
  // detached:true puts the backend in its own process group so on quit we can
  // SIGTERM the whole tree (backend + any agent/dev-server children it spawned).
  // HARO_PARENT_PID lets the backend exit when we die (see desktop_app.py).
  backendProc = spawn(cmd, args, {
    cwd,
    detached: true,
    stdio: ["ignore", logFd, logFd],
    env: { ...process.env, ...env, HARO_PARENT_PID: String(process.pid) },
  });
  // The child inherited its own copy of the fd when spawned; release ours so the
  // parent doesn't hold a second handle open on the log file for the app's whole
  // lifetime.
  fs.closeSync(logFd);
  backendProc.on("error", (err) => console.error("[haro] backend failed to spawn:", err));
}

function stopBackend() {
  if (backendProc && backendProc.pid) {
    try {
      process.kill(-backendProc.pid, "SIGTERM");
    } catch (_) {
      /* already gone */
    }
    backendProc = null;
  }
}

// Self-update relaunch. rebuild.sh (run by the in-app updater) writes this
// sentinel once the new build is installed. We relaunch via Electron itself:
// app.relaunch() re-execs the now-updated binary and app.exit() releases the
// single-instance lock, so exactly ONE new instance comes up — with the correct
// window icon. (A shell `setsid` relaunch raced the old instance, leaving a
// stale window, and lost the Wayland app-id/icon association.) We clear any
// leftover sentinel on startup so a crash mid-update can't cause a relaunch loop.
function watchForUpdateRelaunch() {
  const sentinel = path.join(os.homedir(), ".haro", ".update-ready");
  try {
    fs.rmSync(sentinel, { force: true });
  } catch (_) {
    /* ignore */
  }
  setInterval(() => {
    if (!fs.existsSync(sentinel)) return;
    try {
      fs.rmSync(sentinel, { force: true });
    } catch (_) {
      /* ignore */
    }
    stopBackend();
    app.relaunch();
    app.exit(0);
  }, 1500);
}

function createWindow() {
  // macOS: hide the OS title bar so the app runs edge-to-edge (the seamless look),
  // keeping the traffic-light buttons floating over our own top bar. The .appbar is a
  // -webkit-app-region: drag strip (see appbar.css) so the window still drags. Linux/
  // Windows keep their native frame — titleBarStyle 'hidden' there would drop the
  // window controls entirely with nothing to replace them.
  const mac = process.platform === "darwin";
  win = new BrowserWindow({
    width: 1440,
    height: 960,
    minWidth: 900,
    minHeight: 600,
    backgroundColor: "#0b0a09", // Kuro ground, so no white flash before paint
    title: "haro",
    icon: path.join(__dirname, "assets", "icon.png"), // window + taskbar icon
    autoHideMenuBar: true,
    ...(mac
      ? { titleBarStyle: "hidden", trafficLightPosition: { x: 18, y: 24 } }
      : {}),
    webPreferences: {
      contextIsolation: true,
      // Explicit even though it's Electron's own default: the preload only reads
      // process.platform (still visible under a sandboxed preload), and pinning
      // this stops a future preload edit from silently loosening isolation.
      sandbox: true,
      preload: path.join(__dirname, "preload.js"),
      // With a stable port (pickPort), the origin is the same across launches,
      // so V8's compiled-bytecode cache is actually reusable. bypassHeatCheck
      // writes the code cache on the FIRST load instead of waiting for V8's
      // default heuristic (repeated hits over time), so relaunch #2 already
      // benefits instead of relaunch #5+.
      v8CacheOptions: "bypassHeatCheck",
    },
  });
  // Splash first; we swap to the live app once /health is green.
  win.loadFile(path.join(__dirname, "loader.html"));
  // External links (PR pages, docs) open in the system browser, not in-app.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith("http://127.0.0.1") || url.startsWith("http://localhost")) {
      return { action: "allow" };
    }
    shell.openExternal(url);
    return { action: "deny" };
  });
  win.on("closed", () => {
    win = null;
  });
}

// Linux/Wayland only. On the dev's eGPU the GL/EGL path crashed (eglCreateImage)
// and Chromium fell back to SwiftShader: software rendering on the CPU, which burns
// CPU + heat on every UI update (streaming agent output, the live gate/grid).
// Forcing ANGLE onto Vulkan (radv on AMD) gives it a separate driver path that
// works where GL failed.
//
// This MUST stay Linux-only. macOS has no native Vulkan (its stack is Metal) and
// Windows uses D3D11, so applying these switches there fails to initialise the GPU
// and drops Chromium to the very SwiftShader fallback this is meant to avoid. That
// was the modal-animation lag on the packaged Mac build: a Linux GPU workaround
// leaking onto every platform. Leave macOS/Windows on their own ANGLE defaults.
if (process.platform === "linux") {
  app.commandLine.appendSwitch("use-angle", "vulkan");
  app.commandLine.appendSwitch("enable-features", "Vulkan");
  app.commandLine.appendSwitch("ignore-gpu-blocklist");
}

// Single-instance: a second launch (e.g. pressing Super+H again) focuses the
// existing window instead of opening a duplicate backend.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => {
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
  });

  app.whenReady().then(async () => {
    // Kuro is dark-only (no light theme). Set this before createWindow() so
    // native chrome (scrollbars, form controls, prefers-color-scheme) matches
    // from the very first paint instead of flashing a light default first.
    nativeTheme.themeSource = "dark";
    createWindow();
    watchForUpdateRelaunch();
    port = await pickPort();
    const backendExited = new Promise((resolve) => {
      startBackend().then(() => backendProc && backendProc.once("exit", (code) => resolve({ code })));
    });
    // Race the health poll against the backend process dying outright — a crash
    // at spawn (missing venv, port stolen after pickPort's check, a broken
    // frozen binary) used to take the full 45s to surface, because waitForHealth
    // just keeps polling a socket nothing will ever answer on.
    const ok = await Promise.race([
      waitForHealth().then((healthy) => ({ ok: healthy })),
      backendExited.then(({ code }) => ({ ok: false, exitCode: code })),
    ]);
    if (!win) return;
    if (ok.ok) {
      win.loadURL(`http://127.0.0.1:${port}/`);
    } else {
      // Same dossier manifest as the loading state (loader.html's <style> is
      // still in effect — only body.innerHTML changes), showing the one row
      // that's actually known: backend failed, static (not breathing — nothing
      // more is coming). When the process actually exited (vs. just never
      // answering /health for the full timeout), surface its exit code — that's
      // the difference between "still starting, slow" and "crashed immediately".
      const failLabel =
        "exitCode" in ok && ok.exitCode !== null && ok.exitCode !== undefined
          ? `failed (exit ${ok.exitCode})`
          : "failed";
      win.webContents.executeJavaScript(
        `document.body.innerHTML =
           '<div id="boot"><div id="boot-stack">' +
             '<div class="boot-mark">haro<span class="boot-period">.</span></div>' +
             '<div class="boot-rule"></div>' +
             '<div class="boot-rows">' +
               '<div class="boot-row" data-key="backend"><span class="k">backend</span><span class="v" style="animation:none;opacity:1">${failLabel}</span></div>' +
               '<div class="boot-row" data-key="workspaces"><span class="k">workspaces</span><span class="v" style="animation:none;opacity:.4">—</span></div>' +
               '<div class="boot-row" data-key="feed"><span class="k">live feed</span><span class="v" style="animation:none;opacity:.4">—</span></div>' +
             '</div>' +
             '<div style="font-family:ui-monospace,\\'SF Mono\\',Menlo,monospace;font-size:11px;letter-spacing:.04em;color:rgba(205,196,186,.66);text-align:center;max-width:220px">' +
               'Check the backend logs, then reopen haro.' +
             '</div>' +
           '</div></div>';`
      );
    }
  });
}

app.on("window-all-closed", () => {
  stopBackend();
  app.quit();
});
app.on("before-quit", stopBackend);
