import { useState } from "react";
import { X } from "./icons";
import type { Workspace } from "../types";

/** Rename a workspace's display name and/or its live git branch
 * (`git branch -m` under the hood — the worktree itself never moves). */
export function RenameWorkspaceModal({
  workspace,
  onSave,
  onClose,
}: {
  workspace: Workspace;
  onSave: (name: string, branch: string) => Promise<void>;
  onClose: () => void;
}) {
  const [name, setName] = useState(workspace.name);
  const [branch, setBranch] = useState(workspace.branch);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const submit = async () => {
    if (!name.trim() || !branch.trim() || saving) return;
    setSaving(true);
    setErr(null);
    try {
      await onSave(name.trim(), branch.trim());
    } catch (e: any) {
      setErr(e.message ?? String(e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal nwm" onClick={(e) => e.stopPropagation()}>
        <div className="fp-head">
          <span className="fp-title">Rename workspace</span>
          <button className="ghost" onClick={onClose} aria-label="close">
            <X />
          </button>
        </div>

        <div className="nwm-body">
          <label className="nwm-field">
            <span className="nwm-k">workspace name</span>
            <input
              value={name}
              autoFocus
              onChange={(e) => setName(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && submit()}
            />
          </label>
          <label className="nwm-field">
            <span className="nwm-k">branch name</span>
            <input
              value={branch}
              onChange={(e) => setBranch(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && submit()}
              placeholder="e.g. feat/multiply-helper"
              spellCheck={false}
            />
          </label>
          <div className="nwm-hint dim">
            Renaming the branch runs <code>git branch -m</code> in this workspace's worktree,
            already-pushed remote branches keep their old name until you push again.
          </div>
          {err && <div className="nwm-hint" style={{ color: "var(--del)" }}>{err}</div>}
        </div>

        <div className="fp-foot">
          <button className="ghost" onClick={onClose}>
            cancel
          </button>
          <button
            className="primary"
            onClick={submit}
            disabled={!name.trim() || !branch.trim() || saving}
          >
            {saving ? "saving…" : "save"}
          </button>
        </div>
      </div>
    </div>
  );
}
