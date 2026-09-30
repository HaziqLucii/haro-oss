import { describe, expect, it } from "vitest";
import {
  groupRaces,
  raceButtonState,
  raceHeadline,
  raceProgress,
  raceSpend,
  winnerLane,
} from "./races";
import type { RaceLane, RacePreflight, RaceRun, Workspace } from "./types";

function ws(id: string, raceId?: string): Workspace {
  return {
    id,
    project_id: "p1",
    name: id,
    branch: `haro/${id}`,
    worktree_path: `/tmp/${id}`,
    base_ref: "main",
    port: null,
    status: "idle",
    kind: "managed",
    race_id: raceId ?? null,
  };
}

function lane(id: string, over: Partial<RaceLane> = {}): RaceLane {
  return {
    workspace_id: id,
    name: id,
    branch: `haro/${id}`,
    model: "sonnet",
    effort: "low",
    role: "",
    status: "green",
    green: true,
    cost_usd: 1,
    wall_ms: 1000,
    coverage_delta: 0,
    merge_conflict: false,
    flaky: [],
    degraded: false,
    tamper_count: 0,
    impacted_count: 9,
    diff_lines: 10,
    archived: false,
    note: null,
    finished_at: 100,
    ...over,
  };
}

function race(over: Partial<RaceRun> = {}): RaceRun {
  return {
    id: "race_1",
    project_id: "p1",
    task: "do the thing",
    policy: "cheapest_green",
    status: "judged",
    lanes: [lane("a"), lane("b")],
    winner_id: "a",
    tie: [],
    refused: null,
    reason: "cheapest green ($1.00)",
    verdict: null,
    max_total_usd: 6,
    spent_usd: 2.5,
    losers_archived: true,
    losers_purged: false,
    created_at: 0,
    ended_at: 1,
    ...over,
  };
}

describe("groupRaces", () => {
  it("collapses sibling lanes into ONE card", () => {
    // The whole feature in one assertion: three lanes must not become three cards,
    // or fan-out shows you N diffs — the exact pain it exists to remove.
    const { cards, loose } = groupRaces(
      [ws("a", "race_1"), ws("b", "race_1"), ws("c", "race_1")],
      [race({ lanes: [lane("a"), lane("b"), lane("c")] })],
    );
    expect(cards).toHaveLength(1);
    expect(cards[0].lanes.map((w) => w.id)).toEqual(["a", "b", "c"]);
    expect(loose).toEqual([]);
  });

  it("leaves ordinary workspaces alone", () => {
    const { cards, loose } = groupRaces([ws("solo"), ws("a", "race_1")], [race()]);
    expect(loose.map((w) => w.id)).toEqual(["solo"]);
    expect(cards[0].lanes.map((w) => w.id)).toEqual(["a"]);
  });

  it("shows a lane whose race isn't loaded rather than hiding it", () => {
    // Erring toward a duplicate-looking row beats a workspace that silently vanishes
    // into a card nobody rendered.
    const { cards, loose } = groupRaces([ws("orphan", "race_gone")], []);
    expect(cards).toEqual([]);
    expect(loose.map((w) => w.id)).toEqual(["orphan"]);
  });

  it("keeps a card for a race whose lane workspaces were purged", () => {
    const { cards } = groupRaces([ws("a", "race_1")], [race()]);
    expect(cards[0].lanes).toHaveLength(1); // b was purged; the scorecard row survives
  });
});

describe("raceHeadline", () => {
  it("names the winning lane and why it won", () => {
    const h = raceHeadline(race());
    expect(h.tone).toBe("won");
    expect(h.text).toContain("sonnet-low won");
    expect(h.text).toContain("cheapest green");
  });

  it("never phrases a tie as a win", () => {
    const h = raceHeadline(race({ winner_id: null, tie: ["a", "b"], reason: "can't separate the top two" }));
    expect(h.tone).toBe("tie");
    expect(h.text).not.toContain("won");
  });

  it("surfaces a refusal verbatim", () => {
    const h = raceHeadline(race({ winner_id: null, refused: "not auto-judging: a (1) …" }));
    expect(h.tone).toBe("none");
    expect(h.text).toContain("not auto-judging");
  });

  it("shows progress while the race is still running", () => {
    const h = raceHeadline(
      race({ status: "running", lanes: [lane("a"), lane("b", { status: "running", green: false })] }),
    );
    expect(h.tone).toBe("running");
    expect(h.text).toBe("1 of 2 lanes settled");
  });

  it("says plainly when nothing was rankable", () => {
    const h = raceHeadline(
      race({ winner_id: null, reason: "", lanes: [lane("a", { green: false, status: "red" })] }),
    );
    expect(h.tone).toBe("none");
    expect(h.text).toContain("no lane produced a rankable green");
  });
});

describe("raceProgress + raceSpend", () => {
  it("counts settled lanes, not started ones", () => {
    expect(
      raceProgress(race({ lanes: [lane("a"), lane("b", { status: "pending" }), lane("c", { status: "stopped" })] })),
    ).toBe("2 of 3 lanes settled");
  });

  it("shows spend against the ceiling that would have stopped it", () => {
    expect(raceSpend(race())).toBe("$2.50 of $6.00");
  });
});

describe("winnerLane", () => {
  it("resolves the winner's workspace", () => {
    expect(winnerLane(race(), [ws("a", "race_1"), ws("b", "race_1")])?.id).toBe("a");
  });
  it("returns null when there is no winner", () => {
    expect(winnerLane(race({ winner_id: null }), [ws("a", "race_1")])).toBeNull();
  });
});

describe("raceButtonState", () => {
  const ok: RacePreflight = {
    ok: true,
    refusals: [],
    notes: [],
    max_total_usd: 6,
    lanes: [
      { model: "sonnet", effort: "low" },
      { model: "sonnet", effort: "high" },
      { model: "opus", effort: "" },
    ],
    policy: "cheapest_green",
    suite_tests: 80,
  };

  it("labels the button with the lane count and explains the ceiling", () => {
    const s = raceButtonState(ok);
    expect(s.disabled).toBe(false);
    expect(s.label).toBe("race ×3");
    expect(s.title).toContain("sonnet-low vs sonnet-high vs opus");
    expect(s.title).toContain("$6.00");
  });

  it("passes a refusal through verbatim so it stays actionable", () => {
    const s = raceButtonState({
      ...ok,
      ok: false,
      refusals: ["never race uncapped: set `[agent] max_budget_usd` above 0 before racing"],
    });
    expect(s.disabled).toBe(true);
    expect(s.title).toContain("max_budget_usd");
  });

  it("stays disabled until the preflight has actually answered", () => {
    // Optimistically enabling would let a click spend money §0 was about to refuse.
    expect(raceButtonState(null).disabled).toBe(true);
  });
});
