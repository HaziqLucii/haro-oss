import { type ComponentPropsWithoutRef, type ReactNode } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { CopyButton, InlineCode } from "./AgentMarkdown";
import { api } from "../api";

/** Resolve a markdown image `src` for the in-app preview. Absolute/external refs
 *  (http(s):, data:, protocol-relative `//`, in-page `#`) pass through untouched;
 *  a path relative to the worktree is rewritten to the raw-file endpoint so it
 *  actually loads (a bare relative src would otherwise resolve against the SPA
 *  origin and 404). Resolved against the markdown file's own directory, so a
 *  README at the root maps `docs/x.png` and a nested doc resolves `../y.png`. */
export function resolveImageSrc(src?: string, wsId?: string, basePath?: string): string | undefined {
  if (!src) return src;
  if (/^([a-z][a-z0-9+.-]*:|\/\/|#)/i.test(src)) return src;
  if (!wsId) return src; // no workspace context (e.g. a unit test) → leave as authored
  const dir = basePath && basePath.includes("/") ? basePath.slice(0, basePath.lastIndexOf("/")) : "";
  const out = src.startsWith("/") ? [] : dir.split("/").filter(Boolean);
  for (const seg of src.replace(/^\//, "").split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") out.pop();
    else out.push(seg);
  }
  return api.rawUrl(wsId, out.join("/"));
}

/** Pull the plain-text content out of a rendered code block's children, so the
 *  copy button grabs the source (not React nodes). */
function nodeText(node: ReactNode): string {
  if (node == null || node === false) return "";
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(nodeText).join("");
  if (typeof node === "object" && "props" in (node as { props?: unknown })) {
    return nodeText((node as { props: { children?: ReactNode } }).props.children);
  }
  return "";
}

/** Full-fidelity markdown renderer for opened `.md` files — GitHub-flavored via
 *  remark-gfm (task lists `- [ ]`, tables, strikethrough, autolinks, `---` rules).
 *  Unlike the streaming AgentMarkdown (a tolerant hand parser tuned for live agent
 *  output), this renders a complete document the way an editor like Obsidian would.
 *  We keep haro's touches: fenced blocks get a copy button, inline `code` copies on
 *  click, and links open safely in a new tab. */
export function FileMarkdown({
  text,
  wsId,
  basePath,
}: {
  text: string;
  /** Workspace whose worktree serves relative images (via the raw-file endpoint). */
  wsId?: string;
  /** Path of the markdown file being previewed — relative image srcs resolve against its dir. */
  basePath?: string;
}) {
  return (
    <div className="md md-file">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          // Relative images point at worktree files, not the SPA origin — rewrite
          // them to the raw-file endpoint so they load in the preview.
          img({ src, alt, ...props }: ComponentPropsWithoutRef<"img">) {
            return (
              <img {...props} src={resolveImageSrc(src, wsId, basePath)} alt={alt ?? ""} loading="lazy" />
            );
          },
          // react-markdown renders fenced/indented code as <pre><code>. We hoist
          // the whole block into our copy-enabled card and detect inline code by
          // the absence of a language class / newlines.
          code({ className, children, ...props }: ComponentPropsWithoutRef<"code">) {
            const lang = /language-(\w[\w+.-]*)/.exec(className || "")?.[1];
            const raw = nodeText(children as ReactNode);
            const isBlock = !!lang || raw.includes("\n");
            if (!isBlock) return <InlineCode text={raw.replace(/\n$/, "")} />;
            return (
              <div className="code-block">
                {lang && <span className="code-lang">{lang}</span>}
                <CopyButton text={raw.replace(/\n$/, "")} />
                <pre>
                  <code className={className} {...props}>
                    {children}
                  </code>
                </pre>
              </div>
            );
          },
          // <pre> just passes through — the code() override above supplies the card.
          pre({ children }: ComponentPropsWithoutRef<"pre">) {
            return <>{children}</>;
          },
          a({ children, ...props }: ComponentPropsWithoutRef<"a">) {
            return (
              <a {...props} target="_blank" rel="noreferrer noopener">
                {children}
              </a>
            );
          },
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  );
}
