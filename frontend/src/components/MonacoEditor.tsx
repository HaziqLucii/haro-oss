// The code step's editor, powered by Monaco — the same engine as VS Code, for the
// familiar feel (syntax colouring, minimap, multi-cursor). Everything is bundled
// locally: we point @monaco-editor/react at the npm `monaco-editor` (NOT its CDN
// default) and wire Vite-bundled web workers, so the editor works fully offline —
// haro is local-first. This module pulls in Monaco, so its callers lazy-load it:
// the ~heavy editor only downloads once you actually open a file / a settings pane.
//
// It's also haro's ONE editor engine — the small command / instruction fields in
// the Runbook and Settings use it too (chromeless presets below), so there's no
// second editor (CodeMirror) to reason about.

import { useEffect, useMemo, useRef, useState } from "react";
import Editor, { DiffEditor, loader, type DiffOnMount, type OnMount } from "@monaco-editor/react";
import * as monaco from "monaco-editor";
import { THEMES, parseThemeProp, editorPalette, type Theme } from "../themes";
import editorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";
import jsonWorker from "monaco-editor/esm/vs/language/json/json.worker?worker";
import cssWorker from "monaco-editor/esm/vs/language/css/css.worker?worker";
import htmlWorker from "monaco-editor/esm/vs/language/html/html.worker?worker";
import tsWorker from "monaco-editor/esm/vs/language/typescript/ts.worker?worker";

// Route each language service to its Vite-bundled worker (local, no network).
(self as unknown as { MonacoEnvironment: monaco.Environment }).MonacoEnvironment = {
  getWorker(_workerId, label) {
    if (label === "json") return new jsonWorker();
    if (label === "css" || label === "scss" || label === "less") return new cssWorker();
    if (label === "html" || label === "handlebars" || label === "razor") return new htmlWorker();
    if (label === "typescript" || label === "javascript") return new tsWorker();
    return new editorWorker();
  },
};

// Use the bundled Monaco instead of @monaco-editor/react's CDN loader.
loader.config({ monaco });

// Diagnostics policy for the TS/JS language service. We run over an arbitrary worktree,
// not a full IDE project, so:
//  - SYNTAX validation is ON — it needs no project types, catches real parse errors
//    (unclosed braces, stray tokens) live, and produces no false positives. For it to
//    judge a `.tsx`/`.jsx` correctly we (a) give each model a real file-path URI so the
//    worker picks the right script kind, and (b) load the worktree's tsconfig compiler
//    options (jsx mode, target, decorators) — see `applyTsCompilerOptions`.
//  - SEMANTIC validation stays OFF: without the project's node_modules type graph loaded
//    into the worker, every import resolves to "cannot find module" and cascades into
//    noise. Loading that graph for an arbitrary project is the remaining "real bet"
//    (see backlog/code-editor.md). Enabling it is then a one-line flip here + a type-defs
//    loader.
//  - SUGGESTION diagnostics OFF too — the "unused local" greying needs full type info to
//    be right, so it'd misfire without the semantic graph.
const diagnostics = {
  noSemanticValidation: true,
  noSyntaxValidation: false,
  noSuggestionDiagnostics: true,
} as const;
// monaco-editor's main-entry types mark `languages.typescript` as deprecated (it's
// present at runtime — that's what colours TS/JS), so cast through to the defaults.
type TsDefaults = {
  setDiagnosticsOptions(o: typeof diagnostics): void;
  setCompilerOptions(o: Record<string, unknown>): void;
  getCompilerOptions(): Record<string, unknown>;
};
const tsLangs = monaco.languages.typescript as unknown as {
  typescriptDefaults?: TsDefaults;
  javascriptDefaults?: TsDefaults;
  ScriptTarget?: Record<string, number>;
  ModuleKind?: Record<string, number>;
  ModuleResolutionKind?: Record<string, number>;
  JsxEmit?: Record<string, number>;
};
tsLangs.typescriptDefaults?.setDiagnosticsOptions(diagnostics);
tsLangs.javascriptDefaults?.setDiagnosticsOptions(diagnostics);

