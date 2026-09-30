"""Stack presets — templates that fill in a project's ``.haro/settings.toml``.

A preset is **not** a stored "stack identity"; it's a one-shot template that
*writes* the ordinary config keys (``[scripts] setup/run`` + ``[gate]``) the rest
of the platform already reads. Real repos are polyglot (theme + Node asset build;
Python API + React front), so we never branch behaviour on "stack type" — the
preset just proposes a starting config the dev can accept or edit, and
``custom/none`` is always on the menu.

Each preset carries a ``detect(root)`` that sniffs the repo tree and returns a
confidence in ``[0, 1]``. The add-project detection step ranks every preset by
that score: the clear winner is proposed; a near-tie returns the candidates
rather than auto-picking (see ``detect_stack``). ``custom/none`` sits at a low
floor so it's always offered but never outranks a real match.
"""

from __future__ import annotations

import json
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable


@dataclass(frozen=True)
class Preset:
    """One stack template. ``setup``/``run`` become ``[scripts]`` keys and
    ``gate`` becomes the ``[gate]`` table when serialized to ``settings.toml``."""

    id: str
    label: str
    #: One-line human proposal, e.g. "Looks like a Shopify theme".
    blurb: str
    #: ``root: Path -> confidence in [0, 1]``. 0 means "not this stack".
    detect: Callable[[Path], float]
    setup: str | None = None
    run: str | None = None
    #: ``[gate]`` keys, e.g. ``{"runner": "command", "command": "make test"}``.
    gate: dict[str, str] = field(default_factory=dict)
    #: Run the lifecycle scripts through ``$SHELL -lc`` — set when the stack's CLI
    #: is resolved via a login-sourced PATH (nvm/asdf) or a locally-installed
    #: ``node_modules/.bin`` reached through ``npx``.
    login_shell: bool = False


# --- detectors -------------------------------------------------------------
# Each returns a confidence, not a bool, so ambiguous repos surface candidates
# instead of a wrong auto-pick. Missing/unreadable files read as "no signal" (0)
# rather than raising — detection must never crash add-project.


def _read_toml(path: Path) -> dict:
    try:
        with path.open("rb") as fh:
            return tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def _read_text(path: Path) -> str:
    try:
        return path.read_text()
    except OSError:
        return ""


def _detect_vitest(root: Path) -> float:
    """Node repo whose ``package.json`` pulls in vitest (a dep or a script)."""
    try:
        data = json.loads(_read_text(root / "package.json") or "{}")
    except (ValueError, TypeError):
        return 0.0
    if not isinstance(data, dict):
        return 0.0
    deps = {
        **(data.get("dependencies") or {}),
        **(data.get("devDependencies") or {}),
    }
    if "vitest" in deps:
        return 0.95
    scripts = data.get("scripts") or {}
    if any("vitest" in str(v) for v in scripts.values()):
        return 0.9
    # A Node project with no vitest signal: weak — the dev may still want it,
    # but it shouldn't beat a stack we actually recognize.
    return 0.2 if (root / "package.json").exists() else 0.0


def _detect_pytest(root: Path) -> float:
    """Python repo configured for pytest (pyproject/pytest.ini/setup.cfg/tests)."""
    if (root / "pytest.ini").exists() or (root / "tox.ini").exists():
        return 0.9
    pyproject = _read_toml(root / "pyproject.toml")
    if pyproject:
        tools = pyproject.get("tool", {})
        if isinstance(tools, dict) and "pytest" in tools:
            return 0.95
        deps = str(pyproject.get("project", {}).get("dependencies", "")) + str(
            pyproject.get("project", {}).get("optional-dependencies", "")
        )
        if "pytest" in deps:
            return 0.9
    if "[tool:pytest]" in _read_text(root / "setup.cfg"):
        return 0.9
    # A tests/ tree full of test_*.py is a decent pytest signal on its own.
    tests = root / "tests"
    if tests.is_dir() and any(tests.glob("test_*.py")):
        return 0.6
    if (root / "pyproject.toml").exists():
        return 0.3
    return 0.0


