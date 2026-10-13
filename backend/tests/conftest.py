"""Keep the suite off the developer's real GitHub accounts.

``git_ops.gh_env`` resolves an account (``gh auth status`` plus an API probe with each stored
token), so without this any test that builds a gh env would read real credentials and hit
github.com. ``tests/test_github_accounts.py`` re-enables it against a fake ``gh``.
"""

from __future__ import annotations

import pytest

from haro import github_accounts


@pytest.fixture(autouse=True)
def _no_real_github_accounts(monkeypatch):
    monkeypatch.setattr(github_accounts, "gh_available", lambda: False)
    github_accounts.reset()
    yield
    github_accounts.reset()
