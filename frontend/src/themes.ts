/* Theme registry — a theme is a *family* with two grounds (light + dark), not a
   flat dark/light/skin list. Two orthogonal choices drive the look:
     - family  → `data-theme` on <html>. haro ships ONE trademark family ("haro");
                 the registry stays a list (not a single constant) so a second
                 family can be added back the same way this one is defined.
     - mode    → `data-mode` on <html>: "light" | "dark". Flipped by the appbar
                 sun/moon, which now ALWAYS toggles the mode of the current family.

   Each family defines the FULL token contract across both modes:
     - "haro" → dark = styles/base.css (`:root`, the app default);
                light = styles/themes/haro.css (`[data-theme="haro"][data-mode="light"]`)
   Add a family by dropping its CSS (dark base + a light-mode override block) and
   one entry below — the picker, persistence, and the appbar flip all read this list.

   `swatches` is the preview strip the picker renders; order them
   bg → surface → accent → … so the strip reads as the family. */

export type Mode = "dark" | "light";

/* Third-party surfaces (Monaco, xterm.js) don't read our CSS vars natively, so a
   family that wants them ON-BRAND ships explicit palettes here — the registry is the
   one place a theme's colors live. A family that omits these falls back to the ground
   default (Monaco vs / vs-dark; the terminal keeps reading live CSS vars). The Haro
   family now ships its own warm-monochrome dark palette (matching the ryoku brand —
   syntax colour comes from opacity/weight steps on the same bone ink, not new hues,
   plus the gate green/red for diff evidence); its light mode has no palette yet, so it
   still falls back to stock vs / CSS vars until one ships.

   See MonacoEditor.tsx (registers a Monaco theme per (family × mode) that has an
   `editor` palette) and Terminal.tsx (merges `terminal` ANSI over the CSS-var base). */

/** A Monaco color theme for one (family × mode): the built-in base to inherit and the
    `editor.*` workbench color overrides, plus optional syntax token rules. */
export interface EditorPalette {
  base: "vs" | "vs-dark";
  /** Workbench colors — `editor.background`, `editorCursor.foreground`, … */
  colors: Record<string, string>;
  /** Syntax token rules (scope → color). Usually a few; the base carries the rest. */
  rules?: readonly { token: string; foreground?: string; fontStyle?: string }[];
  /** Diff-view line/text background overrides (the ② code diff lens). */
  diff?: Record<string, string>;
}

/** xterm.js ANSI slots for one (family × mode). The surface colors (background /
    foreground / cursor / selection) keep flowing from live CSS vars — those tokens are
    already themed; only the 16 ANSI slots need a per-family map so program output
    (git, ls, test runners) reads in-key rather than on xterm's stock palette. */
export interface TerminalPalette {
  black?: string; red?: string; green?: string; yellow?: string;
  blue?: string; magenta?: string; cyan?: string; white?: string;
  brightBlack?: string; brightRed?: string; brightGreen?: string; brightYellow?: string;
  brightBlue?: string; brightMagenta?: string; brightCyan?: string; brightWhite?: string;
}

export interface Theme {
  id: string;
  label: string;
  tagline: string;
  swatches: readonly string[];
  /** Optional Monaco palette per mode (absent → stock vs / vs-dark). */
  editor?: Partial<Record<Mode, EditorPalette>>;
  /** Optional xterm ANSI palette per mode (absent → CSS-var surface only). */
  terminal?: Partial<Record<Mode, TerminalPalette>>;
}

