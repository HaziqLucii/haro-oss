// File extension → Monaco language id (Monaco ships tokenizers for all of these).
// Shared by the code editor (CodePanel) and the diff-preview highlighter
// (highlight.ts) so both name languages the same way.
export const MONACO_LANG: Record<string, string> = {
  ts: "typescript", tsx: "typescript", mts: "typescript", cts: "typescript",
  js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
  json: "json", jsonc: "json",
  md: "markdown", markdown: "markdown", mdx: "markdown",
  css: "css", scss: "scss", less: "less",
  html: "html", htm: "html", xml: "xml",
  py: "python", pyi: "python",
  go: "go", rs: "rust", rb: "ruby", java: "java", php: "php",
  c: "c", h: "c", cpp: "cpp", cc: "cpp", cxx: "cpp", hpp: "cpp",
  sh: "shell", bash: "shell", zsh: "shell", fish: "shell",
  yaml: "yaml", yml: "yaml", sql: "sql", lua: "lua", swift: "swift",
  toml: "ini", ini: "ini",
};

export function monacoLang(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return MONACO_LANG[ext] ?? "plaintext";
}
