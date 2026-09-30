// Pure helpers for winner-only fan-out (backlog/winner-fanout.md).
//
// Kept UI-free so the two things most likely to go quietly wrong are unit-testable:
// the **grouping** (N sibling workspaces must collapse into ONE dashboard card, or the
// feature literally shows you three diffs — the exact pain it exists to remove) and the
// **headline** (a race with no winner must never read as if it had one).
import { formatCost } from "./formatCost";
import type { RacePreflight, RaceRun, Workspace } from "./types";

/** One dashboard card: a race plus whichever of its lane workspaces still exist.
 *  Generic over the workspace row so the dashboards can keep their own decorations
 *  (`projectName`, …) through the grouping. */
export interface RaceCard<T extends Workspace = Workspace> {
  race: RaceRun;
  lanes: T[];
}

/**
 * Collapse race siblings into cards, leaving every ordinary workspace alone.
 *
 * The join is `Workspace.race_id` → `RaceRun.id`, so a lane whose race the client
 * hasn't loaded yet falls back to being a normal card rather than vanishing. Losing a
 * workspace to a "grouped under a card that isn't rendered" hole would be worse than a
 * duplicate row, so the fallback deliberately errs toward showing it.
 *
 * Card order follows each race's newest lane, so a running race sorts beside the
 * workspaces it spawned instead of jumping to the bottom of the list.
 */
export function groupRaces<T extends Workspace>(
  workspaces: T[],
  races: RaceRun[],
): { cards: RaceCard<T>[]; loose: T[] } {
  const byId = new Map(races.map((r) => [r.id, r]));
  const lanes = new Map<string, T[]>();
  const loose: T[] = [];
  for (const ws of workspaces) {
    const race = ws.race_id ? byId.get(ws.race_id) : undefined;
    if (!race) {
      loose.push(ws);
      continue;
    }
    const bucket = lanes.get(race.id);
    if (bucket) bucket.push(ws);
    else lanes.set(race.id, [ws]);
  }
  const cards: RaceCard<T>[] = [];
  for (const [raceId, group] of lanes) {
    const race = byId.get(raceId);
    if (race) cards.push({ race, lanes: group });
  }
  return { cards, loose };
}

/** The winner's lane workspace, when the judge named one and it still exists. */
export function winnerLane<T extends Workspace>(race: RaceRun, lanes: T[]): T | null {
  return lanes.find((w) => w.id === race.winner_id) ?? null;
}

/** "2 of 3 lanes settled" — the running card's progress line. */
export function raceProgress(race: RaceRun): string {
  const done = race.lanes.filter((l) => l.status !== "pending" && l.status !== "running").length;
  return `${done} of ${race.lanes.length} lane${race.lanes.length === 1 ? "" : "s"} settled`;
}

/**
 * The card's one-line verdict. Four distinct shapes on purpose — a tie and a refusal
 * must never be phrased so they can be mistaken for a win, because the whole promise
 * ("you review exactly one candidate") is false in both cases and the human needs to
 * know that before they start reading.
 */
export function raceHeadline(race: RaceRun): { tone: "running" | "won" | "tie" | "none"; text: string } {
  if (race.status === "running") return { tone: "running", text: raceProgress(race) };
  if (race.refused) return { tone: "none", text: race.refused };
  if (race.tie.length) return { tone: "tie", text: race.reason || "all lanes green — you tie-break" };
  if (race.winner_id) {
    const won = race.lanes.find((l) => l.workspace_id === race.winner_id);
    const who = won ? `${won.model}${won.effort ? `-${won.effort}` : ""}` : "a lane";
    return { tone: "won", text: `${who} won — ${race.reason}` };
  }
  return { tone: "none", text: race.reason || "no lane produced a rankable green" };
}

/** "$1.20 of $6.00" — spend against the ceiling that would have stopped it. */
export function raceSpend(race: RaceRun): string {
  return `${formatCost(race.spent_usd)} of ${formatCost(race.max_total_usd)}`;
}

/** Total spend across a set of races — the "what did fan-out actually cost me" line. */
export function totalRaceSpend(races: RaceRun[]): number {
  return races.reduce((sum, r) => sum + (r.spent_usd || 0), 0);
}

/**
 * Whether the composer's "race" button is usable, and the tooltip explaining it.
 *
 * The refusals are surfaced verbatim rather than summarized: they're written to be
 * actionable ("set `[agent] max_budget_usd` above 0"), and a paraphrase would cost the
 * user the one thing that tells them how to fix it. `null` preflight = not fetched yet,
 * which reads as disabled — optimistically enabling would let a click spend money the
 * §0 gate was about to refuse.
 */
export function raceButtonState(
  pf: RacePreflight | null,
  lanes = 0,
): { disabled: boolean; label: string; title: string } {
  const n = pf?.lanes.length || lanes || 3;
  const label = `race ×${n}`;
  if (!pf) return { disabled: true, label, title: "checking whether this project can race…" };
  if (!pf.ok) {
    return { disabled: true, label, title: `can't race: ${pf.refusals.join(" · ")}` };
  }
  const grid = pf.lanes.map((l) => (l.effort ? `${l.model}-${l.effort}` : l.model)).join(" vs ");
  const note = pf.notes.length ? `\n\nnote: ${pf.notes.join(" · ")}` : "";
  return {
    disabled: false,
    label,
    title:
      `Race this task across ${n} lanes (${grid}) and let the gate pick the winner ` +
      `by ${pf.policy.replace(/_/g, " ")}. You review one diff plus a scorecard.\n` +
      `Ceiling: ${formatCost(pf.max_total_usd)} total — lanes are stopped if the race crosses it.${note}`,
  };
}
