import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { FileMarkdown, resolveImageSrc } from "./FileMarkdown";

const html = (md: string) => renderToStaticMarkup(<FileMarkdown text={md} />);

describe("FileMarkdown — full GFM fidelity (the hand-rolled parser missed these)", () => {
  it("renders `- [ ]` / `- [x]` as real checkboxes, not literal brackets", () => {
    const out = html("- [ ] todo\n- [x] done");
    expect(out).toContain('type="checkbox"');
    expect(out).not.toContain("[ ]");
    expect(out).not.toContain("[x]");
    // exactly one of the two boxes is checked
    expect((out.match(/checked/g) || []).length).toBe(1);
  });

  it("renders `---` as a horizontal rule", () => {
    expect(html("above\n\n---\n\nbelow")).toContain("<hr");
  });

  it("renders GFM tables", () => {
    const out = html("| a | b |\n| - | - |\n| 1 | 2 |");
    expect(out).toContain("<table");
    expect(out).toContain("<th");
    expect(out).toContain("<td");
  });

  it("renders ordered lists, blockquotes and strikethrough", () => {
    expect(html("1. one\n2. two")).toContain("<ol");
    expect(html("> quoted")).toContain("<blockquote");
    expect(html("~~gone~~")).toContain("<del");
  });

  it("opens links in a new tab safely", () => {
    const out = html("[haro](https://example.com)");
    expect(out).toContain('href="https://example.com"');
    expect(out).toContain('target="_blank"');
    expect(out).toContain("noopener");
  });

  it("keeps fenced code in a copy-enabled block and shows the language", () => {
    const out = html("```ts\nconst x = 1;\n```");
    expect(out).toContain("code-block");
    expect(out).toContain("code-lang");
    expect(out).toContain("const x = 1;");
  });
});

describe("resolveImageSrc — relative images load from the worktree, not the SPA origin", () => {
  const WS = "ws_1";

  it("rewrites a root-relative-to-file path to the raw-file endpoint (README at root)", () => {
    expect(resolveImageSrc("docs/screenshots/cockpit.png", WS, "README.md")).toBe(
      "/workspaces/ws_1/raw?path=docs%2Fscreenshots%2Fcockpit.png"
    );
  });

  it("resolves against the markdown file's own directory", () => {
    expect(resolveImageSrc("img/x.png", WS, "docs/guide.md")).toBe(
      "/workspaces/ws_1/raw?path=docs%2Fimg%2Fx.png"
    );
  });

  it("collapses ./ and ../ segments", () => {
    expect(resolveImageSrc("../assets/x.png", WS, "docs/deep/guide.md")).toBe(
      "/workspaces/ws_1/raw?path=docs%2Fassets%2Fx.png"
    );
  });

  it("leaves absolute/external and data URIs untouched", () => {
    expect(resolveImageSrc("https://x.com/a.png", WS, "README.md")).toBe("https://x.com/a.png");
    expect(resolveImageSrc("//cdn/a.png", WS, "README.md")).toBe("//cdn/a.png");
    expect(resolveImageSrc("data:image/png;base64,AAA", WS, "README.md")).toBe("data:image/png;base64,AAA");
  });

  it("passes the src through when there is no workspace context", () => {
    expect(resolveImageSrc("docs/x.png", undefined, "README.md")).toBe("docs/x.png");
  });
});