def _detect_shopify_theme(root: Path) -> float:
    """Shopify theme layout: the settings schema + sections/, and Liquid or a
    theme-check config. These co-occurring is a strong, unambiguous signal."""
    if (root / ".theme-check.yml").exists() or (root / ".theme-check.yaml").exists():
        return 0.95
    has_schema = (root / "config" / "settings_schema.json").exists()
    has_sections = (root / "sections").is_dir()
    has_liquid = any((root / "templates").glob("*.liquid")) if (
        root / "templates"
    ).is_dir() else False
    if has_schema and has_sections and has_liquid:
        return 0.95
    if has_schema and has_sections:
        return 0.75
    return 0.0


def _detect_custom(root: Path) -> float:
    """Always-available fallback. A low, constant floor so it's offered on every
    repo but never outranks a stack we actually recognized."""
    return 0.1


# --- registry --------------------------------------------------------------
# Ordered by specificity (most-distinctive stack first); ``custom/none`` last so
# it's the tie-break fallback. ``PRESETS_BY_ID`` mirrors this for lookups.

PRESETS: list[Preset] = [
    Preset(
        id="shopify-theme",
        label="Shopify theme",
        blurb="Looks like a Shopify theme",
        detect=_detect_shopify_theme,
        # Install the Shopify CLI *locally* into the worktree's node_modules and
        # invoke it via `npx` — NOT `npm i -g`. haro's setup runs as an unprivileged
        # user whose npm prefix is /usr, so a global install EACCESes (exit 243). Pin
        # to the 3.x line: 4.x needs Node >=22.12 (it imports enableCompileCache from
        # node:module) and hard-fails on the Node 20 runtime. `npx` reaches the local
        # bin, which is why this preset runs through a login shell (see login_shell).
        setup="npm install @shopify/cli@3.94.3",
        run="npx shopify theme dev --port $HARO_PORT",
        # The offense adapter turns `theme check --output json` into the live grid.
        gate={
            "runner": "offense",
            "command": "npx shopify theme check --output json",
            "format": "theme-check",
        },
        login_shell=True,
    ),
    Preset(
        id="pytest",
        label="Python (pytest)",
        blurb="Looks like a Python project (pytest)",
        detect=_detect_pytest,
        setup="pip install -e .",
        run=None,
        gate={"runner": "pytest"},
    ),
    Preset(
        id="vitest",
        label="Node (vitest)",
        blurb="Looks like a Node project (vitest)",
        detect=_detect_vitest,
        setup="npm install",
        run="npm run dev",
        gate={"runner": "vitest"},
    ),
    Preset(
        id="custom",
        label="Custom / none",
        blurb="Configure the gate manually",
        detect=_detect_custom,
        setup=None,
        run=None,
        gate={},
    ),
]

PRESETS_BY_ID: dict[str, Preset] = {p.id: p for p in PRESETS}


def get_preset(preset_id: str) -> Preset | None:
    return PRESETS_BY_ID.get(preset_id)


@dataclass(frozen=True)
class DetectionResult:
    """A preset ranked against a repo. ``confidence`` is the detector's raw score;
    ``ambiguous`` marks a run where no single preset clearly won."""

    preset: Preset
    confidence: float


def detect_stack(project_path: str | Path) -> list[DetectionResult]:
    """Rank every preset against the repo at ``project_path``, best first.

    ``custom`` is always present (its floor guarantees it), so the list is never
    empty. Callers decide how to act on the ranking: the top result is the
    proposal, but when the runner-up scores within ``AMBIGUITY_MARGIN`` of it the
    two are genuine candidates and the UI should ask rather than auto-pick (see
    ``is_ambiguous``)."""
    root = Path(project_path)
    ranked = [
        DetectionResult(preset=p, confidence=max(0.0, min(1.0, p.detect(root))))
        for p in PRESETS
    ]
    ranked.sort(key=lambda r: r.confidence, reverse=True)
    return ranked


#: Two real (non-``custom``) presets scoring within this of each other is a tie
#: we won't break automatically — the add-project flow shows both.
AMBIGUITY_MARGIN = 0.2


def is_ambiguous(ranked: list[DetectionResult]) -> bool:
    """True when the top two *recognized* presets are too close to auto-pick.

    ``custom`` (the always-on floor) is excluded so a lone real match isn't
    reported as ambiguous just because ``custom`` is always in the list."""
    real = [r for r in ranked if r.preset.id != "custom" and r.confidence > 0]
    if len(real) < 2:
        return False
    return (real[0].confidence - real[1].confidence) < AMBIGUITY_MARGIN


