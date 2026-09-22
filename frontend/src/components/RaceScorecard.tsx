import { formatCost } from "../formatCost";
import { raceHeadline, raceProgress, raceSpend } from "../races";
import type { RaceCriterion, RaceLaneScore, RaceRun } from "../types";

/**
 * The winner ceremony (backlog/winner-fanout.md §3).
 *
 * This panel is the entire argument for winner-only fan-out. Every rival racer ends by
 * handing you N diffs, which *multiplies* the review bottleneck; haro ends by handing
 * you one candidate and a receipt. So the design rules here are unusually strict:
 *
 * * **The winner is the only thing you're asked to review.** It gets the card; the
 *   losers get one compact row each.
 * * **But the losers are never hidden.** Their rows carry the same five criteria — a
 *   scorecard whose losing rows are censored can't be second-guessed, and a judge you
 *   can't second-guess is just another opinion.
 * * **A tie and a refusal look nothing like a win.** Both mean "you still have to
 *   compare", so they render as their own headline states rather than a winner card
 *   with a caveat underneath.
 */
export function RaceScorecard({
  race,
  onOpenWorkspace,
  onPurgeLosers,
  onStop,
  purging,
  compact,
}: {
  race: RaceRun;
  onOpenWorkspace?: (wsId: string) => void;
  onPurgeLosers?: () => void;
  onStop?: () => void;
  purging?: boolean;
  compact?: boolean;
}) {
  const head = raceHeadline(race);
  const scored = race.verdict?.lanes ?? [];
  // Fall back to the lane cache when the judge hasn't run yet (a live race), so the
  // card is populated from the first lane onward instead of sitting empty.
  const rows: RaceLaneScore[] = scored.length
    ? scored
    : race.lanes.map((l) => ({
        workspace_id: l.workspace_id,
        name: l.name,
        model: l.model,
        effort: l.effort,
        role: l.role,
        status: l.status,
        rank: null,
        eligible: l.green,
        disqualified: null,
        criteria: [],
      }));
  const winner = rows.find((r) => r.workspace_id === race.winner_id) ?? null;
  const others = rows.filter((r) => r.workspace_id !== race.winner_id);
  const tied = new Set(race.tie);

  return (
    <div className={"race-card race-card-" + head.tone}>
      <div className="race-head">
        <span className="race-badge">race ×{race.lanes.length}</span>
        <span className="race-task" title={race.task}>
          {race.task.split("\n")[0] || "untitled race"}
        </span>
        <span className="race-spacer" />
        <span className="race-spend dim" title="what the lanes spent, against the ceiling that would have stopped them">
          {raceSpend(race)}
        </span>
        {race.status === "running" && onStop && (
          <button className="danger race-stop" onClick={onStop}>
            stop
          </button>
        )}
      </div>

      <div className={"race-headline race-headline-" + head.tone}>
        <span className="race-headline-glyph" aria-hidden="true">
          {head.tone === "won" ? "●" : head.tone === "running" ? "◐" : head.tone === "tie" ? "=" : "○"}
        </span>
        <span>{head.text}</span>
      </div>

      {/* The one thing you're asked to review. */}
      {winner && (
        <button
          className="race-winner"
          onClick={() => onOpenWorkspace?.(winner.workspace_id)}
          title="open the winning workspace — this is the ONE diff you review"
        >
          <span className="race-winner-tag">winner</span>
          <span className="race-winner-name">{winner.name}</span>
          <span className="race-winner-model dim">{laneLabel(winner)}</span>
          <span className="race-spacer" />
          <span className="race-winner-open">review →</span>
        </button>
      )}

      {/* Every lane, winner included, with its criteria. The losers are compact but
          never censored: this row set is what lets a human overrule the judge. */}
      {!compact && (
        <div className="race-lanes">
          {rows.map((r) => (
            <LaneRow
              key={r.workspace_id}
              lane={r}
              isWinner={r.workspace_id === race.winner_id}
              isTied={tied.has(r.workspace_id)}
              note={race.lanes.find((l) => l.workspace_id === r.workspace_id)?.note ?? null}
              archived={race.lanes.find((l) => l.workspace_id === r.workspace_id)?.archived ?? false}
              onOpen={onOpenWorkspace}
            />
          ))}
        </div>
      )}

      {compact && others.length > 0 && (
        <div className="race-compact dim">
          {others.length} other lane{others.length === 1 ? "" : "s"} archived — open the race for the scorecard
        </div>
      )}

      {race.status === "running" && <div className="race-progress dim">{raceProgress(race)}</div>}

      {/* Purging is the irreversible half of the loser afterlife: soft-archiving kept
          their branches so you could still diff them, this deletes those branches. It's
          a deliberate act after reading the scorecard, never part of the ceremony. */}
      {!compact && race.losers_archived && !race.losers_purged && onPurgeLosers && (
        <div className="race-actions">
          <button className="race-purge" onClick={onPurgeLosers} disabled={purging}
            title="Delete the losing lanes' branches and rows. Until you do this, every loser's diff is still there to second-guess the judge with.">
            {purging ? "purging…" : "purge losers"}
          </button>
          <span className="dim race-actions-note">
            loser branches are kept until you do — their diffs stay reviewable
          </span>
        </div>
      )}
      {race.losers_purged && <div className="dim race-actions-note">losers purged</div>}
    </div>
  );
}

