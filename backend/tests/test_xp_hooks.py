"""XP wiring: the facts each hook records, the awards it pays, the ledger table, the endpoints.

The pure rules are pinned in test_xp.py; these tests prove the callers (merge, gate, assist,
editor) feed those rules the right facts, and that an XP failure never reaches them."""

from __future__ import annotations

import asyncio
import subprocess
import time

import pytest
from fastapi import HTTPException

from haro import db, git_ops, main, xp, xp_hooks
from haro import receipt as receipt_svc
from haro.config import load_project_settings
from haro.hub import Hub
from haro.models import (
    AgentRun,
    CreateWorkspaceRequest,
    ModeSwitch,
    Project,
    TestRun,
    TestRunStatus,
    UncheckedRow,
    Workspace,
    WorkspaceStatus,
    XpActivityRequest,
    XpEvent,
)
from haro.store import SETUP_SESSION, Store


def _run(coro):
    return asyncio.run(coro)


def _git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()


def _repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "t@example.com")
    _git(repo, "config", "user.name", "t")
    (repo / "f.txt").write_text("x\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "init")
    return repo


def _wire(monkeypatch, **ws_kw):
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path="/nowhere", default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path="/nowhere/wt",
                   base_ref="main", **ws_kw)
    store.workspaces[ws.id] = ws
    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr(main, "hub", hub)
    return store, hub, ws


def _row(key):
    return UncheckedRow(kind="new_dep", file="package.json", key=key)


def _test(ws, status="passed", **kw):
    return TestRun(workspace_id=ws.id, runner="vitest", status=TestRunStatus(status), **kw)


def _add(store, ws, *statuses, **kw):
    t0 = time.time()
    for i, s in enumerate(statuses):
        t = _test(ws, s, **kw)
        t.started_at = t0 + i
        store.add_test(t)


def _drain(q):
    out = []
    while not q.empty():
        out.append(q.get_nowait())
    return out


# ---- activity ---------------------------------------------------------------------------


