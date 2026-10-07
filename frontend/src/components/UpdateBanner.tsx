import { useEffect, useState } from "react";
import { api } from "../api";
import { ArrowUp } from "./icons";
import type { UpdateProgress, UpdateStatus } from "../types";

/** Compact self-update control that lives at the right of the appbar (which doubles as
 *  the title bar on the desktop app). The packaged app is a frozen snapshot, so when
 *  your source moves ahead it can rebuild itself (backend/haro/update.py). Shows an
 *  "Update" chip when a newer build is available; while the rebuild runs it becomes a
 *  determinate progress pill fed by GET /update/progress — real milestones written by
 *  rebuild.sh (frontend build → backend freeze → package → install), so the user sees
 *  an actual percentage instead of a spinner. Renders nothing when up to date or when
 *  the run can't self-update (dev / run.sh / browser). */
export function UpdateBanner() {
  const [st, setSt] = useState<UpdateStatus | null>(null);
  const [prog, setProg] = useState<UpdateProgress | null>(null);
  const [working, setWorking] = useState(false);
  const [scheduled, setScheduled] = useState(false);

  // A rebuild is in flight while there's live progress (the file exists only during a
  // build; the relaunched app clears it on boot) or we just kicked one off locally and
  // its first milestone hasn't landed yet.
  const applying = prog !== null || working;

  const refresh = () => api.updateStatus().then(setSt).catch(() => {});
  useEffect(() => {
    const pull = () => {
      refresh();
      // Also catch a rebuild started elsewhere (auto mode / another window) on the slow tick.
      api.updateProgress().then((p) => p && setProg(p)).catch(() => {});
    };
    pull();
    const t = window.setInterval(pull, 60_000);
    return () => window.clearInterval(t);
  }, []);

  // Poll progress fast while a rebuild runs, until the app relaunches onto the new build.
  useEffect(() => {
    if (!applying) return;
    const t = window.setInterval(() => {
      api.updateProgress().then(setProg).catch(() => {});
    }, 1200);
    return () => window.clearInterval(t);
  }, [applying]);

  const apply = async () => {
    setWorking(true);
    try {
      const r = await api.applyUpdate();
      if (r.scheduled) {
        setScheduled(true);
        setWorking(false); // queued, not building — drop back to the queued chip
      }
      // else applying: `working` keeps the progress pill up until milestones arrive.
    } catch {
      setWorking(false);
    }
    refresh();
  };

  if (applying) {
    const pct = prog?.pct ?? 1;
    const label = prog?.label || "Updating";
    return (
      <div
        className="upd upd-applying"
        role="progressbar"
        aria-valuenow={pct}
        aria-valuemin={0}
        aria-valuemax={100}
        title="Rebuilding & restarting · workspaces persist"
      >
        <span className="upd-label">{label}</span>
        <div className="upd-track">
          <div className="upd-fill" style={{ width: `${pct}%` }} />
        </div>
        <span className="upd-pct">{pct}%</span>
      </div>
    );
  }

  if (!st || !st.supported) return null;
  if (scheduled || st.pending) {
    return (
      <span className="upd upd-queued" title="Applies automatically when agents finish">
        Update queued
      </span>
    );
  }
  if (!st.available) return null;

  return (
    <button
      className="upd upd-btn"
      disabled={working}
      onClick={apply}
      title={`Rebuild from your local source & restart (workspaces persist)\n${st.buildSha} → ${st.headSha}`}
    >
      <ArrowUp size={13} />
      {st.busy ? "Update when idle" : "Update"}
    </button>
  );
}
