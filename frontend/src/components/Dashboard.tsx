import { useEffect, useState } from "react";
import type { GateSummary, RaceRun, TrustSummary, Workspace } from "../types";
import { bulkBar, cardPick, togglePicked } from "../archiveQueue";
import { tamperCountSummary } from "../gate";
import { groupRaces } from "../races";
import { RaceScorecard } from "./RaceScorecard";
import { UsageStrip } from "./Usage";
import { Archive, X } from "./icons";

type Row = Workspace & { projectName: string };

// A card's `seed_key` names the backlog item that started it (backlog-v2.md
// Move 2 "the link goes both ways" — the backlog shows the workspace, the
// workspace shows the backlog item). "issue:<n>" → "#<n>"; a todo item's
// "<file>::<text>" → its text, since the file is already visible on hover.
export function sourceLabel(seedKey: string): string {
  if (seedKey.startsWith("issue:")) return "#" + seedKey.slice("issue:".length);
  const idx = seedKey.indexOf("::");
  return idx === -1 ? seedKey : seedKey.slice(idx + 2);
}

/** The autonomy-ladder rung a workspace sits on, read off its denormalized trust
 *  summary (backlog/autonomy-ladder.md). Returns null when the project isn't on the
 *  ladder (`enabled` false) or no gate has run yet — the meter stays hidden then. */
export function trustMeter(
  trust?: TrustSummary | null
): { streak: number; required: number; pct: number; label: string; cls: string } | null {
  if (!trust || !trust.enabled) return null;
  const required = Math.max(trust.streak_required, 1);
  const pct = Math.min(100, Math.round((trust.streak / required) * 100));
  // Rung label: the armed auto action is the top of the ladder; "ready" = every
  // condition met but no auto action armed; "locked" = conditions still unmet.
  let label = "locked";
  let cls = "s-fail";
  if (trust.armed) {
    label = "auto-PR";
    cls = "s-pass";
  } else if (trust.met) {
    label = "ready";
    cls = "s-pass";
  }
  return { streak: trust.streak, required: trust.streak_required, pct, label, cls };
}

/** One-line gate detail for a card, keyed off the workspace's authoritative status
 *  (so a coverage-blocked or couldn't-run red never reads as "passed"). */
export function gateLine(status: string, gate?: GateSummary | null): { text: string; cls: string } | null {
  if (status === "gate_green") return { text: `✓ ${gate?.total ?? 0} passed`, cls: "s-pass" };
  if (status === "gate_red") {
    if (gate?.status === "error") return { text: "gate couldn’t run", cls: "s-fail" };
    if (gate && gate.failed > 0)
      return { text: `✗ ${gate.failed} failing · ${gate.total} tests`, cls: "s-fail" };
    return { text: "gate blocked", cls: "s-fail" }; // e.g. coverage guard, no per-test fail
  }
  return null;
}

/** The `green*` marker for a card, read straight off the denormalized `GateSummary`
 *  (`tamper_count` + `tamper_note`) — so a suspicious green stars itself live off the
 *  coarse status feed, with no per-card fetch of the run's findings.
 *
 *  Only a **green** gate stars: `warn` mode is the case the dashboard would otherwise
 *  hide (tests passed, verdict green, suite quietly weakened). A tamper-*blocked* gate
 *  is already red — it lands in the attention banner on its own merit and reads
 *  "gate blocked", with the GatePanel chip explaining the downgrade in full. */
export function tamperStar(
  status: string,
  gate?: GateSummary | null
): { count: number; note: string } | null {
  const count = gate?.tamper_count ?? 0;
  if (status !== "gate_green" || count <= 0) return null;
  return { count, note: tamperCountSummary(count, gate?.tamper_note ?? null) };
}

/** Headline + hint for the attention banner, over the two things that can want you:
 *  red gates (nothing ships until they're green) and starred greens (`green*` — the
 *  tests passed but the suite changed suspiciously). Null when nothing needs you; the
 *  banner turns amber when it's stars only, since no gate is actually failing then. */
