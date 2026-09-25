import { useState } from "react";
import { api } from "../api";
import type { ReceiptResponse } from "../types";

const VERDICT_LABEL: Record<string, string> = {
  green: "GREEN", red: "RED", degraded: "DEGRADED", none: "NOT GATED",
};

/** The Gate Receipt (usp-critique-plan.md idea 1) — the exportable evidence packet a
 *  reviewer reads instead of the diff, rendered on the ④ ship step. `data` is fetched
 *  and refreshed by App.tsx alongside the diff/verified-hunks annotation (the same
 *  "one green-run refresh" data flow every other gate-derived panel uses); reading a
 *  receipt never triggers a test, a mutation pass, or a gh call itself. The PR-comment
 *  action is the one thing this component calls the API for directly — a user-triggered
 *  one-off mutation, not data another view also needs. */
export function ReceiptPanel({
  workspaceId,
  data,
  hasRemote,
}: {
  workspaceId: string;
  data: ReceiptResponse | null;
  hasRemote: boolean;
}) {
  // Open by default: the whole point (usp-critique-plan.md idea 3, "evidence on by
  // default") is that this doesn't hide behind a click the way an opt-in feature would.
  const [open, setOpen] = useState(true);
  const [posting, setPosting] = useState(false);
  const [postNote, setPostNote] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  if (!data || data.receipt.verdict === "none") return null;
  const r = data.receipt;

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(data.markdown);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard can be unavailable (permissions, non-secure context) — a failed
      // copy isn't worth surfacing as an error, the text is still on screen.
    }
  };

  const postToPr = async () => {
    setPosting(true);
    setPostNote(null);
    try {
      const res = await api.postReceiptPrComment(workspaceId);
      setPostNote(res.posted ? "posted to the PR" : "not posted");
    } catch (e) {
      setPostNote(e instanceof Error ? e.message : "failed to post");
    } finally {
      setPosting(false);
    }
  };

  return (
    <div className="receipt-lane">
      <div className="trust-head" onClick={() => setOpen((v) => !v)} style={{ cursor: "pointer" }}>
        <span className="trust-title">
          gate receipt
          <span className="dim"> · the evidence, not the diff</span>
        </span>
        <span className={"trust-verdict trust-verdict-" + (r.verdict === "green" ? "ready" : r.verdict === "red" ? "locked" : "armed")}>
          {r.verdict === "green" ? "✓" : r.verdict === "red" ? "○" : "●"} {VERDICT_LABEL[r.verdict]}
        </span>
      </div>

      {open && (
        <>
          {r.degraded_reasons.length > 0 && (
            <div className="gate-degraded">
              <strong>a check this project asked for could not run</strong>
              <ul className="gate-degraded-list">
                {r.degraded_reasons.map((reason, i) => (
                  <li key={i}>{reason}</li>
                ))}
              </ul>
            </div>
          )}
          <ul className="trust-list">
            <li className="trust-row trust-row-met">
              <span className="trust-row-body">
                <span className="trust-row-label">Suite</span>
                <span className="trust-row-detail dim">
                  {r.suite.passed}/{r.suite.total} passed · {r.suite.runner} · scope={r.suite.scope}
                </span>
              </span>
            </li>
            <li className={"trust-row " + (r.tamper.measured && r.tamper.clean ? "trust-row-met" : "trust-row-unmet")}>
              <span className="trust-glyph">{r.tamper.measured && r.tamper.clean ? "✓" : "○"}</span>
              <span className="trust-row-body">
                <span className="trust-row-label">Tamper alarm</span>
                <span className="trust-row-detail dim">
                  {r.tamper.measured ? (r.tamper.clean ? "clean" : `${r.tamper.findings_count} finding(s)`) : "not measured"}
                </span>
              </span>
            </li>
            <li className="trust-row">
              <span className="trust-row-body">
                <span className="trust-row-label">Verified hunks</span>
                <span className="trust-row-detail dim">
                  {r.verified_hunks.supported && r.verified_hunks.percentage !== null
                    ? `${r.verified_hunks.percentage}% of added lines executed`
                      + (r.verified_hunks.note ? ` (${r.verified_hunks.note})` : "")
                    : r.verified_hunks.note ?? "not available"}
                </span>
              </span>
            </li>
            <li className="trust-row">
              <span className="trust-row-body">
                <span className="trust-row-label">Mutation score</span>
                <span className="trust-row-detail dim">
                  {r.mutation.ran && r.mutation.score !== null
                    ? `${r.mutation.score}% (${r.mutation.survivors.length} survivor${r.mutation.survivors.length === 1 ? "" : "s"})${r.mutation.stale ? " · stale" : ""}`
                    : r.mutation.note ?? "not run"}
                </span>
              </span>
            </li>
            <li className={"trust-row " + (r.quality.measured && !r.quality.blocked ? "trust-row-met" : "trust-row-unmet")}>
              <span className="trust-glyph">{r.quality.measured && !r.quality.blocked ? "✓" : "○"}</span>
              <span className="trust-row-body">
                <span className="trust-row-label">Quality scan</span>
                <span className="trust-row-detail dim">
                  {r.quality.measured
                    ? (r.quality.findings_count ? `${r.quality.findings_count} finding(s)` : "clean")
                      // Mode-agnostic (see ReceiptQuality.blocked): true whenever a finding
                      // meets the blocking threshold, even under [quality] enforce = "warn"
                      // where the automated verdict can otherwise stay green.
                      + (r.quality.blocked ? ` (${r.quality.blocking_count} blocking)` : "")
                    : "not measured"}
                </span>
              </span>
            </li>
            {r.quality.plan_compliance.ran && (() => {
              const pc = r.quality.plan_compliance;
              // Met only when it actually ran clean — an error (could not run) or a
              // block that never got a verdict must NOT draw the same green ✓ a real
              // pass gets. `blocking` alone isn't "blocked" either: under [quality]
              // plan_compliance = "warn" it never enforces, so it can be true on an
              // otherwise GREEN run.
              const ok = !pc.error && pc.compliant;
              const detail = pc.error
                ? `could not run — ${pc.error}`
                : pc.blocking && pc.enforced
                ? `BLOCKING — ${pc.summary ?? "diff does not implement the task"}`
                : pc.blocking
                ? `flagged, not enforced (plan_compliance is "warn") — ${pc.summary ?? "diff does not implement the task"}`
                : !pc.compliant
                ? `possible gap (${pc.confidence} confidence, advisory)`
                : "implements the task";
              return (
                <li className={"trust-row " + (ok ? "trust-row-met" : "trust-row-unmet")}>
                  <span className="trust-glyph">{ok ? "✓" : "○"}</span>
                  <span className="trust-row-body">
                    <span className="trust-row-label">Plan compliance</span>
                    <span className="trust-row-detail dim">{detail}</span>
                  </span>
                </li>
              );
            })()}
            {r.agent.model && (
              <li className="trust-row">
                <span className="trust-row-body">
                  <span className="trust-row-label">Agent</span>
                  <span className="trust-row-detail dim">
                    {r.agent.model}
                    {r.agent.effort ? `/${r.agent.effort}` : ""}
                    {r.agent.cost_usd != null ? ` — $${r.agent.cost_usd.toFixed(2)}` : ""}
                  </span>
                </span>
              </li>
            )}
          </ul>

          <div className="receipt-actions">
            <button type="button" className="trust-fix" onClick={copy}>
              {copied ? "copied ✓" : "copy markdown"}
            </button>
            {hasRemote && (
              <button type="button" className="trust-fix" onClick={postToPr} disabled={posting}>
                {posting ? "posting…" : "post to PR"}
              </button>
            )}
            {postNote && <span className="dim">{postNote}</span>}
          </div>
        </>
      )}
    </div>
  );
}