def detect_stack_response(project_path: str | Path):
    """Assemble the add-project detection payload for the API: every preset ranked
    (best first, ``custom`` always present), whether the run is ambiguous, and the
    single ``proposal`` to auto-fill — ``None`` when ambiguous, so the caller asks
    instead of auto-picking. Each candidate carries its ``settings.toml`` fragment
    so the UI can show the generated config before it's written.

    Returns a ``models.StackDetection``. Imported lazily to keep ``presets`` free
    of a model dependency for the pure-detection callers (and to sidestep import
    ordering)."""
    from .models import StackCandidate, StackDetection, StackPreset

    def _candidate(result: DetectionResult) -> StackCandidate:
        p = result.preset
        return StackCandidate(
            preset=StackPreset(
                id=p.id,
                label=p.label,
                blurb=p.blurb,
                setup=p.setup,
                run=p.run,
                gate=dict(p.gate),
                toml=to_toml_fragment(p),
            ),
            confidence=result.confidence,
        )

    ranked = detect_stack(project_path)
    ambiguous = is_ambiguous(ranked)
    candidates = [_candidate(r) for r in ranked]
    # The proposal is the clear winner only: never auto-pick a tie, and never
    # propose `custom` (the always-on floor) as if it were a detected stack.
    proposal = (
        candidates[0]
        if not ambiguous and ranked[0].preset.id != "custom" and ranked[0].confidence > 0
        else None
    )
    return StackDetection(ambiguous=ambiguous, proposal=proposal, candidates=candidates)


# --- tech-stack logos (sidebar identity, separate from gate presets) -------
# A repo is often polyglot (Vue front + Laravel back), so this returns a LIST of
# framework/language ids, not a single winner like `detect_stack`. It has
# nothing to do with the gate/run config — it only drives the little brand
# logos on each project row. The ids are a contract with the frontend
# (StackIcon.tsx LOGOS map); keep the two in sync when adding one. Detection
# reads only top-level manifests and never raises: a logo is a nicety, not worth
# failing add-project over.

#: Display + priority order: identifying frameworks lead, base runtimes/languages
#: trail (so "vuejs, laravel" reads front-then-back, and a bare Node repo still
#: shows `nodejs`). Also the allow-list — only ids present here are ever emitted.
_LOGO_ORDER = [
    "shopify", "nextjs", "nuxtjs", "react", "vuejs", "svelte", "angular",
    "astro", "laravel", "rails", "django", "flask", "fastapi", "nestjs",
    "express", "go", "rust", "php", "ruby", "python", "nodejs",
]

#: Bump when detection logic changes so `main.list_projects` re-scans projects
#: it already scanned under an older version (the stored marker is compared to
#: this). v1 was root-only; v2 also scans immediate subdirs (monorepos).
STACK_SCAN_VERSION = 2

#: JS framework ids. `nodejs` is only a fallback runtime badge, so it's dropped
#: when any of these is present (React already implies Node — no need for both).
_JS_FRAMEWORKS = {
    "nextjs", "nuxtjs", "angular", "astro", "svelte", "vuejs", "react",
    "nestjs", "express",
}

#: Immediate child dirs we never descend into when scanning a monorepo — vendor
#: trees and build output carry manifests that describe *dependencies*, not the
#: project's own stack, and worktrees would double-count the repo itself.
_SKIP_DIRS = {
    "node_modules", "vendor", "dist", "build", "out", "target", "__pycache__",
    ".venv", "venv", "worktrees", ".haro",
}


