import { describe, it, expect } from "vitest";
import {
  THEMES,
  DEFAULT_THEME,
  DEFAULT_MODE,
  resolveThemeId,
  resolveMode,
  themeById,
  parseThemeProp,
  editorPalette,
  terminalPalette,
} from "./themes";

describe("theme registry", () => {
  it("ships the default family and the default mode is dark", () => {
    expect(DEFAULT_THEME).toBe("haro");
    expect(DEFAULT_MODE).toBe("dark");
    expect(THEMES.some((t) => t.id === DEFAULT_THEME)).toBe(true);
  });

  it("has unique ids and non-empty preview swatches", () => {
    const ids = THEMES.map((t) => t.id);
    expect(new Set(ids).size).toBe(ids.length);
    for (const t of THEMES) expect(t.swatches.length).toBeGreaterThan(0);
  });
});

describe("resolveThemeId — untrusted persisted family", () => {
  it("keeps a registered family id", () => {
    expect(resolveThemeId("haro")).toBe("haro");
  });

  it("maps legacy flat ids and unknowns to the default family", () => {
    expect(resolveThemeId("light")).toBe("haro");
    expect(resolveThemeId("dark")).toBe("haro");
    expect(resolveThemeId("zapper")).toBe(DEFAULT_THEME);
    expect(resolveThemeId(null)).toBe(DEFAULT_THEME);
    expect(resolveThemeId(undefined)).toBe(DEFAULT_THEME);
    expect(resolveThemeId("")).toBe(DEFAULT_THEME);
  });
});

describe("resolveMode — untrusted persisted mode + legacy migration", () => {
  it("keeps a valid mode", () => {
    expect(resolveMode("light")).toBe("light");
    expect(resolveMode("dark")).toBe("dark");
  });

  it("recovers light mode from the legacy 'light' theme id", () => {
    expect(resolveMode(null, "light")).toBe("light");
    expect(resolveMode(undefined, "dark")).toBe("dark");
    expect(resolveMode(null, "zapper")).toBe(DEFAULT_MODE);
  });

  it("falls back to the default mode for unknown / missing values", () => {
    expect(resolveMode("noon")).toBe(DEFAULT_MODE);
    expect(resolveMode(null)).toBe(DEFAULT_MODE);
    expect(resolveMode(undefined)).toBe(DEFAULT_MODE);
    expect(resolveMode("")).toBe(DEFAULT_MODE);
  });
});

describe("themeById", () => {
  it("returns the matching entry", () => {
    expect(themeById("haro").label).toBe("Haro");
  });

  it("falls back to the first family for an unknown id", () => {
    expect(themeById("nope")).toBe(THEMES[0]);
  });
});

describe("parseThemeProp — the editor/terminal `theme` prop", () => {
  it("splits the combined '<family>-<mode>' string", () => {
    expect(parseThemeProp("haro-dark")).toEqual({ id: "haro", mode: "dark" });
    expect(parseThemeProp("haro-light")).toEqual({ id: "haro", mode: "light" });
  });

  it("accepts a bare legacy mode → default family", () => {
    expect(parseThemeProp("dark")).toEqual({ id: "haro", mode: "dark" });
    expect(parseThemeProp("light")).toEqual({ id: "haro", mode: "light" });
  });

  it("falls back for unknown families and empty input (mode still resolves)", () => {
    expect(parseThemeProp("zapper-dark")).toEqual({ id: DEFAULT_THEME, mode: "dark" });
    expect(parseThemeProp("")).toEqual({ id: DEFAULT_THEME, mode: DEFAULT_MODE });
    expect(parseThemeProp(null)).toEqual({ id: DEFAULT_THEME, mode: DEFAULT_MODE });
    expect(parseThemeProp(undefined)).toEqual({ id: DEFAULT_THEME, mode: DEFAULT_MODE });
  });
});

describe("editor / terminal palettes drive the third-party surfaces", () => {
  it("Haro ships a warm-monochrome dark editor + terminal palette", () => {
    const ed = editorPalette("haro", "dark");
    expect(ed?.base).toBe("vs-dark");
    expect(ed?.colors["editor.background"]).toBe("#0b0a09");
    expect(ed?.colors["editor.foreground"]).toBe("#cdc4ba");
    // diff evidence stays the gate green/red, not swept into the monochrome ink.
    expect(ed?.diff?.["diffEditor.insertedLineBackground"]).toMatch(/^#41d183/);
    expect(ed?.diff?.["diffEditor.removedLineBackground"]).toMatch(/^#e0685e/);

    const term = terminalPalette("haro", "dark");
    expect(term?.green).toBe("#41d183"); // "green = good" survives the reskin here too
  });

  it("Haro's light mode has no palette yet (rides stock vs / CSS vars)", () => {
    expect(editorPalette("haro", "light")).toBeUndefined();
    expect(terminalPalette("haro", "light")).toBeUndefined();
  });
});