// Look up a Monaco TS enum member by its tsconfig string value, case-insensitively and
// tolerant of the usual aliases ("es6" → ES2015, "node" → NodeJs, …). Returns undefined
// when the enum or value is unknown so the caller leaves that option at Monaco's default.
function tsEnum(
  table: Record<string, number> | undefined,
  value: unknown,
  aliases: Record<string, string> = {},
): number | undefined {
  if (!table || typeof value !== "string") return undefined;
  const norm = value.toLowerCase().replace(/[-_]/g, "");
  const key = Object.keys(table).find((k) => {
    const kn = k.toLowerCase();
    return kn === norm || kn === aliases[norm];
  });
  return key ? table[key] : undefined;
}

// Map a raw tsconfig `compilerOptions` object to Monaco's `CompilerOptions` shape and
// apply it to both the TS and JS language services (globally — haro edits one workspace
// at a time). The four enum-valued options (target/module/moduleResolution/jsx) need
// numeric Monaco enums; booleans / string arrays / paths pass through untouched. We
// always force `allowJs`/`allowNonTsExtensions` (so `.jsx`/`.tsx`/`.js` are parsed) and a
// jsx default (so TSX parses even when there's no tsconfig), then let the project's own
// values override. Called on each code-editor mount (idempotent).
export function applyTsCompilerOptions(raw: Record<string, unknown> | null | undefined): void {
  const co = raw ?? {};
  const opts: Record<string, unknown> = {
    // Safe universal defaults; project tsconfig overrides below where it sets them.
    allowJs: true,
    allowNonTsExtensions: true,
    jsx: tsLangs.JsxEmit?.ReactJSX ?? 4,
    target: tsLangs.ScriptTarget?.ESNext ?? 99,
    // Pass-through booleans/strings/arrays that affect how files parse.
    ...pick(co, [
      "allowJs",
      "checkJs",
      "experimentalDecorators",
      "emitDecoratorMetadata",
      "jsxImportSource",
      "baseUrl",
      "paths",
      "lib",
      "strict",
      "esModuleInterop",
      "allowSyntheticDefaultImports",
    ]),
  };
  const target = tsEnum(tsLangs.ScriptTarget, co.target, { es6: "es2015", es7: "es2016" });
  if (target !== undefined) opts.target = target;
  const jsx = tsEnum(tsLangs.JsxEmit, co.jsx);
  if (jsx !== undefined) opts.jsx = jsx;
  const mod = tsEnum(tsLangs.ModuleKind, co.module, { es6: "es2015" });
  if (mod !== undefined) opts.module = mod;
  const modRes = tsEnum(tsLangs.ModuleResolutionKind, co.moduleResolution, {
    node: "nodejs",
    node10: "nodejs",
    node16: "nodenext",
  });
  if (modRes !== undefined) opts.moduleResolution = modRes;

  for (const d of [tsLangs.typescriptDefaults, tsLangs.javascriptDefaults]) {
    d?.setCompilerOptions({ ...d.getCompilerOptions(), ...opts });
  }
}

// Shallow-pick only defined keys from an object (skip absent tsconfig options so they
// stay at Monaco's default rather than being clobbered with `undefined`).
function pick(o: Record<string, unknown>, keys: string[]): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of keys) if (o[k] !== undefined) out[k] = o[k];
  return out;
}

// Transparent-background themes so an EMBEDDED editor (Runbook command fields,
// Settings instructions) shows the container's warm panel colour instead of
// Monaco's stock cold #1e1e1e / #fffffe rectangle — keeps small inline fields
// on-brand. Opt in with the `transparent` prop; the full code editor keeps
// vs / vs-dark (it IS the surface, no warm panel behind it).
monaco.editor.defineTheme("haro-dark", {
  base: "vs-dark",
  inherit: true,
  rules: [],
  colors: { "editor.background": "#00000000" },
});
monaco.editor.defineTheme("haro-light", {
  base: "vs",
  inherit: true,
  rules: [],
  colors: { "editor.background": "#00000000" },
});

