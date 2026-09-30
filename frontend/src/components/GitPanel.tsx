import { useCallback, useEffect, useRef, useState } from "react";
import { Check, X } from "./icons";
import { api } from "../api";
import type {
  DiffResponse,
  GitCommit,
  GitStatusResponse,
  PrStatusResponse,
  TrustFix,
  TrustReport,
  VerifiedHunksResponse,
  ReceiptResponse,
} from "../types";
import { Chevron } from "./Chevron";
import { DiffView } from "./DiffView";
import { TrustChecklist, trustUnmet } from "./TrustChecklist";
import { ReceiptPanel } from "./ReceiptPanel";

/** GitHub Octicons (16px), inline so the ship view reads like a PR page without
 *  pulling in an icon dependency. Paths lifted verbatim from @primer/octicons. */
const OCTICON: Record<string, string> = {
  "git-pull-request":
    "M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z",
  "git-merge":
    "M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0-1.5 0 .75.75 0 0 0 1.5 0Z",
  "git-branch":
    "M9.5 3.25a2.25 2.25 0 1 1 3 2.122V6A2.5 2.5 0 0 1 10 8.5H6a1 1 0 0 0-1 1v1.128a2.251 2.251 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.5 0v1.836A2.493 2.493 0 0 1 6 7h4a1 1 0 0 0 1-1v-.628A2.25 2.25 0 0 1 9.5 3.25ZM4.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5ZM3.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Zm8.25-.75a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z",
  "git-commit":
    "M11.93 8.5a4.002 4.002 0 0 1-7.86 0H.75a.75.75 0 0 1 0-1.5h3.32a4.002 4.002 0 0 1 7.86 0h3.32a.75.75 0 0 1 0 1.5Zm-1.43-.75a2.5 2.5 0 1 0-5 0 2.5 2.5 0 0 0 5 0Z",
  "check-circle":
    "M8 16A8 8 0 1 1 8 0a8 8 0 0 1 0 16Zm3.78-9.72a.751.751 0 0 0-.018-1.042.751.751 0 0 0-1.042-.018L6.75 9.19 5.28 7.72a.751.751 0 0 0-1.042.018.751.751 0 0 0-.018 1.042l2 2a.75.75 0 0 0 1.06 0Z",
  "x-circle":
    "M2.343 13.657A8 8 0 1 1 13.658 2.343 8 8 0 0 1 2.343 13.657ZM6.03 4.97a.751.751 0 0 0-1.042.018.751.751 0 0 0-.018 1.042L6.94 8 4.97 9.97a.749.749 0 0 0 .326 1.275.749.749 0 0 0 .734-.215L8 9.06l1.97 1.97a.749.749 0 0 0 1.275-.326.749.749 0 0 0-.215-.734L9.06 8l1.97-1.97a.749.749 0 0 0-.326-1.275.749.749 0 0 0-.734.215L8 6.94Z",
  dot: "M8 4a4 4 0 1 1 0 8 4 4 0 0 1 0-8Z",
  alert:
    "M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z",
  sparkle:
    "M8 1c.35 3.1 2.9 5.65 6 6-3.1.35-5.65 2.9-6 6-.35-3.1-2.9-5.65-6-6 3.1-.35 5.65-2.9 6-6Z",
  sync: "M1.705 8.005a.75.75 0 0 1 .834.656 5.5 5.5 0 0 0 9.592 2.97l-1.204-1.204a.25.25 0 0 1 .177-.427h3.646a.25.25 0 0 1 .25.25v3.646a.25.25 0 0 1-.427.177l-1.38-1.38A7.002 7.002 0 0 1 1.05 8.84a.75.75 0 0 1 .656-.834ZM8 2.5a5.487 5.487 0 0 0-4.131 1.869l1.204 1.204A.25.25 0 0 1 4.896 6H1.25A.25.25 0 0 1 1 5.75V2.104a.25.25 0 0 1 .427-.177l1.38 1.38A7.002 7.002 0 0 1 14.95 7.16a.75.75 0 0 1-1.49.178A5.501 5.501 0 0 0 8 2.5Z",
  diff:
    "M8.75 1.75V5H12a.75.75 0 0 1 0 1.5H8.75v3.25a.75.75 0 0 1-1.5 0V6.5H4A.75.75 0 0 1 4 5h3.25V1.75a.75.75 0 0 1 1.5 0ZM4 13a.75.75 0 0 1 .75-.75h6.5a.75.75 0 0 1 0 1.5h-6.5A.75.75 0 0 1 4 13Z",
};

function Octicon({ name, className }: { name: string; className?: string }) {
  return (
    <svg
      className={"octicon " + (className ?? "")}
      viewBox="0 0 16 16"
      width="16"
      height="16"
      fill="currentColor"
      aria-hidden
    >
      <path d={OCTICON[name]} />
    </svg>
  );
}

