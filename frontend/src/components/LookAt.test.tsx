/** ③ Zone 3, rendered (notes/verify-redesign-plan.md; renamed from CodeToCheck.test.tsx).
 *
 * The honesty state machine itself (what counts as measured, clean, or unmeasured) is
 * pinned in verdict.test.ts (`codeToCheckCaveat`, `lookAt`) now that it's shared across
 * every look-at source, not just code-to-check. These tests cover what THIS component
 * decides on top of that: which rows tick, which don't, and that a caveat never gets
 * papered over by a positive claim.
 */
import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { LookAt } from "./LookAt";
import type { LookAtItem, LookAt as LookAtResult } from "../verdict";
import type { UncheckedRow } from "../types";

const noop = () => {};

const codeRow = (over: Partial<UncheckedRow> = {}): UncheckedRow => ({
  kind: "untested_lines",
  file: "src/a.ts",
  detail: "3 of 9 added lines never ran",
  count: 3,
  key: "untested_lines|src/a.ts|3",
  ...over,
});

const item = (over: Partial<LookAtItem> = {}): LookAtItem =>
  ({
    kind: "code_to_check",
    key: "k1",
    text: "no test ran: src/a.ts",
    raw: codeRow(),
    ...over,
  }) as LookAtItem;

const render = (props: Partial<Parameters<typeof LookAt>[0]> = {}) => {
  const result: LookAtResult = { pending: [], done: [], ...props.result };
  return renderToStaticMarkup(
    <LookAt
      result={result}
      caveat={null}
      past={false}
      onOpenFile={noop}
      onToggleChecked={noop}
      onSendToAgent={noop}
      {...props}
    />,
  );
};

describe("LookAt", () => {
  it("falls back to a plain empty line when there is nothing pending or done and no caveat", () => {
    const html = render();
    expect(html).toMatch(/nothing to look at/);
  });

  it("shows the caveat instead of the empty line, and never claims a positive result it can't back", () => {
    const html = render({ caveat: "the gate is red, so nothing has looked at the diff yet" });
    expect(html).toMatch(/the gate is red/);
    expect(html).not.toMatch(/every added line ran/);
    expect(html).not.toMatch(/nothing to look at/);
  });

  it("counts only rows still pending, and puts the plain sentence on the row", () => {
    const html = render({ result: { pending: [item()], done: [] } });
    expect(html).toMatch(/1 thing to look at/);
    expect(html).toMatch(/3 of 9 added lines never ran/);
  });

  it("ticks are offered only for code-to-check rows", () => {
    const tamper = item({
      kind: "tamper",
      key: "t1",
      text: "skip: adds numbers",
      raw: { kind: "skip", file: "a.ts", detail: "", test: "adds numbers" },
    });
    const html = render({ result: { pending: [item(), tamper], done: [] } });
    // One tickable row (code_to_check) and one non-tickable spacer (tamper).
    expect((html.match(/<button class="ctc-tick"/g) ?? []).length).toBe(1);
    expect((html.match(/ctc-tick-spacer/g) ?? []).length).toBe(1);
  });

  it("splits ticked rows into their own section without deleting them", () => {
    const html = render({ result: { pending: [], done: [item({ key: "d1" })] } });
    expect(html).toMatch(/all checked off by you/);
    expect(html).toMatch(/checked by you/);
    expect(html).not.toMatch(/send to agent/);
  });

  it("hides send-to-agent when nothing is pending", () => {
    const html = render({ result: { pending: [], done: [item({ key: "d1" })] } });
    expect(html).not.toMatch(/send to agent/);
  });

  it("shows send-to-agent when something is pending, and hides it entirely for a past run", () => {
    const withPending = render({ result: { pending: [item()], done: [] } });
    expect(withPending).toMatch(/send to agent/);
    const past = render({ result: { pending: [item()], done: [] }, past: true });
    expect(past).not.toMatch(/send to agent/);
  });

  it("withholds the tick for a code-to-check row too, once time-travelling a past run", () => {
    const html = render({ result: { pending: [item()], done: [] }, past: true });
    expect(html).toMatch(/ctc-tick-spacer/);
    expect(html).not.toMatch(/class="ctc-tick"/);
  });

  it("opens a file only for rows that carry one (a flaky test name has none)", () => {
    const flaky = item({ kind: "flaky", key: "f1", text: "adds numbers", raw: "adds numbers" });
    const html = render({ result: { pending: [flaky], done: [] } });
    expect(html).toMatch(/<button class="ctc-body" disabled=""/);
  });

  // "Send to backlog" (backlog/backlog-v2.md Move 3) — optional, mirrors send-to-agent.
  it("shows send-to-backlog only when the prop is given and something is pending", () => {
    const withProp = render({ result: { pending: [item()], done: [] }, onSendToBacklog: noop });
    expect(withProp).toMatch(/send to backlog/);
    const withoutProp = render({ result: { pending: [item()], done: [] } });
    expect(withoutProp).not.toMatch(/send to backlog/);
  });

  it("hides send-to-backlog for a past run even with the prop given", () => {
    const html = render({
      result: { pending: [item()], done: [] },
      past: true,
      onSendToBacklog: noop,
    });
    expect(html).not.toMatch(/send to backlog/);
  });
});
