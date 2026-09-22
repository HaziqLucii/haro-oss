# haro backend map (`backend/haro/`, Python + FastAPI + asyncio)

A navigation aid, not a spec — always read the target file before editing.

## Contents
- `main.py` — REST + WS routes, `lifespan` boot sequence, merge poll, `_seed_workspace`
  (the extracted create-workspace machinery, shared with the race fan-out), race endpoints
- `adapters/` — the `AgentAdapter` seam (`claude_code.py`, `local_model.py`); Plan/Fast Mode
- `adapters/test_runner/` — the `TestRunnerAdapter` seam (Vitest/pytest/command)
- `gate.py` — the test gate + `ensure_deps`; runs the tamper alarm and the **code to check** pass
  (`unchecked.py`) on an otherwise-green gate; plus `run_watch` (the Live Gate's ADVISORY loop —
  a separate function from `run_gate` precisely so it has no code path to the verdict writes)
- `runner.py` — the agent→gate handoff (+ Plan-Mode gate skip), then the gate→rung handoff
- `integrate.py` — commit → merge → archive, follow-up PR threading, `ship_preflight` (the
  one choke point every ship path clears)
- `rungs.py` — the autonomy ladder's ACTIONS (the one rung, `auto_pr`) fired from a green gate
- `merge_queue.py` — the conflict-aware batch merge's greedy ordering engine (pure, injected IO);
  admission + the git/`integrate` shell live in `main.run_merge_queue`
- `race.py` / `fanout.py` — winner-only fan-out: the pure judge / the IO shell
  (backlog/winner-fanout.md). Same decide-vs-act split as `trust.py`→`rungs.py`
- `archive_queue.py` — **bulk archive** (backlog/bulk-archive.md): the pure admission
  planner + the serial driver; the shell is `main._drain_archive_queue`
