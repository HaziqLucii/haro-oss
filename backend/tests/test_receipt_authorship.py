"""The receipt's "Written by" must not credit the agent with files it never touched: what a run
changed is recorded from a worktree snapshot (so shell writes count), and the receipt names the
files that changed outside every agent run."""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

import pytest

from haro import lifecycle, receipt as receipt_svc, runner as runner_mod, scope_fence
from haro.adapters.base import AgentAdapter, NormalizedEvent
from haro.config import ProjectSettings
from haro.hub import Hub
from haro.models import AgentRun, Project, Receipt, ReceiptHandEdits, Workspace
from haro.runner import run_agent
from haro.store import Store


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
        cwd=repo, check=True, capture_output=True, text=True,
    ).stdout


@pytest.fixture
def repo(tmp_path) -> Path:
    r = tmp_path / "repo"
    (r / "src").mkdir(parents=True)
    _git(r, "init", "-q", "-b", "main")
    (r / "src/price.js").write_text("p0\n")
    (r / "src/config.js").write_text("c0\n")
    (r / "README.md").write_text("r0\n")
    (r / "package-lock.json").write_text("{}\n")
    _git(r, "add", "-A")
    _git(r, "commit", "-q", "-m", "base")
    return r


class _Edits(AgentAdapter):
    name = "edits"

    def __init__(self, writes: dict[str, str]) -> None:
        self.writes = writes

    async def run(self, *, task, cwd, model=None, effort=None, resume=None,
                  instructions=None, max_budget_usd=None, plan=False):
        for rel, text in self.writes.items():
            p = Path(cwd) / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        yield NormalizedEvent("done", {"session_id": "c"})


def _setup(repo: Path, scope: list[str] | None = None):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(repo), base_ref="main")
    store.add_workspace(ws)
    run = AgentRun(workspace_id=ws.id, adapter="edits", task="t", model="haiku", scope=scope or [])
    store.add_run(run)
    return store, hub, ws, run


def _go(store, hub, ws, run, writes, plan=False):
    asyncio.run(run_agent(
        store=store, hub=hub, adapter=_Edits(writes), workspace=ws, run=run, auto_gate=False, plan=plan,
    ))


def _hand(store, ws):
    return asyncio.run(receipt_svc._build_hand_edits(store, ws))


# ---- what a run touched ---------------------------------------------------- #

def test_a_run_records_what_it_changed_and_not_the_devs_earlier_edits(repo):
    (repo / "README.md").write_text("r-by-hand\n")  # before the run: the developer's
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, {"src/price.js": "p1\n", "src/new.js": "n\n"})
    assert run.touched == ["src/new.js", "src/price.js"]


def test_a_fenced_run_does_not_claim_what_the_fence_reverted(repo):
    store, hub, ws, run = _setup(repo, scope=["src/price.js"])
    _go(store, hub, ws, run, {"src/price.js": "p1\n", "src/config.js": "c1\n"})
    assert run.scope_reverted == ["src/config.js"]
    assert run.touched == ["src/price.js"]


def test_a_plan_run_records_nothing(repo):
    store, hub, ws, run = _setup(repo)
    run.plan = True
    _go(store, hub, ws, run, {}, plan=True)
    assert run.touched is None


def test_a_run_that_never_started_touched_nothing(repo, monkeypatch):
    from haro import scope_fence

    async def boom(_wt):
        raise RuntimeError("no git")

    monkeypatch.setattr(scope_fence, "snapshot_tree", boom)
    store, hub, ws, run = _setup(repo, scope=["src"])
    _go(store, hub, ws, run, {"src/price.js": "p1\n"})
    assert run.touched == []


def test_an_unfenced_run_whose_snapshot_fails_still_runs_and_stays_unknown(repo, monkeypatch):
    from haro import scope_fence

    async def boom(_wt):
        raise RuntimeError("no git")

    monkeypatch.setattr(scope_fence, "snapshot_tree", boom)
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, {"src/price.js": "p1\n"})
    assert (repo / "src/price.js").read_text() == "p1\n"  # the agent still ran
    assert run.touched is None


# ---- the receipt ----------------------------------------------------------- #

def test_a_hand_edit_outside_the_runs_is_named_and_the_credit_is_shared(repo):
    (repo / "README.md").write_text("r-by-hand\n")
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, {"src/price.js": "p1\n"})
    hand = _hand(store, ws)
    assert hand.known and hand.paths == ["README.md"] and hand.shared == []
    assert receipt_svc.written_by(ws, "haiku", None, hand_files=1) == "you and the agent (1 file edited by hand)"


def test_a_hand_edit_between_two_runs_counts_too(repo):
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, {"src/price.js": "p1\n"})
    (repo / "README.md").write_text("r-by-hand-later\n")
    run2 = AgentRun(workspace_id=ws.id, adapter="edits", task="t2", model="haiku")
    store.add_run(run2)
    _go(store, hub, ws, run2, {"src/config.js": "c1\n"})
    assert _hand(store, ws).paths == ["README.md"]


def test_no_hand_edits_keeps_the_agent_label(repo):
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, {"src/price.js": "p1\n"})
    hand = _hand(store, ws)
    assert hand.known and hand.paths == [] and hand.shared == []
    assert receipt_svc.written_by(ws, "haiku", None, hand_files=0) == "agent · haiku"


