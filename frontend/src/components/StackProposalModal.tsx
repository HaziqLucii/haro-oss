import { useEffect, useState } from "react";
import { X } from "./icons";
import type { StackDetection, StackPreset } from "../types";

/** A one-line gate descriptor for a preset: the gate command if it has one
 *  (command/offense runners), else the runner name, else "no gate". */
function gateSummary(preset: StackPreset): string {
  const g = preset.gate ?? {};
  if (g.command) return g.command;
  if (g.runner) return `${g.runner} run`;
  return "no gate";
}

/** Propose-and-confirm: after a project is added we sniff its stack and offer the
 *  detected preset ("Looks like a Shopify theme — gate on `shopify theme check`?")
 *  with the generated `settings.toml` rendered for inspection BEFORE anything is
 *  written. The dev can accept the proposal, pick another candidate, or configure
 *  manually (skip). Detection itself is read-only; this modal owns the write. */
export function StackProposalModal({
  projectName,
  detection,
  onApply,
  onClose,
}: {
  projectName: string;
  detection: StackDetection;
  onApply: (presetId: string) => Promise<void>;
  onClose: () => void;
}) {
  const proposal = detection.proposal ?? null;
  // Ambiguous (no clear winner) → open straight into the candidate list so the
  // dev picks; a clear proposal → lead with it, list is one click away.
  const [picking, setPicking] = useState(!proposal);
  const [selectedId, setSelectedId] = useState(
    proposal?.preset.id ?? detection.candidates[0]?.preset.id ?? "custom"
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && !busy && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [busy, onClose]);

  const selected =
    detection.candidates.find((c) => c.preset.id === selectedId) ?? detection.candidates[0];

  const apply = async () => {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await onApply(selectedId);
      // parent closes the modal on success
    } catch (e) {
      setError(e instanceof Error ? e.message : "could not apply preset");
      setBusy(false);
    }
  };

  return (
    <div className="modal-backdrop" onClick={() => !busy && onClose()}>
      <div className="modal sp-modal" onClick={(e) => e.stopPropagation()}>
        <div className="fp-head">
          <span className="fp-title">Set up the gate</span>
          <button className="ghost" onClick={onClose} aria-label="close" disabled={busy}>
            <X />
          </button>
        </div>

        {proposal && !picking ? (
          <p className="sp-proposal">
            {proposal.preset.blurb}, gate on <code>{gateSummary(proposal.preset)}</code>?
          </p>
        ) : (
          <p className="sp-proposal dim">
            {proposal
              ? `Pick the gate for ${projectName}.`
              : `Couldn’t confidently detect the stack for ${projectName}. Pick a gate.`}
          </p>
        )}

        {picking && (
          <div className="sp-list" role="radiogroup" aria-label="stack preset">
            {detection.candidates.map((c) => {
              const isProposed = proposal?.preset.id === c.preset.id;
              const active = c.preset.id === selectedId;
              return (
                <button
                  key={c.preset.id}
                  className={`sp-cand${active ? " active" : ""}`}
                  role="radio"
                  aria-checked={active}
                  onClick={() => setSelectedId(c.preset.id)}
                  disabled={busy}
                >
                  <span className="sp-radio" aria-hidden />
                  <span className="sp-cand-body">
                    <span className="sp-cand-label">
                      {c.preset.label}
                      {isProposed && <span className="sp-badge">detected</span>}
                    </span>
                    <span className="sp-cand-gate dim">gate on {gateSummary(c.preset)}</span>
                  </span>
                </button>
              );
            })}
          </div>
        )}

        <div className="sp-preview">
          <span className="sp-preview-head dim">
            <code>.haro/settings.toml</code> (committed)
          </span>
          <pre className="sp-toml">{selected?.preset.toml?.trim() || "# no config written"}</pre>
        </div>

        {error && <p className="ap-error sp-error">{error}</p>}

        <div className="fp-foot init-foot">
          <button className="ghost" onClick={onClose} disabled={busy}>
            Configure manually
          </button>
          {proposal && !picking && (
            <button className="ghost" onClick={() => setPicking(true)} disabled={busy}>
              Pick another
            </button>
          )}
          <button className="primary" onClick={apply} disabled={busy}>
            {busy ? (
              <>
                <span className="spinner" aria-hidden /> writing…
              </>
            ) : proposal && !picking ? (
              "Use it"
            ) : (
              `Use ${selected?.preset.label ?? "preset"}`
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
