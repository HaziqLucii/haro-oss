"""Whether the gate starts by itself when an agent run finishes.

`[gate] auto_run` (default off) decides; an explicit `run_gate_on_done` on the request wins;
a test-first build keeps its gate whatever the project says.
"""

from __future__ import annotations

from test_acceptance import _start, _wire  # noqa: F401


def _auto_run_in(repo, value: bool) -> None:
    (repo / ".haro").mkdir(exist_ok=True)
    (repo / ".haro" / "settings.toml").write_text(f"[gate]\nauto_run = {str(value).lower()}\n")


def test_the_gate_does_not_start_by_itself_by_default(tmp_path, monkeypatch):
    _store, ws, _repo, seen = _wire(tmp_path, monkeypatch)
    _start(ws, seen, task="add a feature")
    assert seen[0]["auto_gate"] is False


def test_the_project_setting_turns_it_on(tmp_path, monkeypatch):
    _store, ws, repo, seen = _wire(tmp_path, monkeypatch)
    _auto_run_in(repo, True)
    _start(ws, seen, task="add a feature")
    assert seen[0]["auto_gate"] is True


def test_an_explicit_request_value_beats_the_project(tmp_path, monkeypatch):
    _store, ws, repo, seen = _wire(tmp_path, monkeypatch)
    _auto_run_in(repo, True)
    _start(ws, seen, task="a", run_gate_on_done=False)
    assert seen[0]["auto_gate"] is False
    _auto_run_in(repo, False)
    _start(ws, seen, task="b", run_gate_on_done=True)
    assert seen[1]["auto_gate"] is True

