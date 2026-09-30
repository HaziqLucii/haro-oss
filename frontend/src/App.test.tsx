import { afterEach, describe, expect, it, vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";

// A composition smoke test for the app root, added with bulk archive
// (backlog/bulk-archive.md). Deliberately modest about what it proves:
//
// This suite has no jsdom, so effects never run and nothing can be clicked — the WS
// feed handler and the panel's open state are out of reach here. What IS reachable is
// everything App does on a render pass: build the bulk-archive action set, hand
// `onBulkArchive` to both dashboards, and keep the archive panel closed until there's a
// run. Those are exactly the wiring mistakes (a missing import, a prop typo, an action
// factory called with the wrong deps) that unit tests of the helpers cannot catch.
//
// The DECISIONS behind that wiring live in `archiveQueue.ts` (feed + select mode) and
// `archiveActions.ts` (the plan → confirm → drain sequence), both covered directly.

// App reads these at render time (theme prefs, notification prefs). Effects don't run
// under SSR, so no socket is opened and no fetch is issued — the stubs just have to
// exist. If App grows a new render-time global, this fails loudly and obviously.
function stubBrowser() {
  vi.stubGlobal("localStorage", {
    getItem: () => null,
    setItem: () => {},
    removeItem: () => {},
  });
  vi.stubGlobal("matchMedia", () => ({
    matches: false,
    addEventListener: () => {},
    removeEventListener: () => {},
  }));
  vi.stubGlobal("WebSocket", class {
    close() {}
  } as never);
  vi.stubGlobal("fetch", () => Promise.reject(new Error("no network in this test")));
}

afterEach(() => vi.unstubAllGlobals());

async function render() {
  stubBrowser();
  const { App } = await import("./App");
  return renderToStaticMarkup(<App />);
}

describe("App — bulk-archive wiring", () => {
  it("mounts with the bulk-archive action set built", async () => {
    // `bulkArchiveActions(...)` runs on every render pass, so a broken dependency
    // object (or a missing ref) throws right here rather than on first click.
    await expect(render()).resolves.toBeTruthy();
  });

  it("keeps the archive panel closed until there is a run", async () => {
    const html = await render();
    expect(html).not.toContain("Bulk archive");
    expect(html).not.toContain("modal arq");
  });

  it("renders the dashboard route it hands onBulkArchive to", async () => {
    const html = await render();
    // No projects have loaded (effects don't run), so it's the global dashboard's
    // empty state — which is still the branch that constructs the Dashboard element
    // with its bulk-archive prop.
    expect(html).toContain("No workspaces yet");
  });
});

describe("App — verify redesign (notes/verify-redesign-plan.md)", () => {
  it("the look-at chip never leaks into the global dashboard route", async () => {
    // The chip only belongs to a selected workspace's rail; no workspace is ever
    // selected here (no projects loaded), so it must not appear on this route at all.
    const html = await render();
    expect(html).not.toContain("look-at-chip");
  });
});
