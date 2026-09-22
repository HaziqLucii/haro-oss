// The composer's primary button toggles between "run agent" and "queue".
//
// "queue" means an agent pipeline is ALREADY running in this worktree, so a
// submit stacks behind it and drains one-at-a-time. It must NOT show while a
// freshly-created worktree is `setting_up` (installing deps): no agent is
// running then, so the honest label is "run agent".
//
// Bug this guards: seeding a workspace from a backlog TODO flashed "queue" for
// a beat (the setup window) before flipping to "run agent".
//
// `shouldClientQueue` lives here — beside the label, reading the same predicate —
// because the label and the behaviour MUST agree. They didn't: the label read off
// real agent activity while the submit path queued on a broader `busy` that folded
// in `setting_up`. So a click during setup said "run agent" and then quietly filed
// the task into a client-side queue whose only drainer was an effect scoped to the
// SELECTED workspace — switch away and the task was stranded forever. Setup is now
// the BACKEND's wait to own (the run is accepted and held server-side as `queued`),
// and client queuing is only for the deliberate follow-up-while-busy feature.

/** True only when an agent/test run is actively occupying the worktree. */
export function isAgentBusy(wsStatus: string): boolean {
  return wsStatus === "agent_running" || wsStatus === "tests_running";
}

/**
 * Should a submit be held in the CLIENT's follow-up queue instead of POSTed now?
 *
 * Only when an agent pipeline is genuinely running. Never for `setting_up`: that
 * wait belongs to the backend, which accepts the run as `queued` and starts it when
 * the worktree is provisioned — no client needs to be watching for that to happen.
 */
export function shouldClientQueue(wsStatus: string): boolean {
  return isAgentBusy(wsStatus);
}

/** Label for the composer's primary submit button. */
export function composerButtonLabel(wsStatus: string): "queue" | "run agent" {
  return isAgentBusy(wsStatus) ? "queue" : "run agent";
}