/** GitHub's 5-square diffstat proportion bar (+additions −deletions ▪▪▪▫▫).
 *  Squares are split green/red by ratio, guaranteeing at least one of each
 *  present color, capped at 5 — the exact heuristic GitHub uses in its PR
 *  header. Reads as "how much of this diff is add vs delete" at a glance. */
function DiffStat({ additions, deletions }: { additions: number; deletions: number }) {
  const total = additions + deletions;
  let green = total ? Math.round((additions / total) * 5) : 0;
  let red = total ? Math.round((deletions / total) * 5) : 0;
  if (additions > 0 && green === 0) green = 1;
  if (deletions > 0 && red === 0) red = 1;
  while (green + red > 5) green > red ? green-- : red--;
  const neutral = 5 - green - red;
  const squares = [
    ...Array(green).fill("add"),
    ...Array(red).fill("del"),
    ...Array(neutral).fill("neutral"),
  ];
  return (
    <span className="gh-diffstat" title={`+${additions} −${deletions}`}>
      <span className="gh-diff-add">+{additions}</span>
      <span className="gh-diff-del">−{deletions}</span>
      <span className="gh-diff-squares" aria-hidden>
        {squares.map((k, i) => (
          <span key={i} className={"gh-diff-sq " + k} />
        ))}
      </span>
    </span>
  );
}

/** The "ship" view: the gated *merge* (push → PR → merge), plus branch state,
 *  checkpoint commits, the full file diff, history, and PR/CI status — so the
 *  everyday git & GitHub round-trips never mean leaving haro. Merge lives here
 *  (step ④ ship), not in the gate (step ③) — the gate only *verifies*; shipping
 *  is the act that follows it, alongside the commit box. The "Files changed"
 *  diff also lives here (promoted out of the gate) — the ship view is where you
 *  review the branch, exactly like a PR's Files-changed tab.
 *
 *  Skinned to read like opening a pull request on github.com: PR title + state
 *  pill, the "wants to merge N commits into base from head" attribution line
 *  with the diffstat + proportion squares, the signature mergeability banner,
 *  and a commit timeline — all in haro's own warm-dark theme + green-gate
 *  palette (not GitHub's grays). No tab bar: unlike github.com every section is
 *  a distinct panel, here they stack in one scroll, so tabs would only be dead
 *  chrome. */
