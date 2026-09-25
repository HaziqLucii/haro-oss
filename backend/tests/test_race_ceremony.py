"""§3's loser afterlife — soft-archive, keep the branch, survive a reboot.

The ceremony's whole claim is "you review one diff, and the ones you didn't review are
still there if you want them". These tests hold that claim to three concrete promises,
each of which was easy to break:

1. the loser's **row + transcript** survive (a hard teardown drops both),
2. the loser's **branch + committed diff** survive (`worktree remove --force` would
   otherwise take an agent's uncommitted work with it),
3. the loser survives the **next boot** (`db.reconcile` deletes workspaces whose
   worktree directory is gone — which is exactly what a soft-archived one looks like).

Run against a real throwaway git repo, because promises 2 and 3 are about git and the
filesystem, and a stubbed git would prove nothing about either.
"""

from __future__ import annotations

import asyncio
import os
import subprocess
from pathlib import Path

from haro import db, fanout
from haro.config import ProjectSettings
from haro.hub import Hub
from haro.models import Project, RaceLane, RaceRun, Workspace, WorkspaceStatus
from haro.store import Store


def _git(*args: str, cwd: Path) -> str:
    env = {
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
        "PATH": os.environ.get("PATH", ""),
    }
    out = subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True)
    return out.stdout


def _repo_with_lane(root: Path) -> tuple[Store, Project, Workspace, RaceRun]:
    """A project + one race lane whose agent left UNCOMMITTED work — the normal case,
    and the one that makes the checkpoint commit load-bearing."""
    repo = root / "repo"
    repo.mkdir()
    _git("init", "-b", "main", cwd=repo)
    (repo / "a.txt").write_text("hello\n")
    _git("add", ".", cwd=repo)
    _git("commit", "-m", "init", cwd=repo)

    wt = root / "lane"
    _git("worktree", "add", "-b", "haro/lane", str(wt), "main", cwd=repo)
    (wt / "loser.txt").write_text("the work nobody merged\n")  # uncommitted, like an agent leaves it

    store = Store()
    project = Project(name="p", path=str(repo), default_branch="main")
    store.add_project(project)
    ws = Workspace(
        project_id=project.id, name="lane", branch="haro/lane",
        worktree_path=str(wt), base_ref="main", port=4321,
    )
    store.add_workspace(ws)
    store.append_event(
        ws.id,
        {"run_id": "user", "workspace_id": ws.id, "ts": 1.0, "type": "user",
         "payload": {"text": "the losing lane's prompt"}},
    )
    run = RaceRun(project_id=project.id, task="t", winner_id="ws_winner")
    run.lanes = [RaceLane(workspace_id=ws.id, name="lane", branch="haro/lane")]
    store.add_race(run)
    ws.race_id = run.id
    return store, project, ws, run


def _soft_archive(store: Store, project: Project, ws: Workspace) -> None:
    asyncio.run(
        fanout.soft_archive_lane(
            store=store, hub=Hub(), project=project,
            psettings=ProjectSettings(), workspace=ws,
        )
    )


def test_a_soft_archived_loser_keeps_its_row_and_transcript(tmp_path):
    store, project, ws, _run = _repo_with_lane(tmp_path)
    _soft_archive(store, project, ws)

    assert store.get_workspace(ws.id) is not None, "the row is what the scorecard links to"
    assert ws.status == WorkspaceStatus.archived
    assert store.events_for(ws.id), "the transcript is the point of keeping the row"
    assert not Path(ws.worktree_path).exists(), "the checkout itself IS reclaimed"
    assert ws.port is None and 4321 not in store.allocated_ports, "the port goes back"


def test_the_losers_branch_and_diff_survive(tmp_path):
    """Refs are cheap; an agent's uncommitted work is not recoverable. So the ceremony
    checkpoints the worktree onto its branch BEFORE removing the checkout — without
    that, "keep loser branches so the diff stays diffable" would be a branch pointing
    at base with nothing on it."""
    store, project, ws, _run = _repo_with_lane(tmp_path)
    _soft_archive(store, project, ws)

    repo = Path(project.path)
    assert "haro/lane" in _git("branch", "--list", "haro/lane", cwd=repo)
    diff = _git("diff", "--name-only", "main", "haro/lane", cwd=repo)
    assert "loser.txt" in diff, "the loser's work is still diffable from its branch"


def test_reconcile_does_not_delete_a_soft_archived_loser_on_the_next_boot(tmp_path):
    """`reconcile` drops workspaces whose worktree directory is gone — which is exactly
    what a soft-archived lane looks like. Without the archived guard, the very next
    boot would erase the rows the ceremony went out of its way to preserve."""
    store, project, ws, _run = _repo_with_lane(tmp_path)
    _soft_archive(store, project, ws)

    notes = db.reconcile(store)

    assert store.get_workspace(ws.id) is not None
    assert store.events_for(ws.id)
    assert not any("dropped workspace" in n for n in notes)


