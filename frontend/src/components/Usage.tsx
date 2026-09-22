import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../api";
import { Gauge, Refresh } from "./icons";
import type { UsageLimit, UsageResponse } from "../types";

/** Poll cadence for the live usage feed. The backend caches for 60s, so polling
 *  faster just returns the same snapshot — match it. */
const POLL_MS = 60_000;

/** Fetch + poll GET /usage while `active`. Returns the latest snapshot, a manual
 *  refresh, and a loading flag. Kept as a hook so the full Settings panel and the
 *  compact Dashboard strip share one fetch path (and one source of truth). */
export function useUsage(active: boolean) {
  const [data, setData] = useState<UsageResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const timer = useRef<number | null>(null);

  const load = useCallback(async (refresh = false) => {
    setLoading(true);
    try {
      setData(await api.usage(refresh));
    } catch {
      setData({ available: false, reason: "fetch_failed" });
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!active) return;
    load();
    timer.current = window.setInterval(() => load(), POLL_MS);
    return () => {
      if (timer.current) window.clearInterval(timer.current);
    };
  }, [active, load]);

  return { data, loading, refresh: () => load(true) };
}

/** map the backend's severity + percent to a bar tone (green → amber → red). */
function tone(l: { severity: string; percent: number | null }): string {
  if ((l.percent ?? 0) >= 100 || l.severity === "critical" || l.severity === "exceeded")
    return "usage-bar-red";
  if (l.severity === "warning" || (l.percent ?? 0) >= 90) return "usage-bar-amber";
  return "usage-bar-green";
}

/** "resets in 2h 14m" / "resets in 3d 4h" / "resetting…". Recomputed on render;
 *  the parent re-renders on the poll tick so it stays roughly current. */
function resetLabel(iso: string | null): string | null {
  if (!iso) return null;
  const ms = new Date(iso).getTime() - Date.now();
  if (Number.isNaN(ms)) return null;
  if (ms <= 0) return "resetting…";
  const m = Math.floor(ms / 60000);
  const d = Math.floor(m / 1440);
  const h = Math.floor((m % 1440) / 60);
  const mm = m % 60;
  if (d > 0) return `resets in ${d}d ${h}h`;
  if (h > 0) return `resets in ${h}h ${mm}m`;
  return `resets in ${mm}m`;
}

function Bar({ limit }: { limit: UsageLimit }) {
  const pct = Math.max(0, Math.min(100, Math.round(limit.percent ?? 0)));
  const reset = resetLabel(limit.resets_at);
  return (
    <div className="usage-item">
      <div className="usage-item-head">
        <span className="usage-item-label">
          {limit.label}
          {limit.is_active && <span className="usage-active" title="the window currently limiting you">active</span>}
        </span>
        <span className="usage-item-pct">{pct}%</span>
      </div>
      <div className="usage-track">
        <span className={"usage-fill " + tone(limit)} style={{ width: `${pct}%` }} />
      </div>
      {reset && <span className="usage-reset dim">{reset}</span>}
    </div>
  );
}

/** Unavailable-state guidance, keyed off the backend `reason`. */
function unavailable(reason?: string): string {
  switch (reason) {
    case "no_credentials":
      return "No Claude Code login found on this machine. Sign in with `claude` (or run an agent) and reopen.";
    case "token_expired":
      return "Your Claude Code token has expired. Run any agent (or `claude` in a terminal) to refresh it, then reopen.";
    default:
      return "Couldn't reach the usage service. Check your connection and try again.";
  }
}

/** The full Usage surface — Settings → Usage. A near-1:1 of Claude Desktop's
 *  usage view: account/plan header, one bar per rate-limit window, and the
 *  extra-usage credits bar when enabled. */
export function UsagePanel() {
  const { data, loading, refresh } = useUsage(true);

  return (
    <section className="settings-section">
      <div className="settings-head-row">
        <h3 className="settings-h">Usage</h3>
        <button className="ghost btn-icon" onClick={refresh} title="refresh" aria-label="refresh usage">
          <span className={loading ? "usage-spin" : undefined}><Refresh /></span>
        </button>
      </div>
      <p className="settings-sub dim">
        Your Claude subscription limits, the same numbers as Claude Desktop's Usage view, read
        from your local Claude Code login. haro only reads them; it never changes your sign-in.
      </p>

      {!data ? (
        <p className="dim">Loading…</p>
      ) : !data.available ? (
        <p className="usage-note dim">{unavailable(data.reason)}</p>
      ) : (
        <>
          {data.account && (data.account.plan || data.account.org) && (
            <div className="usage-account">
              {data.account.plan && <span className="usage-plan">{data.account.plan}</span>}
              {data.account.org && <span className="dim"> · {data.account.org}</span>}
              {data.account.email && <span className="dim usage-email"> · {data.account.email}</span>}
            </div>
          )}

          <div className="usage-list">
            {(data.limits ?? []).map((l) => (
              <Bar key={l.kind + (l.label ?? "")} limit={l} />
            ))}
          </div>

          {data.spend && (
            <div className="usage-credits">
              <div className="usage-item-head">
                <span className="usage-item-label">Extra-usage credits</span>
                <span className="usage-item-pct">
                  {data.spend.used_label}
                  {data.spend.limit_label ? <span className="dim"> / {data.spend.limit_label}</span> : null}
                </span>
              </div>
              <div className="usage-track">
                <span
                  className={"usage-fill " + tone(data.spend)}
                  style={{ width: `${Math.max(0, Math.min(100, Math.round(data.spend.percent ?? 0)))}%` }}
                />
              </div>
            </div>
          )}
        </>
      )}
    </section>
  );
}

/** Compact glanceable meter for the Dashboard header: session + weekly windows
 *  as two slim bars. Clicking opens the full Settings → Usage panel. Renders
 *  nothing until data arrives (so it never flashes an empty shell). */
export function UsageStrip({ onOpen }: { onOpen?: () => void }) {
  const { data } = useUsage(true);
  if (!data?.available || !data.limits?.length) return null;

  // Prefer the two headline windows; fall back to whatever came back.
  const pick = (kind: string) => data.limits!.find((l) => l.kind === kind);
  const shown = [pick("session"), pick("weekly_all")].filter(Boolean) as UsageLimit[];
  const strip = shown.length ? shown : data.limits!.slice(0, 2);

  return (
    <button className="usage-strip" onClick={onOpen} title="View full usage (Settings → Usage)">
      <Gauge size={13} />
      {strip.map((l) => {
        const pct = Math.max(0, Math.min(100, Math.round(l.percent ?? 0)));
        return (
          <span className="usage-strip-item" key={l.kind}>
            <span className="usage-strip-label dim">{l.kind === "session" ? "session" : "week"}</span>
            <span className="usage-strip-track">
              <span className={"usage-fill " + tone(l)} style={{ width: `${pct}%` }} />
            </span>
            <span className="usage-strip-pct">{pct}%</span>
          </span>
        );
      })}
    </button>
  );
}
