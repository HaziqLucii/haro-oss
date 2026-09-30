import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { ReviewPanel } from "./ReviewPanel";
import type { ReviewComment } from "../types";

// "Send to backlog" (backlog/backlog-v2.md Move 3) is optional — a caller with no
// project context to write into (none exist today, but the prop is optional for
// future callers) must not render a dead button.

const comment: ReviewComment = { id: "c1", target: "src/a.ts", context: null, text: "" };

describe("ReviewPanel — send to backlog", () => {
  it("renders nothing when there are no comments", () => {
    expect(
      renderToStaticMarkup(
        <ReviewPanel comments={[]} busy={false} onUpdate={() => {}} onRemove={() => {}} onSend={() => {}} />,
      ),
    ).toBe("");
  });

  it("shows the backlog button when onSendToBacklog is provided", () => {
    const out = renderToStaticMarkup(
      <ReviewPanel
        comments={[comment]}
        busy={false}
        onUpdate={() => {}}
        onRemove={() => {}}
        onSend={() => {}}
        onSendToBacklog={() => {}}
      />,
    );
    expect(out).toContain("review-backlog");
    expect(out).toContain("+ backlog");
  });

  it("omits the backlog button when the prop isn't given", () => {
    const out = renderToStaticMarkup(
      <ReviewPanel comments={[comment]} busy={false} onUpdate={() => {}} onRemove={() => {}} onSend={() => {}} />,
    );
    expect(out).not.toContain("review-backlog");
  });
});
