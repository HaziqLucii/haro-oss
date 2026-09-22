import { describe, it, expect } from "vitest";
import {
  detectTrigger,
  filterSlashCommands,
  filterFiles,
  flattenFiles,
  applyCompletion,
  findPrRefs,
  SLASH_COMMANDS,
} from "./composerAutocomplete";
import type { FileNode } from "./types";

describe("detectTrigger — slash", () => {
  it("triggers on a lone slash at the start", () => {
    expect(detectTrigger("/", 1)).toEqual({ kind: "slash", query: "", start: 0, end: 1 });
  });

  it("captures the query after the slash", () => {
    expect(detectTrigger("/rev", 4)).toEqual({ kind: "slash", query: "rev", start: 0, end: 4 });
  });

  it("does NOT trigger when the slash is not at the start", () => {
    expect(detectTrigger("hello /rev", 10)).toBeNull();
  });

  it("stops being a slash command once a space is typed", () => {
    expect(detectTrigger("/review foo", 11)).toBeNull();
  });

  it("uses the caret, not the end of the string", () => {
    // caret sits right after "/re" even though more text follows
    expect(detectTrigger("/review", 3)).toEqual({ kind: "slash", query: "re", start: 0, end: 3 });
  });
});

describe("detectTrigger — at", () => {
  it("triggers on a lone @ at the start", () => {
    expect(detectTrigger("@", 1)).toEqual({ kind: "at", query: "", start: 0, end: 1 });
  });

  it("triggers on @ after whitespace and captures the query", () => {
    expect(detectTrigger("fix @src", 8)).toEqual({ kind: "at", query: "src", start: 4, end: 8 });
  });

  it("keeps slashes inside the file token (paths contain /)", () => {
    const t = detectTrigger("@src/api", 8);
    expect(t).toEqual({ kind: "at", query: "src/api", start: 0, end: 8 });
  });

  it("does NOT trigger on an @ mid-word (e.g. an email)", () => {
    expect(detectTrigger("foo@bar", 7)).toBeNull();
  });

  it("tracks the nearest boundary @ when several are present", () => {
    expect(detectTrigger("@a b @cd", 8)).toEqual({ kind: "at", query: "cd", start: 5, end: 8 });
  });

  it("returns null once a space follows the @ token", () => {
    expect(detectTrigger("@src/api ", 9)).toBeNull();
  });
});

describe("detectTrigger — none", () => {
  it("returns null for plain text", () => {
    expect(detectTrigger("just a normal task", 18)).toBeNull();
  });

  it("clamps an out-of-range caret", () => {
    expect(detectTrigger("/x", 99)).toEqual({ kind: "slash", query: "x", start: 0, end: 2 });
  });
});

describe("filterSlashCommands", () => {
  it("returns all commands for an empty query", () => {
    expect(filterSlashCommands("")).toEqual(SLASH_COMMANDS);
  });

  it("filters by substring (ignoring the leading slash)", () => {
    expect(filterSlashCommands("re").map((c) => c.name)).toEqual(["/review"]);
  });

  it("is case-insensitive", () => {
    expect(filterSlashCommands("MODEL").map((c) => c.name)).toEqual(["/model"]);
  });

  it("returns nothing for an unknown command", () => {
    expect(filterSlashCommands("zzz")).toEqual([]);
  });
});

const tree: FileNode[] = [
  {
    name: "src",
    path: "src",
    dir: true,
    children: [
      { name: "App.tsx", path: "src/App.tsx", dir: false },
      { name: "api.ts", path: "src/api.ts", dir: false },
      {
        name: "components",
        path: "src/components",
        dir: true,
        children: [{ name: "AppBar.tsx", path: "src/components/AppBar.tsx", dir: false }],
      },
    ],
  },
  { name: "README.md", path: "README.md", dir: false },
];

describe("flattenFiles", () => {
  it("collects file paths and drops directories", () => {
    expect(flattenFiles(tree)).toEqual([
      "src/App.tsx",
      "src/api.ts",
      "src/components/AppBar.tsx",
      "README.md",
    ]);
  });
});

describe("filterFiles", () => {
  const paths = flattenFiles(tree);

  it("returns the head of the list (capped) for an empty query", () => {
    expect(filterFiles(paths, "")).toEqual(paths);
    expect(filterFiles(paths, "", 2)).toEqual(paths.slice(0, 2));
  });

  it("matches anywhere in the path, case-insensitively", () => {
    expect(filterFiles(paths, "readme")).toEqual(["README.md"]);
  });

  it("ranks basename matches above deep-path matches", () => {
    // "app" is a basename hit for App.tsx and AppBar.tsx, and appears in the
    // path of AppBar.tsx too — the shallower basename hit wins.
    const res = filterFiles(paths, "app");
    expect(res[0]).toBe("src/App.tsx");
    expect(res).toContain("src/components/AppBar.tsx");
  });

  it("respects the limit", () => {
    expect(filterFiles(paths, "s", 1)).toHaveLength(1);
  });
});

describe("applyCompletion", () => {
  it("replaces a slash token and appends a trailing space", () => {
    const trigger = detectTrigger("/rev", 4)!;
    expect(applyCompletion("/rev", trigger, "/review")).toEqual({
      text: "/review ",
      caret: 8,
    });
  });

  it("replaces an @ token in the middle, preserving surrounding text", () => {
    const text = "fix @src then ship";
    const trigger = detectTrigger("fix @src", 8)!; // start=4, end=8
    const res = applyCompletion(text, trigger, "@src/App.tsx");
    expect(res.text).toBe("fix @src/App.tsx  then ship");
    expect(res.caret).toBe("fix @src/App.tsx ".length);
    // caret lands right after the inserted trailing space
    expect(res.text.slice(0, res.caret)).toBe("fix @src/App.tsx ");
  });
});

describe("findPrRefs", () => {
  it("detects a `PR #12` reference with the PR prefix", () => {
    expect(findPrRefs("see PR #12 for context")).toEqual([
      { number: 12, raw: "PR #12", start: 4, end: 10 },
    ]);
  });

  it("detects a bare `#131` reference at a boundary", () => {
    expect(findPrRefs("blocked by #131")).toEqual([
      { number: 131, raw: "#131", start: 11, end: 15 },
    ]);
  });

  it("detects a reference at the very start of the text", () => {
    expect(findPrRefs("#7 landed")).toEqual([{ number: 7, raw: "#7", start: 0, end: 2 }]);
  });

  it("is case-insensitive on the PR prefix and tolerates extra spacing", () => {
    expect(findPrRefs("pr  #9")).toEqual([{ number: 9, raw: "pr  #9", start: 0, end: 6 }]);
  });

  it("finds multiple references, preserving order", () => {
    const refs = findPrRefs("compare PR #12 and #131");
    expect(refs.map((r) => r.number)).toEqual([12, 131]);
  });

  it("does NOT match a markdown heading (`# Title`)", () => {
    expect(findPrRefs("# Heading\ntext")).toEqual([]);
  });

  it("does NOT match a `#` glued to a preceding word (`foo#1`)", () => {
    expect(findPrRefs("foo#1")).toEqual([]);
  });

  it("does NOT match when a word char follows the digits (`#12abc`)", () => {
    expect(findPrRefs("#12abc")).toEqual([]);
  });

  it("keeps a trailing punctuation mark out of the match (`#12.`)", () => {
    expect(findPrRefs("done #12.")).toEqual([{ number: 12, raw: "#12", start: 5, end: 8 }]);
  });

  it("returns nothing for text with no references", () => {
    expect(findPrRefs("just some prose")).toEqual([]);
  });
});
