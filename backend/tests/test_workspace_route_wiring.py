"""Regression guard: the create-workspace route must be wired to ``create_workspace``.

A misplaced ``@app.post("/projects/{project_id}/workspaces")`` decorator once landed
on the helper ``_unique_slug`` (a merge artifact), so the route ran the *helper* —
whose params (``project: Project``, ``base_slug: str``) demanded a ``path`` body +
``base_slug`` query — and EVERY workspace create returned 422 (surfacing in the UI
as an "[object Object]" toast). The whole suite still passed because nothing
exercised the route's *wiring*. These tests do.
"""

from __future__ import annotations

from haro.main import app


def _route(path: str, method: str):
    for r in app.routes:
        if getattr(r, "path", None) == path and method in getattr(r, "methods", set()):
            return r
    return None


def test_create_workspace_route_wired_to_handler() -> None:
    r = _route("/projects/{project_id}/workspaces", "POST")
    assert r is not None, "POST /projects/{project_id}/workspaces route is missing"
    assert r.endpoint.__name__ == "create_workspace", (
        f"route wired to {r.endpoint.__name__!r}, not create_workspace "
        "(decorator on the wrong function?)"
    )


def test_create_workspace_body_needs_no_path_or_base_slug() -> None:
    """The create body must be CreateWorkspaceRequest — no ``path`` field and no
    ``base_slug`` query param (those are the fingerprint of the misplaced decorator
    running _unique_slug / a Project body)."""
    op = app.openapi()["paths"]["/projects/{project_id}/workspaces"]["post"]
    params = {p["name"] for p in op.get("parameters", [])}
    assert "base_slug" not in params, f"unexpected query param base_slug (params={params})"
    ref = op["requestBody"]["content"]["application/json"]["schema"].get("$ref", "")
    assert ref.endswith("CreateWorkspaceRequest"), f"create body schema is {ref!r}"