// Diff-editor themes (② code "diff" view). Stock vs-dark paints inserted/removed
// lines at ~20% opacity, which is nearly invisible on haro's warm-dark surface —
// the diff looked "unhighlighted" even though the decorations were there. Boost
// them to clearly-readable green/red for both the whole-line and inline-char
// backgrounds; `base` keeps syntax + everything else identical.
monaco.editor.defineTheme("haro-diff-dark", {
  base: "vs-dark",
  inherit: true,
  rules: [],
  colors: {
    "diffEditor.insertedLineBackground": "#3fb9504d",
    "diffEditor.removedLineBackground": "#f851494d",
    "diffEditor.insertedTextBackground": "#3fb95066",
    "diffEditor.removedTextBackground": "#f8514966",
  },
});
monaco.editor.defineTheme("haro-diff-light", {
  base: "vs",
  inherit: true,
  rules: [],
  colors: {
    "diffEditor.insertedLineBackground": "#2da44e33",
    "diffEditor.removedLineBackground": "#cf222e33",
    "diffEditor.insertedTextBackground": "#2da44e4d",
    "diffEditor.removedTextBackground": "#cf222e4d",
  },
});

// Per-family editor themes, generated from the `themes.ts` registry so a family's
// colors live in ONE place (the registry entry), not scattered across Monaco calls.
// For every (family × mode) that ships an `editor` palette — 8-bit in both modes,
// Haro in dark mode only so far — we register three variants, the theme NAME
// encoding (family, mode, variant):
//   `<id>-<mode>`        opaque code editor (it IS the surface)
//   `<id>-<mode>-t`      transparent (embedded command/instruction fields show the
//                        container's panel colour through the editor)
//   `<id>-<mode>-diff`   the review lens, with boosted inserted/removed backgrounds
// A (family × mode) with no palette resolves to the stock vs / vs-dark / haro-*
// themes above instead — currently just Haro's light mode, until it ships one.
// Note this loop runs AFTER the `haro-dark` / `haro-dark-t` / `haro-dark-diff`
// placeholders above, so once Haro's dark palette lands here it silently
// overwrites those names (same theme id, real colors) — intentional, not a bug;
// `haro-light` / `haro-diff-light` are untouched since Haro has no light palette.
for (const t of THEMES as readonly Theme[]) {
  for (const mode of ["dark", "light"] as const) {
    const pal = t.editor?.[mode];
    if (!pal) continue;
    const rules = (pal.rules ?? []).map((r) => ({ ...r }));
    monaco.editor.defineTheme(`${t.id}-${mode}`, {
      base: pal.base,
      inherit: true,
      rules,
      colors: { ...pal.colors },
    });
    monaco.editor.defineTheme(`${t.id}-${mode}-t`, {
      base: pal.base,
      inherit: true,
      rules,
      colors: { ...pal.colors, "editor.background": "#00000000" },
    });
    monaco.editor.defineTheme(`${t.id}-${mode}-diff`, {
      base: pal.base,
      inherit: true,
      rules,
      colors: { ...pal.colors, ...(pal.diff ?? {}) },
    });
  }
}

