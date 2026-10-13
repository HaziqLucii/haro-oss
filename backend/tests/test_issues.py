"""Tests for the GitHub Issues backlog source (``haro.issues``).

Guards the behaviours the backlog UI depends on: open-before-closed ordering,
the short-TTL cache that bounds ``gh`` calls, and the graceful-degrade paths
(no remote / no gh / offline → last-good display cache). ``gh`` and
``has_remote`` are monkeypatched so nothing shells out.
"""

import asyncio

import pytest

from haro import issues


@pytest.fixture(autouse=True)
def _clear_cache():
    issues._cache.clear()
    yield
    issues._cache.clear()


def _fake_gh(code, out, err=""):
    async def gh(*args, cwd):  # noqa: ANN001
        return code, out, err
    return gh


def _payload(*rows):
    import json
    return json.dumps(list(rows))


def _row(number, title, state, labels=(), body=""):
    return {
        "number": number,
        "title": title,
        "body": body,
        "state": state,
        "labels": [{"name": n} for n in labels],
        "url": f"https://github.com/o/r/issues/{number}",
    }


def _remote(ok=True):
    async def has_remote(path):  # noqa: ANN001
        return ok
    return has_remote


def test_open_before_closed_recent_first(monkeypatch):
    out = _payload(
        _row(1, "old open", "OPEN"),
        _row(5, "new closed", "CLOSED"),
        _row(9, "new open", "OPEN"),
        _row(3, "old closed", "CLOSED"),
    )
    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", _fake_gh(0, out))
    res = asyncio.run(issues.list_issues("/repo"))
    assert res["available"] is True and res["stale"] is False
    order = [(i["number"], i["state"]) for i in res["issues"]]
    assert order == [(9, "open"), (1, "open"), (5, "closed"), (3, "closed")]
    assert res["issues"][0]["labels"] == []


def test_labels_flattened(monkeypatch):
    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", _fake_gh(0, _payload(_row(1, "t", "OPEN", ["bug", "p1"]))))
    res = asyncio.run(issues.list_issues("/repo"))
    assert res["issues"][0]["labels"] == ["bug", "p1"]


def test_no_remote_is_empty_state(monkeypatch):
    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(False))
    res = asyncio.run(issues.list_issues("/repo"))
    assert res == {"available": False, "reason": "no-remote", "issues": []}


def test_gh_missing_is_empty_state(monkeypatch):
    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", _fake_gh(127, "", "`gh` CLI not found"))
    res = asyncio.run(issues.list_issues("/repo"))
    assert res["available"] is False and res["reason"] == "no-gh"


def test_cache_served_within_ttl_without_reshelling(monkeypatch):
    calls = {"n": 0}

    async def gh(*args, cwd):  # noqa: ANN001
        calls["n"] += 1
        return 0, _payload(_row(1, "t", "OPEN")), ""

    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", gh)
    asyncio.run(issues.list_issues("/repo"))
    res2 = asyncio.run(issues.list_issues("/repo"))
    assert calls["n"] == 1  # second call served from cache
    assert res2["stale"] is False and res2["fetched_at"]


def test_force_bypasses_ttl(monkeypatch):
    calls = {"n": 0}

    async def gh(*args, cwd):  # noqa: ANN001
        calls["n"] += 1
        return 0, _payload(_row(1, "t", "OPEN")), ""

    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", gh)
    asyncio.run(issues.list_issues("/repo"))
    asyncio.run(issues.list_issues("/repo", force=True))
    assert calls["n"] == 2


def test_failed_refresh_serves_stale_cache(monkeypatch):
    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", _fake_gh(0, _payload(_row(1, "t", "OPEN"))))
    asyncio.run(issues.list_issues("/repo"))
    # A later fetch fails (offline / rate-limited) → serve the last good result stamped stale.
    monkeypatch.setattr(issues, "_gh", _fake_gh(1, "", "network error"))
    res = asyncio.run(issues.list_issues("/repo", force=True))
    assert res["available"] is True and res["stale"] is True
    assert res["issues"][0]["number"] == 1
    assert res["reason"] == "network error"