export const THEMES = [
  {
    id: "haro",
    label: "Haro",
    tagline: "The platform look: warm canvas, green gate. Toggles light / dark.",
    swatches: ["#141310", "#201e17", "#41d183", "#ff7a5c", "#f3f0e4"],
    // Dark-mode editor + terminal: warm monochrome (the ryoku brand), so Monaco and
    // the shell stop reading as a stock-VS-Code blue/purple/green rainbow that clashes
    // with the near-black + bone ground. Syntax colour is opacity/weight steps on the
    // same bone ink (#cdc4ba), NOT new hues — the one exception is diff evidence
    // (inserted/removed backgrounds), which stays the gate green/red (--add/--del) on
    // purpose. Light mode ships no palette yet (falls back to stock vs / CSS vars).
    editor: {
      dark: {
        base: "vs-dark",
        colors: {
          "editor.background": "#0b0a09",
          "editor.foreground": "#cdc4ba",
          "editorLineNumber.foreground": "#cdc4ba66",
          "editorLineNumber.activeForeground": "#cdc4ba",
          "editor.lineHighlightBackground": "#cdc4ba0d",
          "editor.selectionBackground": "#cdc4ba1a",
          "editorCursor.foreground": "#cdc4ba",
          "editorWhitespace.foreground": "#cdc4ba33",
          "editorIndentGuide.background1": "#cdc4ba26",
          "editorIndentGuide.activeBackground1": "#cdc4ba4d",
        },
        rules: [
          { token: "comment", foreground: "cdc4ba66", fontStyle: "italic" },
          { token: "keyword", foreground: "cdc4ba", fontStyle: "bold" },
          { token: "string", foreground: "d6c7b4" },
          { token: "number", foreground: "cdc4ba" },
          { token: "type", foreground: "cdc4badb" },
          { token: "class", foreground: "cdc4badb" },
          { token: "identifier", foreground: "cdc4badb" },
          { token: "delimiter", foreground: "cdc4ba99" },
        ],
        diff: {
          "diffEditor.insertedLineBackground": "#41d18326",
          "diffEditor.removedLineBackground": "#e0685e26",
          "diffEditor.insertedTextBackground": "#41d1834d",
          "diffEditor.removedTextBackground": "#e0685e4d",
        },
      },
    },
    // ANSI 16, dark mode only (surface colours keep flowing from live CSS vars — see
    // the TerminalPalette doc comment). Every hue desaturated toward warm-neutral bone
    // except green, kept close to the gate accent (#41d183) since test-runner output
    // leans on "green = pass" reading clearly against the near-black ground.
    terminal: {
      dark: {
        black: "#141310", red: "#d7968c", green: "#41d183", yellow: "#b6a67a",
        blue: "#8a97a0", magenta: "#a48a97", cyan: "#8aa89e", white: "#cdc4ba",
        brightBlack: "#5c564c", brightRed: "#e0685e", brightGreen: "#7be3ab", brightYellow: "#d4c08a",
        brightBlue: "#a9b5bd", brightMagenta: "#c1a4b8", brightCyan: "#a8c7bf", brightWhite: "#f3f0e4",
      },
    },
  },
] as const satisfies readonly Theme[];

/** Union of the registered family ids — widens automatically as families are added. */
export type ThemeId = (typeof THEMES)[number]["id"];

/** The app default family; every fallback resolves to this. */
export const DEFAULT_THEME: ThemeId = "haro";

/** The app default ground; the appbar flip toggles away from and back to this. */
export const DEFAULT_MODE: Mode = "dark";

/** Coerce a persisted (or otherwise untrusted) family value to a real id. Legacy
    values from the old flat model ("light"/"dark") aren't families, so they fall
    back to the default — the paired mode is recovered by resolveMode(). */
export function resolveThemeId(value: string | null | undefined): ThemeId {
  return THEMES.some((t) => t.id === value) ? (value as ThemeId) : DEFAULT_THEME;
}

/** Coerce a persisted (or untrusted) mode value to "light" | "dark". Accepts the
    legacy theme id as a second arg so a user who had the old "light" theme keeps
    light mode after the migration to the family × mode model. */
export function resolveMode(
  value: string | null | undefined,
  legacyTheme?: string | null
): Mode {
  if (value === "light" || value === "dark") return value;
  if (legacyTheme === "light") return "light";
  return DEFAULT_MODE;
}

/** The registry entry for a family id (falls back to the default family). */
export function themeById(id: string): Theme {
  return THEMES.find((t) => t.id === id) ?? THEMES[0];
}

/** Split the `theme` prop the editor/terminal components receive into its family +
    mode. Accepts the combined `"<family>-<mode>"` string App threads through (e.g.
    "haro-dark") and, for safety, a bare legacy mode ("light"/"dark" → default
    family). Both consumers share this so the parsing lives in one place. */
export function parseThemeProp(prop: string | null | undefined): { id: ThemeId; mode: Mode } {
  const s = prop ?? "";
  const mode: Mode = s.endsWith("light") ? "light" : "dark";
  const dash = s.lastIndexOf("-");
  const family = dash > 0 ? s.slice(0, dash) : "";
  return { id: resolveThemeId(family || DEFAULT_THEME), mode };
}

/** The Monaco palette for a (family × mode), or undefined when the family rides the
    stock vs / vs-dark ground (Haro's light mode, until it ships one). */
export function editorPalette(id: string, mode: Mode): EditorPalette | undefined {
  return themeById(id).editor?.[mode];
}

/** The xterm ANSI palette for a (family × mode), or undefined when the family keeps
    the plain CSS-var surface (Haro's light mode, until it ships one). */
export function terminalPalette(id: string, mode: Mode): TerminalPalette | undefined {
  return themeById(id).terminal?.[mode];
}