// Resolve the Monaco theme name for a `theme` prop ("<family>-<mode>", or a bare
// legacy mode). A family with a registry `editor` palette gets its generated theme;
// otherwise we fall back to the stock ground themes keyed on mode (the Haro family).
type EditorVariant = "code" | "transparent" | "diff";
function monacoThemeName(themeProp: string, variant: EditorVariant): string {
  const { id, mode } = parseThemeProp(themeProp);
  if (editorPalette(id, mode)) {
    if (variant === "diff") return `${id}-${mode}-diff`;
    if (variant === "transparent") return `${id}-${mode}-t`;
    return `${id}-${mode}`;
  }
  if (variant === "diff") return mode === "light" ? "haro-diff-light" : "haro-diff-dark";
  if (variant === "transparent") return mode === "light" ? "haro-light" : "haro-dark";
  return mode === "light" ? "vs" : "vs-dark";
}

// Editor options tuned for the code step: VS Code-ish, but restrained. Mono font
// from our bundled IBM Plex Mono; automaticLayout so fullscreen / mobile resizes
// reflow without manual measuring.
const OPTIONS: monaco.editor.IStandaloneEditorConstructionOptions = {
  fontFamily: "'IBM Plex Mono', ui-monospace, SFMono-Regular, Menlo, monospace",
  fontSize: 13,
  minimap: { enabled: true },
  scrollBeyondLastLine: false,
  automaticLayout: true,
  tabSize: 2,
  renderWhitespace: "selection",
  // Native, 1:1 wheel scrolling. Monaco's `smoothScrolling` eases each wheel tick to
  // its target over several frames — that easing is what reads as "floaty / laggy"
  // rather than native. Off = the scroll tracks the wheel exactly.
  smoothScrolling: false,
  padding: { top: 8, bottom: 8 },
  scrollbar: { verticalScrollbarSize: 10, horizontalScrollbarSize: 10 },
};

export default function MonacoEditor({
  value,
  language,
  theme,
  onChange,
  onMount,
  options,
  transparent,
  path,
  compilerOptions,
  height = "100%",
  autoHeight,
  minHeight = 34,
  maxHeight = 480,
  placeholder,
}: {
  value: string;
  language: string;
  theme: string; // "<family>-<mode>" (e.g. "haro-dark"); bare "light"/"dark" also accepted
  onChange: (v: string) => void;
  onMount?: OnMount;
  /** Merged over the defaults (shallow) — pass a preset to reshape the chrome. */
  options?: monaco.editor.IStandaloneEditorConstructionOptions;
  /** Use haro's transparent theme so the container's panel colour shows through. */
  transparent?: boolean;
  /** Worktree-relative file path. Gives the Monaco model a real file URI so the TS/JS
   *  worker parses the correct script kind (.ts vs .tsx vs .js) — required for inline
   *  syntax squiggles to be right. Omit for the small embedded fields (no diagnostics). */
  path?: string;
  /** Worktree tsconfig compilerOptions (from `api.getTsconfig`) — applied to the TS/JS
   *  language service so files parse the project's way. Omit for embedded fields. */
  compilerOptions?: Record<string, unknown> | null;
  /** Fixed height when not auto-sizing (default fills the parent). */
  height?: string | number;
  /** Grow to content between min/max — for the small command fields that used to
   *  auto-grow under CodeMirror. */
  autoHeight?: boolean;
  minHeight?: number;
  maxHeight?: number;
  /** Monaco has no native placeholder; we overlay one while the buffer is empty. */
  placeholder?: string;
}) {
  const [contentH, setContentH] = useState(minHeight);
  const showPlaceholder = placeholder != null && value === "";

  // Apply the project's tsconfig to the (global, singleton) TS/JS language service
  // whenever it resolves — the fetch can land after the editor has already mounted, so
  // this can't live only in onMount. Idempotent; a no-op for the embedded fields that
  // never pass compilerOptions.
  useEffect(() => {
    if (compilerOptions !== undefined) applyTsCompilerOptions(compilerOptions);
  }, [compilerOptions]);
  const themeName = monacoThemeName(theme, transparent ? "transparent" : "code");
  const editorHeight = autoHeight ? contentH : height;

  return (
    <div
      className="mon"
      style={{ position: "relative", width: "100%", height: autoHeight ? undefined : "100%" }}
    >
      <Editor
        value={value}
        // A real file path → the model URI carries the file's extension, so the TS/JS
        // worker parses it as the right script kind (crucial for TSX syntax checking).
        path={path}
        language={language || "plaintext"}
        theme={themeName}
        onChange={(v) => onChange(v ?? "")}
        onMount={(ed, m) => {
          if (autoHeight) {
            const update = () =>
              setContentH(Math.min(Math.max(ed.getContentHeight(), minHeight), maxHeight));
            ed.onDidContentSizeChange(update);
            update();
          }
          onMount?.(ed, m);
        }}
        options={{ ...OPTIONS, ...options }}
        loading={<div className="empty">loading editor…</div>}
        height={editorHeight}
      />
      {showPlaceholder && <div className="mon-ph">{placeholder}</div>}
    </div>
  );
}