export function GitPanel({
  workspaceId,
  onCommitted,
  gateStatus,
  onMerge,
  merging = false,
  onContinue,
  continuing = false,
  priorPrs = [],
  seedKey,
  diff = null,
  onRefreshDiff,
  onAddComment,
  onResolveConflict,
  trust = null,
  onTrustFix,
  verified = null,
  onReviewResidue,
  receipt = null,
}: {
  workspaceId: string;
  onCommitted?: () => void;
  gateStatus: string;
  onMerge: () => void;
  merging?: boolean;
  onContinue?: () => void;
  continuing?: boolean;
  priorPrs?: number[];
  // Autonomy-ladder report for this workspace (backlog/autonomy-ladder.md). Its only
  // home is ④ ship now (notes/verify-redesign-plan.md moved it out of ③ verify's old
  // "trust" tab); it renders under the merge-blocked banner here. Null / disabled ⇒
  // project isn't on the ladder, checklist hidden.
  trust?: TrustReport | null;
  // Deep-link an unmet trust row to its fix — hops to the ③ gate step (where the guard
  // toggles, full-suite run, and regression ribbon live). Wired by the parent.
  onTrustFix?: (fix: TrustFix) => void;
  // "issue:<n>" when this workspace was seeded from a GitHub issue — seeds the commit
  // box with "Closes #<n>" so the merged PR auto-closes the issue.
  seedKey?: string;
  diff?: DiffResponse | null;
  onRefreshDiff?: () => void;
  onAddComment?: (target: string, context: string | null) => void;
  // Hand a ready-made "resolve these conflicts" prompt back to the agent composer
  // (step ①). The parent prefills it and switches views; the dev runs it himself.
  onResolveConflict?: (context: string) => void;
  // Verified Hunks (backlog/verified-hunks.md §3): the last green gate's per-line proof for
  // the branch-vs-base diff. Null ⇒ the diff renders exactly as it always did.
  verified?: VerifiedHunksResponse | null;
  // Batch the never-executed files into the agent composer.
  onReviewResidue?: () => void;
  // Gate Receipt (usp-critique-plan.md idea 1): the exportable evidence packet, fetched
  // and refreshed by the parent alongside `verified` on every gate verdict.
  receipt?: ReceiptResponse | null;
}) {
  const [status, setStatus] = useState<GitStatusResponse | null>(null);
  const [commits, setCommits] = useState<GitCommit[]>([]);
  const [pr, setPr] = useState<PrStatusResponse | null>(null);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [creatingPr, setCreatingPr] = useState(false);
  const [shipNote, setShipNote] = useState<string | null>(null);
  // Trust checklist visibility (notes/verify-redesign-plan.md): shows whenever the
  // ladder is enabled, not only while merge-blocked — a green-but-locked streak
  // ("2 of 3") otherwise has no home once ③ verify stopped rendering it. Open by
  // default while it's the reason the merge is blocked; collapsed behind a Chevron
  // once green, so a satisfied ladder doesn't permanently take up ship's vertical
  // space. The matching effect near `blockedByGate` keeps this in sync on a LIVE
  // transition; the lazy initializer here approximates the same value for the first
  // render (`status`/`pr` are still null pre-fetch either way, so `conflicting`/
  // `needsCommit` are false in both computations) — without it, this would always
  // start closed under a static render, where effects never run.
  const [trustOpen, setTrustOpen] = useState(
    () => gateStatus !== "gate_green" && gateStatus !== "merged" && !merging,
  );

  // Commit-by-commit review filter: step through the branch one commit at a
  // time instead of the full squashed working-vs-base diff. `null` means "full
  // diff" (the default `diff` prop); a sha fetches that commit's own patch.
  const [selectedCommit, setSelectedCommit] = useState<string | null>(null);
  const [commitDiff, setCommitDiff] = useState<DiffResponse | null>(null);
  const [commitDiffLoading, setCommitDiffLoading] = useState(false);

  useEffect(() => {
    setSelectedCommit(null);
  }, [workspaceId]);

  useEffect(() => {
    if (!selectedCommit) {
      setCommitDiff(null);
      return;
    }
    let cancelled = false;
    setCommitDiffLoading(true);
    api
      .getDiff(workspaceId, selectedCommit)
      .then((d) => !cancelled && setCommitDiff(d))
      .catch(() => !cancelled && setCommitDiff(null))
      .finally(() => !cancelled && setCommitDiffLoading(false));
    return () => {
      cancelled = true;
    };
  }, [workspaceId, selectedCommit]);

  const selectedIdx = selectedCommit ? commits.findIndex((c) => c.sha === selectedCommit) : -1;
  const activeDiff = selectedCommit ? commitDiff : diff;

  // Auto-grow the commit box to fit its content (multi-line messages stay fully
  // visible instead of scrolling inside a fixed 2-row box). Manual resize still
  // works via CSS `resize: vertical`; we only push the *minimum* height up.
  const msgRef = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    const ta = msgRef.current;
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = `${ta.scrollHeight}px`;
  }, [message]);

  // Thread the commit body — which `gh pr create --fill` turns into the PR body — with
  // the references the merge should carry: "Follow-up to #N." for a continued
  // workspace, and "Closes #N" when it was seeded from a GitHub issue (merging then
  // auto-closes the issue → the next backlog poll flips its row to ✔). Follow-up is
  // seeded first so the backend's follow-up dedupe (startswith) still matches; both
  // lines are guarded server-side so re-submitting never doubles them. Only seeds an
  // empty box, so it never clobbers what the user is typing.
  const followupRef = priorPrs.length
    ? `Follow-up to ${priorPrs.map((n) => `#${n}`).join(" / ")}.`
    : "";
  const issueNumber = seedKey?.startsWith("issue:")
    ? seedKey.slice("issue:".length)
    : "";
  const closesRef = /^\d+$/.test(issueNumber) ? `Closes #${issueNumber}` : "";
  const seedRefs = [followupRef, closesRef].filter(Boolean).join("\n");
  useEffect(() => {
    if (seedRefs) setMessage((m) => (m === "" ? seedRefs + "\n\n" : m));
  }, [seedRefs]);

  const refresh = useCallback(() => {
    return Promise.all([
      api.gitStatus(workspaceId).then(setStatus).catch(() => setStatus(null)),
      api.gitLog(workspaceId).then((r) => setCommits(r.commits)).catch(() => setCommits([])),
      api.gitPr(workspaceId).then(setPr).catch(() => setPr(null)),
    ]);
  }, [workspaceId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // When the workspace status changes under us — a gate flip, or a merge the backend
  // detected (the git/pr reconcile or the background merge poll flips status →
  // "merged" and pushes it on the live feed) — pull fresh git/PR/CI state so the
  // ship panel reflects it without the ⟳ button.
  const lastStatus = useRef(gateStatus);
  useEffect(() => {
    if (lastStatus.current !== gateStatus) {
      lastStatus.current = gateStatus;
      refresh();
    }
  }, [gateStatus, refresh]);

  const commit = async () => {
    const m = message.trim();
    if (!m || busy) return;
    setBusy(true);
    setNote(null);
    try {
      const r = await api.gitCommit(workspaceId, m);
      if (r.nothing_to_commit) {
        setNote("nothing to commit");
      } else {
        setNote(`committed ${r.committed?.slice(0, 7)}`);
        setMessage("");
        onCommitted?.();
      }
      refresh();
    } catch (e) {
      setNote(e instanceof Error ? e.message : "commit failed");
    } finally {
      setBusy(false);
    }
  };

  const createPr = async () => {
    if (creatingPr) return;
    setCreatingPr(true);
    setShipNote(null);
    try {
      const r = await api.createPr(workspaceId);
      setShipNote(r.already_exists ? "PR already open ↗" : "PR opened ↗");
      // Await the refetch so `pr` (and thus `prOpen`) is up to date before we drop
      // the loading state — otherwise the button flickers back to "Create pull
      // request" for one render until gitPr resolves, letting an eager click
      // re-fire the create.
      await refresh();
    } catch (e) {
      setShipNote(e instanceof Error ? e.message : "create PR failed");
    } finally {
      setCreatingPr(false);
    }
  };

  const green = gateStatus === "gate_green";
  // Reconcile against the *live* PR fetch (on mount and via the header button), not
  // just our stored gateStatus: a PR merged directly on GitHub leaves gateStatus
  // stale until the reconcile lands, which showed a "Open"/"wants to merge" header
  // over a PR section reading MERGED. But read the server's `workspace_merged` — the
  // verdict `GET /git/pr` just reconciled — NOT `state === "MERGED"`: a branch name
  // stays MERGED on GitHub forever, so the SHA-blind version painted this step purple
  // for a branch that had moved on, while the sidebar dot, the bento border and
  // "Continue on a new branch" (all keyed on workspace.status) correctly said green.
  const merged = gateStatus === "merged" || pr?.workspace_merged === true;
  // Commit-first discipline: shipping (PR or merge) is refused while the worktree
  // is dirty, so nothing lands without an explicit, user-authored commit.
  // No worktree on disk (archived/merged, or removed out of band). Every number below is
  // unknown rather than zero, and every git action will refuse, so the panel says so instead
  // of rendering a commit box that cannot work. Opening such a workspace used to 500.
  const worktreeGone = status?.worktree_missing === true;
  const dirty = status?.dirty ?? 0;
  const ahead = status?.ahead ?? 0;
  const behind = status?.behind ?? 0;
  const needsCommit = dirty > 0;
  const nothingToShip = !needsCommit && ahead === 0;
  // `gh` reports the branch's mergeability against its base — "CONFLICTING" means
  // the base moved on in a way git can't auto-merge. Only trust the explicit
  // conflicting verdict (mergeable is null/"UNKNOWN" while GitHub is still computing).
  const conflicting = pr?.mergeable === "CONFLICTING";
  // The green light for the ship row: gate green, tree clean, real work to ship,
  // and no base conflicts (a conflicting branch can't merge until it's rebased/merged).
  const canShip = green && !needsCommit && ahead > 0 && !merged && !conflicting && !worktreeGone;
  // PR actions only make sense with a remote + gh available.
  const prSupported = !!pr?.supported;
  const prOpen = !!(pr?.exists && pr.url && pr.state === "OPEN");
  // [workflow] merge_mode picks which ship buttons show. A no-remote repo can't
  // open a PR, so it always falls back to Merge no matter the mode.
  const mode = status?.merge_mode ?? "both";
  const showPr = prSupported && mode !== "merge";
  const showMerge = mode !== "pr" || !prSupported;

  const head = status?.branch ?? "…";
  const base = status?.base_ref ?? "base";
  const nCommits = (n: number) => `${n} commit${n === 1 ? "" : "s"}`;

  const shipCopy = merged
    ? "This branch has been merged into the base."
    : merging
    ? "Pushing, opening the PR, and merging…"
    : conflicting
    ? `This branch has merge conflicts with ${base} that must be resolved before it can be merged.`
    : needsCommit
    ? `${dirty} uncommitted change${dirty === 1 ? "" : "s"}. Commit them before you can ship.`
    : !green
    ? "The test gate must be green before this branch can be merged."
    : nothingToShip
    ? "This branch is already up to date with the base."
    : showPr && !showMerge
    ? "This branch has no conflicts. Open a pull request for review."
    : showPr && showMerge
    ? "This branch has no conflicts. Open a pull request, or merge directly."
    : "This branch has no conflicts. Merging can be performed automatically.";

  // GitHub-style merge box: an icon + tone that reads at a glance like a PR's
  // "mergeability" banner. Green = ready, purple = merged, amber = blocked.
  const tone = merged ? "merged" : merging ? "pending" : conflicting ? "blocked" : canShip ? "clean" : needsCommit ? "blocked" : !green ? "blocked" : "neutral";
  const headline = merged
    ? "Pull request successfully merged and closed"
    : merging
    ? "Merging…"
    : conflicting
    ? "This branch has conflicts that must be resolved"
    : needsCommit
    ? "Commit your changes to continue"
    : !green
    ? "Merging is blocked"
    : nothingToShip
    ? "Nothing to merge"
    : "Ready to merge";
  const toneIcon =
    tone === "merged" ? "git-merge" : tone === "clean" ? "check-circle" : conflicting ? "alert" : tone === "blocked" ? "x-circle" : "dot";

  // The "merge blocked: gate is not green" case — the exact 409 the backend raises on
  // a manual merge. When it fires and the project is on the autonomy ladder, we render
  // the trust checklist (its only home, since ③ verify moved it out) so a blocked
  // *manual* merge and a locked *auto*-merge read as one story (backlog/autonomy-ladder.md).
  const blockedByGate = !merged && !merging && !conflicting && !needsCommit && !green;

  // Default `trustOpen` to the blocked state on mount and on every real transition
  // (not on every render — the effect only re-fires when `blockedByGate` itself
  // changes), so a fresh merge-blocked workspace opens the checklist and a gate
  // going green collapses it, while leaving room for the viewer to override either
  // way via the Chevron in between.
  useEffect(() => {
    setTrustOpen(blockedByGate);
  }, [blockedByGate]);

  // PR-header state pill: mirrors GitHub's Open / Merged / Draft badge.
  const badge = merged
    ? { label: "Merged", tone: "merged", icon: "git-merge" }
    : prOpen && pr?.draft
    ? { label: "Draft", tone: "neutral", icon: "git-pull-request" }
    : prOpen
    ? { label: "Open", tone: "open", icon: "git-pull-request" }
    : { label: "Unopened", tone: "neutral", icon: "git-pull-request" };

  // The attribution verb tracks GitHub's own state-dependent phrasing: a merged
  // PR reads "merged N commits into base from head"; an open one "wants to merge
  // …"; an unopened branch the imperative "Merge …".
  const attribVerb = merged ? "merged" : prOpen ? "wants to merge" : "Merge";
  const showDiffStat = !!pr?.exists && (pr.additions > 0 || pr.deletions > 0);

  // The ready-made task we hand the agent composer when the dev asks for help with
  // a conflict. It's a concrete git recipe (fetch → merge → resolve → stage) so the
  // agent can act immediately; the dev reviews/edits it and runs it himself.
  const conflictPrompt = () => {
    const ref = pr?.number ? `#${pr.number}` : `\`${head}\``;
    return [
      `The pull request ${ref} (\`${head}\` → \`${base}\`) has merge conflicts with its base branch and can't be merged until they're resolved.`,
      ``,
      `Please resolve them in this worktree:`,
      `1. Fetch the latest base: \`git fetch origin\``,
      `2. Merge it into this branch: \`git merge ${base}\``,
      `3. Resolve every conflicted file: keep both sides' intent; where they overlap, integrate them so no change is lost. Remove all conflict markers.`,
      `4. Stage the resolved files (\`git add\`) and make sure the test gate passes.`,
      ``,
      `Leave the merge staged, don't commit or push, so I can review the resolution before shipping.`,
    ].join("\n");
  };

  return (
    <div className="git gh">
      {/* No worktree on disk: archived or merged, or removed out of band. Said outright at
          the top, because everything below reads off numbers git could not produce — and
          ahead/behind/dirty of 0 is indistinguishable from a clean branch. Opening one of
          these used to return a 500 from /git/pr. */}
      {worktreeGone && (
        <div className="gh-no-worktree">
          <Octicon name="alert" />
          <span>
            <strong>No worktree on disk.</strong> This workspace was archived or merged, so its
            branch state can’t be read and git actions aren’t available. The branch itself still
            exists in the repo.
          </span>
        </div>
      )}
      {/* PR-style header — a large title + the "state · attribution" line with
          the diffstat, exactly the shape github.com opens a pull request with. */}
      <div className="gh-header">
        <div className="gh-title-row">
          <h2 className="gh-title">
            {pr?.exists && pr.title ? pr.title : status?.branch ?? "ship"}
            {pr?.exists && pr.number ? <span className="gh-num">#{pr.number}</span> : null}
          </h2>
          <button className="gh-refresh" onClick={refresh} title="Refresh">
            <Octicon name="sync" />
          </button>
        </div>
        <div className="gh-attribution">
          <span className={"gh-badge " + badge.tone}>
            <Octicon name={badge.icon} />
            {badge.label}
          </span>
          <span className="gh-attr-text">
            {attribVerb} <strong>{nCommits(ahead)}</strong> into{" "}
            <code className="gh-ref base">{base}</code> from{" "}
            <code className="gh-ref head">{head}</code>
          </span>
          <span className="gh-ab">
            {behind > 0 && <span className="gh-behind">{behind} behind</span>}
            {ahead === 0 && behind === 0 && <span className="dim">up to date</span>}
          </span>
          {showDiffStat && <DiffStat additions={pr!.additions} deletions={pr!.deletions} />}
        </div>
      </div>

      {/* The merge box — GitHub's signature mergeability banner. Order mirrors a
          team flow: request review (Create PR / open it) first; Merge is the
          last, most-privileged step. All three are refused until the work is
          committed AND the gate is green (canShip). */}
      <div className={"gh-merge-box tone-" + tone}>
        <div className="gh-merge-body">
          <span className="gh-merge-icon">
            <Octicon name={toneIcon} className="gh-merge-glyph" />
          </span>
          <div className="gh-merge-copy">
            <strong className="gh-merge-headline">{headline}</strong>
            <span className="gh-merge-sub">{shipCopy}</span>
            {shipNote && <span className="gh-merge-note">{shipNote}</span>}
          </div>
          <div className="gh-merge-actions">
            {/* Conflicts → hand the fix to the agent. Prominent because the ship
                buttons are disabled while conflicting; this is the way forward.
                It doesn't act — it seeds step ① with a prompt the dev runs. */}
            {conflicting && onResolveConflict && (
              <button
                className="gh-btn gh-btn-ai"
                onClick={() => onResolveConflict(conflictPrompt())}
                title="send a resolve-conflicts prompt to the agent (you run it)"
              >
                <Octicon name="sparkle" /> Help resolve with AI
              </button>
            )}
            {/* Create PR — the team/junior path: request review without merging. */}
            {showPr && !prOpen && (
              <button
                className="gh-btn"
                onClick={createPr}
                disabled={!canShip || creatingPr || merging}
                title={
                  canShip
                    ? "push & open a pull request (no merge)"
                    : needsCommit
                    ? "commit your changes first"
                    : !green
                    ? "blocked until the gate is green"
                    : "no changes to open a PR for"
                }
              >
                {creatingPr ? (
                  <>
                    <span className="spinner" aria-hidden /> Opening…
                  </>
                ) : (
                  <>
                    <Octicon name="git-pull-request" /> Create pull request
                  </>
                )}
              </button>
            )}
            {/* Open PR — appears once a PR exists; forwards to the PR page. */}
            {showPr && prOpen && (
              <a
                className="gh-btn"
                href={pr!.url!}
                target="_blank"
                rel="noreferrer"
                title="open the pull request on GitHub"
              >
                <Octicon name="git-pull-request" /> View on GitHub ↗
              </a>
            )}
            {/* Merge — the last, most-privileged option. On a protected repo this
                surfaces a friendly "create a PR instead" error (see integrate.py).
                Hidden entirely when the project is PR-only (merge_mode = "pr"). */}
            {showMerge && (
              <button
                className={"gh-btn gh-merge-btn" + (merged ? " merged" : canShip ? " btn-gate" : "")}
                onClick={onMerge}
                disabled={merged || !canShip || merging}
                title={
                  merged
                    ? "merged · archive it when you're done"
                    : merging
                    ? "merging… (push → PR → merge)"
                    : canShip
                    ? "merge this workspace (push → PR → merge)"
                    : needsCommit
                    ? "commit your changes first"
                    : !green
                    ? "merge blocked until the gate is green"
                    : "no changes to merge"
                }
              >
                {merged ? (
                  <>
                    <Octicon name="git-merge" /> Merged
                  </>
                ) : merging ? (
                  <>
                    <span className="spinner" aria-hidden /> Merging…
                  </>
                ) : (
                  <>
                    <Octicon name="git-merge" /> Merge pull request
                  </>
                )}
              </button>
            )}
            {/* Continue on a new branch — the post-merge "keep going" path: same
                worktree + chat, a fresh version branch off the updated base, and the
                next PR threaded as a follow-up. Pairs with Archive (delete workspace). */}
            {merged && onContinue && (
              <button
                className="gh-btn primary"
                onClick={onContinue}
                disabled={continuing}
                title="continue on a new branch off the updated base, keeping this chat"
              >
                {continuing ? (
                  <>
                    <span className="spinner" aria-hidden /> Continuing…
                  </>
                ) : (
                  <>
                    <Octicon name="git-branch" /> Continue on a new branch
                  </>
                )}
              </button>
            )}
          </div>
        </div>
      </div>

      {/* The trust checklist's only home now (notes/verify-redesign-plan.md moved it
          out of ③ verify's old "trust" tab) — shown whenever the ladder is enabled,
          not only while merge-blocked: a green-but-locked streak ("2 of 3") needs
          somewhere to live too, or it's invisible the moment the gate goes green.
          Open while it's the reason the merge is blocked; collapsed behind a Chevron
          once green, so a satisfied ladder doesn't take up permanent space. Collapsed,
          it's a one-line summary; expanded, TrustChecklist renders its own head (title
          + verdict), so the two never show "trust checklist" twice at once. */}
      {trust?.enabled && !merged && (
        <div className="gh-trust">
          {trustOpen ? (
            <>
              <button
                className="gh-trust-collapse"
                onClick={() => setTrustOpen(false)}
                aria-label="collapse trust checklist"
                aria-expanded="true"
              >
                <Chevron open />
              </button>
              <TrustChecklist trust={trust} onFix={(fix) => onTrustFix?.(fix)} />
            </>
          ) : (
            <button className="gh-trust-head" onClick={() => setTrustOpen(true)} aria-expanded="false">
              <Chevron open={false} />
              <span>trust checklist</span>
              <span className="dim">
                {trust.armed
                  ? "armed"
                  : trust.met
                    ? "all conditions met"
                    : `${trustUnmet(trust)} unmet`}
              </span>
            </button>
          )}
        </div>
      )}

      {/* Gate Receipt (usp-critique-plan.md idea 1) — the exportable evidence packet.
          Self-hides when there's no gate run yet; refetches whenever the gate verdict
          or the merge state changes. */}
      <ReceiptPanel workspaceId={workspaceId} data={receipt} hasRemote={prSupported} />

      {/* Commit box — checkpoint the worktree without merging */}
      <div className="git-commit">
        <div className="gh-sec-label">
          <Octicon name="git-commit" /> Commit changes
        </div>
        {status && status.dirty > 0 ? (
          // Dirty tree: the editable commit form. Once committed (or when the
          // tree was already clean) the field is useless (an empty box you
          // can't type into reads as broken chrome), so we swap it for a plain
          // remark below rather than leaving a disabled input on screen.
          <>
            <textarea
              ref={msgRef}
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              onKeyDown={(e) => {
                // stopPropagation so the app-level window ⌘+Enter listener (App.tsx)
                // doesn't also fire submitTask when committing from this field.
                if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
                  e.stopPropagation();
                  commit();
                }
              }}
              placeholder={`Commit ${status.dirty} changed file${status.dirty === 1 ? "" : "s"}…  (⌘↵)`}
              rows={2}
              disabled={busy}
            />
            <div className="git-commit-actions">
              {note && <span className="dim git-note">{note}</span>}
              <button
                className="primary"
                onClick={commit}
                disabled={busy || !message.trim()}
              >
                commit
              </button>
            </div>
          </>
        ) : (
          // Clean tree: nothing to commit, or we just did. `note` carries the
          // fresh "committed 1a2b3c4" confirmation from commit() so it survives
          // the form being replaced.
          <div className="git-commit-empty">
            <Octicon name="check-circle" />
            <span>
              {note
                ? note
                : ahead > 0
                  ? "All changes committed. Ready to ship below."
                  : "Nothing to commit. Working tree is clean."}
            </span>
          </div>
        )}
      </div>

      {/* Files changed — the full branch-vs-base diff, GitHub's PR "Files
          changed" tab. The per-file collapsible unified diff (promoted here out
          of the gate step, which now only *verifies*). Click an add/del line to
          send a review comment back to the agent as a follow-up task. */}
      <div className="git-section git-diff-section">
        <div className="git-sec-head">
          <span className="gh-sec-title rule-title">
            <Octicon name="diff" /> Files changed
            {activeDiff && activeDiff.files_changed > 0 && (
              <span className="gh-counter">{activeDiff.files_changed}</span>
            )}
          </span>
          <div className="git-diff-controls">
            {selectedCommit && (
              <span className="diff-commit-nav">
                <button
                  className="link-btn diff-commit-step"
                  disabled={selectedIdx < 0 || selectedIdx >= commits.length - 1}
                  onClick={() => setSelectedCommit(commits[selectedIdx + 1].sha)}
                  title="older commit"
                >
                  ‹
                </button>
                <span className="diff-commit-chip" title={commits[selectedIdx]?.subject}>
                  viewing <code>{selectedCommit.slice(0, 7)}</code>
                  <button
                    className="link-btn"
                    onClick={() => setSelectedCommit(null)}
                    title="back to the full branch diff"
                  >
                    ✕
                  </button>
                </span>
                <button
                  className="link-btn diff-commit-step"
                  disabled={selectedIdx <= 0}
                  onClick={() => setSelectedCommit(commits[selectedIdx - 1].sha)}
                  title="newer commit"
                >
                  ›
                </button>
              </span>
            )}
            {onRefreshDiff && !selectedCommit && (
              <button className="gh-refresh" onClick={onRefreshDiff} title="Refresh the diff">
                <Octicon name="sync" />
              </button>
            )}
          </div>
        </div>
        {commitDiffLoading ? (
          <div className="diff empty">Loading commit diff…</div>
        ) : (
          // The proof describes the branch-vs-base diff and nothing else: one commit's own
          // patch has different line numbers, so annotating it would attribute hits to the
          // wrong lines — the one mistake this feature cannot make.
          <DiffView
            diff={activeDiff}
            onAddComment={onAddComment}
            verified={selectedCommit ? null : verified}
            onReviewResidue={selectedCommit ? undefined : onReviewResidue}
          />
        )}
      </div>

      {/* PR + CI */}
      <div className="git-section">
        <div className="git-sec-head">
          <span className="gh-sec-title rule-title">
            <Octicon name="git-pull-request" /> Pull request
          </span>
          {pr?.exists && pr.url && (
            <a className="app-link" href={pr.url} target="_blank" rel="noreferrer">
              #{pr.number} ↗
            </a>
          )}
        </div>
        {!pr ? (
          <div className="side-empty dim">…</div>
        ) : !pr.supported ? (
          <div className="side-empty dim">{pr.reason ?? "PRs unavailable"}</div>
        ) : !pr.exists ? (
          <div className="side-empty dim">
            No PR yet. “create PR” (or merge) opens one when the gate is green.
            {pr.reason && <div className="git-warn">{pr.reason}</div>}
          </div>
        ) : (
          <div className="git-pr">
            <div className="git-pr-row">
              <span className={"git-state " + (pr.state ?? "").toLowerCase()}>
                {pr.draft ? "draft" : (pr.state ?? "").toLowerCase()}
              </span>
              <span className="git-pr-title">{pr.title}</span>
            </div>
            <div className="git-pr-meta">
              {pr.review_decision && (
                <span className={"git-chip rev-" + pr.review_decision.toLowerCase()}>
                  {pr.review_decision.replace(/_/g, " ").toLowerCase()}
                </span>
              )}
              {pr.comments > 0 && <span className="git-chip">💬 {pr.comments}</span>}
              <span className="git-chip diffstat">
                <span className="add">+{pr.additions}</span> <span className="del">−{pr.deletions}</span>
              </span>
            </div>
            {/* CI checks */}
            {pr.checks.length > 0 ? (
              <div className="git-checks">
                <div className="git-checks-sum">
                  {pr.checks_passed > 0 && <span className="ck pass"><Check size={11} /> {pr.checks_passed}</span>}
                  {pr.checks_failed > 0 && <span className="ck fail"><X size={11} /> {pr.checks_failed}</span>}
                  {pr.checks_pending > 0 && <span className="ck pending">● {pr.checks_pending}</span>}
                </div>
                {pr.checks.map((c, i) => (
                  <a
                    key={i}
                    className={"git-check " + c.bucket + (c.url ? " linked" : "")}
                    href={c.url || undefined}
                    target="_blank"
                    rel="noreferrer"
                  >
                    <span className={"ck-dot " + c.bucket} />
                    <span className="git-check-name">{c.name}</span>
                  </a>
                ))}
              </div>
            ) : (
              <div className="dim git-nochecks">no CI checks reported</div>
            )}
          </div>
        )}
      </div>

      {/* History */}
      <div className="git-section git-history">
        <div className="git-sec-head">
          <span className="gh-sec-title rule-title">
            <Octicon name="git-commit" /> Commits
            {commits.length > 0 && <span className="gh-counter">{commits.length}</span>}
          </span>
        </div>
        {commits.length === 0 ? (
          <div className="side-empty dim">no commits</div>
        ) : (
          <div className="git-log">
            {commits.map((c) => (
              <div
                key={c.sha}
                className={
                  "git-c git-c-clickable" +
                  (c.own ? " own" : "") +
                  (c.sha === selectedCommit ? " selected" : "")
                }
                onClick={() => setSelectedCommit((cur) => (cur === c.sha ? null : c.sha))}
                title="view this commit's diff alone"
              >
                <span className="git-c-dot" aria-hidden>
                  <Octicon name="git-commit" />
                </span>
                <span className="git-c-sub">{c.subject}</span>
                <span className="git-c-sha">{c.short}</span>
                <span className="git-c-meta dim">
                  {c.author} · {c.when}
                </span>
              </div>
            ))}
            {/* GitHub-style terminal node: the merge commit that closed the PR */}
            {merged && (
              <div className="git-c git-c-merged">
                <span className="git-c-dot merged" aria-hidden>
                  <Octicon name="git-merge" />
                </span>
                <span className="git-c-sub">
                  Merged <strong>{nCommits(ahead)}</strong> into <code className="gh-ref base">{base}</code>
                </span>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
