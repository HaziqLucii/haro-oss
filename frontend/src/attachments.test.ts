import { describe, expect, it } from "vitest";
import {
  attachmentLabel,
  composeWithAttachments,
  shouldAttachPaste,
  type Attachment,
} from "./attachments";

describe("shouldAttachPaste", () => {
  it("leaves short pastes inline", () => {
    expect(shouldAttachPaste("")).toBe(false);
    expect(shouldAttachPaste("a quick one-liner")).toBe(false);
    expect(shouldAttachPaste("line1\nline2\nline3")).toBe(false);
  });

  it("attaches a many-line block", () => {
    expect(shouldAttachPaste(Array(25).fill("x").join("\n"))).toBe(true);
  });

  it("attaches a long single-line block", () => {
    expect(shouldAttachPaste("x".repeat(2500))).toBe(true);
  });
});

describe("attachmentLabel", () => {
  const a = (lines: number): Attachment => ({ path: ".context/p.txt", name: "p.txt", lines });
  it("pluralizes", () => {
    expect(attachmentLabel(a(1))).toBe("p.txt · 1 line");
    expect(attachmentLabel(a(42))).toBe("p.txt · 42 lines");
  });
});

describe("composeWithAttachments", () => {
  const att: Attachment[] = [
    { path: ".context/a.txt", name: "a.txt", lines: 3 },
    { path: ".context/b.txt", name: "b.txt", lines: 5 },
  ];

  it("appends @mentions after the prose", () => {
    expect(composeWithAttachments("fix the bug", att)).toBe(
      "fix the bug\n\n@.context/a.txt @.context/b.txt"
    );
  });

  it("works with attachments and no prose", () => {
    expect(composeWithAttachments("   ", att)).toBe("@.context/a.txt @.context/b.txt");
  });

  it("is a no-op with no attachments", () => {
    expect(composeWithAttachments("just text", [])).toBe("just text");
  });
});