export function attentionSummary(
  reds: number,
  starred: number
): { title: string; hint: string; icon: string; cls: string } | null {
  const n = reds + starred;
  if (n === 0) return null;
  const hints: string[] = [];
  if (reds > 0) hints.push(`${reds} red · none can ship until green`);
  if (starred > 0) hints.push(`${starred} green* · tests pass, but the suite changed suspiciously`);
  return {
    title: `${n} gate${n === 1 ? "" : "s"} need${n === 1 ? "s" : ""} you`,
    hint: `· ${hints.join(" · ")}`,
    icon: reds > 0 ? "🔴" : "✳",
    cls: reds > 0 ? "s-fail" : "s-star",
  };
}

export const LABEL: Record<string, string> = {
  gate_green: "green",
  gate_red: "red",
  agent_running: "agent running",
  tests_running: "testing",
  setting_up: "setting up",
  idle: "idle",
  merged: "merged",
  broken: "needs repair",
};

// Triage order: things needing attention first, then active, then done, then idle.
// A `broken` workspace (desynced worktree) is top of the pile alongside gate_red.
export const RANK: Record<string, number> = {
  broken: 0,
  gate_red: 0,
  agent_running: 1,
  tests_running: 1,
  gate_green: 2,
  merged: 3,
  idle: 4,
};

/** Triage rank for a status (unknown statuses sort last). Exported for tests. */
export const rankOf = (status: string): number => RANK[status] ?? 4;

/** The multi-agent dashboard: every workspace at a glance, so you can fan out
 *  agents and see who's working, who's green, and who needs attention. */
