from pathlib import Path

import haro.update as update


def _use_tmp(monkeypatch, tmp_path) -> Path:
    """Point the progress file at a tmp path so tests never touch the real ~/.haro."""
    p = tmp_path / ".update-progress"
    monkeypatch.setattr(update, "_PROGRESS", p)
    return p


def test_progress_none_when_absent(monkeypatch, tmp_path):
    _use_tmp(monkeypatch, tmp_path)
    assert update.progress() is None


def test_progress_roundtrip_and_clamps(monkeypatch, tmp_path):
    _use_tmp(monkeypatch, tmp_path)
    update._write_progress(35, "Freezing backend")
    assert update.progress() == {"pct": 35, "label": "Freezing backend"}
    # Out-of-range milestones are clamped so the bar can't overflow.
    update._write_progress(250, "over")
    assert update.progress()["pct"] == 100


def test_progress_malformed_pct_is_none(monkeypatch, tmp_path):
    p = _use_tmp(monkeypatch, tmp_path)
    p.write_text("PCT=notanumber\nLABEL=x\n")
    assert update.progress() is None


def test_clear_progress_removes_file(monkeypatch, tmp_path):
    p = _use_tmp(monkeypatch, tmp_path)
    update._write_progress(50, "half")
    assert p.exists()
    update.clear_progress()
    assert not p.exists()
    assert update.progress() is None
