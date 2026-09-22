import { describe, it, expect } from "vitest";
import { fuzzyMatch, fuzzyFind, flattenFiles } from "./fuzzy";
import type { FileNode } from "./types";

describe("fuzzyMatch", () => {
  it("returns null when the query is not a subsequence", () => {
    expect(fuzzyMatch("xyz", "src/App.tsx")).toBeNull();
    expect(fuzzyMatch("abc", "ab")).toBeNull(); // runs out of target
  });

  it("matches a subsequence and reports the matched positions", () => {
    const m = fuzzyMatch("app", "src/App.tsx");
    expect(m).not.toBeNull();
    expect(m!.positions).toEqual([4, 5, 6]); // A p p
  });

  it("empty query matches everything with a neutral score", () => {
    expect(fuzzyMatch("", "anything")).toEqual({ score: 0, positions: [] });
  });

  it("scores a consecutive run above a gappy match of the same query", () => {
    const consecutive = fuzzyMatch("abc", "abcdef")!;
    const gappy = fuzzyMatch("abc", "axbxcx")!;
    expect(consecutive.score).toBeGreaterThan(gappy.score);
  });

  it("rewards a match at a path-segment start", () => {
    const atStart = fuzzyMatch("app", "src/App.tsx")!;
    const midWord = fuzzyMatch("app", "src/snappy.tsx")!;
    expect(atStart.score).toBeGreaterThan(midWord.score);
  });
});

describe("fuzzyFind", () => {
  const paths = [
    "src/App.tsx",
    "src/components/AppShell.tsx",
    "src/api.ts",
    "backend/app/main.py",
    "README.md",
  ];

  it("ranks a basename match above a deep-path match", () => {
    const r = fuzzyFind("app", paths);
    expect(r[0].path).toBe("src/App.tsx");
  });

  it("drops non-matching paths", () => {
    const r = fuzzyFind("zzz", paths);
    expect(r).toHaveLength(0);
  });

  it("empty query returns the corpus in order, capped by limit", () => {
    const r = fuzzyFind("", paths, 2);
    expect(r.map((x) => x.path)).toEqual(["src/App.tsx", "src/components/AppShell.tsx"]);
  });
});

describe("flattenFiles", () => {
  it("collects file paths depth-first and drops directories", () => {
    const tree: FileNode[] = [
      {
        name: "src",
        path: "src",
        dir: true,
        children: [
          { name: "App.tsx", path: "src/App.tsx", dir: false },
          {
            name: "components",
            path: "src/components",
            dir: true,
            children: [{ name: "GoToFile.tsx", path: "src/components/GoToFile.tsx", dir: false }],
          },
        ],
      },
      { name: "README.md", path: "README.md", dir: false },
    ];
    expect(flattenFiles(tree)).toEqual([
      "src/App.tsx",
      "src/components/GoToFile.tsx",
      "README.md",
    ]);
  });
});
