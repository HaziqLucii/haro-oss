import type { AgentEvent } from "../types";

// Claude's standard context window; a resolved model tagged "[1m]" (the CLI echoes
// this in system:init when the 1M-token beta is active) gets the larger window.
const DEFAULT_WINDOW = 200_000;
const LONG_WINDOW = 1_000_000;

function fmt(n: number): string {
  if (n >= 1000) return `${(n / 1000).toFixed(n >= 10_000 ? 0 : 1)}k`;
  return String(n);
}

/**
 * A compact gauge beside the model/effort pickers: how full the model's context
 * window was at the end of the last run. Occupancy = the final assistant turn's
 * input + cache-read + cache-creation tokens (the adapter snapshots this into the
 * `done`/`error` event as `context_tokens`, with `context_cached` and the
 * authoritative `context_window` from `modelUsage`). The vertical bar fills
 * bottom-up in two shades — cached/reused tokens (solid) under fresh tokens this
 * turn (lighter) — with the empty track above standing for headroom.
 *
 * NOTE: this tracks context *fullness*, not cost. A session can cost a lot yet sit
 * at low occupancy (cost is cumulative across turns; occupancy is the current
 * snapshot). Per-run cost lives on the stream's `done` line, not here.
 */
export function ContextMeter({ events, model }: { events: AgentEvent[]; model?: string }) {
  let snap: { total: number; cached: number; window: number | null } | null = null;
  let confirmedModel: string | undefined;
  for (let i = events.length - 1; i >= 0; i--) {
    const e = events[i];
    if (!snap && (e.type === "done" || e.type === "error")) {
      const p = e.payload || {};
      // Prefer the true occupancy snapshot; fall back to raw in+out for old events.
      const total =
        p.context_tokens != null
          ? (p.context_tokens as number)
          : p.tokens_in != null
            ? (p.tokens_in || 0) + (p.tokens_out || 0)
            : null;
      if (total != null) {
        snap = {
          total,
          cached: (p.context_cached as number) || 0,
          window: (p.context_window as number) || null,
        };
      }
    }
    if (!confirmedModel && e.type === "token" && e.payload?.model) {
      confirmedModel = e.payload.model as string;
    }
    if (snap && confirmedModel) break;
  }
  if (!snap) return null; // nothing to track until a run has completed

  const window =
    snap.window || (/\[1m\]|1m/i.test(confirmedModel ?? model ?? "") ? LONG_WINDOW : DEFAULT_WINDOW);
  const used = snap.total;
  const cached = Math.min(snap.cached, used);
  const fresh = Math.max(0, used - cached);
  const pct = Math.min(100, (used / window) * 100);
  const cachedPct = Math.min(100, (cached / window) * 100);
  const freshPct = Math.min(100, (fresh / window) * 100);
  const pctLabel = pct > 0 && pct < 1 ? "<1" : String(Math.round(pct));

  return (
    <div
      className={"ctx-meter" + (pct >= 80 ? " ctx-meter-hot" : "")}
      title={
        `context: ${fmt(used)} / ${fmt(window)} tokens (${pct.toFixed(1)}% full)\n` +
        `${fmt(fresh)} fresh · ${fmt(cached)} cached · last completed run`
      }
    >
      <span className="ctx-bar" role="img" aria-label={`context ${pctLabel}% full`}>
        {/* column packs to the bottom: fresh on top (lighter), cached at base (solid) */}
        <span className="ctx-fill-fresh" style={{ height: `${freshPct}%` }} />
        <span className="ctx-fill-cached" style={{ height: `${cachedPct}%` }} />
      </span>
      <span className="ctx-pct">{pctLabel}%</span>
    </div>
  );
}