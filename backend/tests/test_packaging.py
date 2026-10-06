"""The round-10 regression: a wheel built without a `[tool.setuptools.package-data]`
entry for every non-.py runtime asset silently ships a broken `haro gate` — the
vitest reporter and skill/quality/nvim assets go missing, and the installed CLI
misreports the resulting setup failure as a plain RED gate rather than a clear
"couldn't run" error (0/0 tests read as a failed suite, not "the gate never ran").

This doesn't build a wheel (slow, needs the `build` package as an extra
dependency) — it proves the cheaper, sufficient invariant: every non-.py file
that actually exists under `haro/` on disk is covered by at least one glob in
pyproject.toml, so a new asset file can't be silently forgotten and the config
itself can't silently rot out of sync with the source tree.

**Round 11 of review caught a false negative here**: the first version of this
test matched patterns with `fnmatch.fnmatch`, whose `*` crosses `/` — so a
pattern like `assets/skills/*/*.md` would (wrongly, per this test) also "cover"
`assets/skills/x/reference/y.md`, two segments deep. Fixed (round 11) by
switching to `Path.glob()`.

**Round 12 of review found `Path.glob()` was ALSO not quite it**: setuptools'
actual file discovery (`setuptools.command.build_py.find_data_files`) calls the
stdlib `glob.glob(pattern, recursive=True)` directly — which skips dotfiles by
default — while `pathlib.Path.glob()` does NOT skip them. So a pattern like
`assets/*.sh` would (wrongly, per `Path.glob`) "cover" a hypothetical
`assets/.hidden.sh`, which a real wheel build would still omit. No file under
`haro/` is dot-prefixed today, so this never produced a wrong shipped wheel —
only a guard that could have missed one. Fixed by calling `glob.glob` directly.

**Round 13 of review confirmed that fix correct, then asked the obvious
question**: after three rounds of "the fix for the fix needed its own fix", all
in the same narrow spot (which matcher exactly reproduces setuptools' own file
discovery), is hand-deriving that semantics the right design at all? Measured:
building a REAL wheel from a throwaway copy of `haro/` via
`setuptools.build_meta.build_wheel` and inspecting its actual file list takes
~0.2s, no network, no build isolation, no extra dependency beyond `setuptools`
itself (already the project's declared build backend). That's immune BY
CONSTRUCTION to this entire bug class — it asks the real builder instead of
predicting it — for less cost than several other tests in this suite already
pay. `test_the_real_wheel_contains_every_runtime_asset` below is that test, and
is now the authoritative check; the `_matched_files` pattern-matcher and its
tests above stay as fast, specific regression pins for the two historical bugs
(they still have to stay CORRECT, just not carry sole responsibility anymore).
"""

from __future__ import annotations

import glob as glob_module
import shutil
import tempfile
import tomllib
import zipfile
from pathlib import Path

from setuptools import build_meta

BACKEND = Path(__file__).resolve().parent.parent

# Deliberately excluded from the wheel (see pyproject.toml's comment right above
# [tool.setuptools.package-data]): generated at desktop-build time, stamps the
# BUILDER's own local filesystem path, never read on the `haro gate` CLI path.
# Not every non-.py file under haro/ that exists on some machine belongs in the
# wheel — this is the one deliberate exception, named here rather than given a
# package-data pattern that would just re-include it.
_DELIBERATELY_UNPACKAGED = {"assets/build_info.env"}


def _matched_files(haro_dir: Path, patterns: list[str]) -> set[Path]:
    # `glob.glob(..., recursive=True)` — not `Path.glob()` — because that's the
    # literal call `setuptools.command.build_py.find_data_files` makes. The two
    # disagree on dotfiles (`glob.glob` skips them by default, `Path.glob` doesn't),
    # so this has to be the real function, not a pathlib equivalent of it.
    matched: set[Path] = set()
    for pattern in patterns:
        matched.update(Path(p) for p in glob_module.glob(str(haro_dir / pattern), recursive=True))
    return matched