def _pkg_deps(root: Path) -> dict:
    """Merged dependencies + devDependencies from ``package.json`` ({} if none)."""
    try:
        data = json.loads(_read_text(root / "package.json") or "{}")
    except (ValueError, TypeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {**(data.get("dependencies") or {}), **(data.get("devDependencies") or {})}


def _collect_dir_logos(root: Path, found: set[str]) -> None:
    """Sniff one directory's manifests and add any recognized logo ids to
    ``found``. Called for the repo root and each immediate subdir, so a monorepo
    (``frontend/`` + ``backend/``) surfaces both stacks."""
    deps = _pkg_deps(root)
    if deps:
        local: set[str] = set()
        if "next" in deps:
            local.add("nextjs")
        if "nuxt" in deps:
            local.add("nuxtjs")
        if "@angular/core" in deps:
            local.add("angular")
        if "astro" in deps:
            local.add("astro")
        if "svelte" in deps or "@sveltejs/kit" in deps:
            local.add("svelte")
        if "vue" in deps:
            local.add("vuejs")
        if "react" in deps or "react-dom" in deps:
            local.add("react")
        if "@nestjs/core" in deps:
            local.add("nestjs")
        if "express" in deps:
            local.add("express")
        if any(k.startswith("@shopify/") for k in deps):
            local.add("shopify")
        # A package.json we couldn't pin to any framework: badge the runtime.
        found |= local or {"nodejs"}

    # Shopify theme layout doesn't need a package.json (reuse the gate detector).
    if _detect_shopify_theme(root) > 0 or (root / "shopify.app.toml").exists():
        found.add("shopify")

    composer = _read_text(root / "composer.json")
    if composer:
        found.add("laravel" if "laravel/framework" in composer else "php")

    py_sig = _read_text(root / "requirements.txt") + _read_text(root / "pyproject.toml")
    if py_sig or (root / "pyproject.toml").exists():
        low = py_sig.lower()
        py_frameworks = [f for f in ("django", "flask", "fastapi") if f in low]
        found.update(py_frameworks or ["python"])

    gemfile = _read_text(root / "Gemfile")
    if gemfile:
        found.add("rails" if "rails" in gemfile else "ruby")

    if (root / "go.mod").exists():
        found.add("go")
    if (root / "Cargo.toml").exists():
        found.add("rust")


def detect_stack_logos(project_path: str | Path) -> list[str]:
    """Best-effort tech-stack logo ids for a repo, for the sidebar project row.

    Scans the repo root **and** its immediate subdirectories (skipping vendor /
    build / worktree dirs) so a monorepo whose manifests live under
    ``frontend/``/``backend/`` still lights up. An unrecognized or unreadable
    repo returns ``[]``. The result is ordered by ``_LOGO_ORDER`` and capped so
    the row stays legible."""
    root = Path(project_path)
    found: set[str] = set()
    _collect_dir_logos(root, found)
    try:
        subdirs = [
            p for p in root.iterdir()
            if p.is_dir() and not p.name.startswith(".") and p.name not in _SKIP_DIRS
        ]
    except OSError:
        subdirs = []
    for sub in subdirs:
        _collect_dir_logos(sub, found)

    # `nodejs` is just the "some Node project, no framework" fallback; if the repo
    # has a real JS framework anywhere, that already says "Node" — drop the noise.
    if found & _JS_FRAMEWORKS:
        found.discard("nodejs")

    return [logo for logo in _LOGO_ORDER if logo in found][:4]


def _toml_str(s: str) -> str:
    """Serialize a Python string as a TOML string value (basic or multi-line).

    Mirrors ``config._toml_str`` so preset output matches the in-app editor's."""
    if "\n" in s:
        body = s.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
        return f'"""\n{body}\n"""'
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def to_toml_fragment(preset: Preset) -> str:
    """Render a preset as the ``[scripts]`` + ``[gate]`` block for
    ``settings.toml``. Empty tables are omitted, so ``custom`` yields just a
    header comment (nothing to write, but the dev sees the choice landed)."""
    lines: list[str] = [f"# haro preset: {preset.label} ({preset.id})"]

    if preset.setup or preset.run or preset.login_shell:
        lines.append("")
        lines.append("[scripts]")
        if preset.setup:
            lines.append(f"setup = {_toml_str(preset.setup)}")
        if preset.run:
            lines.append(f"run = {_toml_str(preset.run)}")
        if preset.login_shell:
            lines.append("login_shell = true")

    if preset.gate:
        lines.append("")
        lines.append("[gate]")
        # Stable, readable key order: runner leads, then its command/format.
        for key in ("runner", "command", "format"):
            if key in preset.gate:
                lines.append(f"{key} = {_toml_str(preset.gate[key])}")
        for key, val in preset.gate.items():
            if key not in ("runner", "command", "format"):
                lines.append(f"{key} = {_toml_str(val)}")

    return "\n".join(lines) + "\n"
