"""What the review step reports (Viewed marks, how long each file was open, a reason) and how
the receipt turns it into one bounded sentence: it says what was recorded in haro, measured
against the files changed now, and never that the change was understood."""

from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path

import pytest
from fastapi import HTTPException

from haro import main, receipt as receipt_svc
from haro.config import ProjectSettings
from haro.models import (
    QUICK_VIEW_SECONDS,
    ReceiptReading,
    ReviewRecordRequest,
    ReviewViewedFile,
    Workspace,
)


def run(coro):
    return asyncio.run(coro)


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
        cwd=repo, check=True, capture_output=True, text=True,
    )


@pytest.fixture
def ws(tmp_path):
    repo = tmp_path / "repo"
    (repo / "src").mkdir(parents=True)
    _git(repo, "init", "-q", "-b", "main")
    (repo / "src/a.ts").write_text("a0\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "base")
    for name in ("a.ts", "b.ts", "c.ts"):
        (repo / "src" / name).write_text(f"{name} changed\n")
    w = Workspace(project_id="p", name="w", branch="b", worktree_path=str(repo), base_ref="main")
    main.store.add_workspace(w)
    yield w
    main.store.remove_workspace(w.id)


def put(ws, **kw):
    return run(main.put_review_record(ws.id, ReviewRecordRequest(**kw)))


def reading(ws) -> ReceiptReading:
    return run(receipt_svc.build_receipt(store=main.store, workspace=ws, settings=ProjectSettings())).reading


def v(path, seconds=30.0):
    return ReviewViewedFile(path=path, seconds=seconds)


def test_nothing_recorded_until_the_review_step_reports(ws):
    r = reading(ws)
    assert r.recorded is False and r.viewed == 0 and r.median_seconds is None
    assert receipt_svc.reading_line(r) == "- Review in haro: no Viewed marks were recorded"


def test_a_report_is_measured_against_the_files_changed_now(ws):
    put(ws, viewed=[v("src/a.ts", 40), v("src/b.ts", 10), v("src/gone.ts", 99)], files=3)
    r = reading(ws)
    assert (r.recorded, r.files, r.viewed) == (True, 3, 2)
    assert r.median_seconds == 25.0
    assert r.quick_views == 0
    assert receipt_svc.reading_line(r) == "- Review in haro: Viewed 2 of 3 files, median 25 s open per file"


def test_quick_views_are_counted_and_said(ws):
    put(ws, viewed=[v("src/a.ts", 2), v("src/b.ts", 1.5), v("src/c.ts", 60)], files=3)
    r = reading(ws)
    assert r.quick_views == 2
    line = receipt_svc.reading_line(r)
    assert line.endswith(f"2 marked Viewed in under {QUICK_VIEW_SECONDS:g} s")
    assert "Viewed 3 of 3 files" in line


def test_a_report_with_nothing_viewed_is_still_a_record(ws):
    put(ws, viewed=[], files=3)
    r = reading(ws)
    assert r.recorded is True and r.viewed == 0
    assert receipt_svc.reading_line(r) == "- Review in haro: Viewed 0 of 3 files"


def test_the_reason_is_kept_trimmed_and_capped_and_does_not_touch_the_marks(ws):
    put(ws, viewed=[v("src/a.ts")], files=3)
    rec = put(ws, reason="  Read the diff,\n   ran it by hand.  " + "x" * 400)
    assert rec.reason.startswith("Read the diff, ran it by hand. xxx") and len(rec.reason) == 300
    assert [f.path for f in rec.viewed] == ["src/a.ts"]
    assert put(ws, reason="").reason == ""


def test_marks_sent_again_replace_the_old_ones_and_keep_the_reason(ws):
    put(ws, viewed=[v("src/a.ts"), v("src/b.ts")], files=3, reason="ok")
    rec = put(ws, viewed=[v("src/c.ts", 7)], files=3)
    assert [f.path for f in rec.viewed] == ["src/c.ts"] and rec.reason == "ok"


def test_paths_are_normalised_and_seconds_clamped(ws):
    rec = put(ws, viewed=[v("./src\\a.ts", -5), v("  ", 1), v("/src/b.ts", 10**9)], files=2)
    assert [(f.path, f.seconds) for f in rec.viewed] == [("src/a.ts", 0.0), ("src/b.ts", 86400.0)]


def test_unknown_workspace_and_oversized_reports_are_refused(ws):
    with pytest.raises(HTTPException) as e:
        run(main.put_review_record("nope", ReviewRecordRequest(reason="x")))
    assert e.value.status_code == 404
    with pytest.raises(HTTPException) as e:
        put(ws, viewed=[v(f"f{i}.ts") for i in range(2001)])
    assert e.value.status_code == 400


def test_the_markdown_carries_the_line_and_the_reason(ws):
    put(ws, viewed=[v("src/a.ts", 20)], files=3, reason="Ran it and read the route.")
    rcpt = run(receipt_svc.build_receipt(store=main.store, workspace=ws, settings=ProjectSettings()))
    md = receipt_svc.render_markdown(rcpt)
    assert "- Review in haro: Viewed 1 of 3 files, median 20 s open per file" in md
    assert "- Approval reason: Ran it and read the route. (typed by the developer)" in md
    assert "understood" not in md.lower() and "verified by" not in md.lower()


def test_duplicate_paths_count_once(ws):
    put(ws, viewed=[v("a.ts", 3), v("./a.ts", 9)], files=1)
    assert len(ws.review_record.viewed) == 1