def test_activity_records_pays_once_a_day_and_publishes(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    q = hub.subscribe_global()
    a = _run(xp_hooks.record_activity(store, hub, "research", ws.id))
    assert [x.amount for x in a] == [5]
    assert _run(xp_hooks.record_activity(store, hub, "research", ws.id)) == []
    rows = store.list_xp_events()
    assert len(rows) == 1 and rows[0].kind == "research" and rows[0].mode == "manual"
    ev = _drain(q)
    assert len(ev) == 1 and ev[0]["channel"] == "xp" and ev[0]["amount"] == 5
    assert ev[0]["label"] == "ran a search" and ev[0]["workspace_id"] == ws.id


def test_agent_mode_earns_a_little(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="agent")
    _run(xp_hooks.record_activity(store, hub, "plan_made", ws.id))
    assert store.list_xp_events()[0].amount == 2


def test_an_xp_failure_is_swallowed(monkeypatch):
    store, hub, ws = _wire(monkeypatch)

    def boom(*_a, **_k):
        raise RuntimeError("ledger on fire")

    monkeypatch.setattr(xp, "award_for", boom)
    assert _run(xp_hooks.record_activity(store, hub, "research", ws.id)) == []
    assert _run(xp_hooks.record_merge(store, hub, ws, ["a.js"])) == []
    assert store.xp_events == {}


# ---- merge facts ------------------------------------------------------------------------


def test_red_to_green_needs_a_red_then_a_green_with_no_agent_run(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    _add(store, ws, "failed", "passed")
    assert xp_hooks.merge_facts(store, ws, ["a.js"], at=1.0).red_to_green is True
    store.add_run(AgentRun(workspace_id=ws.id, adapter="claude"))
    assert xp_hooks.merge_facts(store, ws, ["a.js"], at=1.0).red_to_green is False


def test_a_plan_only_agent_run_does_not_count_as_an_agent_edit(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    _add(store, ws, "failed", "passed")
    store.add_run(AgentRun(workspace_id=ws.id, adapter="claude", plan=True))
    assert xp_hooks.merge_facts(store, ws, ["a.js"], at=1.0).red_to_green is True


def test_green_first_try_is_not_red_to_green(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    _add(store, ws, "passed")
    assert xp_hooks.merge_facts(store, ws, ["a.js"], at=1.0).red_to_green is False


def test_latest_run_must_be_green_and_unblocked(monkeypatch):
    store, hub, ws = _wire(monkeypatch)
    _add(store, ws, "passed", "failed")
    assert xp_hooks.merge_facts(store, ws, ["a.js"], at=1.0).green is False
    store2, _, ws2 = _wire(monkeypatch)
    _add(store2, ws2, "passed", tamper_blocked=True)
    assert xp_hooks.merge_facts(store2, ws2, ["a.js"], at=1.0).green is False
    store3, _, ws3 = _wire(monkeypatch)
    assert xp_hooks.merge_facts(store3, ws3, ["a.js"], at=1.0).green is False  # no gate at all


def test_by_hand_means_manual_and_never_switched(monkeypatch):
    _, _, a = _wire(monkeypatch, mode="manual")
    assert xp_hooks.merge_facts(Store(), a, ["x"], at=1.0).by_hand is True
    _, _, b = _wire(monkeypatch, mode="manual", mode_switches=[ModeSwitch(to="manual")])
    assert xp_hooks.merge_facts(Store(), b, ["x"], at=1.0).by_hand is False
    _, _, c = _wire(monkeypatch, mode="agent")
    assert xp_hooks.merge_facts(Store(), c, ["x"], at=1.0).by_hand is False


def test_eyes_review_hand_test_and_flags(monkeypatch):
    store, hub, ws = _wire(
        monkeypatch, mode="agent", checked_rows=["k1", "k2", "k2"],
        reviewed_diff_paths=["src/a.js", "src/a.test.js"],
        hand_saved_paths=["src/a.test.js"], start_from_test=True, start_from_test_ok=True,
        git_search_before_green=True,
    )
    _add(store, ws, "passed", unchecked_items=[_row("k1"), _row("k2")])
    f = xp_hooks.merge_facts(store, ws, ["src/a.js", "src/a.test.js"], at=1.0)
    assert f.eyes == 2 and f.reviewed_all and f.hand_test
    assert f.start_from_test_ok and f.regression_search
    g = xp_hooks.merge_facts(store, ws, ["src/a.js", "src/b.js"], at=1.0)
    assert g.reviewed_all is False and g.hand_test is False


def test_hand_saved_test_must_be_a_test_file(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="agent", hand_saved_paths=["src/a.js"])
    assert xp_hooks.merge_facts(store, ws, ["src/a.js"], at=1.0).hand_test is False


def test_record_merge_pays_and_marks_by_hand(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual", checked_rows=["k1"])
    _add(store, ws, "failed", "passed", unchecked_items=[_row("k1")])
    q = hub.subscribe_global()
    awards = _run(xp_hooks.record_merge(store, hub, ws, ["src/a.js"]))
    got = {a.kind: a.amount for a in awards}
    assert got["merge_green"] == 20 and got["eyes_resolved"] == 10 and got["red_to_green"] == 120
    merge_row = next(e for e in store.list_xp_events() if e.kind == "merge_green")
    assert merge_row.by_hand is True and merge_row.workspace_id == ws.id
    ev = _drain(q)[0]
    assert ev["amount"] == 150 and ev["badge"] == "First by hand"
    assert xp.build_status(store.list_xp_events(), time.time()).streak_days == 1


def test_record_merge_twice_pays_once(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    _add(store, ws, "passed")
    _run(xp_hooks.record_merge(store, hub, ws, ["a.js"]))
    assert _run(xp_hooks.record_merge(store, hub, ws, ["a.js"])) == []


def test_record_merge_empty_diff_and_red_pay_nothing(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    _add(store, ws, "passed")
    assert _run(xp_hooks.record_merge(store, hub, ws, [])) == []
    store2, hub2, ws2 = _wire(monkeypatch, mode="manual")
    _add(store2, ws2, "failed")
    assert _run(xp_hooks.record_merge(store2, hub2, ws2, ["a.js"])) == []
    assert store.xp_events == {} and store2.xp_events == {}


def test_switching_to_agent_keeps_earlier_xp_but_the_merge_is_no_streak_day(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    _run(xp_hooks.record_activity(store, hub, "docs_read", ws.id))
    ws.mode = "agent"
    ws.mode_switches.append(ModeSwitch(to="agent"))
    _add(store, ws, "passed")
    _run(xp_hooks.record_merge(store, hub, ws, ["a.js"]))
    st = xp.build_status(store.list_xp_events(), time.time())
    assert st.xp == 10 + 10
    assert st.streak_days == 0 and st.today_done is False


# ---- recorded facts ---------------------------------------------------------------------


def test_note_helpers_dedupe_and_cap():
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path="/x", base_ref="main")
    xp_hooks.note_hand_saved(ws, "a.js")
    xp_hooks.note_hand_saved(ws, "a.js")
    assert ws.hand_saved_paths == ["a.js"]
    for i in range(600):
        xp_hooks.note_hand_saved(ws, f"f{i}.js")
    assert len(ws.hand_saved_paths) == 500 and ws.hand_saved_paths[-1] == "f599.js"


def test_git_search_before_first_green_only(monkeypatch):
    store, hub, ws = _wire(monkeypatch)
    xp_hooks.note_research(store, ws, "repo")
    assert ws.git_search_before_green is False
    xp_hooks.note_research(store, ws, "git")
    assert ws.git_search_before_green is True
    store2, hub2, ws2 = _wire(monkeypatch)
    _add(store2, ws2, "passed")
    xp_hooks.note_research(store2, ws2, "git")
    assert ws2.git_search_before_green is False


def test_write_file_records_a_hand_save(monkeypatch, tmp_path):
    store, hub, ws = _wire(monkeypatch)
    ws.worktree_path = str(tmp_path)
    from haro.models import WriteFileRequest

    _run(main.write_file(ws.id, WriteFileRequest(path="src/a.test.js", content="x")))
    assert ws.hand_saved_paths == ["src/a.test.js"]


def test_research_endpoint_pays_research_and_flags_git(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    store, hub, ws = _wire(monkeypatch, mode="manual")
    ws.worktree_path = str(repo)
    from haro.models import AssistResearchRequest

    _run(main.assist_research(ws.id, AssistResearchRequest(query="f", scope="git")))
    assert [e.kind for e in store.list_xp_events()] == ["research"]
    assert ws.git_search_before_green is True


# ---- gate hook --------------------------------------------------------------------------


def _worktree(tmp_path):
    repo = _repo(tmp_path)
    wt = tmp_path / "wt"
    _run(git_ops.add_worktree(repo, wt, "feat", "main"))
    return repo, wt


def test_gate_hook_pays_a_green_run_once_a_day_and_not_a_red_one(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    red = _test(ws, "failed")
    store.add_test(red)
    _run(xp_hooks.on_gate_finished(store, hub, ws, red, green=False))
    assert store.xp_events == {}
    green = _test(ws, "passed")
    store.add_test(green)
    _run(xp_hooks.on_gate_finished(store, hub, ws, green, green=True))
    _run(xp_hooks.on_gate_finished(store, hub, ws, green, green=True))
    assert [e.kind for e in store.list_xp_events()] == ["gate_run"]


def test_gate_hook_never_pays_a_watch_run(monkeypatch):
    store, hub, ws = _wire(monkeypatch)
    t = _test(ws, "passed")
    t.trigger = "watch"
    store.add_test(t)
    _run(xp_hooks.on_gate_finished(store, hub, ws, t, green=True))
    assert store.xp_events == {}


def test_start_from_test_ok_when_first_run_is_red_with_only_tests_changed(monkeypatch, tmp_path):
    _, wt = _worktree(tmp_path)
    (wt / "a.test.js").write_text("it('x', () => {})\n")
    store, hub, ws = _wire(monkeypatch, mode="manual", start_from_test=True)
    ws.worktree_path = str(wt)
    red = _test(ws, "failed")
    store.add_test(red)
    _run(xp_hooks.on_gate_finished(store, hub, ws, red, green=False))
    assert ws.start_from_test_ok is True


def test_start_from_test_not_ok_when_source_changed_too(monkeypatch, tmp_path):
    _, wt = _worktree(tmp_path)
    (wt / "a.test.js").write_text("it('x', () => {})\n")
    (wt / "a.js").write_text("export const a = 1\n")
    store, hub, ws = _wire(monkeypatch, mode="manual", start_from_test=True)
    ws.worktree_path = str(wt)
    red = _test(ws, "failed")
    store.add_test(red)
    _run(xp_hooks.on_gate_finished(store, hub, ws, red, green=False))
    assert ws.start_from_test_ok is False


def test_start_from_test_settled_by_the_first_run_only(monkeypatch, tmp_path):
    _, wt = _worktree(tmp_path)
    store, hub, ws = _wire(monkeypatch, mode="manual", start_from_test=True)
    ws.worktree_path = str(wt)
    first = _test(ws, "passed")
    first.started_at = time.time() - 10
    store.add_test(first)
    _run(xp_hooks.on_gate_finished(store, hub, ws, first, green=True))
    assert ws.start_from_test_ok is False
    (wt / "a.test.js").write_text("x\n")
    second = _test(ws, "failed")
    store.add_test(second)
    _run(xp_hooks.on_gate_finished(store, hub, ws, second, green=False))
    assert ws.start_from_test_ok is False


def test_a_normal_workspace_has_no_start_from_test_fact(monkeypatch):
    store, hub, ws = _wire(monkeypatch)
    red = _test(ws, "failed")
    store.add_test(red)
    _run(xp_hooks.on_gate_finished(store, hub, ws, red, green=False))
    assert ws.start_from_test_ok is None


# ---- the merge endpoint -----------------------------------------------------------------


def _merge_setup(monkeypatch, tmp_path, **ws_kw):
    repo, wt = _worktree(tmp_path)
    (wt / "g.js").write_text("export const g = 1\n")
    _git(wt, "add", "-A")
    _git(wt, "commit", "-qm", "work")
    store, hub = Store(), Hub()
    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    store.projects[project.id] = project
    ws = Workspace(project_id="p", name="w", branch="feat", worktree_path=str(wt),
                   base_ref="main", status=WorkspaceStatus.gate_green, **ws_kw)
    store.workspaces[ws.id] = ws
    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr(main, "hub", hub)
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "absent.toml"))
    return store, hub, ws, repo


def test_a_green_manual_merge_pays_the_ledger(monkeypatch, tmp_path):
    store, hub, ws, _ = _merge_setup(monkeypatch, tmp_path, mode="manual")
    _add(store, ws, "failed", "passed")
    out = _run(main.merge(ws.id))
    assert out["merged"] is True and ws.status == WorkspaceStatus.merged
    kinds = {e.kind: e.amount for e in store.list_xp_events()}
    assert kinds["merge_green"] == 20 and kinds["red_to_green"] == 120
    assert kinds["first_by_hand"] == 0
    assert xp_hooks.merged_line(store, ws.id) == "XP: +140 (merged on green, red to green by hand)"


def test_an_agent_merge_pays_the_agent_number(monkeypatch, tmp_path):
    store, hub, ws, _ = _merge_setup(monkeypatch, tmp_path, mode="agent")
    _add(store, ws, "passed")
    _run(main.merge(ws.id))
    assert {e.kind: e.amount for e in store.list_xp_events()} == {"merge_green": 10}


def test_the_merge_succeeds_when_the_xp_hook_throws(monkeypatch, tmp_path):
    store, hub, ws, repo = _merge_setup(monkeypatch, tmp_path, mode="manual")
    _add(store, ws, "passed")

    def boom(*_a, **_k):
        raise RuntimeError("ledger on fire")

    monkeypatch.setattr(xp_hooks, "merge_facts", boom)
    out = _run(main.merge(ws.id))
    assert out["merged"] is True and ws.status == WorkspaceStatus.merged
    assert store.xp_events == {}
    assert (repo / "g.js").exists()


def test_a_red_gate_cannot_merge_so_it_cannot_pay(monkeypatch, tmp_path):
    store, hub, ws, _ = _merge_setup(monkeypatch, tmp_path, mode="manual")
    ws.status = WorkspaceStatus.gate_red
    _add(store, ws, "failed")
    with pytest.raises(HTTPException):
        _run(main.merge(ws.id))
    assert store.xp_events == {}


def test_the_pr_merged_on_github_path_pays_once_for_a_green_workspace(monkeypatch, tmp_path):
    store, hub, ws, _ = _merge_setup(monkeypatch, tmp_path, mode="manual")
    _add(store, ws, "passed")
    head = _run(git_ops.head_sha(ws.worktree_path))
    data = {"supported": True, "exists": True, "state": "MERGED", "head_sha": head, "number": 7}
    assert _run(main._adopt_merged_state(ws, data)) is True
    assert [e.kind for e in store.list_xp_events()].count("merge_green") == 1


def test_the_pr_merged_path_pays_nothing_for_a_workspace_that_was_not_green(monkeypatch, tmp_path):
    store, hub, ws, _ = _merge_setup(monkeypatch, tmp_path, mode="manual")
    ws.status = WorkspaceStatus.gate_red
    _add(store, ws, "failed")
    head = _run(git_ops.head_sha(ws.worktree_path))
    data = {"supported": True, "exists": True, "state": "MERGED", "head_sha": head, "number": 7}
    _run(main._adopt_merged_state(ws, data))
    assert store.xp_events == {}


def test_the_receipt_carries_a_preview_then_the_paid_line(monkeypatch, tmp_path):
    store, hub, ws, _ = _merge_setup(monkeypatch, tmp_path, mode="manual")
    _add(store, ws, "passed")
    settings = load_project_settings(store.projects["p"].path)
    before = _run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings))
    assert before.xp == "XP: +20 (merged on green)"
    _run(main.merge(ws.id))
    after = _run(receipt_svc.build_receipt(store=store, workspace=ws, settings=settings))
    assert after.xp == "XP: +20 (merged on green)"
    assert "XP" not in receipt_svc.render_markdown(after)


# ---- create ----------------------------------------------------------------------------


def _create(monkeypatch, tmp_path, req):
    repo = _repo(tmp_path)
    store = Store()
    project = Project(id="p", name="proj", path=str(repo), default_branch="main")
    store.projects[project.id] = project
    monkeypatch.setattr(main, "store", store)
    monkeypatch.setattr("haro.store.settings.worktree_root", str(tmp_path / "wt"))

    async def spy(**_kw):
        return None

    monkeypatch.setattr(main, "run_setup", spy)

    async def go():
        ws = await main.create_workspace("p", req)
        task = store.active_task(ws.id, SETUP_SESSION)
        if task is not None:
            await task
        return ws

    return _run(go())


def test_start_from_test_is_stored_for_a_manual_workspace(monkeypatch, tmp_path):
    ws = _create(monkeypatch, tmp_path,
                 CreateWorkspaceRequest(name="alpha", mode="manual", start_from_test=True))
    assert ws.start_from_test is True and ws.start_from_test_ok is None


def test_start_from_test_is_ignored_for_an_agent_workspace(monkeypatch, tmp_path):
    ws = _create(monkeypatch, tmp_path, CreateWorkspaceRequest(name="beta", start_from_test=True))
    assert ws.start_from_test is False


# ---- endpoints --------------------------------------------------------------------------


def test_get_xp_and_rules_and_events(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    _run(xp_hooks.record_activity(store, hub, "docs_read", ws.id))
    st = _run(main.get_xp())
    assert st.xp == 10 and st.level == 1 and st.rank == "Novice" and st.next_rank_at == 800
    assert st.latest is not None and st.latest.label == "read the docs"
    rules = _run(main.get_xp_rules())
    assert {r.kind for r in rules.rules} >= {"docs_read", "merge_green", "red_to_green"}
    events = _run(main.get_xp_events(limit=10))
    assert [e.kind for e in events] == ["docs_read"]


def test_events_are_newest_first_and_limited(monkeypatch):
    store, hub, ws = _wire(monkeypatch)
    for i in range(5):
        e = XpEvent(at=1000.0 + i, kind="research", amount=5)
        store.xp_events[e.id] = e
    got = _run(main.get_xp_events(limit=3))
    assert [e.at for e in got] == [1004.0, 1003.0, 1002.0]


def test_activity_endpoint_docs_read_once_a_day(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    r1 = _run(main.post_xp_activity(XpActivityRequest(kind="docs_read", workspace_id=ws.id)))
    r2 = _run(main.post_xp_activity(XpActivityRequest(kind="docs_read", workspace_id=ws.id)))
    assert [a.amount for a in r1.awards] == [10] and r2.awards == []


def test_activity_endpoint_needs_a_workspace_for_docs_read(monkeypatch):
    store, hub, ws = _wire(monkeypatch)
    with pytest.raises(HTTPException) as e:
        _run(main.post_xp_activity(XpActivityRequest(kind="docs_read")))
    assert e.value.status_code == 400
    assert store.xp_events == {}


def test_activity_endpoint_rejects_server_side_kinds_and_unknown_workspaces(monkeypatch):
    store, hub, ws = _wire(monkeypatch)
    for req, code in (
        (XpActivityRequest(kind="merge_green", workspace_id=ws.id), 400),
        (XpActivityRequest(kind="docs_read", workspace_id="nope"), 404),
        (XpActivityRequest(kind="diff_reviewed"), 400),
    ):
        with pytest.raises(HTTPException) as e:
            _run(main.post_xp_activity(req))
        assert e.value.status_code == code


def test_diff_review_pays_only_when_the_reported_files_cover_the_diff(monkeypatch, tmp_path):
    _, wt = _worktree(tmp_path)
    (wt / "a.js").write_text("1\n")
    (wt / "b.js").write_text("2\n")
    store, hub, ws = _wire(monkeypatch, mode="manual")
    ws.worktree_path = str(wt)
    part = _run(main.post_xp_activity(
        XpActivityRequest(kind="diff_reviewed", workspace_id=ws.id, paths=["a.js"])))
    assert part.awards == []
    full = _run(main.post_xp_activity(
        XpActivityRequest(kind="diff_reviewed", workspace_id=ws.id, paths=["b.js"])))
    assert [a.amount for a in full.awards] == [3]
    assert set(ws.reviewed_diff_paths) == {"a.js", "b.js"}
    again = _run(main.post_xp_activity(
        XpActivityRequest(kind="diff_reviewed", workspace_id=ws.id, paths=["a.js", "b.js"])))
    assert again.awards == []


def test_diff_review_with_an_empty_diff_pays_nothing(monkeypatch, tmp_path):
    _, wt = _worktree(tmp_path)
    store, hub, ws = _wire(monkeypatch, mode="manual")
    ws.worktree_path = str(wt)
    r = _run(main.post_xp_activity(
        XpActivityRequest(kind="diff_reviewed", workspace_id=ws.id, paths=[])))
    assert r.awards == []


# ---- persistence ------------------------------------------------------------------------


@pytest.fixture
def sqlite_db(tmp_path, monkeypatch):
    monkeypatch.setenv("HARO_DB", str(tmp_path / "haro.db"))
    monkeypatch.setattr(db, "_conn", None)
    monkeypatch.setattr(db, "_readonly", False)
    monkeypatch.setattr(db, "_lock_fd", None)
    db._hydrated.clear()
    yield
    _run(db.close())
    db._hydrated.clear()


def test_xp_events_round_trip_through_the_snapshot(sqlite_db):
    async def go():
        assert await db.init()
        store = Store()
        for i in range(3):
            e = XpEvent(at=100.0 + i, kind="merge_green", amount=20, workspace_id=f"w{i}",
                        mode="manual", by_hand=True, detail="d")
            store.xp_events[e.id] = e
        await db.save_snapshot(store)
        fresh = Store()
        await db.load_into(fresh)
        return store, fresh

    store, fresh = _run(go())
    assert {e.id: e.model_dump() for e in fresh.xp_events.values()} == {
        e.id: e.model_dump() for e in store.xp_events.values()}
    assert "xp_events" in db._hydrated


def test_an_unhydrated_boot_cannot_wipe_the_ledger(sqlite_db):
    async def go():
        assert await db.init()
        store = Store()
        e = XpEvent(kind="research", amount=5)
        store.xp_events[e.id] = e
        await db.save_snapshot(store)
        db._hydrated.clear()
        await db.save_snapshot(Store())  # an empty store whose loader never ran
        fresh = Store()
        await db.load_into(fresh)
        return fresh

    assert len(_run(go()).xp_events) == 1


def test_a_hydrated_boot_with_an_emptied_ledger_does_clear_it(sqlite_db):
    async def go():
        assert await db.init()
        store = Store()
        e = XpEvent(kind="research", amount=5)
        store.xp_events[e.id] = e
        await db.save_snapshot(store)
        empty = Store()
        await db.load_into(Store())
        await db.save_snapshot(empty)
        fresh = Store()
        await db.load_into(fresh)
        return fresh

    assert _run(go()).xp_events == {}


def test_old_workspace_snapshots_hydrate_with_the_new_fact_defaults():
    legacy = Workspace(
        project_id="p", name="w", branch="b", worktree_path="/tmp/w", base_ref="main"
    ).model_dump()
    for k in ("start_from_test", "start_from_test_ok", "reviewed_diff_paths",
              "hand_saved_paths", "git_search_before_green"):
        legacy.pop(k)
    ws = Workspace.model_validate(legacy)
    assert ws.start_from_test is False and ws.start_from_test_ok is None
    assert ws.reviewed_diff_paths == []


def test_the_xp_routes_are_registered():
    routes = {(m, r.path) for r in main.app.routes for m in getattr(r, "methods", ())}
    assert {("GET", "/xp"), ("GET", "/xp/rules"), ("GET", "/xp/events"),
            ("POST", "/xp/activity")} <= routes


def test_status_and_rules_serialize_the_way_the_client_reads_them(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual")
    _run(xp_hooks.record_activity(store, hub, "docs_read", ws.id))
    status = _run(main.get_xp()).model_dump()
    assert set(status) == {"xp", "level", "rank", "rank_start", "next_rank_at", "streak_days",
                           "streak", "today_done", "latest", "badges"}
    assert len(status["streak"]) == 14 and status["latest"]["kind"] == "docs_read"
    rules = _run(main.get_xp_rules()).model_dump()
    assert {r["group"] for r in rules["rules"]} == {"daily", "merge", "manual", "badge"}
    assert all(set(r) == {"kind", "group", "label", "text", "manual", "agent", "cap"}
               for r in rules["rules"])


# ---- fix round: mode flips, forged ticks, hook safety, path spelling --------------------


def _flip_to_manual(ws):
    ws.mode = "manual"
    ws.mode_switches.append(ModeSwitch(to="manual"))


def test_flipping_to_manual_just_before_the_merge_buys_no_manual_rate_or_bonus(monkeypatch):
    store, hub, ws = _wire(
        monkeypatch, mode="agent", checked_rows=["k1", "k2", "k3", "k4", "k5"],
        git_search_before_green=True,
        start_from_test=True, start_from_test_ok=True,
    )
    _add(store, ws, "failed", "passed", unchecked_items=[_row(f"k{i}") for i in range(1, 6)])
    _flip_to_manual(ws)
    q = hub.subscribe_global()
    awards = _run(xp_hooks.record_merge(store, hub, ws, ["src/a.js"]))
    assert {a.kind: a.amount for a in awards} == {"merge_green": 10, "eyes_resolved": 25}
    rows = store.list_xp_events()
    assert all(not e.by_hand and e.mode == "agent" for e in rows)
    assert not [e for e in rows if e.kind in ("first_by_hand", "regression_hunter")]
    assert _drain(q)[0]["badge"] is None
    st = xp.build_status(store.list_xp_events(), time.time())
    assert st.streak_days == 0 and st.badges == []


def test_a_manual_workspace_switched_to_agent_merges_at_agent_rates(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual", checked_rows=["k1"])
    _add(store, ws, "failed", "passed", unchecked_items=[_row("k1")])
    ws.mode = "agent"
    ws.mode_switches.append(ModeSwitch(to="agent"))
    awards = _run(xp_hooks.record_merge(store, hub, ws, ["src/a.js"]))
    assert {a.kind: a.amount for a in awards} == {"merge_green": 10, "eyes_resolved": 5}


def test_an_agent_to_manual_flip_earns_the_agent_activity_rate(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="agent")
    _flip_to_manual(ws)
    _run(xp_hooks.record_activity(store, hub, "docs_read", ws.id))
    assert store.list_xp_events()[0].amount == 2


def test_the_probe_through_the_merge_endpoint(monkeypatch, tmp_path):
    store, hub, ws, _ = _merge_setup(
        monkeypatch, tmp_path, mode="agent",
        checked_rows=["k1", "k2", "k3", "k4", "k5"])
    _add(store, ws, "passed", unchecked_items=[_row(f"k{i}") for i in range(1, 6)])
    _flip_to_manual(ws)
    _run(main.merge(ws.id))
    paid = {e.kind: e.amount for e in store.list_xp_events()}
    assert paid == {"merge_green": 10, "eyes_resolved": 25}


def test_made_up_ticks_pay_nothing(monkeypatch):
    store, hub, ws = _wire(
        monkeypatch, mode="manual", checked_rows=["a", "b", "c", "d", "e", "f"])
    _add(store, ws, "passed", unchecked_items=[])
    assert xp_hooks.merge_facts(store, ws, ["x.js"], at=1.0).eyes == 0
    awards = _run(xp_hooks.record_merge(store, hub, ws, ["x.js"]))
    assert "eyes_resolved" not in {a.kind for a in awards}


def test_only_ticks_that_match_a_live_row_count_and_the_cap_holds(monkeypatch):
    keys = [f"real{i}" for i in range(8)]
    store, hub, ws = _wire(monkeypatch, mode="manual", checked_rows=keys + ["forged"])
    _add(store, ws, "passed", unchecked_items=[_row(k) for k in keys[:7]])
    assert xp_hooks.merge_facts(store, ws, ["x.js"], at=1.0).eyes == 7
    awards = _run(xp_hooks.record_merge(store, hub, ws, ["x.js"]))
    assert {a.kind: a.amount for a in awards}["eyes_resolved"] == 50


def test_a_run_that_never_measured_rows_leaves_ticks_unpaid(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="manual", checked_rows=["k1"])
    _add(store, ws, "passed")
    assert xp_hooks.merge_facts(store, ws, ["x.js"], at=1.0).eyes == 0


class _Explodes:
    @property
    def hand_saved_paths(self):
        raise RuntimeError("boom")

    id = "ws"


def test_the_note_hooks_never_raise(monkeypatch):
    xp_hooks.note_hand_saved(_Explodes(), "a.js")

    class BadStore:
        def test_history(self, _id):
            raise RuntimeError("boom")

    xp_hooks.note_research(BadStore(), _Explodes(), "git")


def test_a_failing_hand_save_note_does_not_fail_the_save(monkeypatch, tmp_path):
    store, hub, ws = _wire(monkeypatch)
    ws.worktree_path = str(tmp_path)
    from haro.models import WriteFileRequest

    monkeypatch.setattr(xp_hooks, "_remember", lambda *_a: (_ for _ in ()).throw(RuntimeError("x")))
    out = _run(main.write_file(ws.id, WriteFileRequest(path="a.test.js", content="x")))
    assert out["saved"] == "a.test.js" and (tmp_path / "a.test.js").exists()


def test_norm_path_gives_one_spelling():
    n = xp_hooks.norm_path
    assert n("./src/a.test.js") == "src/a.test.js"
    assert n("src//a/../a.test.js") == "src/a.test.js"
    assert n("src\\a.test.js") == "src/a.test.js"
    assert n("/src/a.js") == "src/a.js"
    assert n("src/a.js/") == "src/a.js"
    assert n(".") == "" and n("") == ""


def test_a_hand_saved_test_matches_however_the_path_was_spelled(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="agent")
    xp_hooks.note_hand_saved(ws, "./src//a.test.js")
    assert ws.hand_saved_paths == ["src/a.test.js"]
    assert xp_hooks.merge_facts(store, ws, ["src/a.test.js"], at=1.0).hand_test is True
    assert xp_hooks.merge_facts(store, ws, ["./src/a.test.js"], at=1.0).hand_test is True


def test_reviewed_paths_are_matched_normalised(monkeypatch):
    store, hub, ws = _wire(monkeypatch, mode="agent", reviewed_diff_paths=["./src/a.js"])
    assert xp_hooks.merge_facts(store, ws, ["src/a.js"], at=1.0).reviewed_all is True


def _rename_worktree(tmp_path):
    repo = _repo(tmp_path)
    (repo / "src" / "a").mkdir(parents=True)
    (repo / "src" / "a" / "f.txt").write_text("body\n")
    (repo / "a b.txt").write_text("spaced\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "more")
    wt = tmp_path / "wt"
    _run(git_ops.add_worktree(repo, wt, "feat", "main"))
    _git(wt, "mv", "src/a", "src/b")
    _git(wt, "mv", "a b.txt", "c d.txt")
    return repo, wt


def test_renames_and_odd_names_come_back_as_plain_new_paths(tmp_path):
    _, wt = _rename_worktree(tmp_path)
    assert sorted(_run(git_ops.working_changed_paths(wt, "main"))) == ["c d.txt", "src/b/f.txt"]
    _git(wt, "commit", "-qm", "rename")
    assert sorted(_run(git_ops.branch_changed_paths(wt, "main"))) == ["c d.txt", "src/b/f.txt"]


def test_a_diff_review_pays_for_a_renamed_directory(monkeypatch, tmp_path):
    _, wt = _rename_worktree(tmp_path)
    store, hub, ws = _wire(monkeypatch, mode="manual")
    ws.worktree_path = str(wt)
    r = _run(main.post_xp_activity(XpActivityRequest(
        kind="diff_reviewed", workspace_id=ws.id, paths=["./src/b/f.txt", "c d.txt"])))
    assert [a.amount for a in r.awards] == [3]


def test_the_merge_review_bonus_survives_a_rename(monkeypatch, tmp_path):
    _, wt = _rename_worktree(tmp_path)
    _git(wt, "commit", "-qm", "rename")
    store, hub, ws = _wire(monkeypatch, mode="agent", reviewed_diff_paths=["src/b/f.txt", "c d.txt"])
    ws.worktree_path = str(wt)
    _add(store, ws, "passed")
    changed = _run(xp_hooks.merge_changed_paths(ws))
    assert xp_hooks.merge_facts(store, ws, changed, at=1.0).reviewed_all is True
