import { forwardRef, useEffect, useImperativeHandle, useRef } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { parseThemeProp, terminalPalette } from "../themes";

/** Imperative surface exposed to parents (App) so they can drive the PTY —
 *  used by the terminal card's "claude" menu to drop a command on the prompt. */
export interface TerminalHandle {
  /** Type text into the PTY as if the user typed it, WITHOUT a trailing
   *  newline — the developer reviews the line and presses Enter. Clears the
   *  current input line first so the injected command starts clean. */
  insert: (text: string) => void;
  focus: () => void;
}

const cssVar = (n: string) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();

// The surface (background/foreground/cursor/selection) always flows from live CSS
// vars — those tokens are already themed per family × mode, so the shell background
// tracks the app for free. On top, a family MAY ship a full 16-slot ANSI palette in
// the registry (`themes.ts`) so program output (git, ls, vitest) reads in-key rather
// than on xterm's stock palette; the 8-bit family uses this for its navy/cyan set.
// `themeProp` is the "<family>-<mode>" string App threads in (bare mode also parses).
function xtermTheme(themeProp: string) {
  const base = {
    background: cssVar("--panel"),
    foreground: cssVar("--fg"),
    cursor: cssVar("--accent"),
    cursorAccent: cssVar("--panel"),
    selectionBackground: cssVar("--panel-2"),
    green: cssVar("--accent"),
    red: cssVar("--del"),
    yellow: cssVar("--amber"),
    blue: cssVar("--blue"),
    brightGreen: cssVar("--accent"),
  };
  const { id, mode } = parseThemeProp(themeProp);
  const ansi = terminalPalette(id, mode);
  return ansi ? { ...base, ...ansi } : base;
}

/** A real shell in the workspace's worktree (xterm.js <-> a backend PTY).
 *  Keeps the developer in haro instead of alt-tabbing to a terminal. */
export const Terminal = forwardRef<
  TerminalHandle,
  {
    workspaceId: string;
    shellId: string;
    theme: string;
    autoFocus?: boolean;
    /** Override the WS path (default: the workspace's shell terminal). The nvim
     *  editor pane passes ``/ws/workspaces/{id}/editor`` to reuse this same
     *  xterm.js <-> PTY plumbing for a different backend program. */
    path?: string;
  }
>(function Terminal({ workspaceId, shellId, theme, autoFocus = true, path }, handleRef) {
  const ref = useRef<HTMLDivElement>(null);
  const termRef = useRef<XTerm | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  // Read at PTY-connect time (the effect deps are [workspaceId, shellId]); a ref
  // keeps the on-open focus decision current without re-running the whole effect.
  const autoFocusRef = useRef(autoFocus);
  autoFocusRef.current = autoFocus;
  // Same trick for the theme: the init effect must NOT list `theme` in its deps (a
  // theme flip would remount the whole PTY). A ref keeps the initial paint current
  // without re-running init; the [theme] effect below repaints live afterwards.
  const themeRef = useRef(theme);
  themeRef.current = theme;

  useImperativeHandle(handleRef, () => ({
    insert: (text: string) => {
      const ws = wsRef.current;
      // \x15 = Ctrl-U: clear whatever's on the current prompt line so the
      // injected command starts fresh, then type it (no newline).
      if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ t: "in", d: "\x15" + text }));
      termRef.current?.focus();
    },
    focus: () => termRef.current?.focus(),
  }), []);

  useEffect(() => {
    if (!ref.current) return;
    const term = new XTerm({
      fontFamily: cssVar("--mono") || "monospace",
      fontSize: 12.5,
      lineHeight: 1.15,
      cursorBlink: true,
      theme: xtermTheme(themeRef.current),
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(ref.current);
    termRef.current = term;

    const proto = location.protocol === "https:" ? "wss" : "ws";
    const wsPath = path ?? `/ws/workspaces/${workspaceId}/terminal/${shellId}`;
    const ws = new WebSocket(`${proto}://${location.host}${wsPath}`);
    ws.binaryType = "arraybuffer";
    wsRef.current = ws;
    const send = (m: object) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify(m));

    // Fit, then tell the PTY the real size. xterm measures glyph width from the
    // font, so a fit() before the webfont loads yields the wrong column count —
    // which desyncs the PTY winsize and makes zsh print its reverse-% EOL mark.
    // So we also refit once fonts are ready and after layout settles.
    const doFit = () => {
      try {
        fit.fit();
      } catch {
        /* container not measurable yet */
      }
      send({ t: "resize", c: term.cols, r: term.rows });
    };

    ws.onopen = () => {
      doFit();
      // Only grab focus on connect when this shell was opened intentionally
      // (the "+" / restart flows). On a fresh workspace the composer is the
      // primary surface, so it must win focus over the auto-connecting PTY.
      if (autoFocusRef.current) term.focus();
    };
    ws.onmessage = (e) => term.write(new Uint8Array(e.data as ArrayBuffer));
    ws.onclose = () => term.write("\r\n\x1b[2m[terminal closed]\x1b[0m\r\n");
    term.onData((d) => send({ t: "in", d }));

    // Fit repeatedly as the layout settles (fonts load, flex sizes resolve) so
    // the PTY winsize matches the real width — otherwise zsh leaks its reverse-%.
    requestAnimationFrame(doFit);
    const timers = [setTimeout(doFit, 120), setTimeout(doFit, 400)];
    if (document.fonts?.ready) document.fonts.ready.then(doFit);

    const ro = new ResizeObserver(doFit);
    ro.observe(ref.current);

    return () => {
      timers.forEach(clearTimeout);
      ro.disconnect();
      ws.close();
      wsRef.current = null;
      term.dispose();
      termRef.current = null;
    };
  }, [workspaceId, shellId, path]);

  // recolor when the app theme flips — deferred a frame so the document's
  // data-theme (set by a parent effect) is applied before we read CSS vars,
  // otherwise the terminal picks up the *previous* theme's background.
  useEffect(() => {
    const id = requestAnimationFrame(() => {
      if (termRef.current) termRef.current.options.theme = xtermTheme(theme);
    });
    return () => cancelAnimationFrame(id);
  }, [theme]);

  return <div className="term" ref={ref} />;
});