export function Dashboard({
  workspaces,
  onSelect,
  onOpenUsage,
  races,
  onPurgeRaceLosers,
  onStopRace,
  purgingRace,
  onBulkArchive,
}: {
  workspaces: Row[];
  onSelect: (ws: Workspace) => void;
  onOpenUsage?: () => void;
  /** Winner-only fan-out (backlog/winner-fanout.md §1): a race's sibling lanes are
   *  lifted OUT of the grid into one scorecard card. Showing them as N loose cards
   *  would rebuild the review bottleneck the feature exists to remove. */
  races?: RaceRun[];
  onPurgeRaceLosers?: (raceId: string) => void;
  onStopRace?: (raceId: string) => void;
  purgingRace?: string | null;
  /** Bulk archive (backlog/bulk-archive.md). Given the picked ids, App asks the
   *  backend for a plan — the dashboard only ever collects the selection. */
  onBulkArchive?: (projectId: string, workspaceIds: string[]) => void;
}) {
  // Select mode is opt-in: a click on a card normally *opens* it, and turning that
  // into "tick a box for a destructive batch" by default is how you archive by
  // accident. Leaving the mode clears the picks.
  const [picking, setPicking] = useState(false);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  useEffect(() => {
    if (!picking) setPicked(new Set());
  }, [picking]);

  if (workspaces.length === 0) {
    return (
      <div className="empty-state">
        <div className="empty-inner">
          <div className="empty-title">No workspaces yet</div>
          <div className="dim">Register a repo in the sidebar, then create a workspace to start an agent.</div>
        </div>
      </div>
    );
  }

  // Lift race lanes out of the flat grid first. Everything below — the counts, the
  // attention banner, the card grid — then works on `loose` only: a race owns its
  // lanes' triage (that's what the scorecard IS), so surfacing three red lanes in the
  // "gates need you" banner would be the pile of N results this feature removes.
  const { cards: raceCards, loose } = groupRaces(workspaces, races ?? []);
  const rows = [...loose].sort(
    (a, b) => rankOf(a.status) - rankOf(b.status) || a.name.localeCompare(b.name)
  );
  const count = (s: string) => loose.filter((w) => w.status === s).length;
  const running = count("agent_running") + count("tests_running");
  // First-class gate triage: the red gates, ranked first already, surfaced as a
  // banner so "which gates need me" is answerable at a glance across all agents.
  // A `green*` (green verdict, tamper findings recorded — warn mode) joins them: it
  // ships unless you look, which is exactly why it belongs in the banner. Reds keep
  // their place at the front, since `rows` is already triage-ranked.
  const redGates = rows.filter((w) => w.status === "gate_red");
  const starredGreens = rows.filter((w) => tamperStar(w.status, w.gate));
  const attention = [...redGates, ...starredGreens];
  const attn = attentionSummary(redGates.length, starredGreens.length);
  // Plain greens exclude the starred ones — a `green*` is counted once, as a star.
  const plainGreens = count("gate_green") - starredGreens.length;
  // Every select-mode decision (which project a selection belongs to, what each button
  // may do, which ids an archive targets) is computed by the pure helper, not inline —
  // it decides what a destructive button aims at. See `archiveQueue.bulkBar`.
  const bar = bulkBar(rows, picked);

  return (
    <div className="dash">
      <div className="dash-head">
        <span className="dash-title rule-title">workspaces</span>
        <span className="dash-counts dim">
          {running > 0 && <span className="s-run">{running} active</span>}
          {count("broken") > 0 && <span className="s-fail">{count("broken")} broken</span>}
          {count("gate_red") > 0 && <span className="s-fail">{count("gate_red")} need attention</span>}
          {plainGreens > 0 && <span className="s-pass">{plainGreens} green</span>}
          {starredGreens.length > 0 && (
            <span className="s-star" title="green*: the tests passed, but the tamper alarm flagged the suite">
              {starredGreens.length} green*
            </span>
          )}
          {raceCards.length > 0 && (
            <span title="winner-only fan-out: each race's lanes are grouped into one scorecard">
              {raceCards.length} race{raceCards.length === 1 ? "" : "s"}
            </span>
          )}
          <span>{workspaces.length} total</span>
        </span>
        {onBulkArchive && rows.length > 1 && (
          <button
            className={"ghost dash-pick-toggle" + (picking ? " dash-pick-on" : "")}
            onClick={() => setPicking((v) => !v)}
            title="Pick several workspaces and archive them through the queue"
          >
            {picking ? <X /> : <Archive />}
            {picking ? "cancel" : "select"}
          </button>
        )}
        <UsageStrip onOpen={onOpenUsage} />
      </div>

      {/* Everything below the "workspaces" label scrolls on its own, so the
          label (and its counts/select toggle) stays put when there are more
          workspaces than fit — the label used to scroll away with the grid,
          which read as the whole page scrolling rather than just the list. */}
      <div className="dash-body">
        {picking && (
          <BulkSelectBar
            bar={bar}
            onSelectAll={() => setPicked(new Set(bar.projectIds))}
            onClear={() => setPicked(new Set())}
            onArchive={() => {
              if (!bar.pickedProject) return;
              // App turns this into a backend *plan* first — the confirm dialog is a
              // dry run, so nothing here is the point of no return.
              onBulkArchive?.(bar.pickedProject, bar.pickedIds);
              setPicking(false);
            }}
          />
        )}

        {/* Races first: a decided race is a single diff waiting for review, which is a
            more actionable thing than any individual card below it. */}
        {raceCards.map(({ race, lanes }) => (
          <RaceScorecard
            key={race.id}
            race={race}
            onOpenWorkspace={(wsId) => {
              const ws = lanes.find((w) => w.id === wsId);
              if (ws) onSelect(ws);
            }}
            onPurgeLosers={onPurgeRaceLosers ? () => onPurgeRaceLosers(race.id) : undefined}
            onStop={onStopRace ? () => onStopRace(race.id) : undefined}
            purging={purgingRace === race.id}
          />
        ))}

        {attn && (
          <div className={"dash-attention" + (redGates.length === 0 ? " dash-attention-star" : "")}>
            <span className={"dash-attention-title " + attn.cls}>
              {attn.icon} {attn.title}
            </span>
            <span className="dash-attention-hint dim">{attn.hint}</span>
            <div className="dash-attention-chips">
              {attention.map((w) => {
                const star = tamperStar(w.status, w.gate);
                // A starred green's detail is the tamper reason, not its test count — the
                // count is why it looks fine; the reason is why it's in this banner.
                const detail = star ? star.note : gateLine(w.status, w.gate)?.text;
                return (
                  <button
                    key={w.id}
                    className={"dash-attention-chip" + (star ? " dash-attention-chip-star" : "")}
                    onClick={() => onSelect(w)}
                    title={`${w.projectName} · ${w.branch}`}
                  >
                    <span className={"ws-dot ws-dot-" + w.status} />
                    {w.name}
                    {star && <span className="dash-star">*</span>}
                    {detail && <span className="dash-attention-chip-detail dim">{detail}</span>}
                  </button>
                );
              })}
            </div>
          </div>
        )}
        <div className="dash-grid">
          {rows.map((w) => (
            <WorkspaceCard
              key={w.id}
              w={w}
              picking={picking}
              pick={cardPick(w, { picking, picked, pickedProject: bar.pickedProject })}
              onClick={() => (picking ? setPicked((prev) => togglePicked(prev, w.id)) : onSelect(w))}
            />
          ))}
        </div>
      </div>
    </div>
  );
}

