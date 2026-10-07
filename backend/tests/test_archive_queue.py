"""Bulk archive (backlog/bulk-archive.md): the pure admission planner + the serial
driver's three promises — one teardown at a time, one failure never eats the batch,
and a stop that lets the in-flight teardown finish."""

import asyncio

import pytest
from fastapi import HTTPException

from haro import main as main_mod
from haro.archive_queue import Candidate, plan, run_queue, summarize, to_items
from haro.models import ArchiveQueueRequest, ArchiveQueueRun, Project, Workspace, WorkspaceStatus
from haro.store import Store


def _run(items, force=False):
    return ArchiveQueueRun(project_id="p1", force=force, items=items)


def _clean(name):
    return Candidate(id=name, name=name)


# --------------------------------------------------------------------------- #
# plan — admission
# --------------------------------------------------------------------------- #
def test_clean_workspaces_are_all_queued():
    items = plan([_clean("b"), _clean("a")])
    assert [(i.name, i.queued) for i in items] == [("a", True), ("b", True)]
    assert all(not i.risks for i in items)


def test_work_at_stake_is_skipped_by_default():
    items = plan([
        _clean("clean"),
        Candidate(id="d", name="dirty", dirty=True),
        Candidate(id="u", name="unmerged", ahead=3),
        Candidate(id="r", name="running", busy="an agent"),
    ])
    by_name = {i.name: i for i in items}
    assert by_name["clean"].queued
    for name in ("dirty", "unmerged", "running"):
        assert not by_name[name].queued, name
        assert by_name[name].reason  # the skip always says what it would have cost
    assert "3 unmerged commits" in by_name["unmerged"].reason
    assert "1 unmerged commit" in plan([Candidate(id="x", name="x", ahead=1)])[0].reason


def test_force_takes_the_risky_ones_but_keeps_the_receipt():
    items = plan([Candidate(id="d", name="dirty", dirty=True, ahead=2)], force=True)
    assert items[0].queued
    # Forced ≠ forgotten: the record still says what the user agreed to lose.
    assert len(items[0].risks) == 2


def test_risk_free_workspaces_run_first():
    # So a stopped queue has done the harmless half and none of the destructive.
    items = plan([Candidate(id="a", name="a", dirty=True), _clean("z")], force=True)
    assert [i.name for i in items] == ["z", "a"]


def test_a_husk_has_nothing_left_to_lose():
    # An interrupted `worktree remove` left a directory with no `.git`: archiving is
    # the repair, so it must not be held back as if it held unsaved work.
    items = plan([Candidate(id="h", name="husk", worktree_missing=True, busy="an agent")])
    assert items[0].queued
    assert items[0].risks == []


def test_an_unmeasurable_worktree_is_risky_not_clean():
    items = plan([Candidate(id="m", name="m", measured=False)])
    assert not items[0].queued
    assert "couldn" in items[0].reason  # "couldn’t check this worktree…"


# --------------------------------------------------------------------------- #
# run_queue — the serial driver
# --------------------------------------------------------------------------- #
def test_teardowns_never_overlap():
    inflight = 0
    peak = 0
    order = []

    async def archive_one(ws_id):
        nonlocal inflight, peak
        inflight += 1
        peak = max(peak, inflight)
        await asyncio.sleep(0)  # yield: a parallel driver would interleave here
        order.append(ws_id)
        inflight -= 1

    async def publish(_run):
        pass

    run = _run(to_items(plan([_clean("a"), _clean("b"), _clean("c")])))
    out = asyncio.run(run_queue(run, archive_one=archive_one, publish=publish))
    assert peak == 1
    assert order == ["a", "b", "c"]
    assert [i.outcome for i in out.items] == ["archived"] * 3
    assert out.state == "done"


def test_one_failure_does_not_eat_the_batch():
    async def archive_one(ws_id):
        if ws_id == "b":
            raise RuntimeError("git worktree remove failed")

    async def publish(_run):
        pass

    run = _run(to_items(plan([_clean("a"), _clean("b"), _clean("c")])))
    out = asyncio.run(run_queue(run, archive_one=archive_one, publish=publish))
    outcomes = {i.name: i.outcome for i in out.items}
    assert outcomes == {"a": "archived", "b": "failed", "c": "archived"}
    assert "git worktree remove failed" in next(i.reason for i in out.items if i.name == "b")