def test_a_run_with_no_record_makes_the_receipt_say_nothing_instead_of_guessing(repo):
    (repo / "README.md").write_text("r-by-hand\n")
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, {"src/price.js": "p1\n"})
    old = AgentRun(workspace_id=ws.id, adapter="edits", task="old")  # touched is None, like an older run
    store.add_run(old)
    assert _hand(store, ws) == ReceiptHandEdits(unrecorded_runs=1)


def test_a_workspace_with_no_agent_run_claims_nothing(repo):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(repo), base_ref="main")
    store.add_workspace(ws)
    (repo / "README.md").write_text("r-by-hand\n")
    assert _hand(store, ws) == ReceiptHandEdits()


def test_what_setup_changed_is_never_credited_to_the_developer_but_later_edits_are(repo):
    store, hub, ws, run = _setup(repo)
    (repo / "package-lock.json").write_text('{"rewritten": true}\n')  # setup rewrote it
    ws.setup_tree = asyncio.run(scope_fence.snapshot_tree(str(repo)))
    _go(store, hub, ws, run, {"src/price.js": "p1\n"})
    assert _hand(store, ws).paths == []
    (repo / "package-lock.json").write_text('{"edited": "by hand"}\n')  # a real edit, after setup
    assert _hand(store, ws).paths == ["package-lock.json"]


def test_a_file_both_touched_is_shared_only_when_haros_editor_saved_it(repo):
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, {"src/price.js": "p1\n", "src/config.js": "c1\n"})
    ws.hand_saved_paths = ["src/price.js"]
    hand = _hand(store, ws)
    assert hand.paths == [] and hand.shared == ["src/price.js"]


def test_the_markdown_lists_the_hand_edited_files():
    r = Receipt(
        workspace_id="w", workspace_name="w", branch="b", base_ref="main", verdict="green",
        written_by="you and the agent (2 files edited by hand)",
        hand_edits=ReceiptHandEdits(known=True, paths=["README.md"], shared=["src/price.js"]),
    )
    md = receipt_svc.render_markdown(r)
    assert "Written by: you and the agent (2 files edited by hand)" in md
    assert "edited by hand, outside the agent's runs: `README.md`" in md
    assert "edited by the agent and by hand: `src/price.js`" in md


# ---- setup ----------------------------------------------------------------- #

def test_setup_records_the_tree_after_the_first_setup_only(repo, tmp_path):
    store, hub = Store(), Hub()
    ws = Workspace(project_id="p", name="w", branch="b", worktree_path=str(repo), base_ref="main")
    store.add_workspace(ws)
    project = Project(name="p", path=str(repo), default_branch="main")
    store.projects[project.id] = project
    ws.project_id = project.id
    settings = ProjectSettings(setup="echo rewritten > package-lock.json; echo gen > generated.txt")
    asyncio.run(lifecycle.run_setup(store=store, hub=hub, workspace=ws, project=project, psettings=settings))
    first = ws.setup_tree
    assert first and asyncio.run(scope_fence.changed_since(str(repo), first)) == []  # setup's work is in it
    (repo / "README.md").write_text("r-by-hand\n")
    assert asyncio.run(scope_fence.changed_since(str(repo), first)) == ["README.md"]
    asyncio.run(lifecycle.run_setup(store=store, hub=hub, workspace=ws, project=project, psettings=settings))
    assert ws.setup_tree == first  # a re-run does not move it: later setup output reads as a change


# ---- recording edge cases -------------------------------------------------- #

def test_touched_is_unknown_while_the_agent_runs_and_a_list_afterwards(repo):
    store, hub, ws, run = _setup(repo)
    seen: list = []

    class Peek(_Edits):
        async def run(self, **kw):
            seen.append(run.touched)
            async for ev in super().run(**kw):
                yield ev

    asyncio.run(run_agent(
        store=store, hub=hub, adapter=Peek({"src/price.js": "p1\n"}), workspace=ws, run=run, auto_gate=False,
    ))
    assert seen == [None] and run.touched == ["src/price.js"]


def test_a_slow_snapshot_never_delays_the_agent_and_leaves_authorship_unknown(repo, monkeypatch):
    async def slow(_wt):
        await asyncio.sleep(5)

    monkeypatch.setattr(scope_fence, "snapshot_tree", slow)
    monkeypatch.setattr(runner_mod, "_SNAPSHOT_BUDGET", 0.05)
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, {"src/price.js": "p1\n"})
    assert (repo / "src/price.js").read_text() == "p1\n"
    assert run.touched is None


def test_a_build_output_sized_change_list_is_recorded_as_unknown(repo, monkeypatch):
    monkeypatch.setattr(runner_mod, "_TOUCHED_CAP", 1)
    store, hub, ws, run = _setup(repo)
    _go(store, hub, ws, run, {"src/price.js": "p1\n", "src/config.js": "c1\n"})
    assert run.touched is None


def test_the_markdown_says_when_hand_edits_cannot_be_listed():
    r = Receipt(
        workspace_id="w", workspace_name="w", branch="b", base_ref="main", verdict="green",
        written_by="agent \u00b7 haiku", hand_edits=ReceiptHandEdits(unrecorded_runs=2),
    )
    assert "hand edits cannot be listed: haro has no record of what 2 agent run(s) touched" in receipt_svc.render_markdown(r)
