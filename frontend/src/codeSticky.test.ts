import { describe, it, expect } from "vitest";
import {
  serializeSticky,
  parseSticky,
  stickyKey,
  type StickyCursor,
} from "./codeSticky";

const cursors = (m: Record<string, StickyCursor>) => new Map(Object.entries(m));

describe("codeSticky — stickyKey", () => {
  it("namespaces per workspace", () => {
    expect(stickyKey("abc")).toBe("haro-editor-abc");
    expect(stickyKey("abc")).not.toBe(stickyKey("xyz"));
  });
});

describe("codeSticky — serializeSticky", () => {
  it("keeps only restore-worth fields (path, mdPreview, cursor)", () => {
    const s = serializeSticky(
      [{ path: "a.ts" }, { path: "b.md", mdPreview: true }],
      "b.md",
      cursors({ "a.ts": { lineNumber: 4, column: 2 } }),
    );
    expect(s).toEqual({
      tabs: [
        { path: "a.ts", cursor: { lineNumber: 4, column: 2 } },
        { path: "b.md", mdPreview: true },
      ],
      active: "b.md",
    });
  });

  it("drops falsy mdPreview and absent cursors", () => {
    const s = serializeSticky([{ path: "a.ts", mdPreview: false }], "a.ts", new Map());
    expect(s.tabs).toEqual([{ path: "a.ts" }]);
  });

  it("nulls an active path that isn't among the tabs", () => {
    const s = serializeSticky([{ path: "a.ts" }], "gone.ts", new Map());
    expect(s.active).toBeNull();
  });
});

describe("codeSticky — parseSticky", () => {
  it("round-trips a serialized snapshot", () => {
    const state = serializeSticky(
      [{ path: "a.ts" }, { path: "b.md", mdPreview: true }],
      "a.ts",
      cursors({ "a.ts": { lineNumber: 7, column: 3 } }),
    );
    expect(parseSticky(JSON.stringify(state))).toEqual(state);
  });

  it("returns null for null / garbage / wrong shape", () => {
    expect(parseSticky(null)).toBeNull();
    expect(parseSticky("not json")).toBeNull();
    expect(parseSticky("{}")).toBeNull();
    expect(parseSticky('{"tabs":"nope"}')).toBeNull();
  });

  it("skips tabs without a string path", () => {
    const r = parseSticky('{"tabs":[{"path":"a.ts"},{"foo":1},{"path":42}],"active":"a.ts"}');
    expect(r?.tabs).toEqual([{ path: "a.ts" }]);
  });

  it("drops a malformed cursor but keeps the tab", () => {
    const r = parseSticky('{"tabs":[{"path":"a.ts","cursor":{"lineNumber":"x"}}],"active":null}');
    expect(r?.tabs).toEqual([{ path: "a.ts" }]);
  });

  it("nulls an active path not present in the parsed tabs", () => {
    const r = parseSticky('{"tabs":[{"path":"a.ts"}],"active":"gone.ts"}');
    expect(r?.active).toBeNull();
  });
});
