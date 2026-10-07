import { useState } from "react";
import { GitHubMark, LinkIcon, X } from "./icons";

/** Link, change, or unlink the project's git `origin` remote. Opened from the
 * project home's remote bar — a focused modal, not an inline input, so setting the
 * remote reads as the deliberate, project-scoped action it is. The remote lives in
 * the repo's shared .git, so every workspace inherits it for push + `gh` PR merges. */
export function RemoteModal({
  currentUrl,
  onSave,
  onUnlink,
  onClose,
}: {
  currentUrl: string | null;
  onSave: (url: string) => Promise<void>;
  onUnlink: () => Promise<void>;
  onClose: () => void;
}) {
  const [value, setValue] = useState(currentUrl ?? "");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const submit = async () => {
    if (!value.trim() || busy) return;
    setBusy(true);
    setErr(null);
    try {
      await onSave(value.trim());
    } catch (e: any) {
      setErr(e?.message ?? String(e));
      setBusy(false);
    }
  };

  const unlink = async () => {
    if (busy) return;
    setBusy(true);
    setErr(null);
    try {
      await onUnlink();
    } catch (e: any) {
      setErr(e?.message ?? String(e));
      setBusy(false);
    }
  };

  const isGithub = value.includes("github.com");

  return (
    <div className="modal-backdrop" onClick={() => !busy && onClose()}>
      <div className="modal nwm" onClick={(e) => e.stopPropagation()}>
        <div className="fp-head">
          <span className="fp-title">{currentUrl ? "Edit remote" : "Link a remote"}</span>
          <button className="ghost" onClick={onClose} aria-label="close">
            <X />
          </button>
        </div>

        <div className="nwm-body">
          <label className="nwm-field">
            <span className="nwm-k rm-k">
              <span className="rm-k-icon">{isGithub ? <GitHubMark size={13} /> : <LinkIcon />}</span>
              origin URL
            </span>
            <input
              value={value}
              autoFocus
              spellCheck={false}
              placeholder="https://github.com/you/repo.git  or  git@github.com:you/repo.git"
              onChange={(e) => setValue(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") submit();
                if (e.key === "Escape") !busy && onClose();
              }}
              disabled={busy}
            />
          </label>
          <div className="nwm-hint dim">
            The remote lives in the repo's shared <code>.git</code>, so every workspace pushes
            and opens PRs through it. Without one, merges stay local.
          </div>
          {err && (
            <div className="nwm-hint" style={{ color: "var(--del)" }}>
              {err}
            </div>
          )}
        </div>

        <div className="fp-foot">
          {currentUrl && (
            <button
              className="ghost danger"
              onClick={unlink}
              disabled={busy}
              style={{ marginRight: "auto" }}
            >
              unlink
            </button>
          )}
          <button className="ghost" onClick={onClose} disabled={busy}>
            cancel
          </button>
          <button className="primary" onClick={submit} disabled={busy || !value.trim()}>
            {busy ? "saving…" : currentUrl ? "save" : "link"}
          </button>
        </div>
      </div>
    </div>
  );
}
