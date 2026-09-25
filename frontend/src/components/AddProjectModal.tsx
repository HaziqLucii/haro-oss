import { useEffect, useState } from "react";
import { Star, X } from "./icons";
import { FolderPicker } from "./FolderPicker";

/** Two-layer "Add a project" flow:
 *  Layer 1 — choose: create a brand-new project, or add an existing folder.
 *  Layer 2 — either the folder-tree browser (existing) or a form (new: name +
 *  location + optional git remote).
 *
 *  State is owned here; the parent just handles the terminal actions:
 *  - onPickExisting(path, isGitRepo): add an existing repo (or init a non-git one)
 *  - onCreateNew(path, name, remoteUrl): create + `git init` + link remote. Rejects
 *    with a message on failure so the form can surface it and stay open. */
export function AddProjectModal({
  onPickExisting,
  onCreateNew,
  onClose,
}: {
  onPickExisting: (path: string, isGitRepo: boolean) => void;
  onCreateNew: (path: string, name: string, remoteUrl: string) => Promise<void>;
  onClose: () => void;
}) {
  const [step, setStep] = useState<"choose" | "existing" | "new">("choose");

  // ---- "create new" form state ----
  const [name, setName] = useState("");
  const [location, setLocation] = useState("");
  const [remoteUrl, setRemoteUrl] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [locPicker, setLocPicker] = useState(false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && !busy && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [busy, onClose]);

  // The new project's folder name — sanitized so it's a safe single path segment.
  const folder = name.trim().replace(/[/\\]+/g, "-").replace(/\s+/g, "-");
  const targetPath = location && folder ? `${location.replace(/\/$/, "")}/${folder}` : "";
  const canCreate = !!location && !!folder && !busy;

  const submitNew = async () => {
    if (!canCreate) return;
    setBusy(true);
    setError(null);
    try {
      await onCreateNew(targetPath, name.trim(), remoteUrl.trim());
      // parent closes the modal on success
    } catch (e) {
      setError(e instanceof Error ? e.message : "could not create project");
      setBusy(false);
    }
  };

  // ---- Layer 2: existing-folder browser ----
  if (step === "existing") {
    return (
      <FolderPicker
        variant="project"
        title="Add existing project"
        onBack={() => setStep("choose")}
        onPick={onPickExisting}
        onClose={onClose}
      />
    );
  }

  // ---- Location sub-picker (overlays the new-project form) ----
  if (step === "new" && locPicker) {
    return (
      <FolderPicker
        variant="directory"
        title="Choose location"
        onBack={() => setLocPicker(false)}
        onPick={(path) => {
          setLocation(path);
          setLocPicker(false);
        }}
        onClose={() => setLocPicker(false)}
      />
    );
  }

  // ---- Layer 1: choose ----
  if (step === "choose") {
    return (
      <div className="modal-backdrop" onClick={onClose}>
        <div className="modal ap-choose" onClick={(e) => e.stopPropagation()}>
          <div className="fp-head">
            <span className="fp-title">Add a project</span>
            <button className="ghost" onClick={onClose} aria-label="close">
              <X />
            </button>
          </div>
          <div className="ap-choices">
            <button className="ap-choice" onClick={() => setStep("new")}>
              <span className="ap-choice-ico"><Star /></span>
              <span className="ap-choice-title">Create new project</span>
              <span className="ap-choice-sub dim">
                Make a new folder, <code>git init</code> it, and optionally link a remote.
              </span>
            </button>
            <button className="ap-choice" onClick={() => setStep("existing")}>
              <span className="ap-choice-ico">⑂</span>
              <span className="ap-choice-title">Add existing project</span>
              <span className="ap-choice-sub dim">
                Browse and pick a folder that’s already on disk.
              </span>
            </button>
          </div>
        </div>
      </div>
    );
  }

  // ---- Layer 2: create-new form ----
  return (
    <div className="modal-backdrop" onClick={() => !busy && onClose()}>
      <div className="modal ap-new" onClick={(e) => e.stopPropagation()}>
        <div className="fp-head">
          <span className="fp-title">
            <button
              className="ghost fp-back"
              onClick={() => setStep("choose")}
              title="back"
              aria-label="back"
              disabled={busy}
            >
              ←
            </button>
            Create new project
          </span>
          <button className="ghost" onClick={onClose} aria-label="close" disabled={busy}>
            <X />
          </button>
        </div>

        <div className="ap-form">
          <label className="init-field ap-field">
            <span className="init-label">Project name</span>
            <input
              className="init-input"
              type="text"
              placeholder="my-app"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoFocus
              spellCheck={false}
              autoComplete="off"
            />
          </label>

          <label className="init-field ap-field">
            <span className="init-label">Location</span>
            <div className="ap-location">
              <input
                className="init-input"
                type="text"
                placeholder="pick a folder…"
                value={location}
                onChange={(e) => setLocation(e.target.value)}
                spellCheck={false}
                autoComplete="off"
              />
              <button className="ghost" onClick={() => setLocPicker(true)} disabled={busy}>
                Browse…
              </button>
            </div>
          </label>

          <label className="init-field ap-field">
            <span className="init-label">
              Git remote URL <span className="dim">(optional)</span>
            </span>
            <input
              className="init-input"
              type="text"
              placeholder="https://github.com/you/repo.git"
              value={remoteUrl}
              onChange={(e) => setRemoteUrl(e.target.value)}
              spellCheck={false}
              autoComplete="off"
            />
          </label>

          {targetPath ? (
            <p className="ap-target dim">
              Will create <code>{targetPath}</code>
            </p>
          ) : (
            <p className="ap-target dim">Enter a name and pick a location.</p>
          )}
          {error && <p className="ap-error">{error}</p>}
        </div>

        <div className="fp-foot init-foot">
          <button className="ghost" onClick={() => setStep("choose")} disabled={busy}>
            Back
          </button>
          <button className="primary" onClick={submitNew} disabled={!canCreate}>
            {busy ? (
              <>
                <span className="spinner" aria-hidden /> creating…
              </>
            ) : (
              "Create project"
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
