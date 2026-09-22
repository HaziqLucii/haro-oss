import { describe, it, expect } from "vitest";
import {
  issueMatchesQuery,
  labelCountsOf,
  groupIssuesByLabel,
  stageGlyph,
} from "./components/Backlog";
import type { IssueItem } from "./types";

const mk = (o: Partial<IssueItem> & { number: number }): IssueItem => ({
  title: "",
  body: "",
  state: "open",
  labels: [],
  url: "",
  ...o,
});

describe("issueMatchesQuery", () => {
  const it0 = mk({ number: 42, title: "Fix the gate flake", labels: ["bug", "ci"] });

  it("matches everything on an empty query", () => {
    expect(issueMatchesQuery(it0, "")).toBe(true);
  });
  it("matches on title substring", () => {
    expect(issueMatchesQuery(it0, "flake")).toBe(true);
    expect(issueMatchesQuery(it0, "nope")).toBe(false);
  });
  it("matches on issue number", () => {
    expect(issueMatchesQuery(it0, "42")).toBe(true);
    expect(issueMatchesQuery(it0, "7")).toBe(false);
  });
  it("matches on a label", () => {
    expect(issueMatchesQuery(it0, "ci")).toBe(true);
  });
});

describe("labelCountsOf", () => {
  it("counts distinct labels and ranks count-desc then name", () => {
    const issues = [
      mk({ number: 1, labels: ["bug", "ui"] }),
      mk({ number: 2, labels: ["bug"] }),
      mk({ number: 3, labels: ["ui"] }),
      mk({ number: 4, labels: [] }),
    ];
    expect(labelCountsOf(issues)).toEqual([
      ["bug", 2],
      ["ui", 2],
    ]);
  });
  it("breaks count ties alphabetically", () => {
    const issues = [mk({ number: 1, labels: ["zeta"] }), mk({ number: 2, labels: ["alpha"] })];
    expect(labelCountsOf(issues).map(([l]) => l)).toEqual(["alpha", "zeta"]);
  });
});

describe("groupIssuesByLabel", () => {
  const issues = [
    mk({ number: 1, labels: ["bug", "ui"] }),
    mk({ number: 2, labels: ["ui"] }),
    mk({ number: 3, labels: [] }),
    mk({ number: 4, labels: ["bug"] }),
  ];

  it("groups by first label, one row per issue (no duplication)", () => {
    const groups = groupIssuesByLabel(issues, ["bug", "ui"]);
    const total = groups.reduce((n, [, g]) => n + g.length, 0);
    expect(total).toBe(issues.length);
    // #1 lands under its first label "bug", not "ui"
    const bug = groups.find(([l]) => l === "bug")![1].map((i) => i.number);
    expect(bug).toEqual([1, 4]);
  });

  it("orders groups by the given order and puts unlabeled ('') last", () => {
    const groups = groupIssuesByLabel(issues, ["bug", "ui"]);
    expect(groups.map(([l]) => l)).toEqual(["bug", "ui", ""]);
  });

  it("sends first-labels missing from the order ahead of unlabeled but after ranked", () => {
    const groups = groupIssuesByLabel(
      [mk({ number: 1, labels: ["known"] }), mk({ number: 2, labels: ["orphan"] }), mk({ number: 3, labels: [] })],
      ["known"],
    );
    expect(groups.map(([l]) => l)).toEqual(["known", "orphan", ""]);
  });
});

describe("stageGlyph", () => {
  it("a live seeded workspace wins over `done` — backtracking a closed issue must read as active, not finished", () => {
    // (a todo item is never both done and seeded — renderTodoItem only marks
    // `seeded` on a not-done item — so this case is really about a closed
    // issue re-seeded into a fresh workspace.)
    expect(stageGlyph(true, "running", true)).toBe("◐");
    expect(stageGlyph(true, "green", true)).toBe("●");
    expect(stageGlyph(true, "red", true)).toBe("✕");
  });

  it("maps the active gate stages to their own glyph while seeded", () => {
    expect(stageGlyph(false, "green", true)).toBe("●");
    expect(stageGlyph(false, "red", true)).toBe("✕");
    expect(stageGlyph(false, "queued", true)).toBe("◐");
    expect(stageGlyph(false, "running", true)).toBe("◐");
    expect(stageGlyph(false, undefined, true)).toBe("◐"); // no stage data yet
  });

  it("once unseeded, `done` or a shipped stage reads finished; otherwise startable", () => {
    expect(stageGlyph(true, undefined, false)).toBe("✔");
    expect(stageGlyph(false, "shipped", false)).toBe("✔");
    expect(stageGlyph(false, undefined, false)).toBe("○");
    expect(stageGlyph(false, "ready", false)).toBe("○");
  });
});
