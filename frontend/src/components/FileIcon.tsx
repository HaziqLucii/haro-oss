// VS Code-style file-type icons, using the real Material Icon Theme SVGs (the
// icon set most people picture as "VS Code file icons"). We reuse that theme's
// own extension→icon associations but only bundle the handful of SVGs we ship —
// the raw markup is inlined at build time (`?raw`), so no network fetch and no
// 1250-icon bloat. One leaf component with a `path` prop: the agent-stream chips
// use it now, the code-editor file tree can adopt it later.

import typescript from "material-icon-theme/icons/typescript.svg?raw";
import react_ts from "material-icon-theme/icons/react_ts.svg?raw";
import javascript from "material-icon-theme/icons/javascript.svg?raw";
import react from "material-icon-theme/icons/react.svg?raw";
import python from "material-icon-theme/icons/python.svg?raw";
import html from "material-icon-theme/icons/html.svg?raw";
import css from "material-icon-theme/icons/css.svg?raw";
import sass from "material-icon-theme/icons/sass.svg?raw";
import less from "material-icon-theme/icons/less.svg?raw";
import json from "material-icon-theme/icons/json.svg?raw";
import markdown from "material-icon-theme/icons/markdown.svg?raw";
import vue from "material-icon-theme/icons/vue.svg?raw";
import svelte from "material-icon-theme/icons/svelte.svg?raw";
import liquid from "material-icon-theme/icons/liquid.svg?raw";
import go from "material-icon-theme/icons/go.svg?raw";
import rust from "material-icon-theme/icons/rust.svg?raw";
import ruby from "material-icon-theme/icons/ruby.svg?raw";
import java from "material-icon-theme/icons/java.svg?raw";
import c from "material-icon-theme/icons/c.svg?raw";
import h from "material-icon-theme/icons/h.svg?raw";
import cpp from "material-icon-theme/icons/cpp.svg?raw";
import console from "material-icon-theme/icons/console.svg?raw";
import toml from "material-icon-theme/icons/toml.svg?raw";
import yaml from "material-icon-theme/icons/yaml.svg?raw";
import database from "material-icon-theme/icons/database.svg?raw";
import image from "material-icon-theme/icons/image.svg?raw";
import svg from "material-icon-theme/icons/svg.svg?raw";
import lock from "material-icon-theme/icons/lock.svg?raw";
import document from "material-icon-theme/icons/document.svg?raw";
import nodejs from "material-icon-theme/icons/nodejs.svg?raw";
import tsconfig from "material-icon-theme/icons/tsconfig.svg?raw";
import docker from "material-icon-theme/icons/docker.svg?raw";
import makefile from "material-icon-theme/icons/makefile.svg?raw";
import git from "material-icon-theme/icons/git.svg?raw";
import vite from "material-icon-theme/icons/vite.svg?raw";
import readme from "material-icon-theme/icons/readme.svg?raw";
import file from "material-icon-theme/icons/file.svg?raw";
import folderClosed from "material-icon-theme/icons/folder.svg?raw";
import folderOpened from "material-icon-theme/icons/folder-open.svg?raw";

// icon-name → inlined SVG markup (only the ones we import above).
const SVG: Record<string, string> = {
  typescript, react_ts, javascript, react, python, html, css, sass, less, json,
  markdown, vue, svelte, liquid, go, rust, ruby, java, c, h, cpp, console, toml, yaml,
  database, image, svg, lock, document, nodejs, tsconfig, docker, makefile, git,
  vite, readme, file,
};

// extension → icon-name, taken from Material Icon Theme's own mapping (subset).
const EXT: Record<string, string> = {
  ts: "typescript",
  mts: "typescript",
  cts: "typescript",
  tsx: "react_ts",
  js: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  jsx: "react",
  py: "python",
  pyi: "python",
  html: "html",
  htm: "html",
  css: "css",
  scss: "sass",
  sass: "sass",
  less: "less",
  json: "json",
  jsonc: "json",
  md: "markdown",
  mdx: "markdown",
  vue: "vue",
  svelte: "svelte",
  liquid: "liquid",
  go: "go",
  rs: "rust",
  rb: "ruby",
  java: "java",
  c: "c",
  h: "h",
  hpp: "h",
  cpp: "cpp",
  cc: "cpp",
  cxx: "cpp",
  sh: "console",
  bash: "console",
  zsh: "console",
  fish: "console",
  toml: "toml",
  yaml: "yaml",
  yml: "yaml",
  sql: "database",
  png: "image",
  jpg: "image",
  jpeg: "image",
  gif: "image",
  webp: "image",
  ico: "image",
  svg: "svg",
  lock: "lock",
  txt: "document",
  log: "document",
};

// whole-filename → icon-name (beats the extension when both match).
const NAMES: Record<string, string> = {
  "package.json": "nodejs",
  "package-lock.json": "nodejs",
  "tsconfig.json": "tsconfig",
  dockerfile: "docker",
  "docker-compose.yml": "docker",
  "docker-compose.yaml": "docker",
  makefile: "makefile",
  ".gitignore": "git",
  ".gitattributes": "git",
  "readme.md": "readme",
  "readme": "readme",
};

function iconName(path: string): string {
  const base = (path.split(/[\\/]/).pop() ?? path).trim();
  const lower = base.toLowerCase();
  if (NAMES[lower]) return NAMES[lower];
  if (lower.startsWith("vite.config.")) return "vite";
  const dot = base.lastIndexOf(".");
  const ext = dot > 0 ? base.slice(dot + 1).toLowerCase() : "";
  return (ext && EXT[ext]) || "file";
}

/** A Material-Icon-Theme icon for `path`. Files pick by type; pass `folder` for a
 *  folder icon (`open` swaps to the expanded variant). `size` is the edge in px. */
export function FileIcon({
  path,
  size = 15,
  folder,
  open,
}: {
  path: string;
  size?: number;
  folder?: boolean;
  open?: boolean;
}) {
  const markup = folder ? (open ? folderOpened : folderClosed) : (SVG[iconName(path)] ?? SVG.file);
  return (
    <span
      className="fileicon"
      aria-hidden="true"
      style={{ width: size, height: size }}
      dangerouslySetInnerHTML={{ __html: markup }}
    />
  );
}