/** The bulk-archive selection bar (backlog/bulk-archive.md). Presentational: every
 *  legality question was already answered by `archiveQueue.bulkBar`, so this renders a
 *  decision rather than making one — which is what makes it testable on its own. */
export function BulkSelectBar({
  bar,
  onSelectAll,
  onClear,
  onArchive,
}: {
  bar: ReturnType<typeof bulkBar>;
  onSelectAll: () => void;
  onClear: () => void;
  onArchive: () => void;
}) {
  return (
    <div className="dash-pickbar">
      <span className="dash-pickbar-count">
        {bar.count} selected
        {bar.mixed && <span className="dim"> · one project at a time</span>}
      </span>
      <button className="ghost" disabled={!bar.canSelectAll} onClick={onSelectAll}>
        select all in project
      </button>
      <button className="ghost" disabled={!bar.count} onClick={onClear}>
        clear
      </button>
      <button className="danger" disabled={!bar.canArchive} onClick={onArchive}>
        <Archive /> archive {bar.count || ""}
      </button>
    </div>
  );
}

/** One triage card. Extracted from the grid so the select-mode states (ticked, locked)
 *  can be rendered and asserted directly — inside the map they were only reachable by
 *  clicking, which this suite (static render, no jsdom) can't do. */
export function WorkspaceCard({
  w,
  picking,
  pick,
  onClick,
}: {
  w: Row;
  picking: boolean;
  pick: ReturnType<typeof cardPick>;
  onClick: () => void;
}) {
  const line = gateLine(w.status, w.gate);
  const star = tamperStar(w.status, w.gate);
  const t = trustMeter(w.trust);
  return (
    <button
      // In select mode a card is a checkbox, not a link: clicking it picks it, and a
      // card from another project is locked out (a queue drains one repo).
      className={"dash-card dash-" + w.status + (star ? " dash-card-star" : "") + pick.className}
      disabled={pick.locked}
      aria-pressed={picking ? pick.isPicked : undefined}
      onClick={onClick}
    >
      <div className="dash-card-top">
        {picking && <span className={"dash-tick" + (pick.isPicked ? " dash-tick-on" : "")} />}
        <span className={"ws-dot ws-dot-" + w.status} />
        <span className="dash-name">{w.name}</span>
        {w.kind === "adopted" && (
          <span
            className="dash-adopted"
            title={`Adopted foreign worktree${w.source ? ` (${w.source})` : ""} · agentless, gated in place`}
          >
            adopted{w.source ? ` · ${w.source}` : ""}
          </span>
        )}
      </div>
      <div className="dash-project dim">{w.projectName}</div>
      <div className="dash-status">
        {/* The verdict word itself carries the star, so the card says exactly what
            the gate panel says: `green*`, one language across both surfaces. */}
        {LABEL[w.status] ?? w.status}
        {star && (
          <span
            className="dash-star"
            title={`green* · the tests passed, but the tamper alarm flagged the suite: ${star.note}`}
          >
            *
          </span>
        )}
        {line && <span className={"dash-gate " + line.cls}>{line.text}</span>}
      </div>
      {star && (
        <div className="dash-tamper s-star" title={`green* · ${star.note}`}>
          {star.note}
        </div>
      )}
      {t && (
        <div className="dash-trust" title={`autonomy ladder: ${t.streak}/${t.required} clean greens · ${t.label}`}>
          <div className="dash-trust-bar">
            <div className={"dash-trust-fill " + t.cls} style={{ width: `${t.pct}%` }} />
          </div>
          <span className="dash-trust-meta dim">
            <span className="dash-trust-streak">
              {t.streak}/{t.required}
            </span>
            <span className={"dash-trust-rung " + t.cls}>{t.label}</span>
          </span>
        </div>
      )}
      <div className="dash-branch dim">{w.branch}</div>
      {w.seed_key && (
        <div className="dash-source dim" title={w.seed_key}>
          {sourceLabel(w.seed_key)}
        </div>
      )}
    </button>
  );
}
