"""Tests for on-demand single-issue detail (``haro.issue_detail``).

Guards the shape the detail panel consumes (body + flattened comments + labels)
and the graceful-degrade paths (no remote / no gh / fetch fail / bad JSON).
``gh`` and ``has_remote`` are monkeypatched so nothing shells out.
"""

import asyncio
import json

import pytest

from haro import issue_detail


def _fake_gh(code, out, err=""):
    async def gh(*args, cwd):  # noqa: ANN001
        return code, out, err
    return gh


def _remote(ok=True):
    async def has_remote(path):  # noqa: ANN001
        return ok
    return has_remote


def _payload(**overrides):
    base = {
        "number": 42,
        "title": "A bug",
        "body": "  the body  ",
        "state": "OPEN",
        "url": "https://github.com/o/r/issues/42",
        "labels": [{"name": "bug"}, {"name": "p1"}, {"name": ""}],
        "comments": [
            {"author": {"login": "alice"}, "body": "  first  ", "createdAt": "2026-01-01T10:00:00Z"},
            {"author": None, "body": "second", "createdAt": ""},
        ],
    }
    base.update(overrides)
    return json.dumps(base)


def test_normalizes_body_labels_and_comments(monkeypatch):
    monkeypatch.setattr(issue_detail.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issue_detail, "_gh", _fake_gh(0, _payload()))
    res = asyncio.run(issue_detail.view_issue("/repo", 42))
    assert res["available"] is True
    assert res["number"] == 42
    assert res["title"] == "A bug"
    assert res["body"] == "the body"  # trimmed
    assert res["state"] == "open"  # lowercased
    assert res["labels"] == ["bug", "p1"]  # empty label dropped
    assert res["comments"] == [
        {"author": "alice", "body": "first", "created_at": "2026-01-01T10:00:00Z"},
        {"author": "", "body": "second", "created_at": ""},  # null author → ""
    ]


def test_no_remote_is_unavailable(monkeypatch):
    monkeypatch.setattr(issue_detail.git_ops, "has_remote", _remote(False))
    res = asyncio.run(issue_detail.view_issue("/repo", 1))
    assert res == {"available": False, "reason": "no-remote"}


def test_gh_missing_is_unavailable(monkeypatch):
    monkeypatch.setattr(issue_detail.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issue_detail, "_gh", _fake_gh(127, "", "`gh` CLI not found"))
    res = asyncio.run(issue_detail.view_issue("/repo", 1))
    assert res["available"] is False and res["reason"] == "no-gh"


def test_fetch_failure_reports_reason(monkeypatch):
    monkeypatch.setattr(issue_detail.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issue_detail, "_gh", _fake_gh(1, "", "not found"))
    res = asyncio.run(issue_detail.view_issue("/repo", 999))
    assert res["available"] is False and res["reason"] == "not found"


def test_malformed_json_degrades(monkeypatch):
    monkeypatch.setattr(issue_detail.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issue_detail, "_gh", _fake_gh(0, "{not json"))
    res = asyncio.run(issue_detail.view_issue("/repo", 1))
    assert res["available"] is False and "malformed" in res["reason"]
