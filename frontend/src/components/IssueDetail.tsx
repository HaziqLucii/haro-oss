import { useEffect, useState } from "react";
import { api } from "../api";
import { ExternalLink } from "./icons";
import type { IssueDetailResponse } from "../types";

// Read-only detail for a single GitHub issue, rendered inline when a backlog row
// is expanded. Fetches on demand (a fresh `gh issue view` per expand — no cache,
// no poller) so the body + discussion are always live. Deliberately read-only:
// haro reads and links, GitHub stays the source of truth. Acting on an issue is
// the row's job (click-to-seed); this panel is just for reading in place.

// ISO stamp → local "MMM D, HH:MM" for a comment's timestamp. Falls back to the
// raw string if it doesn't parse (never blows up the panel over a bad date).
function fmtWhen(iso: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  return d.toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

// Mirrors the list's degrade copy so an expanded row reads the same as the tab.
function unavailableMsg(reason?: string | null): string {
  if (reason === "no-remote") return "Link a GitHub remote to read this issue.";
  if (reason === "no-gh") return "Install the GitHub CLI (gh) to read this issue.";
  return "Couldn't load this issue" + (reason ? ` · ${reason}` : "") + ".";
}

export function IssueDetail({
  projectId,
  number,
}: {
  projectId: string;
  number: number;
}) {
  const [detail, setDetail] = useState<IssueDetailResponse | null>(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setDetail(null);
    setError(false);
    api
      .getIssueDetail(projectId, number)
      .then((d) => {
        if (!cancelled) setDetail(d);
      })
      .catch(() => {
        if (!cancelled) setError(true);
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, number]);

  if (error) {
    return <div className="issue-detail issue-detail-msg dim">Couldn't load this issue.</div>;
  }
  if (!detail) {
    return <div className="issue-detail issue-detail-msg dim">Loading issue…</div>;
  }
  if (!detail.available) {
    return <div className="issue-detail issue-detail-msg dim">{unavailableMsg(detail.reason)}</div>;
  }

  const comments = detail.comments ?? [];

  return (
    <div className="issue-detail">
      <div className="issue-detail-body">
        {detail.body ? (
          <p className="issue-detail-text">{detail.body}</p>
        ) : (
          <p className="issue-detail-empty dim">No description.</p>
        )}
      </div>

      {comments.length > 0 && (
        <div className="issue-detail-comments">
          <div className="issue-detail-comments-head dim">
            {comments.length} comment{comments.length === 1 ? "" : "s"}
          </div>
          {comments.map((c, i) => (
            <div className="issue-comment" key={i}>
              <div className="issue-comment-meta dim">
                <span className="issue-comment-author">{c.author || "someone"}</span>
                {c.created_at && (
                  <span className="issue-comment-when">{fmtWhen(c.created_at)}</span>
                )}
              </div>
              <p className="issue-detail-text">{c.body}</p>
            </div>
          ))}
        </div>
      )}

      {detail.url && (
        <a
          className="issue-detail-link"
          href={detail.url}
          target="_blank"
          rel="noreferrer"
        >
          <ExternalLink />
          Open on GitHub
        </a>
      )}
    </div>
  );
}
