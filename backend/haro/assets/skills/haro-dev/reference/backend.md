# haro backend map (`backend/haro/`, Python + FastAPI + asyncio)

A navigation aid, not a spec, always read the target file before editing.
The UI that consumes all of this is the Flutter client in `app/` (see `flutter.md`). Mentions of
`.ts`/`.tsx` files below are the legacy React client (see `frontend.md`).

## Contents
- `main.py`: REST + WS routes, `lifespan` boot sequence, merge poll, `_seed_workspace`
  (the extracted create-workspace machinery)
- `adapters/`: the `AgentAdapter` seam (`claude_code.py`, `local_model.py`); Plan Mode
- `adapters/test_runner/`: the `TestRunnerAdapter` seam (Vitest/pytest/command)
- `gate.py`: the test gate + `ensure_deps`; runs the tamper alarm and the **code to check** pass
  (`unchecked.py`) on an otherwise-green gate; plus `run_watch` (the Live Gate's ADVISORY loop,
  a separate function from `run_gate` precisely so it has no code path to the verdict writes)
- `runner.py`: the agent→gate handoff (+ Plan-Mode gate skip), then the gate→rung handoff
- `integrate.py`: commit → merge → archive, follow-up PR threading, `ship_preflight` (the
  one choke point every ship path clears)
- `rungs.py`: the autonomy ladder's ACTIONS (the one rung, `auto_pr`) fired from a green gate
- `merge_queue.py`: the conflict-aware batch merge's greedy ordering engine (pure, injected IO);
  admission + the git/`integrate` shell live in `main.run_merge_queue`
- `archive_queue.py`: **bulk archive** (backlog/bulk-archive.md): the pure admission
  planner + the serial driver; the shell is `main._drain_archive_queue`
- `lifecycle.py`: setup/run/archive scripts, multiple run scripts, dep provisioning,
  plus `quiesce_workspace` (the "stop everything inside a workspace" half of the teardown)
- `hub.py`: multiplexed pub/sub + the global feed + `notify` channel
- `watcher.py`: event-driven filesystem watch. Its quiescence debounce serves TWO policies,
  forked on workspace kind: **adopted** ⇒ the authoritative auto-gate (`[trust] quiet_secs`,
  backlog/merge-firewall.md §4); **managed + `[gate] watch`** ⇒ the advisory `gate.run_watch`
  (`_WATCH_DEBOUNCE_SECS`, backlog/live-gate.md). `_quiet_secs_for` is the single policy seam
- `store.py`: in-memory reconciled cache, transcript, per-turn markers, rewind
- `git_ops.py` / `git_panel.py`: git CLI wrapper / git-panel queries
- `config.py`: `.haro/settings.toml` load/write, three-source merge, project endpoints
- `presets.py`: declarative stack-preset registry
- `models.py`: pydantic models
- `db.py`: aiosqlite snapshot/hydrate to a local SQLite file (`$HARO_DB`, default
  `~/.haro/haro.db`) + `reconcile`/`mark_broken`
- `procs.py`: the ONE process-group teardown policy every subprocess owner imports
  (`signal_tree` / `terminate_tree`)
- `terminal.py`: embedded PTY shell
- `haro_skill.py`: installs the `haro` + `haro-dev` skills on boot
- Newer modules (manual assistant `assist.py`/`research.py`, XP `xp.py`/`xp_hooks.py`, first-run
  `baseline.py`, test-first `acceptance.py`, `protect_tests.py`, `receipt.py`, `attest.py`,
  `reproduce.py`, `cli.py`, `mutation.py`, `roles.py`, `sandbox.py`, `files.py`, `editors.py`,
  `usage.py`, `update.py`, the offense runner) and what was removed: see **Newer modules** at the
  end of this file
- `analytics.py`: on-demand coverage-delta + flaky detection
- `trust.py`: autonomy-ladder rung evaluator (pure `evaluate` → `TrustReport`, no IO).
  Its project-level streak reads `store.project_test_history(project_id)`, every gate run
  across the project's workspaces, attributed by `TestRun.project_id` (stamped in `gate.run_gate`)
  so a workspace's greens survive its merge+archive. Only **green-first-try** runs climb the
  streak: `TestRun.trigger` (`"auto"` post-agent gate · `"manual"` hand-triggered · `"autofix"`
  a re-gate inside the fix loop, also stamped by `gate.run_gate`; `"watch"` the Live Gate's
  advisory loop, stamped by `gate.run_watch`), `autofix` **and** `watch` greens reset it
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
  the (now-deleted) `auto_merge` rung, cut 2026-09-17 with `auto_merge` itself
  (`notes/usp-critique-round4.md` §4: auto-merging onto the user's own `main` unattended was
  judged too dangerous for a solo/local tool). `no_tamper` today is an ordinary required
  condition like the rest, waivable via `require_no_tamper = false` same as any other.
  There is no `quality` or review condition: the Double Gate was cut (the gate is deterministic),
  so `quality` is not in `config.TRUST_CONDITIONS` and a legacy `require_quality` key is ignored.
  The IO shell around the pure evaluator is `gate.build_trust_report(store, workspace, settings)`
  (fetches `latest_test` + `project_test_history`, calls `evaluate`); it's shared by the
  `GET /workspaces/{id}/trust` endpoint (`main.get_trust`) and `run_gate`, which re-broadcasts
  the report on the **`status`** channel by piggybacking the `GateSummary` publish (`_publish_status`
  gained a `trust=` kwarg), so the ④-ship checklist + dashboard trust meter refresh on every gate
  verdict with no extra fetch (same denormalized-off-the-feed rule as `gate`). `run_gate` also
  stamps a compact `models.TrustSummary` onto `Workspace.trust` (glance subset: streak +
  rung state, via `gate._trust_summary`) so the dashboard meter ships on the workspace list,
  exactly the `Workspace.gate` (`GateSummary`) pattern; cleared alongside `gate` on "continue
  on a new branch".
  Two small **pure** helpers sit beside `evaluate` for the merge queue's admission
  (backlog/autonomy-ladder.md §3): `policy_armed(settings)`, did this *project* arm the ladder
  (`[trust] enabled` + `auto_action != "off"`)?, and `admission_reason(report)` → the skip
  message, or `None` when the rung is complete and the queue may land it. See
  `main.run_merge_queue` below for the wiring; add a new admission rule *here*, not there.