const ROLE_LABEL: Record<string, string> = { tests_only: "tests", impl_only: "impl" };

/** "sonnet-high" — or "sonnet-high (tests)"/"(impl)" on a split_authors lane, where
 *  both lanes otherwise share the identical model/effort and would be indistinguishable
 *  (refuter round-3 caught this: nothing told a human which lane held the tests). */
function laneLabel(l: { model: string; effort: string; role?: string }): string {
  const base = l.effort ? `${l.model}-${l.effort}` : l.model || "—";
  const role = l.role ? ROLE_LABEL[l.role] : null;
  return role ? `${base} (${role})` : base;
}

function LaneRow({
  lane,
  isWinner,
  isTied,
  note,
  archived,
  onOpen,
}: {
  lane: RaceLaneScore;
  isWinner: boolean;
  isTied: boolean;
  note: string | null;
  archived: boolean;
  onOpen?: (wsId: string) => void;
}) {
  const cls = [
    "race-lane",
    isWinner ? "race-lane-win" : "",
    isTied ? "race-lane-tie" : "",
    !lane.eligible ? "race-lane-out" : "",
  ]
    .filter(Boolean)
    .join(" ");
  return (
    <div className={cls}>
      <button
        className="race-lane-name"
        onClick={() => onOpen?.(lane.workspace_id)}
        title={archived ? "archived: the worktree is gone, but the branch + transcript are kept" : "open this lane"}
      >
        {lane.rank ? <span className="race-rank">#{lane.rank}</span> : null}
        <span>{laneLabel(lane)}</span>
        {archived && <span className="race-lane-archived dim">archived</span>}
      </button>
      <div className="race-crit">
        {lane.criteria.map((c) => (
          <Cell key={c.key} c={c} />
        ))}
        {lane.criteria.length === 0 && <span className="dim">{lane.status}</span>}
      </div>
      {/* Why this lane can't win, in words. The disqualifiers are facts the gate
          recorded (flaky green, degraded run, red gate) — never the judge's opinion. */}
      {lane.disqualified && <div className="race-lane-out-why dim">{lane.disqualified}</div>}
      {note && <div className="race-lane-note dim">{note}</div>}
    </div>
  );
}

function Cell({ c }: { c: RaceCriterion }) {
  const cls = [
    "race-cell",
    c.won ? "race-cell-won" : "race-cell-lost",
    c.decisive ? "race-cell-decisive" : "",
  ]
    .filter(Boolean)
    .join(" ");
  return (
    <span
      className={cls}
      title={c.decisive ? `${c.label} — the criterion this race was decided on` : c.label}
    >
      <span className="race-cell-label dim">{c.label}</span>
      <span className="race-cell-value">{c.value}</span>
    </span>
  );
}

/** The dashboard's one-line race chip, for surfaces with no room for the full card. */
export function RaceChip({ race }: { race: RaceRun }) {
  const head = raceHeadline(race);
  return (
    <span className={"race-chip race-chip-" + head.tone} title={head.text}>
      race ×{race.lanes.length} · {formatCost(race.spent_usd)}
    </span>
  );
}
