import type { ReviewComment } from "../types";
import { X } from "./icons";

/** v1.3: pending review comments (from diff lines / failing tests) that round-trip
 *  to the agent as a single follow-up task. */
export function ReviewPanel({
  comments,
  busy,
  onUpdate,
  onRemove,
  onSend,
  onSendToBacklog,
}: {
  comments: ReviewComment[];
  busy: boolean;
  onUpdate: (id: string, text: string) => void;
  onRemove: (id: string) => void;
  onSend: () => void;
  // "Send to backlog" (backlog/backlog-v2.md Move 3): queue the comment as a
  // follow-up item instead of re-tasking the CURRENT agent. Optional — callers
  // without a project context (nothing to write the backlog file into) omit it.
  onSendToBacklog?: (c: ReviewComment) => void;
}) {
  if (comments.length === 0) return null;
  return (
    <section className="review">
      <div className="review-head">
        <span>review · {comments.length} comment{comments.length === 1 ? "" : "s"} → agent</span>
        <button className="primary" onClick={onSend} disabled={busy}>
          send to agent
        </button>
      </div>
      {comments.map((c) => (
        <div key={c.id} className="review-item">
          <div className="review-target">
            <span className="badge">{c.target}</span>
            {onSendToBacklog && (
              <button
                className="ghost review-backlog"
                onClick={() => onSendToBacklog(c)}
                title="Queue this as a backlog follow-up instead of sending it to the agent now"
              >
                + backlog
              </button>
            )}
            <button className="ghost review-x" onClick={() => onRemove(c.id)} title="remove">
              <X />
            </button>
          </div>
          {c.context && <pre className="review-context">{c.context}</pre>}
          <input
            className="review-input"
            value={c.text}
            onChange={(e) => onUpdate(c.id, e.target.value)}
            placeholder="instruction for the agent (e.g. fix this failing test)…"
          />
        </div>
      ))}
    </section>
  );
}
