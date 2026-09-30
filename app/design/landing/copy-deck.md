# haro landing: copy deck

Status: DRAFT for founder review, 2026-09-30. Not published. Layout (founder, 2026-09-30): a hero, then one section
per thing we demonstrate, each with its own screenshot. "Relive life as a developer." heads the Manual mode
section only; the hero is "Arise, Developers~". Sources are `CHANGELOG.md` `[Unreleased]` unless stated.
HTML comments are for the integrator, not page copy.

---

## HERO

**H1:** Arise, Developers~
<!-- Founder's pick 2026-09-30. Keep it alone on its line, large, so the tilde reads as deliberate. -->

**Subline:** Write the code yourself, or hand it to an agent. Either way, nothing merges until your tests are green.
<!-- src: Workspace mode: agent | manual; The gate is fully deterministic. Reuses the old tagline as the subline. -->

**Primary CTA:** Build it from source
**Secondary CTA:** See it work (scrolls to section 01)
**Fine print:** Download for Linux is coming with the first release. Linux first.
<!-- src: Linux release build (no v* tag yet, so the download stays "coming soon") -->

**Screenshot:** none, or a quiet wide crop of triage (`shot-triage`) behind the headline.

---

## 01 // Manual mode

**Heading:** Relive life as a developer.

**Body:** Flip a workspace to "Me, by hand" and the agent is off. Three steps: code, verify, ship. You write every line. haro plans, researches, and keeps score.
<!-- src: Workspace mode: agent | manual (three steps, manual refuses every agent start); Flutter client "Who writes it: Agent | Me, by hand" -->

**Caption line:** Plan it. Write it. Verify it. Ship it. The receipt says you wrote it.
<!-- src: Workspace mode (receipt `written_by`: "you, by hand") -->

**Screenshot `shot-manual`:** a manual workspace on the code step, the top bar switch on MANUAL, the Plan tab in
the rail showing a ticked checklist ("PLAN BY HARO · CODE BY YOU"), the footer "AI: plan and research only · AI edits: 0".

---

## 02 // The assistant

**Heading:** It plans and points. It cannot edit.

**Body:** In manual mode haro's AI has no edit tools and no shell: read, search, fetch, nothing else. Ask it to plan and you get a checklist with the reason for the order. Ask where to look in one box and you get a short answer with sources: files in your repo, git commits and blame, docs links. Code in its answers is stripped, so it points and you write.
<!-- src: Manual rail (read-only whitelist, verified live; fence stripping; Search is one ask box; git lookups merged in) -->

**Proof line:** haro checks git before and after every job. The receipt reads "AI edits: 0" when that check is clean, and "unverified" when something else was writing and it can't tell.
<!-- src: Manual rail (before/after git guard; "AI edits: unverified") -->

**Screenshot `shot-search`:** the Search tab with an `ask` answer (one short line) above its sources, grouped repo / git / docs (no scope chips).

---

## 03 // A real editor, inside haro

**Heading:** Everything you need to write it, in one window.

**Body:** File tree, search across the repo, tabs, split view, a minimap, staging per file and a terminal. The gutter marks every added line the passing suite actually ran. Save and the gate re-runs, if you want it to.
<!-- src: Code step as a small IDE; bottom panel; `[gate] run_on_save` -->

**Screenshot `shot-code`:** the code step: explorer with A/M letters, a diff open, breadcrumbs, the status bar.
<!-- Have: v-code.png from the 2026-09-30 capture pass (agent workspace). Retake on a manual workspace for consistency. -->

---

## 04 // The gate

**Heading:** The referee. No model decides green.

**Body:** The verdict comes from your own tests, run on your machine. The tamper alarm flags deleted, skipped, weakened or loosened tests. The mutation score changes your added lines and checks the tests notice. Needs-your-eyes items never block, but they are in plain view.
<!-- src: The gate is fully deterministic; Tamper alarm gap closure; Mutation score (advisory, on demand) -->

**Screenshot `shot-verify`:** the verify step, green verdict, metrics row.
**Second screenshot `shot-red`:** a tamper-blocked red verdict ("inclusive threshold": run `git checkout -- .` in its
worktree first to restore the tampered state).
<!-- Have: v-verify.png (green). The red shot needs the showcase worktree restored. -->

---

## 05 // Ship with a receipt

**Heading:** A receipt that says who wrote it.

**Body:** Merge only on green. The gate receipt goes on the PR: the verdict, test counts, the tamper check, mutation, and who wrote the code: you, the agent, or both.
<!-- src: Gate Receipt; Workspace mode (`written_by`); PR text line -->

**Screenshot `shot-ship`:** the ship step with the merge panel and the receipt card.
<!-- Have: v-ship.png (agent). A manual one would show "Written by: you, by hand" and the Plan row. -->

---

## 06 // XP

