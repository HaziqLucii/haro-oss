"""Usage panel data — the Claude subscription rate-limit windows.

Mirrors Claude Desktop's "Usage" view (session / weekly utilization + reset
countdowns + extra-usage credits) inside haro, so a dev running agents here can
see how close they are to a limit without leaving the app.

The numbers come from Anthropic's OAuth usage endpoint
(``GET https://api.anthropic.com/api/oauth/usage``) — the same feed Claude Code
and the desktop app read. We authenticate with the *user's own* Claude Code
OAuth token, the one Claude Code already stores on this machine, and only ever
READ it:

  - **macOS**: the live token lives in the login Keychain (generic-password
    service ``Claude Code-credentials``). ``~/.claude/.credentials.json`` there
    is a stale leftover from an old login, so we pick whichever store carries the
    fresher ``expiresAt``.
  - **Linux** (haro's primary target): ``~/.claude/.credentials.json`` *is* the
    live store.

We deliberately do NOT refresh or rewrite the token. OAuth refresh tokens
rotate; refreshing here could invalidate the token Claude Code is actively using
and break the user's live session. When the stored token is expired (Claude Code
hasn't run in a while) we return ``{available: false, reason: "token_expired"}``
and the UI shows a gentle "run any agent to refresh" note — running an agent
makes Claude Code refresh the token for us.

This is the one outbound network call haro makes: a read of the user's own
account usage with their own credentials, not a new cloud permission.
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
_PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
_KEYCHAIN_SERVICE = "Claude Code-credentials"
_CACHE_TTL = 60.0  # the UI polls ~every 60s; cache so we don't hammer the endpoint

# rate_limit_tier -> the plan a user recognizes. Falls back to a prettified tier.
_TIER_LABELS = {
    "default_claude_max_20x": "Claude Max 20×",
    "default_claude_max_5x": "Claude Max 5×",
    "default_claude_pro": "Claude Pro",
    "default_claude_free": "Claude Free",
}
_ORG_LABELS = {
    "claude_team": "Claude Team",
    "claude_enterprise": "Claude Enterprise",
}

# human labels for the usage `limits[]` kinds (scoped ones get the model appended)
_KIND_LABELS = {
    "session": "Current session",
    "weekly_all": "Weekly (all models)",
    "weekly_scoped": "Weekly",
}

_cache: dict[str, Any] | None = None
_cache_at = 0.0


# --------------------------------------------------------------------------- #
# credential loading (read-only)
# --------------------------------------------------------------------------- #
def _from_keychain() -> dict | None:
    if sys.platform != "darwin":
        return None
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", _KEYCHAIN_SERVICE, "-w"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    try:
        return json.loads(out.stdout).get("claudeAiOauth")
    except json.JSONDecodeError:
        return None


def _from_file() -> dict | None:
    path = Path(os.path.expanduser("~/.claude/.credentials.json"))
    try:
        return json.loads(path.read_text()).get("claudeAiOauth")
    except (OSError, json.JSONDecodeError):
        return None


def _load_oauth() -> dict | None:
    """The freshest available credential blob (by ``expiresAt``), or None."""
    candidates = [c for c in (_from_keychain(), _from_file()) if c and c.get("accessToken")]
    if not candidates:
        return None
    return max(candidates, key=lambda c: c.get("expiresAt") or 0)


def _get_json(url: str, token: str) -> Any:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=10) as resp:  # noqa: S310 (fixed https host)
        return json.loads(resp.read().decode())


# --------------------------------------------------------------------------- #
# normalization
# --------------------------------------------------------------------------- #
def _money(m: dict | None) -> str | None:
    """{amount_minor, exponent, currency?} -> "$70.06" style label."""
    if not m or m.get("amount_minor") is None:
        return None
    exp = m.get("exponent", 2)
    amount = m["amount_minor"] / (10 ** exp)
    cur = m.get("currency", "USD")
    sym = "$" if cur == "USD" else f"{cur} "
    return f"{sym}{amount:,.{exp}f}"


def _limit_label(item: dict) -> str:
    base = _KIND_LABELS.get(item.get("kind"), (item.get("kind") or "limit").replace("_", " ").title())
    scope = item.get("scope") or {}
    model = (scope.get("model") or {}).get("display_name")
    if item.get("kind") == "weekly_scoped" and model:
        return f"Weekly ({model})"
    return base


def _normalize_limits(raw: dict) -> list[dict]:
    """Prefer the modern `limits[]` array; synthesize from the legacy
    five_hour/seven_day fields if it's absent (older API shape)."""
    items = raw.get("limits")
    if isinstance(items, list) and items:
        return [
            {
                "kind": it.get("kind"),
                "group": it.get("group"),
                "label": _limit_label(it),
                "percent": it.get("percent"),
                "severity": it.get("severity") or "normal",
                "resets_at": it.get("resets_at"),
                "is_active": bool(it.get("is_active")),
            }
            for it in items
        ]
    out: list[dict] = []
    for kind, key in (("session", "five_hour"), ("weekly_all", "seven_day")):
        w = raw.get(key)
        if isinstance(w, dict) and w.get("utilization") is not None:
            out.append(
                {
                    "kind": kind,
                    "group": "session" if kind == "session" else "weekly",
                    "label": _KIND_LABELS[kind],
                    "percent": round(w["utilization"]),
                    "severity": "normal",
                    "resets_at": w.get("resets_at"),
                    "is_active": kind == "session",
                }
            )
    return out


