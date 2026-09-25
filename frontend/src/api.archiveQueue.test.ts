import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "./api";
import type { ArchiveQueueRun } from "./types";

// The request contract for bulk archive (backlog/bulk-archive.md). Worth pinning because
// the whole safety story rides on two query/body flags: `dry` (preview vs the point of no
// return) and `force` (skip the risky ones vs delete them). A wrong default here is not a
// cosmetic bug — it's an unasked-for `git branch -D`.

const RUN: ArchiveQueueRun = {
  id: "arq_1",
  project_id: "p1",
  dry: true,
  force: false,
  state: "planned",
  stop_requested: false,
  items: [],
  created_at: 0,
  finished_at: null,
};

function stubFetch(body: unknown = RUN, ok = true, status = 200) {
  const fetchMock = vi.fn(async () => ({
    ok,
    status,
    statusText: "err",
    json: async () => body,
  })) as unknown as typeof fetch;
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock as unknown as ReturnType<typeof vi.fn>;
}

const call = (f: ReturnType<typeof vi.fn>, i = 0) => f.mock.calls[i] as [string, RequestInit];

afterEach(() => vi.unstubAllGlobals());

describe("archiveQueue", () => {
  it("defaults to a LIVE run only when explicitly asked — dry is opt-in per call", async () => {
    const f = stubFetch();
    await api.archiveQueue("p1", ["a", "b"], { dry: true });
    const [url, init] = call(f);
    expect(url).toBe("/projects/p1/archive-queue?dry=true");
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual({ workspace_ids: ["a", "b"], force: false });
  });

  it("omitting the options is a live, unforced run", async () => {
    const f = stubFetch();
    await api.archiveQueue("p1", ["a"]);
    const [url, init] = call(f);
    expect(url).toBe("/projects/p1/archive-queue?dry=false");
    // force must never default to true — that's the flag that deletes unmerged work.
    expect(JSON.parse(String(init.body)).force).toBe(false);
  });

  it("sends force when the user ticked include-them-anyway", async () => {
    const f = stubFetch();
    await api.archiveQueue("p1", ["a"], { force: true });
    expect(JSON.parse(String(call(f)[1].body)).force).toBe(true);
  });

  it("surfaces a refusal as its FastAPI detail (the 409 second-queue guard)", async () => {
    stubFetch({ detail: "a bulk archive is already running for this project" }, false, 409);
    await expect(api.archiveQueue("p1", ["a"])).rejects.toThrow(/already running/);
  });
});

describe("getArchiveQueue / stopArchiveQueue", () => {
  it("reads the project's latest run (the reconnect after a reload)", async () => {
    const f = stubFetch();
    await api.getArchiveQueue("p1");
    expect(call(f)[0]).toBe("/projects/p1/archive-queue");
  });

  it("returns null when a project has never run one", async () => {
    stubFetch(null);
    await expect(api.getArchiveQueue("p1")).resolves.toBe(null);
  });

  it("stops by RUN id, not project id — a queue outlives the panel that started it", async () => {
    const f = stubFetch();
    await api.stopArchiveQueue("arq_1");
    const [url, init] = call(f);
    expect(url).toBe("/archive-queue/arq_1/stop");
    expect(init.method).toBe("POST");
  });
});
