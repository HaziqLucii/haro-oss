import { useState } from "react";
import { api } from "../api";
import { GitHubMark, LinkIcon, Pencil, Refresh } from "./icons";
import { RemoteModal } from "./RemoteModal";

// Project-level git remote: a quiet STATUS line, not a git toolbar. The remote is set
// at add-repo time and push/PR/merge route through the per-workspace ship flow —
// there's no project-level push/edit button. So the remote lives in the
// repo's SHARED .git (project-scoped, inherited by every worktree for `gh` PR merges), so
// here we only show `owner/repo`, a quiet Sync (ff-only the base so NEW workspaces branch
// off the latest origin/<default>), and a Gear that folds edit/unlink into RemoteModal.
// Pushing the default branch is intentionally absent — shipping is a workspace action
// (④ ship → integrate.py), never a project-home button. `onChanged` bubbles the new URL
// up so the sidebar badge (and the local-vs-PR merge path) stay in sync without a refetch.
export function ProjectRemote({
  projectId,
  url,
  onChanged,
}: {
  projectId: string;
  url: string | null;
  onChanged: (url: string | null) => void;
}) {
  const [modal, setModal] = useState(false);
  const [sync, setSync] = useState<"idle" | "syncing" | "done" | "error">("idle");
  const [syncMsg, setSyncMsg] = useState<string | null>(null);

  // "Sync" is the former pull: `git pull --ff-only origin <default>`. Its purpose isn't
  // the local checkout — it's freshening the base so create_workspace branches off the
  // latest origin/<default> instead of a drifted local tip. Always available (we have no
  // ahead/behind count without a backend fetch); a future `GET /remote` could return one
  // to gate this on "actually behind" and hide it when up to date.
  const doSync = async () => {
    setSync("syncing");
    setSyncMsg(null);
    try {
      const res = await api.pullProject(projectId);
      setSync("done");
      setSyncMsg(`synced ${res.branch}`);
    } catch (e) {
      setSync("error");
      setSyncMsg((e as Error)?.message ?? "sync failed");
    }
  };

  // The modal owns its own busy/error state; it throws on failure so the modal can
  // surface the message inline and stay open. On success it resolves + we close.
  const save = async (next: string) => {
    const res = await api.setRemote(projectId, next);
    onChanged(res.url);
    setModal(false);
  };
  const unlink = async () => {
    const res = await api.setRemote(projectId, "");
    onChanged(res.url);
    setModal(false);
  };

  const isGithub = !!url && url.includes("github.com");

  return (
    <div className="proj-remote">
      <span className="proj-remote-icon">{isGithub ? <GitHubMark /> : <LinkIcon />}</span>
      {url ? (
        <>
          <span className="proj-remote-url" title={url}>
            {shorten(url)}
          </span>
          <button
            className="proj-remote-key pull"
            onClick={doSync}
            disabled={sync === "syncing"}
            title="Fast-forward the base branch from origin so new workspaces start from the latest tip"
          >
            <Refresh size={12} />
            {sync === "syncing" ? "syncing…" : "sync"}
          </button>
          <button
            className="proj-remote-key"
            onClick={() => setModal(true)}
            title="Edit or unlink the remote URL"
          >
            <Pencil size={12} />
            edit
          </button>
          {syncMsg && (
            <span className={sync === "error" ? "proj-remote-err" : "dim proj-remote-hint"}>
              {syncMsg}
            </span>
          )}
        </>
      ) : (
        <>
          <span className="dim proj-remote-hint">Not linked. Merges stay local.</span>
          <button className="proj-remote-key" onClick={() => setModal(true)}>
            <LinkIcon />
            link remote
          </button>
        </>
      )}

      {modal && (
        <RemoteModal
          currentUrl={url}
          onSave={save}
          onUnlink={unlink}
          onClose={() => setModal(false)}
        />
      )}
    </div>
  );
}

// Collapse a clone URL to owner/repo for display (title carries the full URL).
function shorten(url: string): string {
  const m = url.match(/[/:]([^/:]+\/[^/]+?)(?:\.git)?\/?$/);
  return m ? m[1] : url;
}
