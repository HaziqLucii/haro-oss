import { useEffect, useState } from "react";
import { Folder, GitBranch, X } from "./icons";
import { api } from "../api";
import type { FsListing } from "../types";

/** A directory browser used in two modes:
 *  - `variant="project"` (default): pick a git repo to add, or a non-git folder to
 *    `git init` and add. `onPick(path, isGitRepo)` — isGitRepo=false ⇒ needs init.
 *  - `variant="directory"`: pick any folder as a *location* (e.g. where a new
 *    project goes). Rows only navigate; the footer selects the current folder.
 *
 *  In Docker you can't easily guess absolute paths, so this beats typing one. */
export function FolderPicker({
  variant = "project",
  title,
  onPick,
  onBack,
  onClose,
}: {
  variant?: "project" | "directory";
  title?: string;
  onPick: (path: string, isGitRepo: boolean) => void;
  onBack?: () => void;
  onClose: () => void;
}) {
  const [listing, setListing] = useState<FsListing | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [newName, setNewName] = useState("");
  const [creating, setCreating] = useState(false);
  const dirMode = variant === "directory";

  const go = (path?: string) => {
    setLoading(true);
    setError(null);
    api
      .browseFs(path)
      .then((l) => setListing(l))
      .catch((e) => setError(e instanceof Error ? e.message : "cannot read folder"))
      .finally(() => setLoading(false));
  };

  useEffect(() => {
    go();
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const createFolder = () => {
    const name = newName.trim();
    if (!name || !listing) return;
    setCreating(true);
    setError(null);
    api
      .mkdirFs(listing.path, name)
      .then(() => {
        setNewName("");
        go(listing.path); // refresh so the new folder shows up
      })
      .catch((e) => setError(e instanceof Error ? e.message : "could not create folder"))
      .finally(() => setCreating(false));
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal fp" onClick={(e) => e.stopPropagation()}>
        <div className="fp-head">
          <span className="fp-title">
            {onBack && (
              <button className="ghost fp-back" onClick={onBack} title="back" aria-label="back">
                ←
              </button>
            )}
            {title ?? (dirMode ? "Choose a folder" : "Add a project")}
          </span>
          <button className="ghost" onClick={onClose} aria-label="close">
            <X />
          </button>
        </div>

        <div className="fp-path">
          <button
            className="ghost fp-up"
            onClick={() => listing?.parent && go(listing.parent)}
            disabled={!listing?.parent}
            title="up one folder"
          >
            ⬆
          </button>
          <span className="fp-cwd" title={listing?.path}>
            {listing?.path ?? "…"}
          </span>
        </div>

        <div className="fp-list">
          {loading ? (
            <div className="side-empty dim">loading…</div>
          ) : error ? (
            <div className="side-empty dim">{error}</div>
          ) : listing && listing.entries.length === 0 ? (
            <div className="side-empty dim">no sub-folders here</div>
          ) : (
            listing?.entries.map((e) => (
              <div key={e.path} className={"fp-row" + (e.is_git_repo ? " fp-repo" : "")}>
                <button className="fp-nav" onClick={() => go(e.path)} title="open folder">
                  <span className="fp-folder-ico">{e.is_git_repo ? <GitBranch size={12} /> : <Folder size={12} />}</span>
                  <span className="fp-name">{e.name}</span>
                  {e.is_git_repo && <span className="fp-badge">git repo</span>}
                </button>
                {/* project mode: only git repos are addable (create-new handles init);
                    directory mode selects via footer */}
                {!dirMode && e.is_git_repo && (
                  <button className="primary fp-select" onClick={() => onPick(e.path, true)}>
                    add
                  </button>
                )}
              </div>
            ))
          )}
        </div>

        {/* create a new folder in the current directory — only when picking a
            location for a new project; adding an existing project shouldn't init. */}
        {dirMode && (
          <div className="fp-newdir">
            <input
              className="init-input"
              type="text"
              placeholder="new-folder-name"
              value={newName}
              onChange={(ev) => setNewName(ev.target.value)}
              onKeyDown={(ev) => ev.key === "Enter" && createFolder()}
              spellCheck={false}
              autoComplete="off"
              disabled={!listing || creating}
            />
            <button className="ghost" onClick={createFolder} disabled={!newName.trim() || creating}>
              {creating ? "creating…" : "＋ new folder"}
            </button>
          </div>
        )}

        <div className="fp-foot">
          {dirMode ? (
            <button
              className="primary"
              onClick={() => listing && onPick(listing.path, listing.is_git_repo)}
              disabled={!listing}
            >
              use this folder
            </button>
          ) : listing?.is_git_repo ? (
            <button className="primary" onClick={() => onPick(listing.path, true)}>
              add this folder
            </button>
          ) : listing ? (
            <span className="dim fp-hint">Not a git repo. Open one, or use “Create new project”.</span>
          ) : (
            <span className="dim fp-hint">Loading…</span>
          )}
        </div>
      </div>
    </div>
  );
}
