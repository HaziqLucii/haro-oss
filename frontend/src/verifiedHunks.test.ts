import { describe, expect, it } from "vitest";
import type { VerifiedFile, VerifiedHunksResponse } from "./types";
import {
  collapsesByDefault,
  hunkBadge,
  hunkProof,
  indexProof,
  lineDot,
  mergeProof,
  residueCount,
  residueReviewItems,
  unexecutedCount,
} from "./verifiedHunks";

function file(over: Partial<VerifiedFile> = {}): VerifiedFile {
  return {
    path: "src/math.ts",
    in_map: true,
    stale: false,
    added: 4,
    executed: 2,
    unexecuted: 1,
    noncoverable: 1,
    lines: { "1": 2, "2": 1, "3": 0, "4": null },
    ...over,
  };
}

function res(over: Partial<VerifiedHunksResponse> = {}): VerifiedHunksResponse {
  return {
    base_ref: "main",
    gate_sha: "abc1234",
    supported: true,
    stale: false,
    files: [file()],
    note: "2 of 4 added lines executed · 1 never executed",
    ...over,
  };
}

describe("indexProof", () => {
  it("returns null for every shape that carries no usable proof", () => {
    expect(indexProof(null)).toBeNull();
    expect(indexProof(res({ supported: false }))).toBeNull();
    expect(indexProof(res({ files: [] }))).toBeNull();
  });
});

describe("lineDot", () => {
  const f = file();
  it("marks an executed line and a never-executed line differently", () => {
    expect(lineDot(f, 1)).toBe("hit");
    expect(lineDot(f, 3)).toBe("cold");
  });

  it("says nothing about a non-coverable line", () => {
    // The rule that keeps the gutter readable: a comment or closing brace gets no dot,
    // because a dot is a claim.
    expect(lineDot(f, 4)).toBe("");
  });

  it("says nothing about a line the map never mentioned, or with no proof at all", () => {
    expect(lineDot(f, 99)).toBe("");
    expect(lineDot(undefined, 1)).toBe("");
    expect(lineDot(f, null)).toBe("");
  });

  it("says nothing at all about a stale file", () => {
    expect(lineDot(file({ stale: true }), 1)).toBe("");
  });
});

describe("hunkProof", () => {
  it("tallies from the lines the hunk actually renders", () => {
    expect(hunkProof(file(), [1, 2, 3, 4])).toEqual({
      kind: "partial",
      added: 4,
      executed: 2,
      unexecuted: 1,
      noncoverable: 1,
    });
  });

  it("is 'executed' only when nothing in the hunk was missed", () => {
    expect(hunkProof(file(), [1, 2])?.kind).toBe("executed");
    expect(hunkProof(file(), [1, 2, 4])?.kind).toBe("executed"); // the comment doesn't count
  });

  it("calls a comment-only hunk nonexec rather than executed or untested", () => {
    expect(hunkProof(file(), [4])?.kind).toBe("nonexec");
  });

  it("treats an unmapped file's added lines as never executed", () => {
    const p = hunkProof(file({ in_map: false, lines: {} }), [1, 2, 3]);
    expect(p).toEqual({ kind: "unmapped", added: 3, executed: 0, unexecuted: 3, noncoverable: 0 });
  });

  it("makes no tally for a stale file", () => {
    const p = hunkProof(file({ stale: true, lines: {} }), [1, 2]);
    expect(p?.kind).toBe("stale");
    expect(p?.executed).toBe(0);
  });
});

describe("mergeProof", () => {
  it("rolls hunks up into a file badge", () => {
    const a = hunkProof(file(), [1, 2]);
    const b = hunkProof(file(), [3, 4]);
    expect(mergeProof([a, b])).toEqual({
      kind: "partial",
      added: 4,
      executed: 2,
      unexecuted: 1,
      noncoverable: 1,
    });
  });

  it("lets one stale hunk make the whole file stale", () => {
    const good = hunkProof(file(), [1, 2]);
    const stale = hunkProof(file({ stale: true }), [3]);
    expect(mergeProof([good, stale])?.kind).toBe("stale");
  });

  it("is null when nothing has proof", () => {
    expect(mergeProof([null, null])).toBeNull();
  });
});

