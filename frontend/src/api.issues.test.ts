import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "./api";
import type { IssuesResponse } from "./types";

// The mine/all toggle and the Open/Closed/All tabs are real query params now
// (backlog/backlog-v2.md Move 1) — pinned so the request shape doesn't drift
// back into "@me" being silently forced.

const RESP: IssuesResponse = { available: true, issues: [] };

function stubFetch(body: unknown = RESP) {
  const fetchMock = vi.fn(async () => ({
    ok: true,
    status: 200,
    statusText: "ok",
    json: async () => body,
  })) as unknown as typeof fetch;
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock as unknown as ReturnType<typeof vi.fn>;
}

const call = (f: ReturnType<typeof vi.fn>, i = 0) => f.mock.calls[i] as [string];

afterEach(() => vi.unstubAllGlobals());

describe("api.getIssues", () => {
  it("omitting every option hits the plain endpoint (server's [backlog] defaults apply)", async () => {
    const f = stubFetch();
    await api.getIssues("p1");
    expect(call(f)[0]).toBe("/projects/p1/issues");
  });

  it("mine:true is a real query param, not a client-side filter", async () => {
    const f = stubFetch();
    await api.getIssues("p1", { mine: true });
    expect(call(f)[0]).toBe("/projects/p1/issues?mine=1");
  });

  it("state and mine combine, plus refresh for the ⟳ button", async () => {
    const f = stubFetch();
    await api.getIssues("p1", { refresh: true, state: "all", mine: true });
    const url = call(f)[0];
    expect(url).toContain("refresh=1");
    expect(url).toContain("state=all");
    expect(url).toContain("mine=1");
  });

  it("mine:false is sent explicitly (mine=0) — a real override of the project's config, not a client-side no-op", async () => {
    const f = stubFetch();
    await api.getIssues("p1", { state: "open", mine: false });
    expect(call(f)[0]).toBe("/projects/p1/issues?state=open&mine=0");
  });

  it("omitting the mine key entirely leaves the assignee to the project's own config default", async () => {
    const f = stubFetch();
    await api.getIssues("p1", { state: "open" });
    expect(call(f)[0]).toBe("/projects/p1/issues?state=open");
  });
});
