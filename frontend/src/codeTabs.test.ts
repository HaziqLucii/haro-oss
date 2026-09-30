import { describe, it, expect } from "vitest";
import { closeTab, isDirty, anyDirty, tabLabel, type CodeTab } from "./codeTabs";

const tab = (path: string, over: Partial<CodeTab> = {}): CodeTab => ({
  path,
  content: "x",
  saved: "x",
  note: null,
  mdPreview: false,
  ...over,
});

describe("codeTabs — dirty tracking", () => {
  it("isDirty is true only when content diverges from saved", () => {
    expect(isDirty(tab("a.ts"))).toBe(false);
    expect(isDirty(tab("a.ts", { content: "y", saved: "x" }))).toBe(true);
  });

  it("anyDirty reflects the whole set", () => {
    expect(anyDirty([tab("a.ts"), tab("b.ts")])).toBe(false);
    expect(anyDirty([tab("a.ts"), tab("b.ts", { content: "y", saved: "x" })])).toBe(true);
  });
});

describe("codeTabs — closeTab active-selection rules", () => {
  const tabs = [tab("a.ts"), tab("b.ts"), tab("c.ts")];

  it("closing a non-active tab keeps the active one", () => {
    const r = closeTab(tabs, "a.ts", "c.ts");
    expect(r.tabs.map((t) => t.path)).toEqual(["b.ts", "c.ts"]);
    expect(r.activePath).toBe("c.ts");
  });

  it("closing the active middle tab falls to the right neighbour", () => {
    const r = closeTab(tabs, "b.ts", "b.ts");
    expect(r.tabs.map((t) => t.path)).toEqual(["a.ts", "c.ts"]);
    expect(r.activePath).toBe("c.ts");
  });

  it("closing the active last tab falls to the left neighbour", () => {
    const r = closeTab(tabs, "c.ts", "c.ts");
    expect(r.tabs.map((t) => t.path)).toEqual(["a.ts", "b.ts"]);
    expect(r.activePath).toBe("b.ts");
  });

  it("closing the only tab clears the active path", () => {
    const r = closeTab([tab("a.ts")], "a.ts", "a.ts");
    expect(r.tabs).toEqual([]);
    expect(r.activePath).toBeNull();
  });

  it("closing an unknown path is a no-op", () => {
    const r = closeTab(tabs, "z.ts", "a.ts");
    expect(r.tabs).toBe(tabs);
    expect(r.activePath).toBe("a.ts");
  });
});

describe("codeTabs — tabLabel", () => {
  it("shows the basename", () => {
    expect(tabLabel("src/components/CodePanel.tsx")).toBe("CodePanel.tsx");
    expect(tabLabel("README.md")).toBe("README.md");
  });
});