// Per-file diff (red/green in the editor), Monaco's DiffEditor. Read-only: this is
// a review lens — toggle it off to edit. The sides depend on the review mode the
// caller picks: working-tree-vs-base (original = base_ref, modified = the working
// buffer, unsaved edits included) or one branch commit's before/after. Shares the
// worker/loader/theme setup above (same module, so it's configured once regardless
// of which view opens first).
const DIFF_OPTIONS: monaco.editor.IStandaloneDiffEditorConstructionOptions = {
  ...OPTIONS,
  readOnly: true,
  renderSideBySide: true,
  // Read-only *review* lens. Drop the minimap — two scaled canvases (one per side)
  // that repaint the whole file every scroll frame, the real per-frame cost and of
  // little use here. But KEEP the overview ruler: its green/red change markers on
  // the scrollbar are how you find WHERE the changes are in a long file, and it
  // repaints only when the diff changes, not per scroll frame — so it's cheap
  // (the old comment wrongly lumped it with the minimap). `smoothScrolling` off
  // (inherited) keeps wheel scrolling 1:1.
  minimap: { enabled: false },
  renderOverviewRuler: true,
  // Collapse long unchanged stretches into "⋯ N unchanged lines" bands so a change
  // buried deep in a big file (e.g. App.tsx line 813) is on screen when the diff
  // opens, not a blind scroll away. One click on a band expands it for full context.
  hideUnchangedRegions: { enabled: true },
};

export function MonacoDiffEditor({
  original,
  modified,
  language,
  theme,
  renderSideBySide = true,
  onMount,
}: {
  original: string;
  modified: string;
  language: string;
  theme: string; // "<family>-<mode>" (e.g. "haro-dark"); bare "light"/"dark" also accepted
  /** split (side-by-side, default) vs unified (inline) layout — a reviewer toggle
   *  for large diffs. Applied live via updateOptions so flipping it never remounts
   *  the editor (which would lose scroll position). */
  renderSideBySide?: boolean;
  onMount?: DiffOnMount;
}) {
  const edRef = useRef<monaco.editor.IStandaloneDiffEditor | null>(null);
  // Flip layout on an already-mounted editor without a remount.
  useEffect(() => {
    edRef.current?.updateOptions({ renderSideBySide });
  }, [renderSideBySide]);
  // New identity only when the layout changes, so the DiffEditor wrapper's own
  // option-sync effect also picks it up (belt-and-suspenders with the ref above).
  const options = useMemo(() => ({ ...DIFF_OPTIONS, renderSideBySide }), [renderSideBySide]);
  return (
    <div className="mon" style={{ position: "relative", width: "100%", height: "100%" }}>
      <DiffEditor
        original={original}
        modified={modified}
        language={language || "plaintext"}
        theme={monacoThemeName(theme, "diff")}
        onMount={(ed, m) => {
          edRef.current = ed;
          onMount?.(ed, m);
        }}
        options={options}
        loading={<div className="empty">loading editor…</div>}
        height="100%"
      />
    </div>
  );
}