**Heading:** Points only green merges earn.

**Body:** A level, a rank from Novice to Master, a streak and a few badges. Red earns nothing. Busywork earns nothing. The big ones are for work done by hand: red to green yourself +120, killing a surviving mutant +40, starting from a failing test +30.
<!-- src: XP, rank and streak -->

**Screenshot `shot-xp`:** the sidebar footer (level, rank, bar, streak) with the "How XP works" popover open, and a "+120 XP" toast.

---

## 07 // Agent mode

**Heading:** Rather hand it off? Same gate.

**Body:** Switch a workspace to Agent and describe the task. The agent works in its own git worktree, and the same gate, tamper alarm and receipt apply. Switch mid-task if you like: haro commits your part first, so the receipt can say both of you wrote it.
<!-- src: Workspace mode (checkpoint commit on switch, `written_by` "you and the agent") -->

**Screenshot `shot-agent`:** the agent step mid-run, tool lines streaming, the rail's gate block.

---

## 08 // Triage

**Heading:** One list of what needs you.

**Body:** Every workspace across your projects, grouped by what it needs: you, running, ready to ship, idle, merged. One action per row.
<!-- src: Flutter client triage -->

**Screenshot `shot-triage`:** triage with a few groups filled.
<!-- Have: v-triage.png. Busier data would read better. -->

---

## 09 // Local first, Linux first

**Body:** The gate, git, the editor and the terminal run on your machine against your own repo. The assistant uses your Claude Code login. No GitHub OAuth: pull requests go through your own `gh`.
<!-- src: The Flutter app starts its own backend; Manual rail (Claude Code); CLAUDE.md (local git, optional gh, no OAuth) -->

---

## Honest status

**Works today:** manual mode (plan, search, docs, editor, terminal) · agent or manual per workspace · test gate,
tamper alarm, mutation score · gate receipt with "written by" · XP, rank, streak, badges · first-run baseline on
your default branch · local merge and GitHub PRs via `gh`.

**Not yet:** offline framework docsets (man pages work offline today) · Windows · a tagged release and download
(build from source today).

---

## FAQ

**Is this anti-AI?**
No. Agent mode stays, with the same gate. Manual mode is for the days you want to write it yourself.

**Can the AI write code in manual mode?**
No. It has no edit tools and no shell, and haro checks git before and after every job. Code is stripped from its answers.

**What stops me farming XP?**
Daily activity pays once per kind per day. Merge awards pay once per workspace, only on a green, non-empty, unblocked merge. Needs-your-eyes ticks count only when they match a real item.

**Can I cheat by pasting code from another chatbot?**
Yes. haro can't see outside your workspace, and it doesn't try to. XP is a personal score in your own install, so the only person you'd fool is you.
<!-- Kept deliberately (founder, 2026-09-30): honest about the limit. -->

**What happens if I switch to Agent halfway?**
haro asks first and commits your work. XP you already earned stays yours; the merge pays agent rates, and that task no longer counts toward your streak.

**Does it work on Windows?**
Not yet. Linux is tested first.

**Is it free and open source?**
Yes. MIT licensed, the source is on GitHub, and everything runs on your machine.
<!-- License: MIT (scripts/publish-oss.sh adds it to the public mirror). -->

---

## Screenshot shot list (integrator)

Capture with a `HARO_CAPTURE=true` debug build: write the route to `<capture dir>/.go`, then the file name to
`.shoot` (capture dir in the macOS sandbox: `~/Library/Containers/dev.haro.haroApp/Data/tmp/haro-captures`).

| Shot | File (`shots/v2/`) | Status |
|---|---|---|
| shot-triage | shot-triage.jpg, shot-xp-triage.jpg (with a "+10 XP" toast) | done 2026-09-30 |
| shot-manual | shot-manual.jpg (manual code step, Plan 6/8 ticked) | done |
| shot-search | shot-search.jpg (rail crop: ask answer + sources, AI edits: 0) | done 2026-09-30 (taken by hand) |
| shot-code | shot-code.jpg (agent workspace); shot-manual.jpg also shows the code step | done |
| shot-verify | shot-verify.jpg (manual, green 18/18) | done |
| shot-red | shot-red.jpg ("The test suite was weakened", tamper alarm) | done |
| shot-ship | shot-ship.jpg (manual, "Written by: you, by hand", receipt) | done |
| shot-xp | shot-xp.jpg (How XP works popover); shot-xp-triage.jpg (footer + toast) | done 2026-09-30 |
| shot-agent | shot-agent.jpg (agent working, Stop, "Agent running") | done |

Showcase data (gate-sandbox, 2026-09-30): `weekend surcharge` (manual, written by hand, plan 6/8, 1 ask
lookup, committed as HaziqLucii), `format shipping cost` (agent run), `inclusive threshold` (tamper-red restored).
