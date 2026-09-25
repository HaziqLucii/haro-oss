// The prompt echo in the agent stream renders markdown (the user's own turn used to show
// raw `**bold**` and backticks) WITHOUT losing the two behaviours that were already there:
// clickable `@file` chips, and code fences left untouched inside.
//
// The regression this guards is specific: naive markdown rendering would have replaced
// `renderTaskText` wholesale and silently dropped the `@file` chips.
import { describe, it, expect } from "vitest";
import { Fragment } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { renderTaskText } from "./AgentStream";

// Tested at the unit rather than through <AgentStream>, which pulls in the file-tooltip
// subtree and needs a DOM (there is no jsdom in this project, and adding one for a test
// is not worth a dependency). `renderTaskText` IS the thing that changed.
/** `onOpenFile` present = the @file path is live, as in a real workspace. */
const html = (text: string, withOpenFile = true) =>
  renderToStaticMarkup(
    <Fragment>{renderTaskText(text, withOpenFile ? () => {} : undefined)}</Fragment>
  );

describe("the prompt echo renders markdown", () => {
  it("renders **bold** as a real element, not literal asterisks", () => {
    const out = html("Decide the verdict on a test **rewritten in place** today");
    expect(out).toContain("<strong>rewritten in place</strong>");
    expect(out).not.toContain("**rewritten in place**");
  });

  it("renders *italic* and _italic_ as emphasis", () => {
    expect(html("a test that is retitled *and* re-asserted")).toContain("<em>and</em>");
    expect(html("the _base_ contract")).toContain("<em>base</em>");
  });

  it("renders `inline code` as code, not backticks", () => {
    const out = html("so `no_tamper` read as intact");
    expect(out).toContain("no_tamper");
    expect(out).not.toContain("`no_tamper`");
  });

  it("handles the real-world case that prompted this: nested inline markup", () => {
    // Straight from a seeded backlog item — bold containing inline code.
    const out = html("**an agent needs no `.skip` to hold a clean `no_tamper` row.**");
    expect(out).toContain("<strong>");
    expect(out).not.toContain("**an agent");
  });
});

describe("markdown rendering does not break what was already there", () => {
  it("keeps @file mentions as clickable chips", () => {
    const out = html("look at @backlog/tamper-alarm.md and fix it");
    expect(out).toContain('class="ev-file-ref"');
    expect(out).toContain("@backlog/tamper-alarm.md");
  });

  it("renders BOTH a chip and markdown in the same prompt", () => {
    // The whole point of layering rather than replacing renderTaskText.
    const out = html("check @src/gate.ts for the **fuzzy** tier");
    expect(out).toContain('class="ev-file-ref"');
    expect(out).toContain("<strong>fuzzy</strong>");
  });

  it("still peels trailing punctuation off a mention", () => {
    const out = html("see @notes/e2e-gate-test-plan.md, then stop");
    expect(out).toContain("@notes/e2e-gate-test-plan.md");
    expect(out).not.toContain("@notes/e2e-gate-test-plan.md,");
  });

  it("renders markdown even when @file linking is unavailable", () => {
    // onOpenFile absent (a read-only transcript) used to return the raw string.
    expect(html("a **bold** claim", false)).toContain("<strong>bold</strong>");
  });
});

describe("code fences in a prompt are left alone inside", () => {
  it("renders a fence as a code block", () => {
    const out = html("before\n```ts\nconst a = 1\n```\nafter");
    expect(out).toContain('class="code-block"');
    expect(out).toContain("const a = 1");
  });

  it("does not turn an @decorator inside code into a file link", () => {
    // Pasted Python would otherwise sprout bogus file chips.
    const out = html("```py\n@dataclass\nclass X: pass\n```");
    expect(out).toContain("@dataclass");
    expect(out).not.toContain('class="ev-file-ref"');
  });

  it("does not treat ** inside code as bold", () => {
    const out = html("```py\nx = a ** b\n```");
    expect(out).toContain("a ** b");
    expect(out).not.toContain("<strong>");
  });
});
