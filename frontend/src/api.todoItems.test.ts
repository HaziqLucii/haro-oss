import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "./api";

// "Send to backlog" (backlog/backlog-v2.md Move 3) — pinned so the request always
// targets the fixed follow-ups file by default and never silently drops the title.

function stubFetch(body: unknown = { ok: true, path: "backlog/follow-ups.md" }) {
  const fetchMock = vi.fn(async () => ({
    ok: true,
    status: 200,
    statusText: "ok",
    json: async () => body,
  })) as unknown as typeof fetch;
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock as unknown as ReturnType<typeof vi.fn>;
}

const call = (f: ReturnType<typeof vi.fn>, i = 0) => f.mock.calls[i] as [string, RequestInit];

afterEach(() => vi.unstubAllGlobals());

describe("api.addTodoItem", () => {
  it("posts to /todo/items with the title, defaulting evidence to empty", async () => {
    const f = stubFetch();
    await api.addTodoItem("p1", "Untested hunk");
    const [url, init] = call(f);
    expect(url).toBe("/projects/p1/todo/items");
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual({ title: "Untested hunk", evidence: "" });
  });

  it("includes evidence when given", async () => {
    const f = stubFetch();
    await api.addTodoItem("p1", "Mutation survivor", "src/a.ts:12");
    expect(JSON.parse(String(call(f)[1].body))).toEqual({
      title: "Mutation survivor",
      evidence: "src/a.ts:12",
    });
  });

  it("only sends `file` when explicitly overridden — the server default is the fixed follow-ups doc", async () => {
    const f = stubFetch();
    await api.addTodoItem("p1", "x", "", "backlog/custom.md");
    expect(JSON.parse(String(call(f)[1].body))).toEqual({
      title: "x",
      evidence: "",
      file: "backlog/custom.md",
    });
  });
});