def test_stop_is_cooperative_the_inflight_teardown_finishes():
    finished = []

    async def publish(_run):
        pass

    run = _run(to_items(plan([_clean("a"), _clean("b"), _clean("c")])))

    async def archive_one(ws_id):
        # Ask to stop *while* "a" is being torn down: cancelling here is how you get a
        # half-removed worktree, so "a" must still complete and only b/c drop out.
        run.stop_requested = True
        await asyncio.sleep(0)
        finished.append(ws_id)

    out = asyncio.run(run_queue(run, archive_one=archive_one, publish=publish))
    assert finished == ["a"]
    assert [i.outcome for i in out.items] == ["archived", "canceled", "canceled"]
    assert out.state == "canceled"


def test_a_stop_that_lands_too_late_is_not_reported_as_canceled():
    # Nothing was actually dropped, so "canceled" would send the user hunting for
    # workspaces that are already gone.
    run = _run(to_items(plan([_clean("a")])))

    async def archive_one(_ws_id):
        run.stop_requested = True  # arrives as the only item finishes

    async def publish(_r):
        pass

    out = asyncio.run(run_queue(run, archive_one=archive_one, publish=publish))
    assert out.state == "done"
    assert [i.outcome for i in out.items] == ["archived"]


def test_skipped_items_are_never_reconsidered_by_the_driver():
    torn = []

    async def archive_one(ws_id):
        torn.append(ws_id)

    async def publish(_run):
        pass

    items = to_items(plan([_clean("safe"), Candidate(id="d", name="dirty", dirty=True)]))
    out = asyncio.run(run_queue(_run(items), archive_one=archive_one, publish=publish))
    assert torn == ["safe"]
    assert summarize(out) == "1 archived · 1 skipped"


def test_progress_is_published_before_and_after_each_teardown():
    seen = []

    async def archive_one(ws_id):
        pass

    async def publish(run):
        seen.append([i.outcome for i in run.items])

    run = _run(to_items(plan([_clean("a"), _clean("b")])))
    asyncio.run(run_queue(run, archive_one=archive_one, publish=publish))
    # The UI must be able to see "archiving" — a bulk archive with no visible progress
    # is the "did it hang?" moment the queue exists to remove.
    assert any("archiving" in snapshot for snapshot in seen)
    assert seen[-1] == ["archived", "archived"]


# --------------------------------------------------------------------------- #
# the endpoint — preview, one-queue-per-project, cooperative stop
# --------------------------------------------------------------------------- #
def _endpoint_setup(tmp_path, monkeypatch, *, dirty: bool = False) -> tuple[Store, Project, list[str]]:
    """A project with three workspaces and every git/db call stubbed, so only the
    queue's own behaviour can change the outcome."""
    store = Store()
    project = Project(id="p", name="proj", path=str(tmp_path), default_branch="main")
    store.projects[project.id] = project
    for name in ("a", "b", "c"):
        store.workspaces[name] = Workspace(
            id=name, project_id=project.id, name=name, branch=f"feat/{name}",
            worktree_path=str(tmp_path / name), base_ref="main",
            status=WorkspaceStatus.idle,
        )

    async def _is_clean(*a, **k):
        return not dirty

    async def _ahead(*a, **k):
        return 0

    async def _save(*a, **k):
        return None

    torn: list[str] = []

    async def _teardown(ws, project):
        torn.append(ws.id)
        store.remove_workspace(ws.id)

    monkeypatch.setattr(main_mod.git_ops, "is_clean", _is_clean)
    monkeypatch.setattr(main_mod.git_ops, "ahead_count", _ahead)
    monkeypatch.setattr(main_mod.git_ops, "worktree_valid", lambda p: True)
    monkeypatch.setattr(main_mod.db, "save_snapshot", _save)
    monkeypatch.setattr(main_mod, "_teardown_workspace", _teardown)
    monkeypatch.setattr(main_mod, "store", store)
    return store, project, torn


def test_dry_run_previews_without_tearing_anything_down(tmp_path, monkeypatch):
    store, project, torn = _endpoint_setup(tmp_path, monkeypatch)
    run = asyncio.run(main_mod.start_archive_queue(
        project.id, ArchiveQueueRequest(workspace_ids=["a", "b"]), dry=True
    ))
    assert run.dry and run.state == "planned"
    assert [i.outcome for i in run.items] == ["queued", "queued"]
    assert torn == []
    # A preview is an answer, not an entity: nothing to stop later.
    assert store.archive_runs == {}


