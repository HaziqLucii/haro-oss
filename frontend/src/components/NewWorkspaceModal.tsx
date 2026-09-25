import { useEffect, useState } from "react";
import { X } from "./icons";
import { api } from "../api";

/** Mirror of the backend `git_ops.slugify`: lowercase, non-alphanumerics → "-",
 *  trimmed, with a "task" fallback so an empty name still yields a valid branch. */
function slugify(name: string): string {
  const slug = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug || "task";
}

// Conventional-commit-ish branch prefixes, offered as one-click presets below
// the branch name field so a team doesn't have to type `feat/`/`fix/`/… by hand.
const BRANCH_PREFIXES = ["feat", "fix", "chore", "docs", "refactor", "test"];

/** Swap the leading `<word>/` of a branch name for `prefix/`, keeping whatever
 *  comes after (or falling back to the slugified task name if there's nothing
 *  to keep, e.g. the field is still empty). */
function withPrefix(branch: string, prefix: string, fallback: string): string {
  const slash = branch.indexOf("/");
  const rest = slash === -1 ? branch : branch.slice(slash + 1);
  return `${prefix}/${rest || fallback}`;
}

/** Create a workspace = a fresh git worktree on a new branch. The modal lets you
 *  name the task, choose which branch to seed it from (defaults to the project's
 *  default), and name the new branch. The branch defaults to `feat/<slug>`
 *  and tracks the task name until you edit it yourself — so teams can name
 *  `feat/…`, `fix/…`, `chore/…` branches that push as reviewable PRs. */
export function NewWorkspaceModal({
  projectId,
  projectName,
  initialName = "",
  onCreate,
  onClose,
}: {
  projectId: string;
  projectName: string;
  initialName?: string; // prefilled task name (e.g. seeded from a clicked backlog todo)
  onCreate: (name: string, baseRef: string, branch: string) => void;
  onClose: () => void;
}) {
  const [name, setName] = useState(initialName);
  const [branches, setBranches] = useState<string[]>([]);
  const [baseRef, setBaseRef] = useState("");
  // The branch field auto-follows the task name (as `feat/<slug>`) until the
  // user types into it, at which point we stop overwriting their choice.
  const [branch, setBranch] = useState(`feat/${slugify(initialName)}`);
  const [branchTouched, setBranchTouched] = useState(false);

  useEffect(() => {
    api
      .listBranches(projectId)
      .then((r) => {
        setBranches(r.branches);
        setBaseRef(r.default);
      })
      .catch(() => {});
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [projectId]); // eslint-disable-line react-hooks/exhaustive-deps

  const onName = (v: string) => {
    setName(v);
    if (!branchTouched) setBranch(`feat/${slugify(v)}`);
  };

  const setPrefix = (prefix: string) => {
    setBranchTouched(true);
    setBranch((b) => withPrefix(b, prefix, slugify(name)));
  };

  const submit = () => {
    if (name.trim()) onCreate(name.trim(), baseRef, branch.trim());
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal nwm" onClick={(e) => e.stopPropagation()}>
        <div className="fp-head">
          <span className="fp-title">
            New workspace <span className="dim nwm-proj">in {projectName}</span>
          </span>
          <button className="ghost" onClick={onClose} aria-label="close">
            <X />
          </button>
        </div>

        <div className="nwm-body">
          <label className="nwm-field">
            <span className="nwm-k">task name</span>
            <input
              value={name}
              autoFocus
              onChange={(e) => onName(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && submit()}
              placeholder="e.g. add multiply helper"
            />
          </label>
          <label className="nwm-field">
            <span className="nwm-k">base branch</span>
            <select value={baseRef} onChange={(e) => setBaseRef(e.target.value)}>
              {branches.length === 0 && <option value={baseRef}>{baseRef || "…"}</option>}
              {branches.map((b) => (
                <option key={b} value={b}>
                  {b}
                </option>
              ))}
            </select>
          </label>
          <label className="nwm-field">
            <span className="nwm-k">branch name</span>
            <input
              value={branch}
              onChange={(e) => {
                setBranchTouched(true);
                setBranch(e.target.value);
              }}
              onKeyDown={(e) => e.key === "Enter" && submit()}
              placeholder="e.g. feat/multiply-helper"
              spellCheck={false}
            />
            <div className="nwm-prefixes">
              {BRANCH_PREFIXES.map((p) => (
                <button
                  key={p}
                  type="button"
                  className={"chip" + (branch.startsWith(`${p}/`) ? " chip-on" : "")}
                  onClick={() => setPrefix(p)}
                >
                  {p}/
                </button>
              ))}
            </div>
          </label>
          <div className="nwm-hint dim">
            Creates an isolated worktree on <code>{branch || "a new branch"}</code> off{" "}
            <code>{baseRef || "the base"}</code>.
          </div>
        </div>

        <div className="fp-foot">
          <button className="ghost" onClick={onClose}>
            cancel
          </button>
          <button
            className="primary"
            onClick={submit}
            disabled={!name.trim() || !branch.trim()}
          >
            create workspace
          </button>
        </div>
      </div>
    </div>
  );
}