def _build_real_wheel_namelist(source_backend: Path) -> set[str]:
    """Copies the real `haro/` package + `pyproject.toml` into a throwaway
    directory, builds an ACTUAL wheel via the same backend the project declares
    (`setuptools.build_meta` — no `build` frontend package needed, this calls the
    backend hook directly), and returns its file list. Ground truth, not a
    prediction of one."""
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / "backend"
        shutil.copytree(source_backend / "haro", work / "haro")
        shutil.copy(source_backend / "pyproject.toml", work / "pyproject.toml")
        dist_dir = Path(tmp) / "dist"
        dist_dir.mkdir()

        import os
        cwd = os.getcwd()
        os.chdir(work)
        try:
            wheel_name = build_meta.build_wheel(str(dist_dir))
        finally:
            os.chdir(cwd)

        with zipfile.ZipFile(dist_dir / wheel_name) as zf:
            return set(zf.namelist())


def test_the_real_wheel_contains_every_runtime_asset():
    # The authoritative check (see the module docstring for why this replaced a
    # hand-rolled glob predictor after round 13): build an actual wheel and
    # compare its actual file list against ground truth, rather than predicting
    # what setuptools will do.
    haro_dir = BACKEND / "haro"
    ground_truth = {
        path.relative_to(haro_dir).as_posix()
        for path in haro_dir.rglob("*")
        if path.is_file() and path.suffix not in (".py", ".pyc")
        and path.relative_to(haro_dir).as_posix() not in _DELIBERATELY_UNPACKAGED
    }

    namelist = _build_real_wheel_namelist(BACKEND)
    shipped = {n[len("haro/"):] for n in namelist if n.startswith("haro/")}

    missing = ground_truth - shipped
    assert not missing, (
        f"a REAL built wheel is missing these files: {missing} — "
        "not a prediction, this is what setuptools actually produced"
    )


def test_a_single_star_does_not_cross_a_directory_boundary(tmp_path):
    # The exact false negative round 11 found, pinned directly: a file two path
    # segments below a `*/*.md`-shaped pattern must NOT read as covered. `fnmatch`
    # would wrongly accept it (its `*` crosses `/`); `Path.glob` correctly doesn't.
    haro_dir = tmp_path / "haro"
    deep = haro_dir / "assets" / "skills" / "x" / "reference" / "y.md"
    deep.parent.mkdir(parents=True)
    deep.write_text("x")

    matched = _matched_files(haro_dir, ["assets/skills/*/*.md"])
    assert deep not in matched

    # The fix for it, pinned the same way: a pattern that names the extra segment
    # does cover it.
    matched = _matched_files(haro_dir, ["assets/skills/*/*/*.md"])
    assert deep in matched


def test_a_pattern_does_not_silently_cover_a_dotfile(tmp_path):
    # The exact false negative round 12 found, pinned directly: `glob.glob` (what
    # setuptools actually calls) skips dotfiles by default, but `Path.glob` does
    # not — so a hidden file matching a pattern's shape would (wrongly, under
    # `Path.glob`) read as covered while a real wheel build still omits it.
    haro_dir = tmp_path / "haro"
    hidden = haro_dir / "assets" / ".hidden.sh"
    hidden.parent.mkdir(parents=True)
    hidden.write_text("x")

    matched = _matched_files(haro_dir, ["assets/*.sh"])
    assert hidden not in matched


def test_the_vitest_reporter_specifically_is_covered():
    # The concrete failure round 10 reproduced: without this, `VitestAdapter`'s
    # `--reporter=<path>` resolves to nothing in an installed wheel, vitest fails
    # to load it, and the adapter reports 0 tests — which then reads as a plain
    # red gate rather than "the gate's own setup is broken".
    pyproject = tomllib.loads((BACKEND / "pyproject.toml").read_text())
    patterns = pyproject["tool"]["setuptools"]["package-data"]["haro"]
    haro_dir = BACKEND / "haro"
    reporter = haro_dir / "adapters" / "test_runner" / "vitest_reporter.mjs"
    assert reporter in _matched_files(haro_dir, patterns)
