// Syntax highlighting for diff previews, reusing the bundled Monaco tokenizer —
// no extra dependency. We call `monaco.editor.colorize`, the static text→HTML
// tokenizer VS Code ships, instead of instantiating an editor, so a preview stays
// cheap. Monaco is dynamically imported on first use (CodePanel lazy-loads the full
// editor the same way), keeping the engine out of the first-paint bundle.

import { parseThemeProp, editorPalette } from "./themes";

let monacoP: Promise<typeof import("monaco-editor")> | null = null;
function getMonaco() {
  if (!monacoP) monacoP = import("monaco-editor");
  return monacoP;
}

// Colorize `text` under Monaco language `lang`, returning one HTML string per input
// line. Tokens are wrapped in Monaco's `.mtkN` classes, coloured by the global
// stylesheet Monaco injects for the ACTIVE theme, so we set that theme to the
// requested family × mode before colorizing. `themeProp` is the app's combined
// "<family>-<mode>" string (e.g. "haro-light"). Getting the MODE right here is
// what keeps light-mode text readable (dark tokens on a light card is the
// washed-out failure). Returns null for unknown languages or if Monaco is
// unavailable; callers fall back to plain text.
export async function highlightLines(
  text: string,
  lang: string,
  themeProp: string
): Promise<string[] | null> {
  if (!lang || lang === "plaintext") return null;
  try {
    const monaco = await getMonaco();
    const { id, mode } = parseThemeProp(themeProp);
    const pal = editorPalette(id, mode);
    let themeName: string;
    if (pal) {
      // Register the family's token palette so colorize reads in the theme's own
      // colours (each theme stays visually unique). Idempotent: MonacoEditor defines
      // the same name once its module loads, and redefining a theme is harmless, so
      // this also covers previewing a diff BEFORE the code editor has ever mounted.
      themeName = `${id}-${mode}`;
      monaco.editor.defineTheme(themeName, {
        base: pal.base,
        inherit: true,
        rules: (pal.rules ?? []).map((r) => ({ ...r })),
        colors: { ...pal.colors },
      });
    } else {
      // Haro family: no palette, stock ground keyed on the (correct) mode.
      themeName = mode === "light" ? "vs" : "vs-dark";
    }
    monaco.editor.setTheme(themeName);
    const html = await monaco.editor.colorize(text, lang, { tabSize: 2 });
    // colorize joins rendered lines with <br/> and appends a trailing one; token
    // text is HTML-escaped, so a literal "<br/>" in source can't appear here.
    const lines = html.split("<br/>");
    if (lines.length && lines[lines.length - 1] === "") lines.pop();
    return lines;
  } catch {
    return null;
  }
}