def test_dirty_workspaces_are_previewed_as_skipped(tmp_path, monkeypatch):
    _, project, _ = _endpoint_setup(tmp_path, monkeypatch, dirty=True)
    run = asyncio.run(main_mod.start_archive_queue(
        project.id, ArchiveQueueRequest(workspace_ids=["a"]), dry=True
    ))
    assert run.items[0].outcome == "skipped"
    forced = asyncio.run(main_mod.start_archive_queue(
        project.id, ArchiveQueueRequest(workspace_ids=["a"], force=True), dry=True
    ))
    assert forced.items[0].outcome == "queued"
    assert forced.items[0].risks


def test_live_run_drains_serially_and_removes_the_workspaces(tmp_path, monkeypatch):
    store, project, torn = _endpoint_setup(tmp_path, monkeypatch)

    async def go():
        run = await main_mod.start_archive_queue(project.id, ArchiveQueueRequest(workspace_ids=["a", "b", "c"]))
        await store.archive_tasks[project.id]
        return run

    run = asyncio.run(go())
    assert torn == ["a", "b", "c"]
    assert run.state == "done"
    assert store.list_workspaces(project.id) == []
    assert store.latest_archive_run(project.id) is run


def test_a_second_queue_is_refused_while_one_is_draining(tmp_path, monkeypatch):
    store, project, _ = _endpoint_setup(tmp_path, monkeypatch)
    gate = asyncio.Event()

    async def _slow_teardown(ws, project):
        await gate.wait()

    monkeypatch.setattr(main_mod, "_teardown_workspace", _slow_teardown)

    async def go():
        await main_mod.start_archive_queue(project.id, ArchiveQueueRequest(workspace_ids=["a"]))
        await asyncio.sleep(0)  # let the driver take the first item
        with pytest.raises(HTTPException) as exc:
            # Two queues would be concurrent teardowns again — the thing this replaces.
            await main_mod.start_archive_queue(project.id, ArchiveQueueRequest(workspace_ids=["b"]))
        assert exc.value.status_code == 409
        gate.set()
        await store.archive_tasks[project.id]

    asyncio.run(go())


def test_stop_endpoint_cancels_only_what_has_not_run(tmp_path, monkeypatch):
    store, project, torn = _endpoint_setup(tmp_path, monkeypatch)

    async def go():
        run = await main_mod.start_archive_queue(project.id, ArchiveQueueRequest(workspace_ids=["a", "b", "c"]))
        await main_mod.stop_archive_queue(run.id)
        await store.archive_tasks[project.id]
        return run

    run = asyncio.run(go())
    assert run.state == "canceled"
    assert len(torn) < 3
    assert any(i.outcome == "canceled" for i in run.items)


def test_the_four_routes_are_wired_and_the_schema_builds():
    # Same guard as test_workspace_route_wiring.py: a misplaced decorator or an
    # unresolvable response_model only shows up when the schema is actually built.
    wanted = {
        ("/projects/{project_id}/archive-queue", "POST"): "start_archive_queue",
        ("/projects/{project_id}/archive-queue", "GET"): "get_archive_queue",
        ("/archive-queue/{run_id}/stop", "POST"): "stop_archive_queue",
    }
    found = {
        (getattr(r, "path", None), m): r.endpoint.__name__
        for r in main_mod.app.routes
        for m in getattr(r, "methods", set())
    }
    for key, name in wanted.items():
        assert found.get(key) == name, f"{key} wired to {found.get(key)!r}"
    paths = main_mod.app.openapi()["paths"]
    op = paths["/projects/{project_id}/archive-queue"]["post"]
    assert {p["name"] for p in op.get("parameters", [])} >= {"project_id", "dry"}


def test_workspace_from_another_project_is_refused(tmp_path, monkeypatch):
    store, project, _ = _endpoint_setup(tmp_path, monkeypatch)
    other = Project(id="p2", name="other", path=str(tmp_path / "other"), default_branch="main")
    store.projects[other.id] = other
    with pytest.raises(HTTPException) as exc:
        asyncio.run(main_mod.start_archive_queue(other.id, ArchiveQueueRequest(workspace_ids=["a"])))
    assert exc.value.status_code == 404