def test_mark_broken_leaves_a_soft_archived_loser_alone(tmp_path):
    """The husk classifier keys off a missing `.git`, which an archived lane also
    lacks. It must not relabel a deliberate archive as "needs repair"."""
    store, project, ws, _run = _repo_with_lane(tmp_path)
    _soft_archive(store, project, ws)

    asyncio.run(db.mark_broken(store))

    assert store.get_workspace(ws.id) is not None
    assert ws.status == WorkspaceStatus.archived


def test_purging_losers_is_the_explicit_irreversible_step(tmp_path):
    """Archiving keeps the branch; purging is the separate "I'm done second-guessing"
    action that actually deletes it."""
    store, project, ws, run = _repo_with_lane(tmp_path)
    _soft_archive(store, project, ws)

    asyncio.run(fanout.purge_losers(store=store, hub=Hub(), project=project, run=run))

    assert store.get_workspace(ws.id) is None
    assert _git("branch", "--list", "haro/lane", cwd=Path(project.path)).strip() == ""
    assert run.losers_purged is True


def test_purging_never_touches_the_winner(tmp_path):
    store, project, ws, run = _repo_with_lane(tmp_path)
    run.winner_id = ws.id  # this lane won

    asyncio.run(fanout.purge_losers(store=store, hub=Hub(), project=project, run=run))

    assert store.get_workspace(ws.id) is not None
    assert Path(ws.worktree_path).exists()


def test_archiving_losers_is_idempotent(tmp_path):
    store, project, ws, run = _repo_with_lane(tmp_path)
    hub = Hub()
    kw = dict(store=store, hub=hub, project=project, psettings=ProjectSettings(), run=run)
    asyncio.run(fanout.archive_losers(**kw))
    asyncio.run(fanout.archive_losers(**kw))  # a re-judge / retry must not double-archive

    assert run.losers_archived is True
    assert store.get_workspace(ws.id) is not None
    assert ws.status == WorkspaceStatus.archived


def test_a_race_resolves_from_any_of_its_lanes(tmp_path):
    """Resolved through `Workspace.race_id` rather than by scanning lane lists, so a
    soft-archived loser still finds its own scorecard."""
    store, _project, ws, run = _repo_with_lane(tmp_path)
    assert store.race_for_workspace(ws.id) is run


def test_stopping_a_race_cancels_its_LANES_not_its_supervisor(tmp_path):
    """The distinction that keeps a stopped race from becoming an orphaned spinner: the
    supervisor's `finally` is what judges whatever finished, and a cancelled supervisor
    dies at its first await inside that block. The spend already happened, so refusing to
    show the result would be the worst of both."""
    store, _project, _ws, run = _repo_with_lane(tmp_path)

    async def scenario():
        lane_task = asyncio.create_task(asyncio.sleep(3600))  # a lane still running
        supervisor = asyncio.create_task(asyncio.sleep(3600))
        store.race_tasks[run.id] = supervisor
        store.race_lane_tasks[run.id] = [lane_task]

        stopped = fanout.request_stop(store, run)
        await asyncio.sleep(0)
        result = (stopped, lane_task.cancelled(), supervisor.done())
        supervisor.cancel()
        return result

    stopped, lane_cancelled, supervisor_done = asyncio.run(scenario())
    assert stopped == 1
    assert lane_cancelled is True
    assert supervisor_done is False, "the supervisor must survive to judge + settle"
    assert run.status == "stopped"
    assert run.lanes[0].status == "stopped"
    assert run.lanes[0].note == "stopped by hand"


def test_a_stopped_race_still_gets_a_verdict_and_keeps_saying_stopped(tmp_path):
    """`stopped` outranks `judged`/`refused`: it's the only status that explains why some
    lanes have no verdict, so a budget-capped race must never read as a clean result."""
    store, project, ws, run = _repo_with_lane(tmp_path)
    run.status = "stopped"
    run.winner_id = None
    run.lanes[0].green = True
    run.lanes[0].status = "green"
    run.lanes[0].impacted_count = 9

    asyncio.run(
        fanout.judge_race(
            store=store, hub=Hub(), project=project,
            psettings=ProjectSettings(), run=run,
        )
    )

    assert run.status == "stopped"
    assert run.verdict is not None, "the spend happened — the scorecard is still owed"
    assert run.winner_id == ws.id


def test_a_running_race_is_settled_on_boot(tmp_path):
    """Its supervisor task died with the process, so it can never make progress. A
    spinner with no owner is the one outcome the UI has no recovery path for."""
    store, _project, _ws, run = _repo_with_lane(tmp_path)
    run.status = "running"

    notes = db.reconcile(store)

    assert run.status == "stopped"
    assert "restarted" in run.reason
    assert any("settled race" in n for n in notes)
