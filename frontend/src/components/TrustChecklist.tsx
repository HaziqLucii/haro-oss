import type { TrustFix, TrustReport } from "../types";

/** Human-readable label per trust condition key — the `detail` from the backend
 *  carries the full state (and the *why* when unmet); this is the short row title. */
export const TRUST_LABELS: Record<string, string> = {
  merge_result: "Merged tree is green",
  coverage: "Coverage holds vs base",
  full_scope: "Full suite ran",
  no_flaky: "No flaky tests",
  no_tamper: "No tamper findings",
  // The Double Gate's other half (backlog/double-gate.md §1) — the backend only emits
  // this row once a quality gate exists to measure it, so today it never renders.
  quality: "Quality gate green",
  streak: "Green streak",
};

export const TRUST_ACTION_LABELS: Record<string, string> = {
  off: "auto-ship",
  auto_pr: "auto-PR",
};

/** The call-to-action label for each fix deep-link (backend `fix` token). */
export const TRUST_FIX_LABELS: Record<TrustFix, string> = {
  gate_settings: "Gate settings",
  run_full: "Run full suite",
  ribbon: "See the ribbon",
  tamper: "See the findings",
};

/** Count of *required, unmet* conditions — the blockers between here and auto-ship.
 *  A count of remaining work, deliberately not a score/percentage over the whole set. */
export function trustUnmet(t: TrustReport): number {
  return t.conditions.filter((c) => c.required && !c.met).length;
}

/** The autonomy-ladder checklist — "why you can't auto-ship yet" as a deterministic
 *  conjunction of gate facts (backlog/autonomy-ladder.md). Every condition renders as
 *  a met/unmet row with its `detail` — a checklist, never a score or percentage. 96%
 *  of devs don't fully trust agent code, so the legible checklist IS the product; the
 *  auto-PR switch is the reward at the top.
 *
 *  Its only home is ④ ship now (notes/verify-redesign-plan.md moved it out of ③ verify,
 *  which used to render the same component in its own "trust" tab) — GitPanel renders
 *  it under the merge-blocked banner. (Widening that to show whenever the ladder is
 *  enabled, not only while merge-blocked, is Phase 3 — not shipped yet.) `onFix`
 *  deep-links an unmet row to its fix, which lives on ③: a guard toggle opens the
 *  project's Gate settings, "run full" hops to the gate and runs the whole suite, and
 *  "see the ribbon" / "see the findings" land on ③ with the relevant zone opened. */
export function TrustChecklist({
  trust,
  onFix,
}: {
  trust: TrustReport | null;
  onFix: (fix: TrustFix) => void;
}) {
  if (!trust) {
    return (
      <div className="empty trust-empty">
        No trust report yet. Run the gate: the ladder is computed from its result.
      </div>
    );
  }

  const action = TRUST_ACTION_LABELS[trust.auto_action] ?? "auto-ship";
  // The headline is a *state*, not a number: armed (fires now) → met-but-not-armed
  // (conditions hold, but the policy is off) → locked (a required condition unmet).
  const verdict = trust.armed
    ? { cls: "trust-verdict-armed", glyph: "●", text: `${action} armed` }
    : trust.met
    ? { cls: "trust-verdict-ready", glyph: "✓", text: "all conditions met" }
    : { cls: "trust-verdict-locked", glyph: "○", text: `${action} locked` };

  // When conditions hold but nothing fires, say why — the policy, not the gate.
  const readyHint = trust.met && !trust.armed
    ? trust.auto_action === "off"
      ? "Conditions hold: set [trust] auto_action to auto_pr to earn auto-ship."
      : !trust.enabled
      ? "Conditions hold: enable the [trust] policy to arm the auto action."
      : null
    : null;

  return (
    <div className="trust-lane">
      <div className="trust-head">
        <span className="trust-title">
          trust checklist
          <span className="dim"> · why you can’t auto-ship yet</span>
        </span>
        <span className={"trust-verdict " + verdict.cls}>
          {verdict.glyph} {verdict.text}
        </span>
      </div>

      {readyHint && <div className="trust-hint dim">{readyHint}</div>}

      <ul className="trust-list">
        {trust.conditions.map((c) => (
          <li
            key={c.key}
            className={"trust-row " + (c.met ? "trust-row-met" : "trust-row-unmet")}
          >
            <span className="trust-glyph">{c.met ? "✓" : "○"}</span>
            <span className="trust-row-body">
              <span className="trust-row-label">
                {TRUST_LABELS[c.key] ?? c.key}
                {!c.required && <span className="trust-optional dim"> · optional</span>}
              </span>
              <span className="trust-row-detail dim">{c.detail}</span>
            </span>
            {!c.met && c.fix && (
              <button
                type="button"
                className="trust-fix"
                onClick={() => onFix(c.fix!)}
                title={`Fix: ${TRUST_FIX_LABELS[c.fix]}`}
              >
                {TRUST_FIX_LABELS[c.fix]} →
              </button>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}