- `rungs.py`: the ladder's **actions** (backlog/autonomy-ladder.md §3), i.e. what an *armed*
  `TrustReport` is allowed to DO. `trust.py` decides, this acts; keeping them apart is what
  keeps the decision pure/unit-testable. `maybe_fire(store, hub, workspace, test)` recomputes
  the report via `gate.build_trust_report`, returns `None` unless `report.armed` (the common
  case, the ladder is opt-in), then runs `integrate.ship_preflight` and
  `git_panel.create_pr` (the one remaining rung, `auto_pr`, no merge). It **never raises**: a
  failed rung must not damage the verdict it acted on, so failures come back as a `notify`
  instead. (An `auto_merge` rung that went through the full `integrate()` path and the same
  post-merge bookkeeping as `POST /workspaces/{id}/merge` was cut 2026-09-17, see
  `notes/usp-critique-round4.md` §4, along with `no_tamper`'s hard precondition, which existed
  only to guard it.)
  **Three invariants worth not breaking:** (1) *nothing bypasses the choke point*, the rung
  clears the very same `ship_preflight` the manual buttons do, so an uncommitted worktree is
  **held, never auto-committed**; (2) *never silent*, every fired/held/failed rung publishes
  `{channel: "notify", kind: "rung", action, state, detail, pr_url, streak}` on the global feed;
  (3) *attributable*, `report_body()` renders the checklist into the PR body, via
  `git_panel.create_pr(body=…)`, which swaps `gh`'s `--fill` for `--title <tip subject> --body
  <report>`; a bodyless `gh pr create` would *prompt* and hang, so a failed title lookup falls
  back to `--fill`).
  `report_body`'s `_VERB` map carries a third, non-rung key, `"merge_queue"` → "Merge-queued",
  because `main.run_merge_queue` reuses the same renderer for the workspaces the ladder admitted,
  so a ladder-authorized merge cites its evidence identically whichever path landed it.
  **Where it's wired:** every *authoritative* gate, `runner.run_agent` (after its `finally`,
  see below), and `rungs.gate_and_fire` (= `run_gate` + `maybe_fire`) which `main.run_tests`
  and `watcher._on_quiescence`'s adopted branch schedule instead of `run_gate` directly. Tests
  that stub the watcher's gate must patch `watcher.rungs.gate_and_fire`. The advisory
  `gate.run_watch` has no path here at all (it never sets `gate_green`), and an
  impacted/`failed`-scope gate can't fire either, `trust`'s `full_scope` condition rejects it
  before `armed`.
- `secrets_scan.py`: the ADVISORY gitleaks pass (`[gate] secrets_scan`, default on).
  `scan(cwd, changed_files)` returns `SecretFinding[]` or `None` when gitleaks is missing or
  failed (`None` is silent: never degraded, never blocking). `gate._attach_secret_rows` runs it
  on a passing full-scope gate and merges `secret_found` rows (with `line`/`rule`) into
  `TestRun.unchecked_items` via `unchecked.secret_items`. The old `quality.py`, semgrep/lint
  adapters, `run_plan_compliance` and the gate-path refuter/review-fix loop were deleted;
  `TestRun.quality_*` / `review*` / `plan_compliance` fields stay on the model, unset, so old
  rows parse.
- `verified_hunks.py`: per-line proof on the ④ ship diff (pure); the annotation half of the
  diff-level signal, sharing one coverage run with `unchecked.py`
- `unchecked.py`: **code to check** (`backlog/code-to-check.md`): the DIFF-level signal, pure
  `analyze(diff_text, line_hits, tamper_findings, scope) -> UncheckedReport` with no IO, the same
  shape as `tamper.py`/`blame.py`. Exists because every OTHER gate guard is suite-level
  (`merge_result`, `coverage`, `full_scope`, `no_flaky`, `no_tamper`), so none of them can notice
  that the lines an agent just added were executed by nothing. Two coverage tiers, `no_test_file`
  (the path is ABSENT from the coverage map, i.e. nothing imports it) and `untested_lines` (imported,
  but N added lines never ran), plus deliberately boring risk rules (dep manifest, secret-ish path,
  deletion, migration) and the tamper findings folded in as `suite_weakened`, so this is the ONE
  place that answers "what has nothing checked". Reuses `tamper.parse_file_diffs` +
  `blame.changed_lines` rather than parsing the diff a third time.
  Also the home of the alarm's one **advisory** output: `tamper_rewrites=` (→
  `rewritten_items` → `assertion_rewritten` rows), a base test retitled AND re-asserted in
  place. It lands here rather than on the `green*` chip because it is not evidence the suite got
  weaker *and* because the chip only renders when there ARE tamper findings, which for this
  shape there are none, so the chip would hide it in the one case it's for. See `tamper.py`.
  The other advisory input is `vacuous_tests=` (→ `vacuous_items` → `vacuous_test` rows): new
  tests that already pass at `base_ref` (`gate._red_first_check`). Never a tamper finding, since
  a test that passes at base weakens nothing.
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
  ⚠ The coverage call is **no longer inside this pane's block**, it was hoisted in
  `run_gate` to serve BOTH diff-level signals (this pane + `verified_hunks.py`), because it costs an
  instrumented test run and neither feature should pay for its own. The entry condition is now
  `code_to_check == "warn" or verified_hunks`; if you add a third reader, read the shared
  `line_hits`, don't call the adapter again.
  ⚠⚠ **The two readers get DIFFERENT maps from that one run.** `coverage_line_maps` returns
  `(lenient, strict)` and `run_gate` hands this pane the **lenient** one and `store.set_line_hits`
  (i.e. Verified Hunks) the **strict** one. They need opposite tie-breaks where several statements
  overlap a line, because their failure modes are opposite: this pane's is a false "no test ran" row
  (so it accumulates, one hot statement makes the line hot), Verified Hunks' is telling a reviewer
  the suite executed a line it never touched (so it takes the MINIMUM, executed only if every
  statement touching the line ran). istanbul emits an enclosing `if` *around* its own never-taken
  `throw` (`5→7 count=3` over `6→6 count=0`), which is what made accumulating overclaim. Pick the
  right one deliberately if you add a reader; `_line_hits(raw, root, strict=...)` is the switch.
- `verified_hunks.py`: **Verified Hunks** (`backlog/verified-hunks.md`, round-2 Bet 12): per-line
  proof on the ④ ship diff. Pure `annotate(gate_diff, current_diff, line_hits, scope)
  -> VerifiedHunksReport`, no IO, same shape as `blame.py`/`unchecked.py`/`tamper.py`. Where
  `unchecked.py` answers "what has nothing checked?" as a *list of rows*, this answers "which of
  THESE lines ran?" as an annotation the diff viewer draws on itself, so a 1,200-line agent diff
  collapses to the residue the suite never exercised.
  **Why it takes TWO diffs, and this is the load-bearing bit:** the line map was measured against
  one particular working tree, and agent edits are **uncommitted**, a line can be inserted,
  renumbering everything below it, without HEAD ever moving. So staleness is decided **per file** by
  comparing that file's added lines at gate time (`blame.changed_lines` of the cached gate diff)
  against its added lines now; a file that moved comes back `stale=True` with an **empty** line map.
  A green dot on a shifted line is the one mistake this feature cannot survive, so silence is the
  only honest output. The gate's HEAD sha is carried for display only (`gate_sha`).
  **Three line states**, and the third is why the signal stays usable: `hits >= 1` executed,
  `hits == 0` never executed, `hits is None` **not coverable** (absent from `statementMap`, blank,
  comment, closing brace), counted separately, NEVER as untested. A file absent from the map
  entirely is its own case (`in_map=False`): nothing imports it so nothing ran, reported at file
  level with no per-line claim, mirroring `unchecked.py`'s `no_test_file` vs `untested_lines` tiers.
  Reuses `unchecked.runner_scope`/`is_source_file`/`_family` rather than re-deriving the two scope
  guards (family match + `[gate] dir` prefix).
  **Wiring:** `run_gate` caches `{sha, line_hits, diff, scope, runner}` via `store.set_line_hits`
  when `[gate] verified_hunks` is on (cache keyed by workspace with the sha INSIDE the payload, the
  endpoint must be able to *report* staleness, which a key miss cannot do), and calls
  `store.drop_line_hits` on any non-green verdict so an earlier green's proof can never be drawn
  over a failing tree. Served by `GET /workspaces/{id}/verified-hunks` (`main.get_verified_hunks` →
  `models.VerifiedHunksResponse`/`VerifiedFile`), which never runs a suite, it reads the cache and
  the current diff. `supported=False` + a note per cause (off · non-vitest runner · no coverage
  provider · no green gate on this tree yet), because those want different fixes.
  **Naming law, same as `unchecked.py` and enforced by test:** nothing says verified/proven/correct.
  An executed line is not an asserted line. Advisory by construction, there is no
  `verified_blocked`, so it cannot touch a verdict. Config `[gate] verified_hunks` (bool, default
  **false**, it annotates the reviewer's own diff, so it's switched on knowingly; it adds no test
  run). Tests: `test_verified_hunks.py` (engine), `test_verified_hunks_gate.py` (gate cache +
  green-only + the endpoint's states). Flutter half: `app/lib/features/workspace/steps/code/proof.dart` + `diff_view.dart`.
- `tamper.py`: test-tamper alarm (pure `analyze(diff_text, base_inventory, worktree_inventory)`
  → `TamperReport{findings, note, rewrites}`, no IO, same `blame.py` shape). Classifies a suspicious green
  as `green*`: `removed` tests (rename-aware inventory diff, three matching tiers so a rename /
  move / retitle yields **zero** findings), added `.skip`/`.only`/`.todo`, net-negative `expect(`
  count, and snapshot-churn ratio. The four signals are then folded by **`reconcile()`**, because
  they are not independent observers: `vitest list` reports what *would run*, so a modifier both
  trips its own signal AND vanishes from the worktree inventory. A `.skip`/`.todo` absorbs the
  removals it names (`it.skip` = its own test, `describe.skip` = every test beneath it, matched on
  the removal's ` > ` name segments); an `.only` absorbs its **whole file's** removals and carries
  the count in its detail (`.only added, 6 other tests in this file no longer run`); and
  `assertion_deltas` is dropped for any file a stronger signal already flagged, plus it skips
  whole-file adds/deletes entirely (a consolidation's deleted test file is not mass
  assertion-gutting, that was a live false positive, see `notes/e2e-gate-test-plan.md` Phase 7).
  Reconciliation only ever *merges* findings, so it can never lower a verdict, it exists purely to
  keep severity scaling with tampering rather than with detector count (the "cries wolf" kill
  condition).
  **`rewrites` is the deliberate non-finding** (`backlog/tamper-alarm.md` §1, closed 2026-07-25).
  All four signals answer "does this test still exist?", so a base test retitled **and**
  re-asserted in place is silent: the fuzzy tier pairs the retitle and swapping one assertion for
  another drops no `expect(` count. `rewritten_tests(file_diffs, retitled)` reports those pairs on
  `TamperReport.rewrites` (`kind="rewritten"`), **never** in `findings`/`note`, so it cannot reach
  `green*`, `tamper_blocked`, `trust.no_tamper` or the streak by construction rather than by every
  consumer filtering. `run_gate` routes it to `unchecked.analyze(tamper_rewrites=…)`. Option (c),
  tightening the fuzzy tier, was rejected: a retitle-plus-re-assert is also exactly what an honest
  contract change looks like, so promoting it would aim the chip at legitimate work. Mechanics to
  respect if you touch it: matching now runs once in **`pair_removals`** (returns
  `(unmatched, retitled)`; `_find_match` returns `(index, tier)` and only tier 3 = fuzzy counts as a
  retitle, since tiers 1–2 kept the name verbatim); attribution is **hunk-scoped** via the new
  `FileDiff.hunks` (context lines kept, so a title changed in one hunk can't adopt an assertion
  changed in another); comparison is the multiset of `_assertion_text` (from `expect` to EOL,
  whitespace collapsed) so a one-line retitle keeping its assertion stays silent. `_FUZZY_THRESHOLD`
  is a coin flip at this distance and `SequenceMatcher` is **order-sensitive**, `_similar(added,
  removed)` scores the §8.8 pair 0.812/0.824, the reverse 0.781/0.794, so both ratios and the
  argument order are pinned in `test_tamper.py`.
  §1 + §2 done (backlog/tamper-alarm.md): the engine +
  fixtures, `TestRun.tamper_findings`/`tamper_note`/`tamper_blocked` (pydantic `TamperFinding` twin
  of the dataclass, mirrors the `coverage_*` trio in `models.py`), and the `run_gate` wiring,
  computed on an **otherwise-green** gate only (`test.status == passed and only is None`, exactly
  the coverage-guard entry rule), via `git_ops.diff` + `analytics.test_inventories`; an engine
  crash degrades to no findings, never sinking the verdict. Mode-gated by the `[workflow]
  tamper_alarm` key (`config.load_project_settings`; `off | warn | block`, **default `warn`**, the
  one guard that's on by default, since it's deterministic + adds no test run): `warn` records
  findings but stays green, `block` sets `tamper_blocked` which folds into the `green` conjunction
  (so `integrate.py` preflight refuses it for free), `off` skips the pass. Surfaced in the Gate
  settings tab (`GateConfig.tamper_alarm` / `write_project_gate`, which OMITS the default `"warn"`,
  inverse polarity from the other guards that omit `"off"`). The `green*` chip and banner live in the Flutter verify step:
  `app/lib/features/workspace/steps/verify/tamper_banner.dart` (the compact `tamper_note`, per-finding
  rows, a red border and fix hint when `tamper_blocked`), copy in `state/verdict.dart`, and the
  restore batch built by `state/review_items.dart` (a restore instruction per finding kind) and sent
  by `data/workspace_actions.dart` `restoreTests`. Kinds now include pytest parity (deleted or
  retitled `def test_*`, `skip`/`skipif`, the `xfail` kind, assertion-count deltas, `conftest.py` and
  tox/setup.cfg edits as config), `weakened` (strict matcher to loose, one-for-one per hunk) and
  `timeout` (added or raised, never lowered); grep `tamper.py` for the full set.
  §3 in progress: the **glance star**: `models.GateSummary` gained `tamper_count` +
  `tamper_note` (stamped in `run_gate` beside the other summary fields), so the triage row and the
  needs-you count render `green*` off the coarse `status`-channel feed with
  **no fetch-per-card**; the findings themselves stay on the `TestRun` for the drill-down.
  Same denormalization rule as `gate`/`trust`; add a field here (not a new endpoint) whenever a
  gate signal has to be visible on every card. Run history needs no new endpoint either:
  `GET /workspaces/{id}/history` already returns the full `TestRun` with its tamper trio
  (persisted as one JSON blob by `db.py`; Flutter `workspaceHistoryProvider`). §3's **ladder rung** is done too: `trust.py`'s `no_tamper` condition +
  the streak's `green*` reset (its old hard `auto_merge` precondition was cut with `auto_merge`
  itself, 2026-09-17, see `trust.py` above). Remaining: the sandbox E2E.
- Backlog (todo files), the 1st backlog source (`main.py` discovery/parse + `backlog.py` write)
- `issues.py`: the GitHub Issues backlog source
- `issue_detail.py`: on-demand detail for one issue
- `review.py`: on-demand AI review (`POST /workspaces/{id}/review`), not part of the gate

---

- `main.py`: REST + WS routes, FastAPI app, `lifespan` boot sequence (reconcile,
  autosave, orphan sweep, skill install, fs-watch + merge-poll background tasks).
  **Agent start/stop (backlog/agent-session-lifecycle.md §1/§3):** `start_agent` does NOT
  refuse a run while setup is in flight, it creates the `AgentRun` as
  `AgentRunStatus.queued` and returns 200 (fire-and-forget), leaving the wait to
  `runner.run_agent`. The duplicate-same-session 409 is the guard that IS correct; keep it.
  `stop_agent` `cancel()`s then **awaits the settle** (`asyncio.wait_for(shield(task), 5s)`,
  returning `settled: bool`), "stopped" used to be a lie for as long as the process took to
  die, and now that cancellation really kills a process group there's genuine teardown to
  wait for. It only swallows `CancelledError` when `task.cancelled()` is true, so a client
  disconnect isn't mistaken for the run ending. `_detach(coro)` + the `_detached` set is the
  home for genuinely fire-and-forget background coroutines: asyncio holds only a **weak**
  reference to a running task, so a bare `create_task(...)` nobody keeps can be GC'd
  mid-flight. Anything with a real owner belongs in that owner's registry
  (`store.active_tasks`/`run_tasks`/`gate_tasks`) instead.
  `_adopt_merged_state` (GitHub-side MERGED → status `merged`, shared by the
  `GET /git/pr` route and the merge poll); `_poll_merges` (~30s, green + remote-linked
  workspaces only, detects a PR merged on github.com, which emits no local event).
  ⚠ `_adopt_merged_state` acts **only on a real PR record** (`supported && exists`).
  `pr_status` degrades to `supported=False` (no remote / no `gh` / worktree gone) or
  `exists=False` (no PR), an *absence* of evidence, not a "not merged"; reading it as one
  demoted every LOCAL merge back to `gate_green` the instant the ship panel fetched
  `/git/pr`. Promotion additionally requires the PR's `headRefOid` == the worktree HEAD
  (a branch NAME stays MERGED on GitHub forever). `GET /git/pr` returns that reconciled
  verdict as `PrStatusResponse.workspace_merged`, every client must read **that**, never
  re-derive merged from `state == "MERGED"`. Tests: `tests/test_merged_status_sync.py`.
  **Merge Firewall (adopt foreign worktrees, backlog/merge-firewall.md §1):**
  `_scan_foreign_worktrees(project)` runs `git_ops.list_worktrees` and drops every row
  haro already governs (workspaces tracked ACROSS EVERY project, not just this one,
  since nothing dedupes projects by path, the main checkout, bare) → unadopted rows
  tagged with a `source` (`_guess_worktree_source`). A row under haro's own worktree
  root that is untracked is an ORPHAN (the store lost it, e.g. a create that never
  made it into a persisted snapshot before the app quit), surfaced too, tagged
  `orphaned`, rather than silently dropped as "already governed"; otherwise a lost
  workspace's worktree/branch could never be reclaimed or freed for reuse;
  `GET /projects/{id}/worktrees` (`list_foreign_worktrees`) is the on-demand scan (refreshes
  `store.adoptable`, broadcasts a `notify`/`adoptable` hint for the *newly-appeared* rows);
  `POST /projects/{id}/workspaces/adopt` (`adopt_workspace`) registers one in place
  (`kind="adopted"`) **then runs the exact create-path provisioning** (§2, the cry-wolf
  fix): `seed_worktree_env` + `copy_worktree_includes` (both non-clobbering, so a foreign
  tool's own `.env`/certs survive) then `run_setup` under `SETUP_SESSION`, born
  `setting_up`, deps chip via `store.setup_state`; `gate.ensure_deps` no-ops on an existing
  `node_modules` **install**, real dir **or** symlink, incl. a dangling one `exists()` alone
  would miss, so a foreign install is never clobbered by the symlink stopgap. Its counterweight
  is `gate._holds_packages` (backlog/gate.md): a *package-less* `node_modules` (no `.bin`, no
  non-dot entry, i.e. a bare `npx vitest` build cache) is NOT an install, so it gets cleared
  and symlinked; "exists" was letting an agent cancel dep provisioning by running the suite.
  `reconcile_adoptable(store)` is the **boot rescan** (called from
  `lifespan`, mirrors `db.reconcile`/`mark_broken`: seeds `store.adoptable` silently, returns
  `[adoptable] …` notes). Never auto-adopts. **The firewall verdict oracle (§3):**
  `GET /firewall/verdict?repo=<abs-path>&branch=<name>` (`firewall_verdict` → `models.FirewallVerdict`)
  is what the repo-level git hook curls to decide whether a push/merge may proceed, a
  top-level route (NOT under `/projects/{id}`: the hook knows only its repo dir, not haro's
  project id). Project matched by path (`git_ops._norm_path`), workspace by branch; reads the
  denormalized `Workspace.gate`/`.status` off the store, no git/disk call, so the hook's
  `--max-time 2` curl stays fast. Tri-state: `green` ⇔ `status == gate_green`, `red` ⇔
  `gate_red`, else `unknown` (ungoverned branch, unregistered repo, or not gated yet). It only
  *reports*; blocking (fail-open warn by default) is the hook + `[trust]` config's job.
  **The hook itself (§3):** `assets/firewall/hook.sh`, one ~30-line POSIX-sh script installed
  into the repo's *shared* hooks dir (`$GIT_COMMON_DIR/hooks`) as both `pre-push` and
  `pre-merge-commit` (branches on `basename "$0"`); it curls the verdict for the branch (main
  worktree path via `git worktree list`, backend from `git config haro.url`, default
  `:8000`) and exits 1 on `red`, naming the workspace. **Failure semantics are explicit and
  keyed on `git config haro.strict`** (bool, default false, read from git config, not the
  verdict response, so fail-closed still resolves with the backend down): unreachable/timeout
  ⇒ fail-open warn by default, block under strict; verdict `unknown` (ungoverned/not-gated
  branch) ⇒ warn+allow by default, block under strict; `red` always blocks. **The installer
  (§3):** `firewall.py`, `install_hooks(repo, backend_url, strict)` writes `hook.sh` under both
  names into the repo's active hooks dir and sets `git config haro.url` (only when non-default)
  + `haro.strict`; `uninstall_hooks` disarms. **`_hooks_dir` is `core.hooksPath`-aware**
  (`git_ops.get_config`): husky/lefthook redirect git to e.g. `.husky` and git then ignores
  `$GIT_COMMON_DIR/hooks`, so we install *there*; else the shared `$GIT_COMMON_DIR/hooks`
  (`--git-common-dir`, one install governs every worktree). **Chain, never clobber:** a
  pre-existing *foreign* hook (husky's own, hand-rolled) is chained onto, `_install_one`
  appends an idempotent marker-fenced block (`_FENCE_START`/`_FENCE_END` = `# >>> haro firewall
  >>>` … `# <<< …`) carrying the firewall logic (`_fence_block` = `hook.sh` minus its shebang,
  one source of truth). Reinstall refreshes the block in place (no dup); `uninstall_hooks`
  `_strip_fence`s exactly our block (foreign hook left byte-identical) or removes a slot we
  wholly own (detected via `_HOOK_MARKER`). No conflict/`409` path, chaining always succeeds.
  `POST /projects/{id}/firewall`
  (`install_firewall` → `models.FirewallInstallRequest`/`Result`) persists the `[trust]` posture
  (`config.write_project_firewall`) then installs (`warn`/`block`) or disarms (`off`); effective
  strict = `strict or firewall == "block"` (the hook expresses posture purely through
  `haro.strict`). `git_ops.set_config`/`unset_config`/`get_config` are the config
  helpers. **Uninstall is one command (§3):** `DELETE /projects/{id}/firewall`
  (`uninstall_firewall`) is the body-less, idempotent disarm; both it and `POST {firewall:"off"}`
  route through the shared `_disarm_firewall(project)` so the two paths can't drift. Disarm is
  pure file edits + a `git config` unset (never reads gate state), with the hook's fail-open
  default, a stopped/removed haro can't brick a merge. Client seam:
  `HaroApi.installFirewall`/`uninstallFirewall` (Flutter `api/haro_api.dart`; the legacy React
  `api.ts` has twins), with no rendered control in either client. **Don't firewall ourselves (§3):** `git_ops._git` exports `HARO_INTERNAL=1`
  (`_INTERNAL_ENV`, beside `_CRED_OVERRIDE`) into every git subprocess; git passes its env to
  the hooks it spawns, so `hook.sh` early-returns (`[ "${HARO_INTERNAL:-}" = 1 ] && exit 0`) when
  haro itself drives the merge, integrate's `local_merge`, the merge queue, the gate's
  `snapshot_worktree_commit`/`create_merge_worktree`. Otherwise the base branch reads "unknown"
  and strict would block haro merging its own green work. A **convenience seam, not a security
  boundary** (any process can set the var; real enforcement is the verdict oracle, a red gate
  still blocks, and haro never merges red work internally).
  Tests: `test_firewall_verdict.py` (oracle),
  `test_firewall_hook.py` (hook + strict/unknown branches + `HARO_INTERNAL` bypass),
  `test_firewall_install.py` (config keys + writer + installer + endpoint),
  `test_git_ops.py` (the `_git` marker reaches git's hooks end-to-end).
- `adapters/`: the `AgentAdapter` seam. `claude_code.py` = `ClaudeCodeAdapter`
  (shells `claude --output-format stream-json`, normalizes to
  `token|tool_call|file_edit|done|error`). **Teardown
  (backlog/agent-session-lifecycle.md §2):** `claude` is spawned with
  `start_new_session=True` (its own process group) and `run`'s `finally` closes the inner
  `_stream` generator then calls `procs.terminate_tree`. Cancelling a run used to just
  unwind this generator, leaving `claude` AND every tool it had shelled out to alive and
  detached, so ⏹ stop, archive-mid-run and shutdown all leaked a live agent still burning
  tokens. `_stream` was split out of `run` purely to keep that `finally` visible instead of
  buried under 60 lines of parsing. The kill is only deterministic because `runner.py`
  closes the generator via `aclosing`; don't remove either half. **Plan Mode:** `run(plan=True)` swaps
  `--permission-mode bypassPermissions` for `--permission-mode plan` (propose a plan,
  edit nothing, the review surface before any file edit); the flag is per-run, threaded
  `StartAgentRequest.plan` → `run_agent` → `_drive_agent` → `adapter.run` (base + local
  accept + ignore it). (The composer "fast" toggle, a `--settings` fastMode source, was removed 2026-09-30.) `local_model.py` = `LocalModelAdapter`
  (Ollama / llama.cpp, no cloud): talks the OpenAI-compatible
  `/v1/chat/completions` API over a **curl** SSE subprocess and runs the agentic
  tool loop *itself* (read/write/edit/list/bash tools executed in the worktree),
  since a bare local model has no harness. Transport is injectable
  (`transport=`) so the loop is unit-testable without a live server
  (`tests/test_local_model_adapter.py`). New agent adapter → add here, register
  in `adapters/__init__.py`, wire into `main.py`'s `start_agent` adapter selection
  (keyed off `[agent] adapter`). The gate handoff in `runner.py` is adapter-agnostic.
- `adapters/test_runner/`: the `TestRunnerAdapter` seam: `VitestAdapter` (JS/TS,
  reads `vitest_reporter.mjs` NDJSON), `PytestAdapter` (Python, JUnit-XML),
  `CommandAdapter` (generic escape hatch, runs any configured shell command, exit
  0 → green, non-zero → red, no per-case grid). New gate runner → add here, register
  in `adapters/test_runner/__init__.py`, wire into `main.py`'s `_test_adapter`
  dispatch (keyed off `[gate] runner`).
- `gate.py`: runs the test gate (`run_gate`) + `ensure_deps` (node_modules symlink
  fallback). This is where "gate green/red" decisions are made. **Merge Firewall
  cry-wolf guard (backlog/merge-firewall.md §2):** `auto_gate_allowed(workspace,
  setup_state)` (pure), managed workspaces always auto-gate; an **adopted** worktree
  only once its provisioning reports `setup_state == "ok"`. `run_gate` enforces it at the
  top for any non-`manual` trigger (`auto`/`autofix`, incl. the §4 quiescence auto-gate
  in `watcher.py`): held → early return, no run/red-flip/record. A `manual` gate is never held. The
  Flutter client turns a resulting `error_kind="setup"` into the `rerunSetup` next action
  (`state/workspace_flow.dart`), so it reads as environment, not code.
  **The coverage guard measures, or it says so (backlog/gate.md):**
  `evaluate_coverage_guard(delta, mode, tol, unmeasured_cause=)` treats a **missing** number
  like a measured drop, `block` blocks, `warn` warns, because it used to return `("ok", None)`
  and so never blocked in exactly the case where the *measurement* broke (the easiest half to
  break: see `_holds_packages` above, running the suite by hand was enough). The note names the
  cause, reusing `analytics.coverage_delta`'s own `note` (missing provider · red suite · no run
  yet) instead of re-guessing; `gate.unmeasured_coverage_note` is the one string shared by the
  `coverage_note` row and the §0 `degraded_reasons` entry. `off` is still the escape hatch, no
  new config key. Landing it on `coverage_blocked` (not `degraded` alone) is deliberate:
  `degraded` only reaches `integrate.ship_preflight`, while `workspace.status` is what the
  dashboard, the ribbon and the firewall's verdict oracle read. The client's blocker copy
  (`app/lib/state/verdict.dart`, `BlockerKind.coverageBlocked`) is where a fix hint would fork on
  `coverage_delta == null` (fix reporting vs restore coverage).
  Tests: `test_coverage_guard.py`, `test_degraded_gate.py`, `test_ensure_deps.py`.
- `runner.py`: the agent→gate handoff: runs an agent, then triggers the gate on
  `done`. **It also owns both ways a run is HELD before it spawns**
  (backlog/agent-session-lifecycle.md §1 + §5), deliberately here and not in the route,
  because this task outlives the client that asked for it:
  * **waiting for setup**, `_await_setup` awaits `store.setup_task(ws_id)` before taking
    the worktree lock. `start_agent` used to 409 on `setup_running` instead, which pushed
    the wait onto a *frontend* queue drained only while that workspace was SELECTED, so
    "create from the backlog → run → switch away" stranded the task forever. That was the
    felt bug. Uses `asyncio.wait` (NOT `wait_for`) on purpose: a timeout must not cancel
    the install other runs are also waiting on. Bounded by `SETUP_WAIT_TIMEOUT` (900s) and
    a timeout **fails the run loudly** via `_fail_run`, §1's kill condition is a run stuck
    `queued` forever. A *failed* setup is not reported here (the deps chip + a `setup` gate
    error already say so, and the agent may be being asked to fix exactly that).
  * **waiting for a slot**, `_spawn_slot` holds one permit of a module-level
    `asyncio.Semaphore` sized by `[agent] max_parallel` (0 ⇒ uncapped), scoped tightly
    around `adapter.run` so a slot is never held through a gate. Rebuilt when the cap OR
    the running event loop changes (asyncio primitives bind to a loop on first await, and
    each test runs in its own `asyncio.run`), see `_slots`.
  Both surface as `AgentRunStatus.queued` plus a published-only line on that session's
  stream (`_notice`, the shared-branch queued-notice pattern), so a held run reads as
  "⏳ waiting", never as a hang. `_drive_agent` flips `queued → running` at the moment it
  holds the slot, i.e. the moment the run starts costing money.
  ⚠ `_drive_agent` iterates the adapter under **`contextlib.aclosing`**, and that is
  load-bearing: a bare `async for` that exits via `CancelledError` leaves the adapter's
  async generator SUSPENDED, so its teardown `finally` (which kills the `claude` process
  group) would only run whenever the GC got round to it. Don't unwrap it.
  A **Plan-Mode** run (`run_agent(plan=…)`, from `StartAgentRequest.plan`)
  edits nothing, so the handoff **skips the gate + auto-fix** for it (`gate_ready`'s
  `not plan`, step ③ stays idle). `plan` is feature-detected against the adapter's `run`
  signature (claude-code supports it; others degrade to a normal gated auto-edit run,
  never a skipped gate on real edits), and `_drive_agent` tags a plan run's terminal
  `done` event `plan: True` so the stream can offer the approve/feedback actions.
  **Multi-session:** `run_agent(session_id=…)` names which agent session the run + its
  auto-fix rounds belong to; it rides `drive_kw` so every `_drive_agent`/`_announce_autofix`
  call tags its `agent` envelope with `session_id` and `--resume`s that session's own
  `Workspace.session_resume` id (the gate stays session-agnostic, one shared worktree diff).
  **The gate→rung handoff** lands at the very end, *after* the `finally` that pops the active
  task: `await rungs.maybe_fire(…)` with the last gate result (post-auto-fix). It must run from
  a settled workspace, inside the run, `store.busy_reason` would report "an agent" and hold
  every rung forever (`test_rungs.py::test_runner_fires_the_rung_after_releasing_the_agent_slot`
  pins this). A user stop re-raises `CancelledError` before it, which is correct: a cancelled
  run's gate isn't a verdict to ship on.
- `integrate.py`: commit → merge → archive: local merge (no remote) or `gh` PR
  flow (remote present); refuses unless `gate_green`. **`ship_preflight`** is the shared choke
  point for that refusal, gate green, `store.busy_reason`, clean tree (commit-first), and
  `[workflow] merge_mode`, in one `action="merge" | "pr"` function raising `ShipRefused(msg,
  status)`. `POST /workspaces/{id}/merge`, `POST /workspaces/{id}/git/pr` (→ `HTTPException`)
  and both autonomy-ladder rungs (`rungs.py` → a held notification) call it, so an automatic
  ship can't drift into having fewer checks than the button. Also **follow-up PR threading**
  (`_followup_prefix`/`_pr_number`), a workspace continued onto a fresh branch
  prefixes "Follow-up to #N." from `workspace.prior_prs`. "Continue on a new branch"
  itself is the `POST /workspaces/{id}/continue` route in `main.py` (re-branch in
  place off the updated base, keep `last_session_id`, promote `last_pr_number` →
  `prior_prs`, clear the gate).
- `merge_queue.py` + **`main.run_merge_queue`** (`POST /projects/{id}/merge-queue`,
  `?dry=true` to preview), the conflict-aware batch merge: land every admitted workspace in a
  conflict-safe order. The module is the **greedy engine only** and pure of IO like `trust.py`
  (`run_merge_queue` / `preview_merge_queue`, with `conflict_check` + `merge_one` injected): it
  merges whatever currently merges cleanly onto its base (`git_ops.merge_tree_conflicts`, a dry
  `git merge-tree --write-tree` touching no worktree), advances the base, and re-scans, so a
  sibling that only conflicts *after* another lands is deferred, never merged into a broken
  state; the rest come back `blocked` with their conflict files. **Admission lives in the
  endpoint**, and there are two tiers:
  (1) always, green + not busy + valid worktree + clean tree + not `merge_mode = "pr"`;
  (2) **the queue inherits the autonomy ladder** (backlog/autonomy-ladder.md §3), when
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
  ⚠ Backend + `HaroApi.mergeQueue` only: no client has a "merge all green" button or results
  panel (backlog/gate.md §4).
- **`archive_queue.py` (pure planner + serial driver) + `main._drain_archive_queue` (shell)
 bulk archive** (`backlog/bulk-archive.md`). Tearing down N workspaces at once multiplies
  every failure mode simultaneously (N archive scripts, N git commands on one repo's index, a
  partial failure nobody can attribute), so a batch **drains serially**. Same decide/act split
  as `trust.py`→`rungs.py`.
  * **`plan(candidates, force=…)`** is pure: facts in (`busy` · `dirty` · `ahead` ·
    `worktree_missing` · `measured`), admission + order out. Its rule is the feature's whole
    safety story, `remove_worktree` ends in `git branch -D`, a **force** delete, so anything
    with work at stake is `skipped` **with the risk named** unless the caller forces it. Risk-free
    items are ordered **first**, so a stopped queue has done the harmless half. An
    **unmeasurable** worktree (git wouldn't answer) is risky, never clean (the coverage-guard
    rule); a **husk** (no `.git`) has nothing left to lose, so it IS admitted, archiving is the
    repair. Facts are gathered by `main._archive_candidate` (`store.busy_reason`,
    `git_ops.is_clean`, the new **`git_ops.ahead_count`**, which RAISES rather than reporting a
    comforting zero, unlike `git_panel.status`'s lenient display-side twin).
  * **`run_queue(run, archive_one=, publish=)`** is the driver: one at a time, a failed item
    recorded as `failed` and the batch continuing, and a **cooperative** stop
    (`run.stop_requested` checked *between* items, cancelling mid-`remove_worktree` is how you
    get the half-removed husk the crash-safety work exists to avoid).
  * **Wiring:** `models.ArchiveQueueRun`/`ArchiveQueueItem`/`ArchiveQueueRequest`;
    `store.archive_runs`/`archive_tasks` + `archive_running(project_id)` (one queue per project
   two would be concurrent teardowns again) + `latest_archive_run`. Endpoints:
    `POST /projects/{id}/archive-queue?dry=true` (the preview the confirm dialog renders, an
    answer, not an entity, so it's never stored), `POST …/archive-queue` (starts the detached
    driver, returns immediately), `GET …/archive-queue` (reconnect after a reload),
    `POST /archive-queue/{run_id}/stop`. Progress rides `hub.broadcast_global` as
    `notify`/`archive_queue` carrying the whole run. The teardown itself is still
    `main._teardown_workspace`, the queue adds no second way to delete a worktree.
  * **Deliberately not persisted:** a queue is an in-flight operation, not an entity. A reboot
    mid-queue leaves the untorn workspaces intact and archivable by hand; resuming a destructive
    batch the user never saw finish is the worse failure.
  * Tests: `test_archive_queue.py` (engine + endpoint admission/409/stop),
    `test_archive_queue_git.py` (a real repo, the held-back branch genuinely survives, the
    admitted worktree genuinely doesn't). Clients: `HaroApi.archiveQueue` / `getArchiveQueue` / `stopArchiveQueue` exist; the Flutter
    app has no screen for it yet (the legacy React dashboard had select mode).
- `lifecycle.py`: workspace lifecycle scripts: `run_setup`/`start_run`/`stop_run`/
  `run_archive`, `script_env` (the `HARO_*` env vars, `port=` override),
  `sweep_orphan_runs`. **Multiple run scripts:** a project can define several named
  runs (`[scripts.run.<id>]` tables, web/worker/test, each with `command`/`default`/
  `icon`, parsed in `config._parse_run_scripts` → `ProjectSettings.runs`); a bare
  `run = "cmd"` string is the legacy single run (id `app`). `start_run(…, run_id=)`
  starts one named run; `stop_run(…, run_id=)` stops one (`None` → all). `run_procs`/
  `run_tasks`/`run_ports` are keyed by `(workspace_id, run_id)`, the default run
  reuses `workspace.port` (the rail's app strip binds to it), each other run allocates a fresh
  port from `[ports] range` and releases it on stop. Run-channel WS messages carry a
  `run_id`. Also `_provision_deps` + `detect_install_cmd`, the no-setup-script fallback:
  symlink an installed `node_modules`, or auto-`npm install` a fresh JS project once
  in the project root (per-root lock, honest `setup_state`) before symlinking.
  **`quiesce_workspace(store, workspace)`** is the "stop everything running
  *inside* a workspace" step (every session's agent task + setup, the gate task, the
  PTYs, the dev servers) used by `main._teardown_workspace` (hard delete). It
  deliberately does NOT touch the port, the status or the store row.
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
- `procs.py`: the **one** process-group teardown policy, imported by every subprocess
  owner: `signal_tree(proc, sig)` (killpg with a single-pid fallback) and
  `terminate_tree(proc, grace=3)` (SIGTERM the group → grace → SIGKILL; a **no-op** on an
  already-exited process, so it's safe to call unconditionally from a `finally`, and a
  cancellation mid-teardown escalates to SIGKILL and re-raises). It exists because this
  policy was implemented once per owner and drifted: the dev-server path had it, the agent
  adapter didn't, so every stop/archive/shutdown orphaned a live `claude` and its whole
  tool tree. stdlib-only on purpose, `adapters/` imports it, so it must not drag the
  service layer in behind it. Add a new long-lived subprocess ⇒ spawn with
  `start_new_session=True` and tear down through here, never hand-rolled.
- `hub.py`: multiplexed pub/sub (workspace WS channels: `agent`/`test`/`watch`/`status`/`run`/`assist`/`fs`;
  `status`/`test`/`notify` also fan out to the global feed, and `baseline`/`xp` go out only on it via
  `broadcast_global`). **Every buffer here is
  bounded**, subscriber queues included (`_QUEUE_MAX`, 2000): `publish` hands off through
  `_offer`, which never blocks the publisher and **drops the OLDEST** envelope on a full
  queue (first drop per subscriber logged). Unbounded queues meant a consumer that stopped
  draining, wedged socket, paused tab, slow global-feed reader, grew without limit while
  an agent streamed tokens into it; and making the publisher *await* a slow socket would let
  one stalled reader stall the run. Recent output is what a live view needs; the durable
  record is `store.events`. `hub.subscribe_global`
  for the cross-workspace live feed, `hub.broadcast_global` for app-level events with
  no owning workspace (e.g. `backlog_changed`). The `notify` channel carries the coarse
  cross-workspace signals the UI beeps / desktop-notifies on: `agent_done` +
  `cost_warning` (from `runner.py`), `gate_green`/`gate_red` (from `gate.py` `run_gate`),
  `rung` (from `rungs.py`, an autonomy-ladder action fired/held/failed),
  `backlog_changed` (from `watcher.py`).
- `watcher.py`: event-driven filesystem watch (`watchfiles.awatch`, native
  inotify/FSEvents) so panels stay live without a manual refresh. Watches the worktree
  root + each project path + each **adopted** worktree path (NOT `$HOME`), adopted
  worktrees can live outside the repo tree (a claude-squad dir), so their `worktree_path`
  is added explicitly and the watch set rebuilds when one is adopted/removed. Emits
  `fs`/`changed` (per-workspace → code tree) + `notify`/`backlog_changed` (global →
  backlog). Started as a `lifespan` task. This is the "push where a local event source
  exists" half; the merge poll in `main.py` is the "poll where none does" half
  (github.com merges). **Quiescence (Merge Firewall §4):** an adopted worktree is
  agentless (no agent `done` handoff), so `_Quiescence` layers a *second* debounce on
  `fs_changed`, a per-workspace timer (re)armed on every change, firing `_on_quiescence`
  after `[trust] quiet_secs` (default 30, clamped ≥1) of silence. Only adopted workspaces
  are armed (`_dispatch`); the fire emits `fs`/`quiescent` then auto-gates, skips if
  `store.busy_reason` shows setup/agent/gate in flight, else schedules
  **`rungs.gate_and_fire`** (`run_gate` + the autonomy-ladder handoff, so an agentless green
  earns the same rung as an agent's) at the project's `[gate] default_scope` under
  `trigger="auto"` (so §2's `auto_gate_allowed` cry-wolf guard still holds it until
  provisioning is `ok`). `rungs` is a top-level import; `_test_adapter` is lazy-imported from
  `main` to dodge the load-time cycle.
  Tests: `test_quiescence.py`.
- `store.py`: in-memory state (reconciled cache, ground truth is SQLite/OS
  procs/git worktrees, see `notes/desync-hardening-plan.md`). Also owns the **persisted
  agent transcript**. `store.adoptable[project_id]` caches the last foreign-worktree scan
  (Merge Firewall); `update_adoptable(project_id, rows)` swaps in a fresh scan and returns
  the *newly-appeared* rows (diff by path), the "adoptable" hint, seeded on boot by
  `main.reconcile_adoptable`. **Multi-session data model:** a workspace holds N agent sessions,
  not one, `store.events` is keyed by `(workspace_id, session_id)` (mirrors run scripts
  keyed by `(workspace_id, run_id)`), and every transcript method takes a `session_id`
  defaulting to `store.DEFAULT_SESSION` (`"main"`), so single-session callers are byte-
  identical. Read via `store.events_for(ws_id[, session_id])` (NOT `store.events[ws_id]`,
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
  per-**session** `turn` ordinal (a `user` event, prompt echo / auto-fix announce, opens
  a new turn; agent events that follow share it), *derived from the transcript tail* so it
  needs no new persisted state and survives hydration + the 4000-event cap; `turns(ws_id[,
  session_id])` derives the rewindable boundaries (one per `user` event:
  `turn`/`prompt`/`ts`/`kind`), the "rewind to here" anchors, exposed at
  `GET /workspaces/{id}/turns` beside `/events`. **Rewind:** `store.rewind(ws_id, turn[,
  session_id])` is the *conversation* half of "rewind to here", it truncates the transcript
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
  agent runs **serialize** on a per-worktree `asyncio.Lock`, `store.agent_lock(ws_id)`, the analogue
  of `git_ops._cwd_locks`, held by `run_agent` across drive + gate + auto-fix; a 2nd session streams
  a "queued" notice immediately but only edits once the 1st releases, so its gate sees the combined
  diff (the gate was always session-agnostic, it runs on `workspace.worktree_path`). `active_tasks`
  is now keyed by **`(ws_id, session_id)`** (was bare `ws_id`) so a 2nd session isn't rejected and
  doesn't clobber the 1st's stop handle; setup rides the same registry under the reserved
  `store.SETUP_SESSION` (`"__setup__"`). Go through the helpers, never index `active_tasks[ws_id]`:
  `set_active_task`/`active_task`/`pop_active_task` (per session), `workspace_tasks`/`workspace_busy`
  (any session), `setup_running`, `setup_task(ws_id)`, the provisioning handle
  `runner._await_setup` awaits so a run fired during setup is HELD rather than refused, and
  `busy_reason(ws_id)`, the one "setup/agent/gate → label" the
  commit/PR/merge/rewind/gate/setup guards share (it replaced the inline `ws_id in reg` loops).
  `pop_active_task` takes an **optional `task=`** for an identity-checked pop (only clear the
  slot if it still holds THAT task), `run_agent`'s `finally` passes `asyncio.current_task()`
  so a settling run can never evict a newer run's stop handle from the same session.
  `start_agent`'s guard is per-session; `stop_agent` takes a `?session=` selector; teardown cancels
  every session. Tests: `tests/test_shared_branch.py`. UI composer `busy` is still workspace-level, so
  concurrent sessions are a backend/API capability pending a per-session busy UI.
- `git_ops.py` / `git_panel.py`: git CLI wrapper (serialized per-cwd lock;
  `ensure_excluded` keeps `.context/` in `.git/info/exclude`) / the git-panel
  queries (ahead/behind, log, PR status via `gh`, reconciles a GitHub-side
  `MERGED` PR to workspace status `merged`).
- `config.py`: `.haro/settings.toml` + `.local` load/write (`[scripts]`,
  `[gate]`, `[workflow]`, `[backlog]`, `[trust]`, custom instructions). (`[editor] nvim` was removed 2026-09-30; an old
  `[editor]` table is ignored.)
  `load_project_settings`
  merges three TOML sources, lowest → highest precedence: the user-global
  `~/.haro/settings.toml` (`user_settings_path`, override with `HARO_USER_CONFIG`) <
  committed `settings.toml` < personal `settings.local.toml`. `[backlog] issue_writeback`
  (default off) → `ProjectSettings.issue_writeback`, the write-on-pickup gate (see
  `issues.write_back_on_pickup`). `[backlog] dir` (default `backlog`) →
  `ProjectSettings.backlog_dir`: the folder whose docs are ALL treated as backlog
  regardless of filename (so `backlog/gate.md` works with a clean name), on top of
  the legacy "filename contains 'todo'" rule, see `main._discover_todo_files` /
  `backlog.is_backlog_path`. `[trust]` (autonomy ladder, Bet 9) →
  `ProjectSettings.trust_{enabled,streak_required,auto_action,require}`: `enabled`
  (default off), `streak_required` (default 3, clamped ≥1), `auto_action`
  (`off`|`auto_pr`, default `off`, junk → `off`, `auto_merge` was cut 2026-09-17, see
  `trust.py` above), and per-condition
  `require_<key>` flags (all default true) over the `config.TRUST_CONDITIONS` set
  (`merge_result` · `coverage` · `full_scope` · `no_flaky` · `no_tamper`);
  parsed as pure config here, written back by `write_project_trust` (`.local` may only
  *tighten* the committed team policy). The rung evaluator is `trust.py` (below) and the
  `GET /workspaces/{id}/trust` endpoint + `status`-channel re-broadcast are shipped (see
  `trust.py`); the checklist UI is still a separate `backlog/autonomy-ladder.md` item.
  The **Merge Firewall** shares the `[trust]` table (§3, backlog/merge-firewall.md):
  `firewall` (`off`|`warn`|`block`, default `off`, junk → `off`) + `strict` (default false)
  → `ProjectSettings.firewall`/`firewall_strict`, parsed by a *separate* `_parse_firewall`
  (different concern from the ladder, jurisdiction vs auto-merge) and written by
  `write_project_firewall` (targeted upsert, preserves the ladder keys). The installer that
  writes the hook + git config is `firewall.py` / `POST /projects/{id}/firewall` (above).
  `quiet_secs` (§4, default 30, clamped ≥1) → `ProjectSettings.trust_quiet_secs` is the
  quiescence debounce for `watcher.py`'s agentless auto-gate; read-only (no writer round-trip),
  parsed inline in `load_project_settings`.
  `write_project_scripts` regenerates the
  scripts/gate/ports tables wholesale; `write_project_merge_mode` + `write_project_gate`
  + `write_project_agent` are **targeted** edits (via the shared `_upsert_table_keys`
  upsert) so a settings tab can't clobber the other tables, `write_project_merge_mode`
  touches only `[workflow] merge_mode` (Git tab); `write_project_gate` writes the `[gate]`
  block (incl. `watch` and `verified_hunks`) + the flaky/coverage guard keys under `[workflow]`
  (Gate tab, add a new gate knob to `GateConfig`, `_gate_config`, this writer, and the tab's
  `settings-row`, in that order); `write_project_agent`
  writes the `[agent]` keys (Agent tab), the backend `adapter`
  (`claude-code` | `local`), the `local_base_url`/`local_model` for the local
  backend, and the Claude model/effort/budget guardrails. Custom instructions
  (`instructions.md` + `.local`, Instructions tab) go through `write_instructions`.
  The worktree `.env` seed (Environment tab) is separate from the TOML: `read_env`/
  `write_env` manage `.haro/.env` (always gitignored, secrets), and
  `seed_worktree_env` copies it into each new worktree's `.env` on create (called in
  `create_workspace`, before setup, a clean checkout never carries a gitignored `.env`).
  Beyond that dedicated seed, `[files] include = [...]` (parsed to
  `ProjectSettings.include_files`, default `[".env*"]`) is a glob list
  of gitignored files (`.npmrc` registry auth, `certs/*.pem`, service-account JSON) that
  `copy_worktree_includes` copies from the checkout into the worktree at the same
  relative path, right after the `.env` seed, only filling in missing files (so it
  never clobbers the seed or a tracked file, and refuses `..`/absolute patterns).
  Project config endpoints:
  `PUT /projects/{id}/default-branch` (base branch, stored bare), `GET/PUT
  /projects/{id}/workflow` (merge_mode), `GET/PUT /projects/{id}/gate` (runner/command/
  dir/scope/guards), `GET/PUT /projects/{id}/agent` (default model/effort + budget
  guardrails), `GET/PUT /projects/{id}/env` (worktree `.env` seed),
  `GET/PUT /projects/{id}/instructions`, `GET/PUT /remote`.
- `presets.py`: declarative stack-preset registry (vitest/pytest/shopify-theme/
  custom): each preset `detect(root)`s a confidence + serializes a `settings.toml`
  fragment (`to_toml_fragment`). `detect_stack`/`is_ambiguous` rank them;
  `detect_stack_response` builds the `GET /projects/{id}/detect-stack` payload
  (ranked candidates + a `proposal`, `None` when ambiguous, no auto-pick). New
  preset → add to `PRESETS`.
- `models.py`: pydantic models (`Workspace`, `Project`, request/response shapes).
- `db.py`: **aiosqlite** snapshot/hydrate to a local SQLite file (`$HARO_DB`, default
  `~/.haro/haro.db`; migrated off Postgres, same `(id, data)` JSON-blob schema, so
  entity shapes never need a column migration), `reconcile`/`mark_broken`. Every
  entity is snapshotted + hydrated (an entity added to `save_snapshot` but forgotten in
  `load_into` boots empty and the next autosave DELETEs the real rows, see `_should_wipe`).
  A `races` table left by a pre-2026-09-30 DB is never read, written or dropped.
  **`reconcile` settles interrupted agent runs** (backlog/agent-session-lifecycle.md §4):
  every `AgentRun` left `running`/`queued` with no live task in `store.active_tasks` →
  `stopped` + `ended_at`, one aggregate boot note. Without it a run in flight when the
  process died stayed persisted as `running` forever (the field defaults to `running`),
  skewing `store.latest_run` and any run-history UI. Guarded on `workspace_busy` rather
  than assuming boot, so it stays correct wherever it's called from.
- `terminal.py`: embedded PTY shell (`spawn_shell`, `set_winsize`) over
  `/ws/workspaces/{id}/terminal/{shell_id}`. A workspace hosts **several concurrent
  shells**, so each PTY is registered in `store.term_procs` under a composite
  `{ws_id}:{shell_id}` key (keying by `ws_id` alone would let a 2nd shell clobber the
  1st's handle + orphan it); the archive path in `main.py` sweeps every `ws.id:` key.
  Spawns the user's real `$SHELL -i`, so it sources
  their rc. `_neutralize_host_terminal` scrubs the launching terminal's identity
  (`TERM`→`xterm-256color`, `TERM_PROGRAM`→`haro`, drops `GHOSTTY_*`/`ITERM_*`) that
  the backend inherited from whatever terminal ran `./run.sh`, so rc gates like
  `[[ $TERM_PROGRAM == ghostty ]] && fastfetch` don't fire in the tiny grid cell.
  `_spawn_pty` is the controlling-tty / `setsid --ctty` core behind `spawn_shell`, and
  `main.py`'s `_serve_pty` is the read/pump/input transport. (The nvim editor PTY,
  `/ws/workspaces/{id}/editor`, was removed 2026-09-30. "Open in... Neovim" runs the user's own
  nvim in the Shell tab via `POST /workspaces/{id}/open`.)
- `haro_skill.py`: installs the `haro` + `haro-dev` skills at user level on boot
  (meta, but useful if asked "how do the haro skills get installed").
- `analytics.py`: on-demand coverage-delta + flaky-test detection (kept out of
  the merge-gate hot path deliberately).
- **Backlog (todo files), the 1st backlog source.** Discovery + parse live in
  `main.py`: `_discover_todo_files(project_path, backlog_dir)` runs `git ls-files`
  over the whole repo and keeps doc-ext files that are either under `backlog_dir`
  (`[backlog] dir`, default `backlog`, any name) or whose basename contains 'todo'
  (legacy; a root `TODO.md` anywhere still counts). `_parse_todo_doc(text)` parses a
  file into an ordered `blocks` list, `{kind:"note", md}` (headings/prose/context,
  rendered as read-only markdown) and `{kind:"item", …}` (the seedable `- [ ]` tasks);
  `_parse_todo` is now a thin items-only wrapper over it (the shape click-to-seed +
  `tests/test_todo_parse.py` depend on). `GET /projects/{id}/todo` (`get_todo`) returns
  per file `items`, `blocks` (interleaved render) and `content` (raw markdown, for the
  editor). `backlog.py` is the **write** seam (create/edit from the panel):
  `write_todo(project_path, rel, content, backlog_dir=)` + `is_backlog_path` guard the
  path (must be backlog-eligible + inside the project), behind `PUT /projects/{id}/todo`
  (`put_todo`, `TodoWriteRequest`); the fs watcher's `backlog_changed` refreshes the UI.
  `watcher._is_todo_doc` also recognizes the `backlog/` folder so edits there fire live.
- `issues.py`: the **GitHub Issues backlog source** (a 2nd backlog tab beside the
  parsed `backlog/*.md` files). `list_issues(project_path, force=)` shells `gh issue list
  --assignee @me --state all --limit 50 --json …` in the repo cwd (per-project
  scoping is free, `gh` reads `origin`), normalizes to the todo-row shape, sorts
  open-before-closed (recent first). Never persists issue content (GitHub is truth);
  a short-TTL in-process cache bounds `gh` calls AND doubles as the offline/rate-
  limited *display* cache (`stale` + `fetched_at` → "as of HH:MM"). Degrades to
  `available: False` (`no-remote`/`no-gh`) like the PR chip. Endpoint `GET
  /projects/{id}/issues?refresh=1` (`main.get_issues`) tacks on the same
  `seed_key="issue:<n>"`/`seeded_workspace` linkage `get_todo` uses, so click-to-seed
  + the in-progress guard work unchanged. Also `write_back_on_pickup(project_path, n)`
 an opt-in ("`[backlog] issue_writeback`", default off), best-effort GitHub
  announcement fired from `create_workspace` when a `seed_key="issue:<n>"` workspace is
  born: self-assign + add an `in-progress` label + a "Picked up in haro" comment (so a
  teammate doesn't grab the same issue), then invalidates the display cache. Reads stay
  live/unconditional; only this *write* is gated. Tests: `tests/test_issues.py`.
- `issue_detail.py`: **on-demand detail for ONE issue** (body + comments + labels),
  fetched when a backlog row is expanded. `view_issue(project_path, number)` shells
  `gh issue view <n> --json number,title,body,state,labels,comments,url` and flattens
  it (comment author → `login`). No cache (fresh per expand, GitHub is truth), degrades
  to `available: False` (`no-remote`/`no-gh`) like the list. Kept **separate from
  `issues.py`** on purpose (disjoint file ownership for the parallel follow-ups).
  Endpoint `GET /projects/{id}/issues/{number}` (`main.get_issue_detail`).
- `review.py`: **on-demand AI review** ("Review with AI"), a library for `POST
  /workspaces/{id}/review` and nothing else (the gate never calls it). `run_review`: one-shot
  `claude -p … --output-format json --tools ""` over the worktree diff → `ReviewResult`
  (`findings[]`). `run_refuter`: same with read-only Read/Grep/Glob tools → `ReviewVerdict`
  (`must_fix[]`, cite-or-drop in `parse_refuter_verdict`); used when `[roles] enabled` and a
  review role is set. An empty diff returns `nothing_to_review=True` (not an error) and a
  missing task is fine (the prompt says to judge the diff on its own merits). Request
  `ReviewRequest{model?}`; nothing is written to any TestRun. Tests:
  `tests/test_review_endpoint.py`, `tests/test_refuter_parse.py`. Client: the ship step's
  "Review with AI" (`app/lib/features/workspace/steps/ship/ai_review_panel.dart`).

---

## Newer modules

### Workspace mode (agent | manual)
- `Workspace.mode` (`agent` default, old snapshots hydrate as agent) and `Workspace.mode_switches`
  (`models.ModeSwitch`: target, time, HEAD sha). `POST /workspaces/{id}/mode` (`main.set_workspace_mode`)
  flips it: a same-mode call is a no-op; 409 while an agent run or start, an assistant job, a gate run
  or the setup script is live, and for merged/archived workspaces; it adds the id to
  `store.mode_switching` so a concurrent agent start is refused instead of racing; a dirty tree is
  checkpoint-committed first (`checkpoint: switch to <mode> mode`) so before and after are separable.
  `POST /projects/{id}/workspaces` takes an optional `mode`.
- `main._refuse_if_manual(ws)` is called first by every path that can start an editing agent
  (`start_agent`, plan approve, test-first draft and approve, answer/follow-up sessions): 409 `manual
  mode: the agent is off for this workspace`. Add it to any new agent-starting route. `POST
  /workspaces/{id}/review` deliberately stays allowed. `main._assist_guard` is the twin for assistant
  runs (welcome in manual mode, refused while an agent, setup or another assist job is running).
- `models.status_payload(ws, **extra)` builds every `status` event (workspace socket and global
  feed) so `mode` rides on all of them; use it instead of a hand-built dict.
- `receipt.written_by(workspace, model)` renders `you, by hand`, `agent · <model>` or `you and the
  agent (manual -> agent at HH:MM)`; the receipt markdown has a `Written by:` line.

### `assist.py` + `research.py`, the manual rail's assistant
- `assist.py` runs Claude Code as a read-only planner/researcher and enforces "no edits" in three
  layers: a tool whitelist (`READ_ONLY_TOOLS` = Read, Grep, Glob, WebFetch, WebSearch via `--tools`, the
  editing tools in `--disallowedTools`, `--permission-mode dontAsk`, `--strict-mcp-config`, never
  `bypassPermissions`); an event tripwire (a `file_edit` event or an off-list tool kills the run); a git
  guard (status + HEAD + a digest of every dirty file before and after; files the dev saved through haro
  during the run are excused). `strip_code_fences` replaces every fenced block with `CODE_REMOVED`.
  `PLAN_SYSTEM`/`ASK_SYSTEM` are the prompts; `parse_research` + `verify_sources` drop sources that point
  at nothing. When haro's own writers (gate, Live Gate, mutation, dev server, commit) ran during a job
  the guard is **inconclusive**, recorded as `unverified`, which turns "AI edits: 0" into "AI edits:
  unverified" on the receipt, PR body and footer (`models.ManualPlan.ai_edits`, `unverified`).
- `research.py` is the no-AI half (`repo` ripgrep, `git` pickaxe/log/blame, `man` offline pages, `web`
  search links only, nothing fetched); it returns `ResearchRow` pointers, never prose or code.
  `DOCS_SITES` maps a detected stack to its official-docs domain. `extract_identifiers` +
  `merge_git_hits` are what an `ask` adds: git rows for up to 3 identifiers in the question (deduped by
  commit, total rows <= 8), which also sets `git_search_before_green` for the regression-hunter badge.
- Routes in `main.py`: `POST /workspaces/{id}/assist/plan`, `/assist/research` (`scope` defaults to `ask`,
  the only one the client sends: it starts a job; `repo|git|man|web` answer inline for scripts/tests), `/assist/stop`, `GET /workspaces/{id}/assist` (latest job, for a
  reconnecting client), `GET/PATCH/DELETE /workspaces/{id}/plans[/{plan_id}]` (saved plans, stored in
  haro not the repo, appended to the PR body), `GET/PUT /projects/{id}/pinned-docs`, `GET /man/{page}`.
  Progress rides the workspace socket's `assist` channel (`main._start_assist` / `_drive_assist`).
- Client: `app/lib/features/workspace/rail/manual/` and `state/manual_rail.dart`.

### `xp.py` + `xp_hooks.py`, XP, rank, streak
- `xp.py` is pure: `RULES` (the award table, the single source served by `GET /xp/rules`),
  `award_for`, `level_for` (`LEVEL_XP` = 180), `rank_for` (Novice, Journeyman, Craftsman, Master),
  `streak_state` (`STREAK_DAYS` = 14; days with a by-hand green merge), `build_status`. Un-farmable by
  construction: an activity pays once per kind per local day, a merge pays once per workspace and only
  green with a non-empty diff, nothing pays for a red or blocked run. `CLIENT_KINDS` (`docs_read`,
  `diff_reviewed`) are the only kinds a client may report.
- `xp_hooks.py` is the side-effecting half: it reads workspace facts (`by_hand` = manual and never
  switched, hand-saved and test paths, mutation survivors, research scopes), asks `xp.award_for`, writes
  the `xp_events` ledger (`store.xp_events`, persisted by `db.py`, table `xp_events`) and broadcasts an
  `xp` event on the global feed. Every public function swallows its own failure: XP must never break a
  merge or a gate run. Call sites: `gate.run_gate` (`on_gate_finished`), the merge routes and
  merge queue in `main.py` (`record_merge`), the assist and research routes, file save
  (`note_hand_saved`), mutation (`note_mutation`).
- Routes: `GET /xp`, `/xp/rules`, `/xp/events`, `POST /xp/activity`. The receipt's XP line is ship-card
  only (`receipt._xp_line`), never in PR bodies.

### `baseline.py`, first-run baseline gate
`run_baseline` runs one full-scope gate on the project's default branch in a throwaway
`git worktree add --detach` (never the user's checkout), seeded like a workspace (`.haro/.env`, `[files]
include`), with the runner chosen from the default branch's own committed config. Result on
`Project.baseline` (`models.BaselineState` / `BaselineResult`: status, counts, up to 20 failing ids,
coverage for a green vitest run, a note when a setup script was not run); no workspace or `TestRun` is
created and it can never block a merge. `sweep_stale`/`sweep_stale_all` remove temp worktrees a killed
run left (owner-pid file, live dirs never touched); run at boot and before each run. `POST/GET
/projects/{id}/baseline`, events on the global `baseline` channel. Client: `features/first_run/`.

### `acceptance.py` + `protect_tests.py`, test-first and protected tests
- `acceptance.py`: Phase A (the agent drafts only a failing acceptance test; `scan_draft` checks the
  diff afterwards: only brand-new test files may appear), red proof (`judge_red`: every collected case
  must fail; zero collected, a pass or a skip blocks approval), approval (sha256 per file), and the
  gate check (`check_acceptance`, `verify_unchanged_since_proof`): every approved case present and
  passing and each file byte-identical, else `acceptance_blocked` blocks the merge whatever
  `[workflow] tamper_alarm` says. State on `Workspace.test_first`; routes `POST
  /workspaces/{id}/test-first/approve` and `/cancel` plus `StartAgentRequest.test_first`; receipt line
  via `receipt_line`. The build run gets edit-deny rules for the approved files (`build_deny_patterns`).
- `protect_tests.py`: `[agent] protect_tests = "existing"` (or the per-run `StartAgentRequest.protect_tests`)
  builds deny rules (`protected_patterns`, `deny_patterns_at`) for every test file tracked at `base_ref`,
  passed to the CLI as `--disallowedTools` in `adapters/claude_code.py`; deny rules still apply under
  `bypassPermissions`. A speed bump, never a guarantee: the tamper alarm is the check.
- Client: `state/test_first.dart`, `features/workspace/steps/agent/acceptance_panel.dart`.

### Git panel stage and unstage
`git_panel.stage(worktree, paths)` / `unstage(...)` (literal pathspecs; refused while an agent or gate is
running; merge conflicts are never staged) behind `POST /workspaces/{id}/git/stage` and `/git/unstage`;
`git_panel.commit(..., staged_only=True)` (`POST /workspaces/{id}/git/commit` with `staged_only`)
commits only the index. `git status` is parsed with `-z` so spaced and non-ASCII paths work. Client:
the code step's Changes panel (`features/workspace/steps/code/workbench/changes_panel.dart`).

### Other modules
- `receipt.py` builds the Gate Receipt (`GET /workspaces/{id}/receipt`, PR line `receipt.pr_line`,
  `POST /workspaces/{id}/receipt/pr-comment`); runs no test, mutation or `gh` call of its own.
- `attest.py` (signed in-toto-shaped statement over a receipt, ed25519, saved under
  `.haro/attestations/`), `reproduce.py` (`haro verify <sha> --rerun`: re-run the gate on the attested
  tree in a throwaway worktree and compare verdicts; `POST /workspaces/{id}/verify` is a thin wrapper),
  `cli.py` (`haro gate [--attest]`, `haro verify`: the same gate headless, no server).
- `mutation.py` is the on-demand mutation score engine (pure; `run_suite` injected) behind
  `POST /workspaces/{id}/mutation`; advisory, no `mutation_blocked`. The unmutated suite must pass
  first or the run is refused.
- `roles.py` builds the read-only `scout` sub-agent passed with `--agents` when `[roles] scout` is set.
- `sandbox.py` two bubblewrap profiles: the gate's suite with network denied (`[gate] sandbox`) and
  the agent subprocess confined to the worktree (`[agent] sandbox`).
- `files.py` worktree file access for the editor routes (`/files`, `/file`, `/fs/*`); paths are always
  resolved inside the worktree. `editors.py` detects external editors and spawns GUI ones
  (`GET /editors`, `POST /workspaces/{id}/open`); terminal editors are typed into the Shell tab by the
  client.
- `usage.py` (Claude subscription rate-limit windows, `GET /usage`), `update.py` (in-app self-update of
  the packaged build, `/update/*`).
- `adapters/test_runner/offense.py` (`OffenseAdapter`): a JSON-emitting linter (`theme-check`, `eslint`,
  `ruff`) rendered as the gate grid, selected by `[gate] runner = "offense"` + `format`.

### Removed (2026-09-30), do not look for them
`race.py`, `fanout.py`, the `[race]` config, the `/projects/{id}/race*` and `/races*` endpoints, the
`races` table (an old DB still boots; the table is never read or written), `Workspace.race_id`; the
composer `fast` toggle (`StartAgentRequest.fast`, `--settings` injection); the Neovim editor PTY
(`/ws/workspaces/{id}/editor`, `terminal.spawn_editor`, `assets/nvim/`, `[editor] nvim`); and the
gate-path quality scanners, plan compliance and refuter loop (see `secrets_scan.py` above). Old
`[race]`, `[editor]` and `[quality]` tables and `review_enforce` keys in a settings file are ignored.
