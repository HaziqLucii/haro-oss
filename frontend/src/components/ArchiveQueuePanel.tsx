import { AlertTriangle, Archive, X } from "./icons";
import { heldBack, isDraining, outcomeTone, previewHeadline, progress, summary } from "../archiveQueue";
import type { ArchiveQueueRun } from "../types";

const OUTCOME_LABEL: Record<string, string> = {
  queued: "queued",
  archiving: "archiving…",
  archived: "archived",
  failed: "failed",
  skipped: "held back",
  canceled: "canceled",
};

/** Bulk archive: the confirm dialog and the live queue, in one panel
 *  (backlog/bulk-archive.md).
 *
 *  Preview and progress are the SAME `ArchiveQueueRun` shape — the dry-run plan the
 *  user approves is the model the live run then fills in — so the dialog can never
 *  promise something the queue doesn't do.
 *
 *  Nothing in here decides *which* workspaces are safe: flipping "include" re-asks the
 *  backend planner for a fresh preview. A second, client-side copy of an admission rule
 *  this destructive is precisely how a UI ends up deleting a branch it said it wouldn't.
 */
export function ArchiveQueuePanel({
  run,
  busy,
  onToggleForce,
  onConfirm,
  onStop,
  onClose,
}: {
  run: ArchiveQueueRun;
  busy?: boolean;
  /** Re-plan with/without the risky workspaces (a round trip, on purpose). */
  onToggleForce: (force: boolean) => void;
  onConfirm: () => void;
  onStop: () => void;
  onClose: () => void;
}) {
  const preview = run.dry;
  const head = previewHeadline(run);
  const held = heldBack(run);
  const prog = progress(run);
  const draining = isDraining(run);
  // The risk block lists whoever is at stake — the ones held back, or (once forced) the
  // ones now admitted *because* it was forced. Keying it on `held` alone made the
  // checkbox vanish the moment you ticked it, leaving no way back to the safe plan.
  const risky = held.length > 0 ? held : run.items.filter((i) => i.risks.length > 0);

  return (
    <div className="modal-backdrop" onClick={draining ? undefined : onClose}>
      <div className="modal arq" onClick={(e) => e.stopPropagation()}>
        <div className="fp-head">
          <span className="fp-title">
            <Archive /> Bulk archive
          </span>
          <button className="ghost" onClick={onClose} aria-label="close" disabled={draining}>
            <X />
          </button>
        </div>

        <div className="arq-body">
          {preview ? (
            <>
              <div className="arq-headline">{head.text}</div>
              {head.detail && <div className="arq-sub dim">{head.detail}</div>}
            </>
          ) : (
            <>
              <div className="arq-headline">
                {run.state === "running" ? "Archiving…" : run.state === "canceled" ? "Stopped" : "Done"}
              </div>
              <div className="arq-sub dim">{prog.label}</div>
              {prog.total > 0 && (
                <div className="arq-bar">
                  <div
                    className="arq-bar-fill"
                    style={{ width: `${Math.round((prog.done / prog.total) * 100)}%` }}
                  />
                </div>
              )}
            </>
          )}

          {/* The risk gate. Held-back workspaces are named with what they'd lose —
              "3 skipped" without the reason is an invitation to force it blindly. */}
          {preview && risky.length > 0 && (
            <div className="arq-risk">
              <div className="arq-risk-head">
                <AlertTriangle />
                <span>
                  {run.force
                    ? `${risky.length} will lose work — archiving deletes the branch, so this is gone`
                    : `${risky.length} held back — archiving deletes the branch, so this work would be gone`}
                </span>
              </div>
              <ul className="arq-risk-list">
                {risky.map((i) => (
                  <li key={i.workspace_id}>
                    <span className="arq-risk-name">{i.name}</span>
                    <span className="dim">{i.reason ?? i.risks.join(" · ")}</span>
                  </li>
                ))}
              </ul>
              <label className="arq-force">
                <input
                  type="checkbox"
                  className="switch"
                  checked={run.force}
                  disabled={busy}
                  onChange={(e) => onToggleForce(e.target.checked)}
                />
                <span>include them anyway</span>
              </label>
            </div>
          )}

          <ul className="arq-items">
            {run.items.map((i) => (
              <li key={i.workspace_id} className={"arq-item arq-" + i.outcome}>
                <span className={"arq-item-state " + outcomeTone(i.outcome)}>
                  {OUTCOME_LABEL[i.outcome] ?? i.outcome}
                </span>
                <span className="arq-item-name">{i.name}</span>
                {/* A forced item keeps its risks visible right up to the moment it runs. */}
                {i.reason ? (
                  <span className="arq-item-why dim">{i.reason}</span>
                ) : i.risks.length > 0 ? (
                  <span className="arq-item-why s-star">{i.risks.join(" · ")}</span>
                ) : null}
              </li>
            ))}
          </ul>
        </div>

        <div className="arq-foot">
          <span className="dim arq-foot-note">
            {preview
              ? "one workspace at a time — you can stop the queue between them"
              : summary(run)}
          </span>
          <div className="arq-foot-actions">
            {preview ? (
              <>
                <button className="ghost" onClick={onClose}>
                  cancel
                </button>
                <button className="danger" onClick={onConfirm} disabled={!head.canRun || busy}>
                  {head.text.toLowerCase()}
                </button>
              </>
            ) : draining ? (
              <button className="ghost" onClick={onStop} disabled={run.stop_requested}>
                {run.stop_requested ? "stopping after this one…" : "stop"}
              </button>
            ) : (
              <button className="ghost" onClick={onClose}>
                close
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