def _normalize_spend(raw: dict) -> dict | None:
    """Extra-usage credits (`spend`) — the "usage credits cover you past your
    plan limits" bar Claude Desktop shows when it's enabled."""
    s = raw.get("spend")
    if not isinstance(s, dict) or not s.get("enabled"):
        return None
    return {
        "percent": s.get("percent"),
        "severity": s.get("severity") or "normal",
        "used_label": _money(s.get("used")),
        "limit_label": _money(s.get("limit")),
        "disclaimer": s.get("disclaimer"),
    }


def _account(profile: dict, oauth: dict) -> dict:
    acct = profile.get("account") or {}
    org = profile.get("organization") or {}
    tier = org.get("rate_limit_tier") or oauth.get("rateLimitTier")
    org_type = org.get("organization_type")
    plan = _TIER_LABELS.get(tier) or _ORG_LABELS.get(org_type)
    if not plan and tier:
        plan = tier.replace("default_", "").replace("_", " ").title()
    return {
        "name": acct.get("display_name") or acct.get("full_name"),
        "email": acct.get("email"),
        "org": org.get("name"),
        "plan": plan,
    }


# --------------------------------------------------------------------------- #
# public API
# --------------------------------------------------------------------------- #
def _fetch_sync() -> dict[str, Any]:
    oauth = _load_oauth()
    if not oauth:
        return {"available": False, "reason": "no_credentials"}

    expires_at = oauth.get("expiresAt") or 0
    if expires_at and expires_at / 1000 <= time.time() + 30:
        return {"available": False, "reason": "token_expired"}

    token = oauth["accessToken"]
    try:
        raw = _get_json(_USAGE_URL, token)
    except urllib.error.HTTPError as e:
        # 401/403 => the stored token was rejected (expired/revoked despite the
        # local expiry stamp). Treat as "run an agent to refresh".
        reason = "token_expired" if e.code in (401, 403) else "fetch_failed"
        return {"available": False, "reason": reason, "detail": f"HTTP {e.code}"}
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
        return {"available": False, "reason": "fetch_failed", "detail": str(e)}

    # Profile is best-effort: usage still renders without the account header.
    profile: dict = {}
    try:
        profile = _get_json(_PROFILE_URL, token)
    except Exception:  # noqa: BLE001 — cosmetic; never block on it
        profile = {}

    return {
        "available": True,
        "fetched_at": time.time(),
        "account": _account(profile, oauth),
        "limits": _normalize_limits(raw),
        "spend": _normalize_spend(raw),
    }


async def get_usage(*, force: bool = False) -> dict[str, Any]:
    """Cached (60s) usage snapshot for GET /usage. The blocking read+HTTP runs off
    the event loop so a slow network call can't stall the API."""
    global _cache, _cache_at
    if not force and _cache is not None and time.time() - _cache_at < _CACHE_TTL:
        return _cache
    result = await asyncio.to_thread(_fetch_sync)
    if result.get("available"):
        _cache, _cache_at = result, time.time()
    return result