def test_failed_first_fetch_without_cache_is_unavailable(monkeypatch):
    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", _fake_gh(1, "", "boom"))
    res = asyncio.run(issues.list_issues("/repo"))
    assert res["available"] is False and res["reason"] == "boom"


# ── state/assignee/limit are real query params, not hard-coded ──────────────────
def test_state_assignee_limit_passed_to_gh(monkeypatch):
    calls: list = []

    async def gh(*args, cwd):  # noqa: ANN001
        calls.append(args)
        return 0, _payload(_row(1, "t", "OPEN")), ""

    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", gh)
    asyncio.run(issues.list_issues("/repo", state="closed", assignee="@me", limit=7))
    args = calls[0]
    assert "--state" in args and args[args.index("--state") + 1] == "closed"
    assert "--assignee" in args and args[args.index("--assignee") + 1] == "@me"
    assert "--limit" in args and args[args.index("--limit") + 1] == "7"


def test_no_assignee_omits_the_flag(monkeypatch):
    calls: list = []

    async def gh(*args, cwd):  # noqa: ANN001
        calls.append(args)
        return 0, _payload(), ""

    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", gh)
    asyncio.run(issues.list_issues("/repo", assignee=""))
    assert "--assignee" not in calls[0]


def test_different_queries_cache_independently(monkeypatch):
    calls = {"n": 0}

    async def gh(*args, cwd):  # noqa: ANN001
        calls["n"] += 1
        return 0, _payload(_row(1, "t", "OPEN")), ""

    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", gh)
    asyncio.run(issues.list_issues("/repo", state="open"))
    asyncio.run(issues.list_issues("/repo", state="closed"))
    assert calls["n"] == 2  # distinct query, no cache hit


def test_truncated_when_result_hits_limit(monkeypatch):
    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(
        issues, "_gh", _fake_gh(0, _payload(_row(1, "a", "OPEN"), _row(2, "b", "OPEN")))
    )
    res = asyncio.run(issues.list_issues("/repo", limit=2))
    assert res["truncated"] is True


def test_not_truncated_under_limit(monkeypatch):
    monkeypatch.setattr(issues.git_ops, "has_remote", _remote(True))
    monkeypatch.setattr(issues, "_gh", _fake_gh(0, _payload(_row(1, "a", "OPEN"))))
    res = asyncio.run(issues.list_issues("/repo", limit=100))
    assert res["truncated"] is False


def _recording_gh(calls, code=0):
    async def gh(*args, cwd):  # noqa: ANN001
        calls.append((args, cwd))
        return code, "", ""
    return gh


def test_write_back_assigns_labels_and_comments(monkeypatch):
    calls: list = []
    monkeypatch.setattr(issues, "_gh", _recording_gh(calls))
    asyncio.run(issues.write_back_on_pickup("/repo", 42))
    assert calls[0] == (
        ("issue", "edit", "42", "--add-assignee", "@me", "--add-label", "in-progress"),
        "/repo",
    )
    assert calls[1] == (("issue", "comment", "42", "--body", "Picked up in haro."), "/repo")


def test_write_back_invalidates_cache(monkeypatch):
    # Two different queries cached for the same project — both must be dropped,
    # a cached query for a different project must not be touched.
    issues._cache[("/repo", "open", "", 100)] = (0.0, [_row(1, "t", "open")])
    issues._cache[("/repo", "all", "@me", 100)] = (0.0, [_row(1, "t", "open")])
    issues._cache[("/other", "open", "", 100)] = (0.0, [_row(2, "t", "open")])
    monkeypatch.setattr(issues, "_gh", _recording_gh([]))
    asyncio.run(issues.write_back_on_pickup("/repo", 1))
    assert not any(k[0] == "/repo" for k in issues._cache)
    assert ("/other", "open", "", 100) in issues._cache


def test_write_back_swallows_gh_failure(monkeypatch):
    # Missing label / no perms / offline → gh exits non-zero; the pickup already
    # succeeded locally, so write-back must not raise.
    monkeypatch.setattr(issues, "_gh", _recording_gh([], code=1))
    asyncio.run(issues.write_back_on_pickup("/repo", 7))  # no exception
