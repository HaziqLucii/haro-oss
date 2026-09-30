import { useEffect, useRef, useState } from "react";
import { X } from "./icons";

/** Shown when the user picks a folder that isn't a git repo yet. Confirms the
 *  `git init` and lets them paste a remote URL to link in the same step (so a
 *  fresh project is immediately push/PR-ready). */
export function InitRepoModal({
  path,
  busy = false,
  onConfirm,
  onCancel,
}: {
  path: string;
  busy?: boolean;
  onConfirm: (remoteUrl: string) => void;
  onCancel: () => void;
}) {
  const [remoteUrl, setRemoteUrl] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onCancel();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const folder = path.split("/").filter(Boolean).pop() ?? path;

  return (
    <div className="modal-backdrop" onClick={onCancel}>
      <div className="modal init-modal" onClick={(e) => e.stopPropagation()}>
        <div className="fp-head">
          <span className="fp-title">Initialize git repository</span>
          <button className="ghost" onClick={onCancel} aria-label="close">
            <X />
          </button>
        </div>

        <p className="init-body">
          <strong>{folder}</strong> isn’t a git repository yet. haro needs git to
          create isolated worktrees. Run <code>git init</code> here?
        </p>
        <p className="dim init-path" title={path}>
          {path}
        </p>

        <label className="init-field">
          <span className="init-label">Remote URL <span className="dim">(optional)</span></span>
          <input
            ref={inputRef}
            className="init-input"
            type="text"
            placeholder="https://github.com/you/repo.git"
            value={remoteUrl}
            onChange={(e) => setRemoteUrl(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && !busy && onConfirm(remoteUrl.trim())}
            spellCheck={false}
            autoComplete="off"
          />
          <span className="dim init-hint">
            Paste a remote to link <code>origin</code> now, or add it later.
          </span>
        </label>

        <div className="fp-foot init-foot">
          <button className="ghost" onClick={onCancel} disabled={busy}>
            Cancel
          </button>
          <button className="primary" onClick={() => onConfirm(remoteUrl.trim())} disabled={busy}>
            {busy ? (
              <>
                <span className="spinner" aria-hidden /> initializing…
              </>
            ) : (
              "Initialize & add"
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