- `lifecycle.py` — setup/run/archive scripts, multiple run scripts, dep provisioning,
  plus `quiesce_workspace` (the shared "stop everything inside a workspace" half of
  BOTH teardown paths — hard delete and the race ceremony's soft archive)
- `hub.py` — multiplexed pub/sub + the global feed + `notify` channel
- `watcher.py` — event-driven filesystem watch. Its quiescence debounce serves TWO policies,
  forked on workspace kind: **adopted** ⇒ the authoritative auto-gate (`[trust] quiet_secs`,
  backlog/merge-firewall.md §4); **managed + `[gate] watch`** ⇒ the advisory `gate.run_watch`
  (`_WATCH_DEBOUNCE_SECS`, backlog/live-gate.md). `_quiet_secs_for` is the single policy seam
- `store.py` — in-memory reconciled cache, transcript, per-turn markers, rewind
- `git_ops.py` / `git_panel.py` — git CLI wrapper / git-panel queries
- `config.py` — `.haro/settings.toml` load/write, three-source merge, project endpoints
- `presets.py` — declarative stack-preset registry
- `models.py` — pydantic models
- `db.py` — aiosqlite snapshot/hydrate to a local SQLite file (`$HARO_DB`, default
  `~/.haro/haro.db`) + `reconcile`/`mark_broken`
- `procs.py` — the ONE process-group teardown policy every subprocess owner imports
  (`signal_tree` / `terminate_tree`)
- `terminal.py` — embedded PTY shell + nvim editor
- `haro_skill.py` — installs the `haro` + `haro-dev` skills on boot
- `analytics.py` — on-demand coverage-delta + flaky detection
- `trust.py` — autonomy-ladder rung evaluator (pure `evaluate` → `TrustReport`, no IO).
  Its project-level streak reads `store.project_test_history(project_id)` — every gate run
  across the project's workspaces, attributed by `TestRun.project_id` (stamped in `gate.run_gate`)
  so a workspace's greens survive its merge+archive. Only **green-first-try** runs climb the
  streak: `TestRun.trigger` (`"auto"` post-agent gate · `"manual"` hand-triggered · `"autofix"`
  a re-gate inside the fix loop, also stamped by `gate.run_gate`; `"watch"` the Live Gate's
  advisory loop, stamped by `gate.run_watch`) — `autofix` **and** `watch` greens reset it
  (`trust._is_clean_green`), so neither fail→autofix→green churn nor a cheap continuous
  impacted-only green can inflate trust. A watch run never reaches `store.tests` at all, so the
  trigger check is a second lock (backlog/live-gate.md). A **`green*` also breaks the streak**:
  `trust._break_reason(run)` is the single source of truth for "why isn't this a clean green"
  (red · autofix/watch · tamper findings), shared by `_is_clean_green` and the streak row's
  detail (`"0/3 … · a green* run (tamper findings) reset it"`: a 0/N beside a green gate reads
  as a bug unless the row names the reset). Checking only the *latest* run for tamper would let a
  streak be banked on a weakened suite, so the streak itself would become the gamed metric.
  The **`no_tamper` condition** reads `TestRun.tamper_findings` (backlog/tamper-alarm.md §3): alarm
  `off` ⇒ unmet + `fix="gate_settings"` (an *unmeasured* suite is not a clean one), a `green*` ⇒
  unmet + the alarm's `tamper_note` + `fix="tamper"` (→ the findings chip on the grid tab), red or a
  `scope="failed"` partial ⇒ "not measured" (the alarm only reads a whole green gate), clean ⇒ met.
  It's the condition every other one leans on (one `it.skip` moves coverage, flaky and
  merge-result together). It used to have a hard, `require_`-independent precondition guarding
  the (now-deleted) `auto_merge` rung — cut 2026-09-17 with `auto_merge` itself
  (`notes/usp-critique-round4.md` §4: auto-merging onto the user's own `main` unattended was
  judged too dangerous for a solo/local tool). `no_tamper` today is an ordinary required
  condition like the rest, waivable via `require_no_tamper = false` same as any other.
  A **`quality` condition** is pre-wired for the Double Gate's other half
  (backlog/double-gate.md §1, backlog/autonomy-ladder.md §3 "add the key, don't redesign"): the key
  is in `config.TRUST_CONDITIONS` so `require_quality` parses + round-trips today, but `evaluate`
  **omits the row entirely** while `settings` has no `quality_enabled` attribute — a condition
  nobody can satisfy would disarm every rung on a build with no quality gate, and there'd be no fix
  to link to. When §1 ships, give `ProjectSettings` a `quality_enabled` (`[quality] enabled`) and
  stamp `TestRun.quality_findings` (+ optional `quality_note`) the way the alarm stamps
  `tamper_findings` — `None` = not measured, `[]` = clean, non-empty = quality-red — and the row
  goes live with no evaluator change: off ⇒ unmet + `fix="gate_settings"`, findings ⇒ unmet with the
  note and no fix link (the findings-panel deep-link is double-gate §2's job), clean ⇒ met.
  The IO shell around the pure evaluator is `gate.build_trust_report(store, workspace, settings)`
  (fetches `latest_test` + `project_test_history`, calls `evaluate`); it's shared by the
  `GET /workspaces/{id}/trust` endpoint (`main.get_trust`) and `run_gate`, which re-broadcasts
  the report on the **`status`** channel by piggybacking the `GateSummary` publish (`_publish_status`
  gained a `trust=` kwarg) — so the ④-ship checklist + dashboard trust meter refresh on every gate
  verdict with no extra fetch (same denormalized-off-the-feed rule as `gate`). `run_gate` also
  stamps a compact `models.TrustSummary` onto `Workspace.trust` (glance subset: streak +
  rung state, via `gate._trust_summary`) so the dashboard meter ships on the workspace list —
  exactly the `Workspace.gate` (`GateSummary`) pattern; cleared alongside `gate` on "continue
  on a new branch".
  Two small **pure** helpers sit beside `evaluate` for the merge queue's admission
  (backlog/autonomy-ladder.md §3): `policy_armed(settings)` — did this *project* arm the ladder
  (`[trust] enabled` + `auto_action != "off"`)? — and `admission_reason(report)` → the skip
  message, or `None` when the rung is complete and the queue may land it. See
  `main.run_merge_queue` below for the wiring; add a new admission rule *here*, not there.
- `rungs.py` — the ladder's **actions** (backlog/autonomy-ladder.md §3), i.e. what an *armed*
  `TrustReport` is allowed to DO. `trust.py` decides, this acts; keeping them apart is what
  keeps the decision pure/unit-testable. `maybe_fire(store, hub, workspace, test)` recomputes
  the report via `gate.build_trust_report`, returns `None` unless `report.armed` (the common
  case — the ladder is opt-in), then runs `integrate.ship_preflight` and
  `git_panel.create_pr` (the one remaining rung, `auto_pr` — no merge). It **never raises**: a
  failed rung must not damage the verdict it acted on, so failures come back as a `notify`
  instead. (An `auto_merge` rung that went through the full `integrate()` path and the same
  post-merge bookkeeping as `POST /workspaces/{id}/merge` was cut 2026-09-17 — see
  `notes/usp-critique-round4.md` §4 — along with `no_tamper`'s hard precondition, which existed
  only to guard it.)
  **Three invariants worth not breaking:** (1) *nothing bypasses the choke point* — the rung
  clears the very same `ship_preflight` the manual buttons do, so an uncommitted worktree is
  **held, never auto-committed**; (2) *never silent* — every fired/held/failed rung publishes
  `{channel: "notify", kind: "rung", action, state, detail, pr_url, streak}` on the global feed;
  (3) *attributable* — `report_body()` renders the checklist into the PR body, via
  `git_panel.create_pr(body=…)`, which swaps `gh`'s `--fill` for `--title <tip subject> --body
  <report>`; a bodyless `gh pr create` would *prompt* and hang, so a failed title lookup falls
  back to `--fill`).
  `report_body`'s `_VERB` map carries a third, non-rung key — `"merge_queue"` → "Merge-queued" —
  because `main.run_merge_queue` reuses the same renderer for the workspaces the ladder admitted,
  so a ladder-authorized merge cites its evidence identically whichever path landed it.
  **Where it's wired:** every *authoritative* gate — `runner.run_agent` (after its `finally`,
  see below), and `rungs.gate_and_fire` (= `run_gate` + `maybe_fire`) which `main.run_tests`
  and `watcher._on_quiescence`'s adopted branch schedule instead of `run_gate` directly. Tests
  that stub the watcher's gate must patch `watcher.rungs.gate_and_fire`. The advisory
  `gate.run_watch` has no path here at all (it never sets `gate_green`), and an
  impacted/`failed`-scope gate can't fire either — `trust`'s `full_scope` condition rejects it
  before `armed`.
- `quality.py` + `adapters/quality/` — **THE DOUBLE GATE's deterministic half**
  (`backlog/double-gate.md` §1). `QualityRunnerAdapter` mirrors `TestRunnerAdapter`;
  `gitleaks`/`semgrep`/`lint` normalize to `{tool, severity, file, line, rule, message}`.
  `quality.analyze` runs them concurrently, diff-scoped and de-duped, streaming on the
  `quality` WS channel. Wired in `run_gate` after the tamper/code-to-check blocks; stamps
  `TestRun.quality_findings` (**tri-state**: `None` = not measured, `[]` = clean, non-empty
  = findings), `quality_note`, `quality_blocked` — the last folds into the green
  conjunction. ⚠ Two rules to preserve if you touch this: **`available=False` is never
  `findings=[]`** (a missing binary degrades the run, it does not report clean), and paths
  go through `base.rel_path` (gitleaks echoes an absolute `File` for an absolute `--source`,
  which silently matched nothing and reported every real secret as clean). Bundled offline
  semgrep rules live at `assets/quality/semgrep-rules.yaml`.
- `review.run_plan_compliance` — the Double Gate's **LLM third** (§3). Runs last, only when
  tests *and* deterministic quality are green, behind its own `[quality] plan_compliance`
  switch (a model call per gate). The guardrail is in `parse_plan_verdict`, not the prompt:
  uncited gaps are DROPPED, an all-dropped non-compliance downgrades to low confidence, and
  only high-confidence non-compliance sets `quality_blocked`. Adding a caller? Keep those
  two invariants or the reviewer becomes a hallucinated-blocker generator.
- `verified_hunks.py` — per-line proof on the ④ ship diff (pure); the annotation half of the
  diff-level signal, sharing one coverage run with `unchecked.py`
- `unchecked.py` — **code to check** (`backlog/code-to-check.md`): the DIFF-level signal, pure
  `analyze(diff_text, line_hits, tamper_findings, scope) -> UncheckedReport` with no IO, the same
  shape as `tamper.py`/`blame.py`. Exists because every OTHER gate guard is suite-level
  (`merge_result`, `coverage`, `full_scope`, `no_flaky`, `no_tamper`), so none of them can notice
  that the lines an agent just added were executed by nothing. Two coverage tiers — `no_test_file`
  (the path is ABSENT from the coverage map, i.e. nothing imports it) and `untested_lines` (imported,
  but N added lines never ran) — plus deliberately boring risk rules (dep manifest, secret-ish path,
  deletion, migration) and the tamper findings folded in as `suite_weakened`, so this is the ONE
  place that answers "what has nothing checked". Reuses `tamper.parse_file_diffs` +
  `blame.changed_lines` rather than parsing the diff a third time.
  Also the home of the alarm's one **advisory** output: `tamper_rewrites=` (→
  `rewritten_items` → `assertion_rewritten` rows), a base test retitled AND re-asserted in
  place. It lands here rather than on the `green*` chip because it is not evidence the suite got
  weaker *and* because the chip only renders when there ARE tamper findings — which for this
  shape there are none, so the chip would hide it in the one case it's for. See `tamper.py`.
  **Two guards worth knowing before you touch it**, both added after real-data false positives:
  `runner_scope` lets the coverage map define its own language universe at FAMILY level (a vitest
  map holds only JS, so a changed `.py` must not be reported; a `.ts`-only map must still cover a
  changed `.tsx`), and `_MIN_ADDED_FOR_UNTESTED_FILE` floors trivial edits because this pane reports
  on the CHANGE, not on the repo's standing test debt. Line hits come from
  `VitestAdapter.coverage_line_maps` (`--coverage --coverage.reporter=json` →
  `coverage-final.json`, collapsing `statementMap` + `s`; `None` on any failure, which degrades to
  risk-rules-only and must NEVER be read as "everything is unchecked"). Wired in `run_gate` on an otherwise-green full-scope
  run, beside the tamper alarm, reusing the diff already fetched there. **Advisory by construction:
  there is no `unchecked_blocked`**, so it cannot downgrade a verdict the tests earned; `no_unchecked`
  as a ladder rung is deferred (§4). Mode key `[workflow] code_to_check = "warn" | "off"`.
  ⚠ The coverage call is **no longer inside this pane's block** — it was hoisted in
  `run_gate` to serve BOTH diff-level signals (this pane + `verified_hunks.py`), because it costs an
  instrumented test run and neither feature should pay for its own. The entry condition is now
  `code_to_check == "warn" or verified_hunks`; if you add a third reader, read the shared
  `line_hits`, don't call the adapter again.
  ⚠⚠ **The two readers get DIFFERENT maps from that one run.** `coverage_line_maps` returns
  `(lenient, strict)` and `run_gate` hands this pane the **lenient** one and `store.set_line_hits`
  (i.e. Verified Hunks) the **strict** one. They need opposite tie-breaks where several statements
  overlap a line, because their failure modes are opposite: this pane's is a false "no test ran" row
  (so it accumulates — one hot statement makes the line hot), Verified Hunks' is telling a reviewer
  the suite executed a line it never touched (so it takes the MINIMUM — executed only if every
  statement touching the line ran). istanbul emits an enclosing `if` *around* its own never-taken
  `throw` (`5→7 count=3` over `6→6 count=0`), which is what made accumulating overclaim. Pick the
  right one deliberately if you add a reader; `_line_hits(raw, root, strict=...)` is the switch.
- `verified_hunks.py` — **Verified Hunks** (`backlog/verified-hunks.md`, round-2 Bet 12): per-line
  proof on the ④ ship diff. Pure `annotate(gate_diff, current_diff, line_hits, scope)
  -> VerifiedHunksReport`, no IO — same shape as `blame.py`/`unchecked.py`/`tamper.py`. Where
  `unchecked.py` answers "what has nothing checked?" as a *list of rows*, this answers "which of
  THESE lines ran?" as an annotation the diff viewer draws on itself, so a 1,200-line agent diff
  collapses to the residue the suite never exercised.
  **Why it takes TWO diffs, and this is the load-bearing bit:** the line map was measured against
  one particular working tree, and agent edits are **uncommitted** — a line can be inserted,
  renumbering everything below it, without HEAD ever moving. So staleness is decided **per file** by
  comparing that file's added lines at gate time (`blame.changed_lines` of the cached gate diff)
  against its added lines now; a file that moved comes back `stale=True` with an **empty** line map.
  A green dot on a shifted line is the one mistake this feature cannot survive, so silence is the
  only honest output. The gate's HEAD sha is carried for display only (`gate_sha`).
  **Three line states**, and the third is why the signal stays usable: `hits >= 1` executed,
  `hits == 0` never executed, `hits is None` **not coverable** (absent from `statementMap` — blank,
  comment, closing brace) — counted separately, NEVER as untested. A file absent from the map
  entirely is its own case (`in_map=False`): nothing imports it so nothing ran, reported at file
  level with no per-line claim, mirroring `unchecked.py`'s `no_test_file` vs `untested_lines` tiers.
  Reuses `unchecked.runner_scope`/`is_source_file`/`_family` rather than re-deriving the two scope
  guards (family match + `[gate] dir` prefix).
  **Wiring:** `run_gate` caches `{sha, line_hits, diff, scope, runner}` via `store.set_line_hits`
  when `[gate] verified_hunks` is on (cache keyed by workspace with the sha INSIDE the payload — the
  endpoint must be able to *report* staleness, which a key miss cannot do), and calls
  `store.drop_line_hits` on any non-green verdict so an earlier green's proof can never be drawn
  over a failing tree. Served by `GET /workspaces/{id}/verified-hunks` (`main.get_verified_hunks` →
  `models.VerifiedHunksResponse`/`VerifiedFile`), which never runs a suite — it reads the cache and
  the current diff. `supported=False` + a note per cause (off · non-vitest runner · no coverage
  provider · no green gate on this tree yet), because those want different fixes.
  **Naming law, same as `unchecked.py` and enforced by test:** nothing says verified/proven/correct.
  An executed line is not an asserted line. Advisory by construction — there is no
  `verified_blocked`, so it cannot touch a verdict. Config `[gate] verified_hunks` (bool, default
  **false** — it annotates the reviewer's own diff, so it's switched on knowingly; it adds no test
  run). Tests: `test_verified_hunks.py` (engine), `test_verified_hunks_gate.py` (gate cache +
  green-only + the endpoint's states). Frontend half: `verifiedHunks.ts` + `DiffView.tsx`.
- `tamper.py` — test-tamper alarm (pure `analyze(diff_text, base_inventory, worktree_inventory)`
  → `TamperReport{findings, note, rewrites}`, no IO — same `blame.py` shape). Classifies a suspicious green
  as `green*`: `removed` tests (rename-aware inventory diff — three matching tiers so a rename /
  move / retitle yields **zero** findings), added `.skip`/`.only`/`.todo`, net-negative `expect(`
  count, and snapshot-churn ratio. The four signals are then folded by **`reconcile()`**, because
  they are not independent observers: `vitest list` reports what *would run*, so a modifier both
  trips its own signal AND vanishes from the worktree inventory. A `.skip`/`.todo` absorbs the
  removals it names (`it.skip` = its own test, `describe.skip` = every test beneath it, matched on
  the removal's ` > ` name segments); an `.only` absorbs its **whole file's** removals and carries
  the count in its detail (`.only added — 6 other tests in this file no longer run`); and
  `assertion_deltas` is dropped for any file a stronger signal already flagged, plus it skips
  whole-file adds/deletes entirely (a consolidation's deleted test file is not mass
  assertion-gutting — that was a live false positive, see `notes/e2e-gate-test-plan.md` Phase 7).
  Reconciliation only ever *merges* findings, so it can never lower a verdict — it exists purely to
  keep severity scaling with tampering rather than with detector count (the "cries wolf" kill
  condition).
  **`rewrites` is the deliberate non-finding** (`backlog/tamper-alarm.md` §1, closed 2026-07-25).
  All four signals answer "does this test still exist?", so a base test retitled **and**
  re-asserted in place is silent: the fuzzy tier pairs the retitle and swapping one assertion for
  another drops no `expect(` count. `rewritten_tests(file_diffs, retitled)` reports those pairs on
  `TamperReport.rewrites` (`kind="rewritten"`) — **never** in `findings`/`note`, so it cannot reach
  `green*`, `tamper_blocked`, `trust.no_tamper` or the streak by construction rather than by every
  consumer filtering. `run_gate` routes it to `unchecked.analyze(tamper_rewrites=…)`. Option (c) —
  tightening the fuzzy tier — was rejected: a retitle-plus-re-assert is also exactly what an honest
  contract change looks like, so promoting it would aim the chip at legitimate work. Mechanics to
  respect if you touch it: matching now runs once in **`pair_removals`** (returns
  `(unmatched, retitled)`; `_find_match` returns `(index, tier)` and only tier 3 = fuzzy counts as a
  retitle, since tiers 1–2 kept the name verbatim); attribution is **hunk-scoped** via the new
  `FileDiff.hunks` (context lines kept, so a title changed in one hunk can't adopt an assertion
  changed in another); comparison is the multiset of `_assertion_text` (from `expect` to EOL,
  whitespace collapsed) so a one-line retitle keeping its assertion stays silent. `_FUZZY_THRESHOLD`
  is a coin flip at this distance and `SequenceMatcher` is **order-sensitive** — `_similar(added,
  removed)` scores the §8.8 pair 0.812/0.824, the reverse 0.781/0.794 — so both ratios and the
  argument order are pinned in `test_tamper.py`.
  §1 + §2 done (backlog/tamper-alarm.md): the engine +
  fixtures, `TestRun.tamper_findings`/`tamper_note`/`tamper_blocked` (pydantic `TamperFinding` twin
  of the dataclass, mirrors the `coverage_*` trio in `models.py`), and the `run_gate` wiring —
  computed on an **otherwise-green** gate only (`test.status == passed and only is None`, exactly
  the coverage-guard entry rule), via `git_ops.diff` + `analytics.test_inventories`; an engine
  crash degrades to no findings, never sinking the verdict. Mode-gated by the `[workflow]
  tamper_alarm` key (`config.load_project_settings`; `off | warn | block`, **default `warn`** — the
  one guard that's on by default, since it's deterministic + adds no test run): `warn` records
  findings but stays green, `block` sets `tamper_blocked` which folds into the `green` conjunction
  (so `integrate.py` preflight refuses it for free), `off` skips the pass. Surfaced in the Gate
  settings tab (`GateConfig.tamper_alarm` / `write_project_gate`, which OMITS the default `"warn"` —
  inverse polarity from the other guards that omit `"off"`). §2's `green*` chip is shipped in
  `GatePanel.tsx`: an otherwise-green gate with `tamper_findings` renders the verdict as `● green*`
  (asterisk on the `.verdict-green-star` span) plus a `TamperBanner` in the merge-note slot — the
  compact `tamper_note` ("3 removed · 2 skipped …"), click-to-expand into per-finding kind · test ·
  detail · file; red-bordered + a fix hint when `tamper_blocked`, and a **`+ restore weakened tests →
  agent`** action row that batches every finding into the review composer (`App.restoreWeakenedTests`
  → `gate.ts` `tamperReviewItems`, the `failureReviewItems`/fix-all pattern) with each item's restore
  instruction **prefilled** per kind (`TAMPER_FIX_HINT`) — so `green*` routes to action the way red
  does. Display logic is pure/tested in `gate.ts` (`tamperKindLabel`, `tamperSummary`,
  `tamperCountSummary`, `tamperFixHint`, `tamperReviewItems`; `gate.test.ts`).
  §3 in progress — the **glance star**: `models.GateSummary` gained `tamper_count` +
  `tamper_note` (stamped in `run_gate` beside the other summary fields), so the dashboard card
  and the "N gates need you" banner render `green*` off the coarse `status`-channel feed with
  **no fetch-per-card** — the findings themselves stay on the `TestRun` for the drill-down.
  Same denormalization rule as `gate`/`trust`; add a field here (not a new endpoint) whenever a
  gate signal has to be visible on every card. Same §3 also stars `green*` runs in the
  **regression ribbon** and time-travels their findings (frontend-only — `gate.ts` `ribbonDot`
  + `GatePanel`'s `viewTest`; no new endpoint, `GET /workspaces/{id}/history` already returns the
  full `TestRun` with its tamper trio, persisted as one JSON blob by `db.py`). See
  `reference/frontend.md`. §3's **ladder rung** is done too: `trust.py`'s `no_tamper` condition +
  the streak's `green*` reset (its old hard `auto_merge` precondition was cut with `auto_merge`
  itself, 2026-09-17 — see `trust.py` above). Remaining: the sandbox E2E.
- Backlog (todo files) — the 1st backlog source (`main.py` discovery/parse + `backlog.py` write)
- `issues.py` — the GitHub Issues backlog source
- `issue_detail.py` — on-demand detail for one issue
- `review.py` — AI code review (verify's advisory quality lane)

---

- `main.py` — REST + WS routes, FastAPI app, `lifespan` boot sequence (reconcile,
  autosave, orphan sweep, skill install, fs-watch + merge-poll background tasks).
  **Agent start/stop (backlog/agent-session-lifecycle.md §1/§3):** `start_agent` does NOT
  refuse a run while setup is in flight — it creates the `AgentRun` as
  `AgentRunStatus.queued` and returns 200 (fire-and-forget), leaving the wait to
  `runner.run_agent`. The duplicate-same-session 409 is the guard that IS correct; keep it.
  `stop_agent` `cancel()`s then **awaits the settle** (`asyncio.wait_for(shield(task), 5s)`,
  returning `settled: bool`) — "stopped" used to be a lie for as long as the process took to
  die, and now that cancellation really kills a process group there's genuine teardown to
  wait for. It only swallows `CancelledError` when `task.cancelled()` is true, so a client
  disconnect isn't mistaken for the run ending. `_detach(coro)` + the `_detached` set is the
  home for genuinely fire-and-forget background coroutines: asyncio holds only a **weak**
  reference to a running task, so a bare `create_task(...)` nobody keeps can be GC'd
  mid-flight. Anything with a real owner belongs in that owner's registry
  (`store.active_tasks`/`run_tasks`/`gate_tasks`) instead.
  `_adopt_merged_state` (GitHub-side MERGED → status `merged`, shared by the
  `GET /git/pr` route and the merge poll); `_poll_merges` (~30s, green + remote-linked
  workspaces only — detects a PR merged on github.com, which emits no local event).
  ⚠ `_adopt_merged_state` acts **only on a real PR record** (`supported && exists`).
  `pr_status` degrades to `supported=False` (no remote / no `gh` / worktree gone) or
  `exists=False` (no PR) — an *absence* of evidence, not a "not merged"; reading it as one
  demoted every LOCAL merge back to `gate_green` the instant the ship panel fetched
  `/git/pr`. Promotion additionally requires the PR's `headRefOid` == the worktree HEAD
  (a branch NAME stays MERGED on GitHub forever). `GET /git/pr` returns that reconciled
  verdict as `PrStatusResponse.workspace_merged` — the frontend must read **that**, never
  re-derive merged from `state == "MERGED"`. Tests: `tests/test_merged_status_sync.py`.
  **Merge Firewall (adopt foreign worktrees, backlog/merge-firewall.md §1):**
  `_scan_foreign_worktrees(project)` runs `git_ops.list_worktrees` and drops every row
  haro already governs (workspaces tracked ACROSS EVERY project — not just this one,
  since nothing dedupes projects by path — the main checkout, bare) → unadopted rows
  tagged with a `source` (`_guess_worktree_source`). A row under haro's own worktree
  root that is untracked is an ORPHAN (the store lost it, e.g. a create that never
  made it into a persisted snapshot before the app quit) — surfaced too, tagged
  `orphaned`, rather than silently dropped as "already governed"; otherwise a lost
  workspace's worktree/branch could never be reclaimed or freed for reuse;
  `GET /projects/{id}/worktrees` (`list_foreign_worktrees`) is the on-demand scan (refreshes
  `store.adoptable`, broadcasts a `notify`/`adoptable` hint for the *newly-appeared* rows);
  `POST /projects/{id}/workspaces/adopt` (`adopt_workspace`) registers one in place
  (`kind="adopted"`) **then runs the exact create-path provisioning** (§2, the cry-wolf
  fix): `seed_worktree_env` + `copy_worktree_includes` (both non-clobbering, so a foreign
  tool's own `.env`/certs survive) then `run_setup` under `SETUP_SESSION` — born
  `setting_up`, deps chip via `store.setup_state`; `gate.ensure_deps` no-ops on an existing
  `node_modules` **install** — real dir **or** symlink, incl. a dangling one `exists()` alone
  would miss — so a foreign install is never clobbered by the symlink stopgap. Its counterweight
  is `gate._holds_packages` (backlog/gate.md): a *package-less* `node_modules` (no `.bin`, no
  non-dot entry — i.e. a bare `npx vitest` build cache) is NOT an install, so it gets cleared
  and symlinked; "exists" was letting an agent cancel dep provisioning by running the suite.
  `reconcile_adoptable(store)` is the **boot rescan** (called from
  `lifespan`, mirrors `db.reconcile`/`mark_broken`: seeds `store.adoptable` silently, returns
  `[adoptable] …` notes). Never auto-adopts. **The firewall verdict oracle (§3):**
  `GET /firewall/verdict?repo=<abs-path>&branch=<name>` (`firewall_verdict` → `models.FirewallVerdict`)
  is what the repo-level git hook curls to decide whether a push/merge may proceed — a
  top-level route (NOT under `/projects/{id}`: the hook knows only its repo dir, not haro's
  project id). Project matched by path (`git_ops._norm_path`), workspace by branch; reads the
  denormalized `Workspace.gate`/`.status` off the store — no git/disk call, so the hook's
  `--max-time 2` curl stays fast. Tri-state: `green` ⇔ `status == gate_green`, `red` ⇔
  `gate_red`, else `unknown` (ungoverned branch, unregistered repo, or not gated yet). It only
  *reports*; blocking (fail-open warn by default) is the hook + `[trust]` config's job.
  **The hook itself (§3):** `assets/firewall/hook.sh` — one ~30-line POSIX-sh script installed
  into the repo's *shared* hooks dir (`$GIT_COMMON_DIR/hooks`) as both `pre-push` and
  `pre-merge-commit` (branches on `basename "$0"`); it curls the verdict for the branch (main
  worktree path via `git worktree list`, backend from `git config haro.url`, default
  `:8000`) and exits 1 on `red`, naming the workspace. **Failure semantics are explicit and
  keyed on `git config haro.strict`** (bool, default false — read from git config, not the
  verdict response, so fail-closed still resolves with the backend down): unreachable/timeout
  ⇒ fail-open warn by default, block under strict; verdict `unknown` (ungoverned/not-gated
  branch) ⇒ warn+allow by default, block under strict; `red` always blocks. **The installer
  (§3):** `firewall.py` — `install_hooks(repo, backend_url, strict)` writes `hook.sh` under both
  names into the repo's active hooks dir and sets `git config haro.url` (only when non-default)
  + `haro.strict`; `uninstall_hooks` disarms. **`_hooks_dir` is `core.hooksPath`-aware**
  (`git_ops.get_config`): husky/lefthook redirect git to e.g. `.husky` and git then ignores
  `$GIT_COMMON_DIR/hooks`, so we install *there*; else the shared `$GIT_COMMON_DIR/hooks`
  (`--git-common-dir`, one install governs every worktree). **Chain, never clobber:** a
  pre-existing *foreign* hook (husky's own, hand-rolled) is chained onto — `_install_one`
  appends an idempotent marker-fenced block (`_FENCE_START`/`_FENCE_END` = `# >>> haro firewall
  >>>` … `# <<< …`) carrying the firewall logic (`_fence_block` = `hook.sh` minus its shebang,
  one source of truth). Reinstall refreshes the block in place (no dup); `uninstall_hooks`
  `_strip_fence`s exactly our block (foreign hook left byte-identical) or removes a slot we
  wholly own (detected via `_HOOK_MARKER`). No conflict/`409` path — chaining always succeeds.
  `POST /projects/{id}/firewall`
  (`install_firewall` → `models.FirewallInstallRequest`/`Result`) persists the `[trust]` posture
  (`config.write_project_firewall`) then installs (`warn`/`block`) or disarms (`off`); effective
  strict = `strict or firewall == "block"` (the hook expresses posture purely through
  `haro.strict`). `git_ops.set_config`/`unset_config`/`get_config` are the config
  helpers. **Uninstall is one command (§3):** `DELETE /projects/{id}/firewall`
  (`uninstall_firewall`) is the body-less, idempotent disarm; both it and `POST {firewall:"off"}`
  route through the shared `_disarm_firewall(project)` so the two paths can't drift. Disarm is
  pure file edits + a `git config` unset (never reads gate state) — with the hook's fail-open
  default, a stopped/removed haro can't brick a merge. Frontend seam:
  `api.installFirewall`/`uninstallFirewall` + `FirewallPosture`/`FirewallResult` (no rendered
  control yet). **Don't firewall ourselves (§3):** `git_ops._git` exports `HARO_INTERNAL=1`
  (`_INTERNAL_ENV`, beside `_CRED_OVERRIDE`) into every git subprocess; git passes its env to
  the hooks it spawns, so `hook.sh` early-returns (`[ "${HARO_INTERNAL:-}" = 1 ] && exit 0`) when
  haro itself drives the merge — integrate's `local_merge`, the merge queue, the gate's
  `snapshot_worktree_commit`/`create_merge_worktree`. Otherwise the base branch reads "unknown"
  and strict would block haro merging its own green work. A **convenience seam, not a security
  boundary** (any process can set the var; real enforcement is the verdict oracle — a red gate
  still blocks, and haro never merges red work internally).
  Tests: `test_firewall_verdict.py` (oracle),
  `test_firewall_hook.py` (hook + strict/unknown branches + `HARO_INTERNAL` bypass),
  `test_firewall_install.py` (config keys + writer + installer + endpoint),
  `test_git_ops.py` (the `_git` marker reaches git's hooks end-to-end).
- `adapters/` — the `AgentAdapter` seam. `claude_code.py` = `ClaudeCodeAdapter`
  (shells `claude --output-format stream-json`, normalizes to
  `token|tool_call|file_edit|done|error`). **Teardown
  (backlog/agent-session-lifecycle.md §2):** `claude` is spawned with
  `start_new_session=True` (its own process group) and `run`'s `finally` closes the inner
  `_stream` generator then calls `procs.terminate_tree`. Cancelling a run used to just
  unwind this generator, leaving `claude` AND every tool it had shelled out to alive and
  detached — so ⏹ stop, archive-mid-run and shutdown all leaked a live agent still burning
  tokens. `_stream` was split out of `run` purely to keep that `finally` visible instead of
  buried under 60 lines of parsing. The kill is only deterministic because `runner.py`
  closes the generator via `aclosing`; don't remove either half. **Plan Mode:** `run(plan=True)` swaps
  `--permission-mode bypassPermissions` for `--permission-mode plan` (propose a plan,
  edit nothing — the review surface before any file edit); the flag is per-run, threaded
  `StartAgentRequest.plan` → `run_agent` → `_drive_agent` → `adapter.run` (base + local
  accept + ignore it). **Fast Mode:** `run(fast=True)` injects `--settings
  '{"fastMode":true}'` ("speed over depth" — there is NO `--fast` flag; fast mode is a
  persisted `fastMode` *setting*, verified against v2.1.214 to flip the session's
  `fast_mode_state`; the CLI then runs Opus + `speed="fast"`). Threaded the same way
  (`StartAgentRequest.fast` → `run_agent`/`_drive_agent`, feature-detected via
  `inspect.signature`), but rides `drive_kw` so auto-fix rounds inherit it and — unlike
  plan — a fast run still edits + gates normally. Per-run, mutually exclusive with plan
  in the UI. `local_model.py` = `LocalModelAdapter`
  (Ollama / llama.cpp — no cloud): talks the OpenAI-compatible
  `/v1/chat/completions` API over a **curl** SSE subprocess and runs the agentic
  tool loop *itself* (read/write/edit/list/bash tools executed in the worktree),
  since a bare local model has no harness. Transport is injectable
  (`transport=`) so the loop is unit-testable without a live server
  (`tests/test_local_model_adapter.py`). New agent adapter → add here, register
  in `adapters/__init__.py`, wire into `main.py`'s `start_agent` adapter selection
  (keyed off `[agent] adapter`). The gate handoff in `runner.py` is adapter-agnostic.
- `adapters/test_runner/` — the `TestRunnerAdapter` seam: `VitestAdapter` (JS/TS,
  reads `vitest_reporter.mjs` NDJSON), `PytestAdapter` (Python, JUnit-XML),
  `CommandAdapter` (generic escape hatch — runs any configured shell command, exit
  0 → green, non-zero → red, no per-case grid). New gate runner → add here, register
  in `adapters/test_runner/__init__.py`, wire into `main.py`'s `_test_adapter`
  dispatch (keyed off `[gate] runner`).
- `gate.py` — runs the test gate (`run_gate`) + `ensure_deps` (node_modules symlink
  fallback). This is where "gate green/red" decisions are made. **Merge Firewall
  cry-wolf guard (backlog/merge-firewall.md §2):** `auto_gate_allowed(workspace,
  setup_state)` (pure) — managed workspaces always auto-gate; an **adopted** worktree
  only once its provisioning reports `setup_state == "ok"`. `run_gate` enforces it at the
  top for any non-`manual` trigger (`auto`/`autofix`, incl. the §4 quiescence auto-gate
  in `watcher.py`): held → early return, no run/red-flip/record. A `manual` gate is never held. The
  frontend renders a resulting `error_kind="setup"` on an adopted worktree as "environment,
  not code" with a re-run-setup affordance (see frontend.md `GateErrorCard`).
  **The coverage guard measures, or it says so (backlog/gate.md):**
  `evaluate_coverage_guard(delta, mode, tol, unmeasured_cause=)` treats a **missing** number
  like a measured drop — `block` blocks, `warn` warns — because it used to return `("ok", None)`
  and so never blocked in exactly the case where the *measurement* broke (the easiest half to
  break: see `_holds_packages` above, running the suite by hand was enough). The note names the
  cause, reusing `analytics.coverage_delta`'s own `note` (missing provider · red suite · no run
  yet) instead of re-guessing; `gate.unmeasured_coverage_note` is the one string shared by the
  `coverage_note` row and the §0 `degraded_reasons` entry. `off` is still the escape hatch — no
  new config key. Landing it on `coverage_blocked` (not `degraded` alone) is deliberate:
  `degraded` only reaches `integrate.ship_preflight`, while `workspace.status` is what the
  dashboard, the ribbon and the firewall's verdict oracle read. The frontend's fix hint forks on
  `coverage_delta == null` (`gate.ts` `coverageBlockHint` — fix reporting vs restore coverage).
  Tests: `test_coverage_guard.py`, `test_degraded_gate.py`, `test_ensure_deps.py`.
- `runner.py` — the agent→gate handoff: runs an agent, then triggers the gate on
  `done`. **It also owns both ways a run is HELD before it spawns**
  (backlog/agent-session-lifecycle.md §1 + §5) — deliberately here and not in the route,
  because this task outlives the client that asked for it:
  * **waiting for setup** — `_await_setup` awaits `store.setup_task(ws_id)` before taking
    the worktree lock. `start_agent` used to 409 on `setup_running` instead, which pushed
    the wait onto a *frontend* queue drained only while that workspace was SELECTED — so
    "create from the backlog → run → switch away" stranded the task forever. That was the
    felt bug. Uses `asyncio.wait` (NOT `wait_for`) on purpose: a timeout must not cancel
    the install other runs are also waiting on. Bounded by `SETUP_WAIT_TIMEOUT` (900s) and
    a timeout **fails the run loudly** via `_fail_run` — §1's kill condition is a run stuck
    `queued` forever. A *failed* setup is not reported here (the deps chip + a `setup` gate
    error already say so, and the agent may be being asked to fix exactly that).
  * **waiting for a slot** — `_spawn_slot` holds one permit of a module-level
    `asyncio.Semaphore` sized by `[agent] max_parallel` (0 ⇒ uncapped), scoped tightly
    around `adapter.run` so a slot is never held through a gate. Rebuilt when the cap OR
    the running event loop changes (asyncio primitives bind to a loop on first await, and
    each test runs in its own `asyncio.run`) — see `_slots`.
  Both surface as `AgentRunStatus.queued` plus a published-only line on that session's
  stream (`_notice`, the shared-branch queued-notice pattern), so a held run reads as
  "⏳ waiting", never as a hang. `_drive_agent` flips `queued → running` at the moment it
  holds the slot — i.e. the moment the run starts costing money.
  ⚠ `_drive_agent` iterates the adapter under **`contextlib.aclosing`**, and that is
  load-bearing: a bare `async for` that exits via `CancelledError` leaves the adapter's
  async generator SUSPENDED, so its teardown `finally` (which kills the `claude` process
  group) would only run whenever the GC got round to it. Don't unwrap it.
  A **Plan-Mode** run (`run_agent(plan=…)`, from `StartAgentRequest.plan`)
  edits nothing, so the handoff **skips the gate + auto-fix** for it (`gate_ready`'s
  `not plan`, step ③ stays idle). `plan` is feature-detected against the adapter's `run`
  signature (claude-code supports it; others degrade to a normal gated auto-edit run —
  never a skipped gate on real edits), and `_drive_agent` tags a plan run's terminal
  `done` event `plan: True` so the stream can offer the approve/feedback actions.
  **Multi-session:** `run_agent(session_id=…)` names which agent session the run + its
  auto-fix rounds belong to; it rides `drive_kw` so every `_drive_agent`/`_announce_autofix`
  call tags its `agent` envelope with `session_id` and `--resume`s that session's own
  `Workspace.session_resume` id (the gate stays session-agnostic — one shared worktree diff).
  **The gate→rung handoff** lands at the very end, *after* the `finally` that pops the active
  task: `await rungs.maybe_fire(…)` with the last gate result (post-auto-fix). It must run from
  a settled workspace — inside the run, `store.busy_reason` would report "an agent" and hold
  every rung forever (`test_rungs.py::test_runner_fires_the_rung_after_releasing_the_agent_slot`
  pins this). A user stop re-raises `CancelledError` before it, which is correct: a cancelled
  run's gate isn't a verdict to ship on.
- `integrate.py` — commit → merge → archive: local merge (no remote) or `gh` PR
  flow (remote present); refuses unless `gate_green`. **`ship_preflight`** is the shared choke
  point for that refusal — gate green, `store.busy_reason`, clean tree (commit-first), and
  `[workflow] merge_mode`, in one `action="merge" | "pr"` function raising `ShipRefused(msg,
  status)`. `POST /workspaces/{id}/merge`, `POST /workspaces/{id}/git/pr` (→ `HTTPException`)
  and both autonomy-ladder rungs (`rungs.py` → a held notification) call it, so an automatic
  ship can't drift into having fewer checks than the button. Also **follow-up PR threading**
  (`_followup_prefix`/`_pr_number`) — a workspace continued onto a fresh branch
  prefixes "Follow-up to #N." from `workspace.prior_prs`. "Continue on a new branch"
  itself is the `POST /workspaces/{id}/continue` route in `main.py` (re-branch in
  place off the updated base, keep `last_session_id`, promote `last_pr_number` →
  `prior_prs`, clear the gate).
- `merge_queue.py` + **`main.run_merge_queue`** (`POST /projects/{id}/merge-queue`,
  `?dry=true` to preview) — the conflict-aware batch merge: land every admitted workspace in a
  conflict-safe order. The module is the **greedy engine only** and pure of IO like `trust.py`
  (`run_merge_queue` / `preview_merge_queue`, with `conflict_check` + `merge_one` injected): it
  merges whatever currently merges cleanly onto its base (`git_ops.merge_tree_conflicts`, a dry
  `git merge-tree --write-tree` touching no worktree), advances the base, and re-scans, so a
  sibling that only conflicts *after* another lands is deferred, never merged into a broken
  state; the rest come back `blocked` with their conflict files. **Admission lives in the
  endpoint**, and there are two tiers:
  (1) always — green + not busy + valid worktree + clean tree + not `merge_mode = "pr"`;
  (2) **the queue inherits the autonomy ladder** (backlog/autonomy-ladder.md §3) — when
  `trust.policy_armed(settings)` the endpoint additionally calls `gate.build_trust_report` per
  candidate and admits only where `trust.admission_reason(report)` is `None`, i.e. exactly the
  rung-complete bar `rungs.maybe_fire` clears. Otherwise a batch "merge all green" would be a
  hole straight through the ladder. Rung-incomplete workspaces come back `outcome="skipped"` with the unmet condition **keys**
  named and stay merge-by-hand (④ ship still works: unattended shipping is earned, a human
  clicking merge is not), and a project that never armed `[trust]` keeps tier 1 alone. Merges the
  ladder admitted carry `rungs.report_body(report, "merge_queue")` in the commit body, same
  attribution as a rung. `MergeQueueItem.outcome` ∈ `merged` | `ready` (dry) | `blocked` |
  `skipped`. Tests: `test_merge_queue.py` (engine, real `merge-tree`, and the admission tiers
  with the git/`integrate` IO stubbed), `test_trust.py` for the two pure helpers.
  ⚠ Backend + `api.mergeQueue` + `types.ts` only — the dashboard "merge all green" button and
  results panel are still an unbuilt frontend follow-up (backlog/gate.md §4).
- **`archive_queue.py` (pure planner + serial driver) + `main._drain_archive_queue` (shell)
  — bulk archive** (`backlog/bulk-archive.md`). Tearing down N workspaces at once multiplies
  every failure mode simultaneously (N archive scripts, N git commands on one repo's index, a
  partial failure nobody can attribute), so a batch **drains serially**. Same decide/act split
  as `trust.py`→`rungs.py`.
  * **`plan(candidates, force=…)`** is pure: facts in (`busy` · `dirty` · `ahead` ·
    `worktree_missing` · `measured`), admission + order out. Its rule is the feature's whole
    safety story — `remove_worktree` ends in `git branch -D`, a **force** delete, so anything
    with work at stake is `skipped` **with the risk named** unless the caller forces it. Risk-free
    items are ordered **first**, so a stopped queue has done the harmless half. An
    **unmeasurable** worktree (git wouldn't answer) is risky, never clean (the coverage-guard
    rule); a **husk** (no `.git`) has nothing left to lose, so it IS admitted — archiving is the
    repair. Facts are gathered by `main._archive_candidate` (`store.busy_reason`,
    `git_ops.is_clean`, the new **`git_ops.ahead_count`** — which RAISES rather than reporting a
    comforting zero, unlike `git_panel.status`'s lenient display-side twin).
  * **`run_queue(run, archive_one=, publish=)`** is the driver: one at a time, a failed item
    recorded as `failed` and the batch continuing, and a **cooperative** stop
    (`run.stop_requested` checked *between* items — cancelling mid-`remove_worktree` is how you
    get the half-removed husk the crash-safety work exists to avoid).
  * **Wiring:** `models.ArchiveQueueRun`/`ArchiveQueueItem`/`ArchiveQueueRequest`;
    `store.archive_runs`/`archive_tasks` + `archive_running(project_id)` (one queue per project
    — two would be concurrent teardowns again) + `latest_archive_run`. Endpoints:
    `POST /projects/{id}/archive-queue?dry=true` (the preview the confirm dialog renders — an
    answer, not an entity, so it's never stored), `POST …/archive-queue` (starts the detached
    driver, returns immediately), `GET …/archive-queue` (reconnect after a reload),
    `POST /archive-queue/{run_id}/stop`. Progress rides `hub.broadcast_global` as
    `notify`/`archive_queue` carrying the whole run. The teardown itself is still
    `main._teardown_workspace` — the queue adds no second way to delete a worktree.
  * **Deliberately not persisted:** a queue is an in-flight operation, not an entity. A reboot
    mid-queue leaves the untorn workspaces intact and archivable by hand; resuming a destructive
    batch the user never saw finish is the worse failure.
  * Tests: `test_archive_queue.py` (engine + endpoint admission/409/stop),
    `test_archive_queue_git.py` (a real repo — the held-back branch genuinely survives, the
    admitted worktree genuinely doesn't). Frontend half: `archiveQueue.ts` +
    `ArchiveQueuePanel.tsx` + Dashboard select mode.
- **`race.py` (pure) + `fanout.py` (shell) — winner-only fan-out**, Bet 11
  (`backlog/winner-fanout.md`). One prompt fans out to N sibling workspaces (lane =
  model×effort), every lane resolves to a real merge-blocking gate verdict, and the gate
  **ranks** them — so the human reviews ONE diff plus a scorecard, instead of the N diffs
  every rival racer dumps on them. The decide/act split is the same as `trust.py`→`rungs.py`
  and for the same reason: the ranking is the part that must be provably deterministic.
  * **`race.py`** — `judge(lanes) -> Ranking` + `preflight(...) -> Preflight`, both pure
    (dataclasses in, verdict out; no git/store/clock), so "same inputs, same winner, every
    time" is testable with no repo. `POLICIES` = `first_green` · `cheapest_green` (default) ·
    `best_coverage_delta` · `merge_clean`, each with an `EPSILON` indifference band, over a
    fixed tie-break chain (**cost → wall → diff size → workspace id**; the trailing id is
    what stops input order deciding). `_disqualify` is the eligibility bar — not green ·
    merge-conflicting · **degraded** · **flaky-rested green** — every entry a fact the gate
    recorded, never a judgement. `Ranking` has **three** legal shapes and the UI renders all
    three: `winner_id`, an **honest `tie`** (all lanes green + the metric can't separate the
    top two), or **`refused`** (a green lane's `impacted_count` < `[race] min_impacted_tests`
    ⇒ decline to rank rather than crown noise). The refusals are the feature. Dormant slots,
    specced not built: `LaneFacts.quality_findings` (Double Gate §1) and tamper-as-a-
    disqualifier — `tamper_count` renders `green*` on the scorecard today but does NOT
    disqualify. Tests: `test_race_judge.py`.
  * **`fanout.py`** — the shell: `preflight_race` (measures the base suite via
    `analyze_impact` → `race.preflight`), `start_race` (refuses BEFORE creating anything,
    then loops the injected `seed_workspace` once per lane), `_supervise` (lanes concurrent
    under `_watch_budget`, then judge + ceremony, and **always settles the race** in its
    `finally`), `judge_race`, `soft_archive_lane`/`archive_losers`, `purge_losers`.
    `lane_gate_settings` is the §0 enforcement point: it `dataclasses.replace`s the project
    config with `gate_merge_result` + `flaky_rerun` + full scope FORCED on (all three only
    ever make a gate stricter) — ranking is a comparison, so every lane's green must mean
    the same thing. `_watch_budget` cancels still-running lanes when the lanes' summed
    `AgentRun.cost_usd` crosses `RaceRun.max_total_usd` (0 ⇒ lanes × `[agent] max_budget_usd`),
    and says so on the feed: N× spend is this feature's headline risk.
    `_seed_workspace` is injected (it lives in `main.py`) rather than imported — same
    injected-IO trick `merge_queue` uses.
  * **The soft archive is the subtle part** (§3). `soft_archive_lane` ≠
    `main._teardown_workspace`: it **checkpoint-commits first** (an agent's work is almost
    always uncommitted, and `worktree remove --force` would take the loser's whole diff with
    it — "keep the branches so the diff stays diffable" is false without this), calls
    `remove_worktree` **without the branch**, and keeps the store row + transcript +
    `test_history`. Two guards in `db.py` make it survive a reboot: `reconcile` and
    `mark_broken` both skip `WorkspaceStatus.archived` rows, which are worktree-less BY
    DESIGN and would otherwise read as desync and be deleted. `purge_losers` is the separate,
    irreversible act (branch + row), never part of the ceremony.
  * **Wiring:** `Workspace.race_id` (its OWN field — `seed_key` is *parsed* by the issue
    write-back, so smuggling a race tag through it would fire GitHub writes for a lane);
    `models.RaceRun`/`RaceLane` + `store.races`/`race_tasks` + a `races` table in `db.py`
    (§3 keeps every outcome as $/green-by-model calibration data); `gate.run_gate(settings=)`
    and `runner.run_agent(gate_settings=, on_gate=)` are the two threading seams.
    Endpoints: `GET /projects/{id}/race/preflight` (never 400s — the refusal IS the payload,
    so the composer can grey the button out *and say why* before a dollar is spent),
    `POST /projects/{id}/races`, `GET /projects/{id}/races`, `GET /races/{id}`,
    `POST /races/{id}/stop`, `POST /races/{id}/purge-losers`. Lifecycle rides
    `hub.broadcast_global` as `notify`/`race_*` carrying the whole `RaceRun` (a race belongs
    to a *project*, not a workspace). Config: the `[race]` table (`config._parse_race_lanes`,
    `RaceLaneConfig`). Tests: `test_race_judge.py`, `test_race_config.py`,
    `test_race_ceremony.py` (real git repo — the branch/diff/reboot promises are about git).
- `lifecycle.py` — workspace lifecycle scripts: `run_setup`/`start_run`/`stop_run`/
  `run_archive`, `script_env` (the `HARO_*` env vars, `port=` override),
  `sweep_orphan_runs`. **Multiple run scripts:** a project can define several named
  runs (`[scripts.run.<id>]` tables — web/worker/test, each with `command`/`default`/
  `icon`, parsed in `config._parse_run_scripts` → `ProjectSettings.runs`); a bare
  `run = "cmd"` string is the legacy single run (id `app`). `start_run(…, run_id=)`
  starts one named run; `stop_run(…, run_id=)` stops one (`None` → all). `run_procs`/
  `run_tasks`/`run_ports` are keyed by `(workspace_id, run_id)` — the default run
  reuses `workspace.port` (the rail's app strip binds to it), each other run allocates a fresh
  port from `[ports] range` and releases it on stop. Run-channel WS messages carry a
  `run_id`. Also `_provision_deps` + `detect_install_cmd` — the no-setup-script fallback:
  symlink an installed `node_modules`, or auto-`npm install` a fresh JS project once
  in the project root (per-root lock, honest `setup_state`) before symlinking.
  **`quiesce_workspace(store, workspace)`** is the shared "stop everything running
  *inside* a workspace" step (every session's agent task + setup, the gate task, the
  PTYs, the dev servers) — extracted so `main._teardown_workspace` (hard delete) and
  `fanout.soft_archive_lane` (a race loser) can't drift. It deliberately does NOT touch
  the port, the status or the store row: those are exactly what the two paths disagree
  about, and folding them in is how a "soft" archive quietly becomes a hard one.
  **Every lifecycle child is group-led + killed in a `finally`**
  (backlog/agent-session-lifecycle.md §3): `_spawn`'s `new_session` now defaults **True**
  and `_run_shell` tears the tree down via `procs.terminate_tree`, so a workspace deleted
  mid-`npm install` doesn't leave the install churning (a setup shell used to spawn
  group-less with no `finally` kill). `stop_run` shares that same helper with a longer
  grace (5s) so a vite tree can release its port.
  ⚠ `run_setup`'s `finally` **pops `SETUP_SESSION` BEFORE publishing `idle`**. The old
  order announced readiness while `store.setup_running()` was still true, so anything
  reacting to that event could be refused by the very guard the event said had lifted.
  Release the guard, then say you're ready.
- `procs.py` — the **one** process-group teardown policy, imported by every subprocess
  owner: `signal_tree(proc, sig)` (killpg with a single-pid fallback) and
  `terminate_tree(proc, grace=3)` (SIGTERM the group → grace → SIGKILL; a **no-op** on an
  already-exited process, so it's safe to call unconditionally from a `finally`, and a
  cancellation mid-teardown escalates to SIGKILL and re-raises). It exists because this
  policy was implemented once per owner and drifted: the dev-server path had it, the agent
  adapter didn't, so every stop/archive/shutdown orphaned a live `claude` and its whole
  tool tree. stdlib-only on purpose — `adapters/` imports it, so it must not drag the
  service layer in behind it. Add a new long-lived subprocess ⇒ spawn with
  `start_new_session=True` and tear down through here, never hand-rolled.
- `hub.py` — multiplexed pub/sub (WS channels: `agent`/`test`/`status`/`run`/`fs`;
  `status`/`test`/`notify` also fan out to the global feed). **Every buffer here is
  bounded**, subscriber queues included (`_QUEUE_MAX`, 2000): `publish` hands off through
  `_offer`, which never blocks the publisher and **drops the OLDEST** envelope on a full
  queue (first drop per subscriber logged). Unbounded queues meant a consumer that stopped
  draining — wedged socket, paused tab, slow global-feed reader — grew without limit while
  an agent streamed tokens into it; and making the publisher *await* a slow socket would let
  one stalled reader stall the run. Recent output is what a live view needs; the durable
  record is `store.events`. `hub.subscribe_global`
  for the cross-workspace live feed, `hub.broadcast_global` for app-level events with
  no owning workspace (e.g. `backlog_changed`). The `notify` channel carries the coarse
  cross-workspace signals the UI beeps / desktop-notifies on: `agent_done` +
  `cost_warning` (from `runner.py`), `gate_green`/`gate_red` (from `gate.py` `run_gate`),
  `rung` (from `rungs.py` — an autonomy-ladder action fired/held/failed),
  `backlog_changed` (from `watcher.py`).
- `watcher.py` — event-driven filesystem watch (`watchfiles.awatch`, native
  inotify/FSEvents) so panels stay live without a manual refresh. Watches the worktree
  root + each project path + each **adopted** worktree path (NOT `$HOME`) — adopted
  worktrees can live outside the repo tree (a claude-squad dir), so their `worktree_path`
  is added explicitly and the watch set rebuilds when one is adopted/removed. Emits
  `fs`/`changed` (per-workspace → code tree) + `notify`/`backlog_changed` (global →
  backlog). Started as a `lifespan` task. This is the "push where a local event source
  exists" half; the merge poll in `main.py` is the "poll where none does" half
  (github.com merges). **Quiescence (Merge Firewall §4):** an adopted worktree is
  agentless (no agent `done` handoff), so `_Quiescence` layers a *second* debounce on
  `fs_changed` — a per-workspace timer (re)armed on every change, firing `_on_quiescence`
  after `[trust] quiet_secs` (default 30, clamped ≥1) of silence. Only adopted workspaces
  are armed (`_dispatch`); the fire emits `fs`/`quiescent` then auto-gates — skips if
  `store.busy_reason` shows setup/agent/gate in flight, else schedules
  **`rungs.gate_and_fire`** (`run_gate` + the autonomy-ladder handoff, so an agentless green
  earns the same rung as an agent's) at the project's `[gate] default_scope` under
  `trigger="auto"` (so §2's `auto_gate_allowed` cry-wolf guard still holds it until
  provisioning is `ok`). `rungs` is a top-level import; `_test_adapter` is lazy-imported from
  `main` to dodge the load-time cycle.
  Tests: `test_quiescence.py`.
- `store.py` — in-memory state (reconciled cache — ground truth is SQLite/OS
  procs/git worktrees, see `notes/desync-hardening-plan.md`). Also owns the **persisted
  agent transcript**. `store.races`/`race_tasks` + `add_race`/`get_race`/`list_races`/
  `race_for_workspace` hold winner-only fan-out; `race_for_workspace` resolves through
  `Workspace.race_id` rather than scanning lane lists, so a soft-archived loser still
  finds its own scorecard. `store.adoptable[project_id]` caches the last foreign-worktree scan
  (Merge Firewall); `update_adoptable(project_id, rows)` swaps in a fresh scan and returns
  the *newly-appeared* rows (diff by path) — the "adoptable" hint, seeded on boot by
  `main.reconcile_adoptable`. **Multi-session data model:** a workspace holds N agent sessions,
  not one — `store.events` is keyed by `(workspace_id, session_id)` (mirrors run scripts
  keyed by `(workspace_id, run_id)`), and every transcript method takes a `session_id`
  defaulting to `store.DEFAULT_SESSION` (`"main"`), so single-session callers are byte-
  identical. Read via `store.events_for(ws_id[, session_id])` (NOT `store.events[ws_id]` —
  the key is a tuple now); `store.sessions(ws_id)` lists a workspace's session ids (the
  switcher's set); `store.drop_transcript(ws_id)` forgets every session (used by
  `remove_workspace` + reconcile/`mark_broken`). **WS multiplexing (built):** the `agent`
  channel envelope carries a `session_id` (`runner.py` `emit`), so the UI routes concurrent
  streams to the right switcher tab; each session `--resume`s its OWN Claude conversation via
  `Workspace.session_resume` (`session_id` → Claude id; the primary session mirrors into the
  legacy `Workspace.last_session_id` for backward-compat + pre-multi-session hydrate).
  `StartAgentRequest.session_id` (→ `run_agent(session_id=…)`) picks the session; `GET
  /workspaces/{id}/sessions` lists them; `/events`, `/turns`, `/rewind` all take a `session`
  selector (default primary). Tests: `tests/test_ws_multiplexing.py`. **Per-turn markers:** `append_event` tags every event with a monotonic
  per-**session** `turn` ordinal (a `user` event — prompt echo / auto-fix announce — opens
  a new turn; agent events that follow share it), *derived from the transcript tail* so it
  needs no new persisted state and survives hydration + the 4000-event cap; `turns(ws_id[,
  session_id])` derives the rewindable boundaries (one per `user` event:
  `turn`/`prompt`/`ts`/`kind`), the "rewind to here" anchors, exposed at
  `GET /workspaces/{id}/turns` beside `/events`. **Rewind:** `store.rewind(ws_id, turn[,
  session_id])` is the *conversation* half of "rewind to here" — it truncates the transcript
  at/after a target `turn` (drops every `turn`-tagged event ≥ N; pre-marker events with no
  `turn` are always kept) and returns that turn's `prompt` + a `dropped` count.
  `last_session_id` is left intact, so the next run `--resume`s the same Claude session and
  continues from the rewound point (there's no headless `--rewind`; see
  `notes/claude-code-stream-json.md` §11).
  The *worktree* half lives in the `POST /workspaces/{id}/rewind` route (`RewindRequest`/
  `RewindResponse`): when `checkpoint` is set it snapshots the worktree via `git_panel.commit`
  *first* (best-effort) so the dropped turns' edits stay recoverable in git history, then calls
  `store.rewind` + `db.save_snapshot`. Tests: `tests/test_rewind.py`.
  **Shared-branch semantics (built):** a workspace's N sessions all edit ONE worktree, so their
  agent runs **serialize** on a per-worktree `asyncio.Lock` — `store.agent_lock(ws_id)`, the analogue
  of `git_ops._cwd_locks` — held by `run_agent` across drive + gate + auto-fix; a 2nd session streams
  a "queued" notice immediately but only edits once the 1st releases, so its gate sees the combined
  diff (the gate was always session-agnostic — it runs on `workspace.worktree_path`). `active_tasks`
  is now keyed by **`(ws_id, session_id)`** (was bare `ws_id`) so a 2nd session isn't rejected and
  doesn't clobber the 1st's stop handle; setup rides the same registry under the reserved
  `store.SETUP_SESSION` (`"__setup__"`). Go through the helpers, never index `active_tasks[ws_id]`:
  `set_active_task`/`active_task`/`pop_active_task` (per session), `workspace_tasks`/`workspace_busy`
  (any session), `setup_running`, `setup_task(ws_id)` — the provisioning handle
  `runner._await_setup` awaits so a run fired during setup is HELD rather than refused — and
  `busy_reason(ws_id)`, the one "setup/agent/gate → label" the
  commit/PR/merge/rewind/gate/setup guards share (it replaced the inline `ws_id in reg` loops).
  `pop_active_task` takes an **optional `task=`** for an identity-checked pop (only clear the
  slot if it still holds THAT task) — `run_agent`'s `finally` passes `asyncio.current_task()`
  so a settling run can never evict a newer run's stop handle from the same session.
  `start_agent`'s guard is per-session; `stop_agent` takes a `?session=` selector; teardown cancels
  every session. Tests: `tests/test_shared_branch.py`. UI composer `busy` is still workspace-level, so
  concurrent sessions are a backend/API capability pending a per-session busy UI.
- `git_ops.py` / `git_panel.py` — git CLI wrapper (serialized per-cwd lock;
  `ensure_excluded` keeps `.context/` in `.git/info/exclude`) / the git-panel
  queries (ahead/behind, log, PR status via `gh` — reconciles a GitHub-side
  `MERGED` PR to workspace status `merged`).
- `config.py` — `.haro/settings.toml` + `.local` load/write (`[scripts]`,
  `[gate]`, `[workflow]`, `[backlog]`, `[editor]`, `[trust]`, custom instructions). `[editor] nvim`
  (`auto`/`byo`/`bundled`, default `auto`) → `ProjectSettings.nvim_mode`, which nvim
  config the code step's nvim editor launches (see `terminal.spawn_editor`).
  `load_project_settings`
  merges three TOML sources, lowest → highest precedence: the user-global
  `~/.haro/settings.toml` (`user_settings_path`, override with `HARO_USER_CONFIG`) <
  committed `settings.toml` < personal `settings.local.toml`. `[backlog] issue_writeback`
  (default off) → `ProjectSettings.issue_writeback`, the write-on-pickup gate (see
  `issues.write_back_on_pickup`). `[backlog] dir` (default `backlog`) →
  `ProjectSettings.backlog_dir`: the folder whose docs are ALL treated as backlog
  regardless of filename (so `backlog/gate.md` works with a clean name), on top of
  the legacy "filename contains 'todo'" rule — see `main._discover_todo_files` /
  `backlog.is_backlog_path`. `[trust]` (autonomy ladder, Bet 9) →
  `ProjectSettings.trust_{enabled,streak_required,auto_action,require}`: `enabled`
  (default off), `streak_required` (default 3, clamped ≥1), `auto_action`
  (`off`|`auto_pr`, default `off`, junk → `off` — `auto_merge` was cut 2026-09-17, see
  `trust.py` above), and per-condition
  `require_<key>` flags (all default true) over the `config.TRUST_CONDITIONS` set
  (`merge_result` · `coverage` · `full_scope` · `no_flaky` · `no_tamper` · `quality`, the last
  dormant until the Double Gate ships — see `trust.py` below) —
  parsed as pure config here, written back by `write_project_trust` (`.local` may only
  *tighten* the committed team policy). The rung evaluator is `trust.py` (below) and the
  `GET /workspaces/{id}/trust` endpoint + `status`-channel re-broadcast are shipped (see
  `trust.py`); the checklist UI is still a separate `backlog/autonomy-ladder.md` item.
  The **Merge Firewall** shares the `[trust]` table (§3, backlog/merge-firewall.md):
  `firewall` (`off`|`warn`|`block`, default `off`, junk → `off`) + `strict` (default false)
  → `ProjectSettings.firewall`/`firewall_strict`, parsed by a *separate* `_parse_firewall`
  (different concern from the ladder — jurisdiction vs auto-merge) and written by
  `write_project_firewall` (targeted upsert, preserves the ladder keys). The installer that
  writes the hook + git config is `firewall.py` / `POST /projects/{id}/firewall` (above).
  `quiet_secs` (§4, default 30, clamped ≥1) → `ProjectSettings.trust_quiet_secs` is the
  quiescence debounce for `watcher.py`'s agentless auto-gate; read-only (no writer round-trip),
  parsed inline in `load_project_settings`.
  The **`[race]` table** (winner-only fan-out, backlog/winner-fanout.md) →
  `ProjectSettings.race_{enabled,max_lanes,lanes,policy,min_suite_tests,min_impacted_tests,
  max_total_usd}`. `enabled` is OFF by default — this is the one feature that multiplies
  token spend by the lane count, so it can never be a default. `lanes` goes through
  `_parse_race_lanes` → `RaceLaneConfig`, which accepts an array of tables
  (`[[race.lanes]] model = "opus"`), plain model strings, or `"model:effort"` — the
  array-of-tables form is the one people hand-write wrong, and a config nobody can write
  is a feature nobody turns on. Junk entries are dropped (never raise) and an empty result
  falls back to `race.DEFAULT_LANES`, so `[race] enabled = true` alone is a working config.
  `max_lanes` clamps ≥ 2, `min_suite_tests`/`min_impacted_tests` clamp ≥ 1 (0 would disable
  the thin-suite guards outright), and an unknown `policy` falls back to `cheapest_green`.
  Read-only so far: no writer round-trip, no settings tab.
  `write_project_scripts` regenerates the
  scripts/gate/ports tables wholesale; `write_project_merge_mode` + `write_project_gate`
  + `write_project_agent` are **targeted** edits (via the shared `_upsert_table_keys`
  upsert) so a settings tab can't clobber the other tables — `write_project_merge_mode`
  touches only `[workflow] merge_mode` (Git tab); `write_project_gate` writes the `[gate]`
  block (incl. `watch` and `verified_hunks`) + the flaky/coverage guard keys under `[workflow]`
  (Gate tab — add a new gate knob to `GateConfig`, `_gate_config`, this writer, and the tab's
  `settings-row`, in that order); `write_project_agent`
  writes the `[agent]` keys (Agent tab) — the backend `adapter`
  (`claude-code` | `local`), the `local_base_url`/`local_model` for the local
  backend, and the Claude model/effort/budget guardrails. Custom instructions
  (`instructions.md` + `.local`, Instructions tab) go through `write_instructions`.
  The worktree `.env` seed (Environment tab) is separate from the TOML: `read_env`/
  `write_env` manage `.haro/.env` (always gitignored — secrets), and
  `seed_worktree_env` copies it into each new worktree's `.env` on create (called in
  `create_workspace`, before setup — a clean checkout never carries a gitignored `.env`).
  Beyond that dedicated seed, `[files] include = [...]` (parsed to
  `ProjectSettings.include_files`, default `[".env*"]`) is a glob list
  of gitignored files (`.npmrc` registry auth, `certs/*.pem`, service-account JSON) that
  `copy_worktree_includes` copies from the checkout into the worktree at the same
  relative path — right after the `.env` seed, only filling in missing files (so it
  never clobbers the seed or a tracked file, and refuses `..`/absolute patterns).
  Project config endpoints:
  `PUT /projects/{id}/default-branch` (base branch, stored bare), `GET/PUT
  /projects/{id}/workflow` (merge_mode), `GET/PUT /projects/{id}/gate` (runner/command/
  dir/scope/guards), `GET/PUT /projects/{id}/agent` (default model/effort + budget
  guardrails), `GET/PUT /projects/{id}/env` (worktree `.env` seed),
  `GET/PUT /projects/{id}/instructions`, `GET/PUT /remote`.
- `presets.py` — declarative stack-preset registry (vitest/pytest/shopify-theme/
  custom): each preset `detect(root)`s a confidence + serializes a `settings.toml`
  fragment (`to_toml_fragment`). `detect_stack`/`is_ambiguous` rank them;
  `detect_stack_response` builds the `GET /projects/{id}/detect-stack` payload
  (ranked candidates + a `proposal`, `None` when ambiguous — no auto-pick). New
  preset → add to `PRESETS`.
- `models.py` — pydantic models (`Workspace`, `Project`, request/response shapes).
  `RaceRun`/`RaceLane` are the winner-only fan-out record: the lane rows are a **cache of
  gate facts** copied off each lane's `TestRun`/`AgentRun` when it settles (live workspace
  state wins while a race runs), and `RaceRun.verdict` stores the serialized `race.Ranking`
  rather than recomputing it — the losers are about to lose their worktrees, so a re-judge
  would be scoring a different world, and the scorecard a human acted on is the one the
  record must keep. `Workspace.race_id` is the join.
- `db.py` — **aiosqlite** snapshot/hydrate to a local SQLite file (`$HARO_DB`, default
  `~/.haro/haro.db`; migrated off Postgres — same `(id, data)` JSON-blob schema, so
  entity shapes never need a column migration), `reconcile`/`mark_broken`. The `races`
  table is snapshotted + hydrated like every other entity (an entity added to
  `save_snapshot` but forgotten in `load_into` boots empty and the next autosave DELETEs
  the real rows — see `_should_wipe`). Both `reconcile` and `mark_broken` **skip
  `WorkspaceStatus.archived`** rows: a soft-archived race loser is worktree-less by design,
  and without the guard the next boot would read that as desync and erase exactly the rows
  the ceremony preserved. `reconcile` also settles a `running` race to `stopped` — its
  supervisor task died with the process, and a spinner with no owner has no recovery path.
  **It settles interrupted agent runs the same way** (backlog/agent-session-lifecycle.md §4):
  every `AgentRun` left `running`/`queued` with no live task in `store.active_tasks` →
  `stopped` + `ended_at`, one aggregate boot note. Without it a run in flight when the
  process died stayed persisted as `running` forever (the field defaults to `running`),
  skewing `store.latest_run` and any run-history UI. Guarded on `workspace_busy` rather
  than assuming boot, so it stays correct wherever it's called from.
- `terminal.py` — embedded PTY shell (`spawn_shell`, `set_winsize`) over
  `/ws/workspaces/{id}/terminal/{shell_id}`. A workspace hosts **several concurrent
  shells**, so each PTY is registered in `store.term_procs` under a composite
  `{ws_id}:{shell_id}` key (keying by `ws_id` alone would let a 2nd shell clobber the
  1st's handle + orphan it); the archive path in `main.py` sweeps every `ws.id:` key.
  Spawns the user's real `$SHELL -i`, so it sources
  their rc. `_neutralize_host_terminal` scrubs the launching terminal's identity
  (`TERM`→`xterm-256color`, `TERM_PROGRAM`→`haro`, drops `GHOSTTY_*`/`ITERM_*`) that
  the backend inherited from whatever terminal ran `./run.sh`, so rc gates like
  `[[ $TERM_PROGRAM == ghostty ]] && fastfetch` don't fire in the tiny grid cell.
  **nvim editor (code step's nvim option):** `spawn_editor` execs `nvim` on the same
  PTY machinery (`_spawn_pty` is the shared core behind both `spawn_shell` and
  `spawn_editor` — the controlling-tty / `setsid --ctty` setup). It's served over
  `/ws/workspaces/{id}/editor` (`editor_ws` in `main.py`, registered under the
  `{ws_id}:editor` term_procs key so the archive sweep reaps it); `main.py`'s
  `_serve_pty` is the extracted read/pump/input transport both terminal routes share.
  `[editor] nvim` (`config.ProjectSettings.nvim_mode`, byo/bundled/auto) picks WHICH
  nvim: `byo` = the user's `~/.config/nvim`; `bundled` = haro's LazyVim starter
  (`assets/nvim/`, seeded into `~/.config/haro-nvim` under an isolated `NVIM_APPNAME`
  by `_ensure_bundled_nvim` on first launch); `auto` (default) uses their config if
  present else bundled. Missing nvim → the WS writes a plain error and closes.
- `haro_skill.py` — installs the `haro` + `haro-dev` skills at user level on boot
  (meta, but useful if asked "how do the haro skills get installed").
- `analytics.py` — on-demand coverage-delta + flaky-test detection (kept out of
  the merge-gate hot path deliberately).
- **Backlog (todo files) — the 1st backlog source.** Discovery + parse live in
  `main.py`: `_discover_todo_files(project_path, backlog_dir)` runs `git ls-files`
  over the whole repo and keeps doc-ext files that are either under `backlog_dir`
  (`[backlog] dir`, default `backlog` — any name) or whose basename contains 'todo'
  (legacy; a root `TODO.md` anywhere still counts). `_parse_todo_doc(text)` parses a
  file into an ordered `blocks` list — `{kind:"note", md}` (headings/prose/context,
  rendered as read-only markdown) and `{kind:"item", …}` (the seedable `- [ ]` tasks);
  `_parse_todo` is now a thin items-only wrapper over it (the shape click-to-seed +
  `tests/test_todo_parse.py` depend on). `GET /projects/{id}/todo` (`get_todo`) returns
  per file `items`, `blocks` (interleaved render) and `content` (raw markdown, for the
  editor). `backlog.py` is the **write** seam (create/edit from the panel):
  `write_todo(project_path, rel, content, backlog_dir=)` + `is_backlog_path` guard the
  path (must be backlog-eligible + inside the project), behind `PUT /projects/{id}/todo`
  (`put_todo`, `TodoWriteRequest`); the fs watcher's `backlog_changed` refreshes the UI.
  `watcher._is_todo_doc` also recognizes the `backlog/` folder so edits there fire live.
- `issues.py` — the **GitHub Issues backlog source** (a 2nd backlog tab beside the
  parsed `backlog/*.md` files). `list_issues(project_path, force=)` shells `gh issue list
  --assignee @me --state all --limit 50 --json …` in the repo cwd (per-project
  scoping is free — `gh` reads `origin`), normalizes to the todo-row shape, sorts
  open-before-closed (recent first). Never persists issue content (GitHub is truth);
  a short-TTL in-process cache bounds `gh` calls AND doubles as the offline/rate-
  limited *display* cache (`stale` + `fetched_at` → "as of HH:MM"). Degrades to
  `available: False` (`no-remote`/`no-gh`) like the PR chip. Endpoint `GET
  /projects/{id}/issues?refresh=1` (`main.get_issues`) tacks on the same
  `seed_key="issue:<n>"`/`seeded_workspace` linkage `get_todo` uses, so click-to-seed
  + the in-progress guard work unchanged. Also `write_back_on_pickup(project_path, n)`
  — an opt-in ("`[backlog] issue_writeback`", default off), best-effort GitHub
  announcement fired from `create_workspace` when a `seed_key="issue:<n>"` workspace is
  born: self-assign + add an `in-progress` label + a "Picked up in haro" comment (so a
  teammate doesn't grab the same issue), then invalidates the display cache. Reads stay
  live/unconditional; only this *write* is gated. Tests: `tests/test_issues.py`.
- `issue_detail.py` — **on-demand detail for ONE issue** (body + comments + labels),
  fetched when a backlog row is expanded. `view_issue(project_path, number)` shells
  `gh issue view <n> --json number,title,body,state,labels,comments,url` and flattens
  it (comment author → `login`). No cache (fresh per expand — GitHub is truth), degrades
  to `available: False` (`no-remote`/`no-gh`) like the list. Kept **separate from
  `issues.py`** on purpose (disjoint file ownership for the parallel follow-ups).
  Endpoint `GET /projects/{id}/issues/{number}` (`main.get_issue_detail`).
- `review.py` — **AI code review** (the verify step's advisory "quality" lane, Bet 7
  Double Gate): one-shot `claude -p … --output-format json --tools ""` over the worktree
  diff → parsed `ReviewFinding[]` (`run_review`/`parse_findings`). `--tools ""` disables
  all tools so it stays a single text turn (the diff is embedded in the prompt) and can't
  wander into file reads and exit with an empty result. Parsing is tolerant: `is_error`
  envelopes and empty replies surface a clear reason, and `_extract_json_object` recovers
  JSON the model wrapped in prose/fences. Advisory only — never touches gate status.
  Endpoint `POST /workspaces/{id}/review` (`ReviewRequest` → `ReviewResult` in `models.py`);
  fed the latest agent prompt for plan-compliance. Tests: `tests/test_review_parse.py`.
  Deterministic-first (gitleaks/semgrep) layering is a later bet, not built.