describe("hunkBadge", () => {
  it("never claims a line is verified, proven or correct", () => {
    // THE guard on this feature. An executed line is not an asserted line, and copy is the
    // only thing standing between those two ideas in a reviewer's head.
    const kinds = [
      hunkProof(file(), [1, 2]),
      hunkProof(file(), [1, 2, 3]),
      hunkProof(file({ in_map: false, lines: {} }), [1]),
      hunkProof(file({ stale: true }), [1]),
      hunkProof(file(), [4]),
    ];
    for (const p of kinds) {
      const b = hunkBadge(p)!;
      const text = `${b.label} ${b.title}`.toLowerCase();
      expect(text).not.toMatch(/verif|proven|proof|correct/);
      expect(b.label.length).toBeGreaterThan(0);
    }
  });

  it("uses the interim §3 copy for a fully-executed hunk", () => {
    // "executed by N passing tests" waits for §4's per-test attribution — a number we
    // cannot attribute yet would be the first crack in the surface.
    expect(hunkBadge(hunkProof(file(), [1, 2]))?.label).toBe("executed by the green suite");
  });

  it("counts the residue, not the whole hunk, for a partial hunk", () => {
    expect(hunkBadge(hunkProof(file(), [1, 2, 3, 4]))?.label).toBe(
      "1 of 4 added lines never executed",
    );
  });

  it("spells out executed ≠ asserted in the tooltip", () => {
    expect(hunkBadge(hunkProof(file(), [1, 2]))?.title).toContain("executed ≠ asserted");
  });

  it("is null with no proof, so the diff renders exactly as it does today", () => {
    expect(hunkBadge(null)).toBeNull();
  });
});

describe("unexecutedCount + collapsesByDefault", () => {
  const proof = indexProof(res());

  it("sorts by what the suite missed", () => {
    expect(unexecutedCount(proof, "src/math.ts")).toBe(1);
    expect(unexecutedCount(proof, "src/unknown.ts")).toBe(0);
    expect(unexecutedCount(null, "src/math.ts")).toBe(0);
  });

  it("collapses only a file whose every coverable added line ran", () => {
    const clean = indexProof(
      res({ files: [file({ unexecuted: 0, executed: 3, lines: { "1": 1, "2": 1, "3": 1 } })] }),
    );
    expect(collapsesByDefault(clean, "src/math.ts")).toBe(true);
    expect(collapsesByDefault(proof, "src/math.ts")).toBe(false);
  });

  it("refuses to collapse anything it is unsure about", () => {
    // Hiding a file on weak evidence is the exact failure the kill conditions describe.
    expect(collapsesByDefault(indexProof(res({ files: [file({ stale: true })] })), "src/math.ts")).toBe(
      false,
    );
    expect(
      collapsesByDefault(
        indexProof(res({ files: [file({ in_map: false, unexecuted: 0, lines: {} })] })),
        "src/math.ts",
      ),
    ).toBe(false);
    expect(collapsesByDefault(null, "src/math.ts")).toBe(false);
  });

  it("does not collapse a file with nothing executable in it", () => {
    const commentsOnly = indexProof(
      res({ files: [file({ added: 2, executed: 0, unexecuted: 0, noncoverable: 2, lines: {} })] }),
    );
    expect(collapsesByDefault(commentsOnly, "src/math.ts")).toBe(false);
  });
});

describe("residueReviewItems", () => {
  it("batches the never-executed files, biggest residue first", () => {
    const v = res({
      files: [
        file({ path: "src/small.ts", added: 3, executed: 2, unexecuted: 1, lines: {} }),
        file({ path: "src/big.ts", added: 20, executed: 2, unexecuted: 18, lines: {} }),
        file({ path: "src/clean.ts", added: 4, executed: 4, unexecuted: 0, lines: {} }),
      ],
    });
    const items = residueReviewItems(v);
    expect(items.map((i) => i.target)).toEqual([
      "never executed: big.ts",
      "never executed: small.ts",
    ]);
    expect(residueCount(v)).toBe(2);
  });

  it("asks for tests OR a justification, never tests alone", () => {
    // A signal that only accepts one answer gets gamed into accepting anything.
    expect(residueReviewItems(res())[0].text).toMatch(/or explain why they cannot be covered/);
  });

  it("skips stale files — their residue may describe a diff that is gone", () => {
    const v = res({ files: [file({ stale: true, unexecuted: 9 })] });
    expect(residueReviewItems(v)).toEqual([]);
  });

  it("is empty when there is no proof", () => {
    expect(residueReviewItems(null)).toEqual([]);
    expect(residueReviewItems(res({ supported: false }))).toEqual([]);
  });
});
