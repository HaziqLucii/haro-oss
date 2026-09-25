"""Code to check — the diff-level signal the gate never had (backlog/code-to-check.md).

Every condition on the Autonomy Ladder is **suite-level**: did the merged tree pass, did
total coverage drop, was the whole suite run, was the run deterministic, was the suite
weakened, is the diff lint-clean. **None of them looks at the change itself.** So a green
gate says "the tests passed"; it never says "the tests covered what the agent changed". An
agent can add 400 lines, the existing suite still passes, the coverage *delta* can even
rise if the new file ships a couple of tests, and nothing in the conjunction notices that
300 of those lines were executed by nothing at all. Since ``rungs.py`` shipped
``auto_pr``, that stopped being a review problem and became a shipping one.

``tamper.py`` defends the suite from getting *weaker*. This defends against new code
arriving *unobserved*. Together they answer "should I trust this green?".

**Naming law, and it is load-bearing.** The UI calls this "code to check"; the policy key
is ``no_unchecked``; nothing here says *proven*, *verified* or *vouched*. A line with a hit
count was **executed**, which is not the same as asserted about. A positive word would be a
comforting lie, and would become precisely the metric an agent games — the failure mode the
tamper alarm exists to prevent. Row labels stay literal ("no test ran"); the imperative
lives in the pane title.

Pure of IO, exactly like ``tamper.py`` and ``blame.py``: hand it a diff string, a line-hit
map and the tamper findings, get a report. Reuses ``tamper.parse_file_diffs`` /
``tamper.is_test_file`` rather than re-parsing the diff a third time.

Two coverage tiers, because they mean different things:
  * ``no_test_file``    — the changed file is ABSENT from the coverage map, i.e. no test
                          even imports it. The stronger signal. (On haro itself this is 44
                          of 67 source files, including App.tsx and CodePanel.tsx.)
  * ``untested_lines``  — the file IS imported, but N of its added lines never executed.

Plus deliberately boring risk rules. #213 taught us what a crying-wolf alarm costs, so
there are no heuristics about intent here: a dependency manifest changed, a secret-ish path
was touched, a file was deleted, a migration was added. Facts, not guesses.

The pane is also the home for the alarm's one *advisory* signal, ``tamper.rewrites`` — a base
test retitled **and** re-asserted in place (``assertion_rewritten``). It lands here rather
than on the ``green*`` chip for two reasons: it is not evidence the suite got weaker (it is
equally what a deliberate contract change looks like, so it must never touch a verdict), and
the chip only renders when there ARE tamper findings, which in this exact case there are
none — so the chip would hide it in the one situation it exists for. A row in an
advisory-by-construction pane is the honest severity. See ``tamper.rewritten_tests``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .tamper import FileDiff, is_test_file, parse_file_diffs

#: Dependency manifests + lockfiles. A change here means the dependency graph moved, which
#: no test in the suite is able to vouch for.
_DEP_MANIFESTS = {
    "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock",
    "pnpm-lock.yaml", "bun.lockb", "requirements.txt", "pyproject.toml", "poetry.lock",
    "uv.lock", "Pipfile", "Pipfile.lock", "Cargo.toml", "Cargo.lock", "go.mod", "go.sum",
    "Gemfile", "Gemfile.lock", "composer.json", "composer.lock",
}

#: Secret-ish paths. Matched on the basename or a path segment, never on content — we do
#: not scan for secrets here (that is the Double Gate's job, backlog/double-gate.md); we
#: only note that a file whose whole purpose is secrets was touched.
_SECRET_RE = re.compile(
    r"(?:^|/)(?:\.env(?:\.[\w.-]+)?|secrets?\.(?:ya?ml|json|toml)|credentials)$"
    r"|\.(?:pem|key|p12|pfx|jks)$"
    r"|(?:^|/)id_(?:rsa|ed25519|ecdsa)$",
    re.IGNORECASE,
)

#: Schema migrations. Irreversible in production and almost never covered by unit tests.
_MIGRATION_RE = re.compile(r"(?:^|/)(?:migrations?|alembic/versions)/", re.IGNORECASE)

#: The cry-wolf floor, and the reasoning matters more than the number: **this pane reports
#: on the CHANGE, not on the repo's standing test debt.** A one-line edit to an untested file
#: is a fact about the file, not about what you just did, and "write a test for
#: AnalysisPanel.tsx because you fixed a comma" is not work anyone will do. Measured against
#: a real commit (#205): without a floor, an em-dash sweep filed 22 rows, 15 of them for
#: one- or two-line edits, which is exactly the wallpaper the kill conditions warn about.
#: Pre-existing debt belongs in a different report; this one has to be clearable.
_MIN_ADDED_FOR_UNTESTED_FILE = 3

#: Declaration-only files: erased at runtime, so they can never appear in a coverage map and
#: flagging them is a guaranteed false positive.
_TYPE_ONLY_RE = re.compile(r"\.d\.[cm]?ts$", re.IGNORECASE)

#: Row ordering: the tiers a human should read first come first. Sorting by this rather
#: than by discovery order keeps the pane stable as a diff grows.
_KIND_ORDER = (
    "suite_weakened", "assertion_rewritten", "secret", "no_test_file", "untested_lines",
    "new_dep", "deleted", "migration",
)


def row_key(kind: str, file: str, detail: str = "", count: int = 0) -> str:
    """Stable identity for a row across re-gates, so ticking one off survives the next gate
    while a **changed** claim comes back unticked.

    The discriminator is the count where the kind has one and the detail where it does not,
    and that IS the semantics of the tick. "I looked at these 23 lines nothing ran" stops
    being true the moment there are 24, so the key has to move and the tick has to die.
    Conversely two removed tests in one file are two separate claims, which is why a
    countless kind falls back to its detail rather than collapsing onto the path.
    """
    return f"{kind}|{file}|{count if count else detail}"


@dataclass
class UncheckedItem:
    """One claim that nothing has checked. ``kind`` selects the row label, ``file`` locates
    it, ``detail`` is the human one-liner, and ``count`` carries the number the label needs
    (untested lines) or 0 when the kind is not countable."""

    kind: str
    file: str
    detail: str = ""
    count: int = 0

    @property
    def key(self) -> str:
        """See :func:`row_key`. A property rather than a stored field so it can never drift
        out of sync with the claim it identifies."""
        return row_key(self.kind, self.file, self.detail, self.count)


@dataclass
class UncheckedReport:
    items: list[UncheckedItem] = field(default_factory=list)
    #: Compact glance line for the status feed, mirroring ``tamper_note``. None when clean.
    note: str | None = None
    #: How many changed source files the coverage half was actually able to speak about,
    #: i.e. files this diff touched that the line-hit map contains. **Tri-state, and it is
    #: the difference between a clean pane and a lying one**: ``None`` = no per-line map at
    #: all (no provider installed, a crashed coverage run), ``0`` = a map existed but said
    #: nothing about anything in this diff (the everyday case for a Python change under a
    #: vitest gate), ``N`` = N files were genuinely executed and measured.
    #:
    #: Without this an empty ``items`` list renders as "every changed line ran" in all three
    #: cases, which on this repo's own history was a false claim on the majority of runs.
    #: Same None-vs-empty contract ``quality_findings`` carries, for the same reason.
    covered_files: int | None = None


def _basename(path: str) -> str:
    return path.replace("\\", "/").rsplit("/", 1)[-1]


def is_source_file(path: str | None) -> bool:
    """A file whose *behaviour* tests could cover, so its absence from coverage means
    something. Excludes test files (they ARE the checking), and excludes the non-code
    files a coverage map would never mention anyway — otherwise every CSS tweak and
    markdown edit would file a row and the pane would be wallpaper within a day."""
    if not path or is_test_file(path) or _TYPE_ONLY_RE.search(path):
        return False
    name = _basename(path)
    if name in _DEP_MANIFESTS:
        return False
    return path.replace("\\", "/").lower().endswith(
        (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".rs", ".go", ".rb", ".java", ".kt")
    )


def risk_items(file_diffs: list[FileDiff]) -> list[UncheckedItem]:
    """The coverage-free half: facts about the diff that no test could vouch for.

    Deterministic and dull on purpose. Every rule here answers "is this a thing tests
    structurally cannot check?" — not "does this look risky?", which is a judgement and
    belongs to the AI review (``review.py``), not to a signal that wants to reach zero.
    """
    items: list[UncheckedItem] = []
    for fd in file_diffs:
        path = fd.path
        if not path:
            continue
        # A rename is not a deletion, and its content moved rather than vanished.
        if fd.new_path is None and not fd.is_rename:
            items.append(UncheckedItem(kind="deleted", file=path, detail="file deleted"))
            continue
        if _SECRET_RE.search(path.replace("\\", "/")):
            items.append(UncheckedItem(kind="secret", file=path, detail="secret-bearing file touched"))
        if _basename(path) in _DEP_MANIFESTS:
            items.append(UncheckedItem(kind="new_dep", file=path, detail="dependency graph changed"))
        if _MIGRATION_RE.search(path.replace("\\", "/")):
            items.append(UncheckedItem(kind="migration", file=path, detail="schema migration"))
    return items


#: Extension → language family. Compared at FAMILY level, never per-extension: a vitest
#: coverage map full of ``.ts`` must still cover a changed ``.tsx``, since they are the same
#: runner. Grouping is what makes "did this runner see this language?" the actual question.
_FAMILY = {
    ".ts": "js", ".tsx": "js", ".mts": "js", ".cts": "js",
    ".js": "js", ".jsx": "js", ".mjs": "js", ".cjs": "js",
    ".py": "py", ".rs": "rs", ".go": "go", ".rb": "rb",
    ".java": "jvm", ".kt": "jvm",
}


def _ext(path: str) -> str:
    name = path.replace("\\", "/").rsplit("/", 1)[-1]
    return ("." + name.rsplit(".", 1)[-1]).lower() if "." in name else ""


def _family(path: str) -> str:
    return _FAMILY.get(_ext(path), "")


def runner_scope(line_hits: dict[str, dict[int, int]]) -> set[str]:
    """The language families this gate runner can actually instrument, inferred from the
    coverage map itself.

    Without this the signal cries wolf across language boundaries, and it is not
    hypothetical: haro's gate runs **vitest** in ``frontend/``, so its coverage map contains
    only JS-family files. A diff touching ``backend/haro/gate.py`` would then look "absent
    from the map" and file a "no test imports this file" row, when the truth is that a JS
    coverage report has nothing to say about Python either way. (Caught by running the engine
    against a real report and a real diff, not by a fixture.)

    Letting the map define its own universe keeps the engine runner-agnostic: point it at a
    pytest gate and the same logic scopes itself to Python with no per-runner branching.
    """
    return {f for f in (_family(p) for p in line_hits) if f}


def scoped_paths(
    changed: dict[str, dict[int, str]],
    line_hits: dict[str, dict[int, int]] | None,
    scope: str = "",
) -> list[str]:
    """The changed source files this runner's coverage map is even entitled to judge.

    Split out of :func:`coverage_items` so that "which files did coverage speak about?" has
    exactly one definition. Two callers need it and they must agree: the row builder, and
    :func:`covered_files`, which is what stops the pane claiming "every changed line ran"
    about files the map never contained.
    """
    if line_hits is None:
        return []
    families = runner_scope(line_hits)
    if not families:
        return []  # nothing instrumented ⇒ we cannot tell what is in scope; stay silent
    prefix = scope.strip("/") + "/" if scope.strip("/") else ""
    out: list[str] = []
    for path, added in sorted(changed.items()):
        if not is_source_file(path) or not added:
            continue
        if _family(path) not in families:
            continue  # a language this runner does not instrument
        if prefix and not path.replace("\\", "/").startswith(prefix):
            continue  # outside the gate's subtree in a monorepo
        out.append(path)
    return out


def covered_files(
    changed: dict[str, dict[int, str]],
    line_hits: dict[str, dict[int, int]] | None,
    scope: str = "",
) -> int | None:
    """How many changed files the suite actually executed something in — the number that
    decides whether an empty pane is *earned* or merely *uninformed*.

    ``None`` when there is no per-line map at all; ``0`` when a map exists but contains
    nothing from this diff (a Python change under a vitest gate, or a diff of files no test
    imports); otherwise the count of files that were genuinely measured. Only the last case
    entitles anyone to say "every changed line ran".
    """
    if line_hits is None:
        return None
    return sum(1 for p in scoped_paths(changed, line_hits, scope) if p in line_hits)


def coverage_items(
    changed: dict[str, dict[int, str]],
    line_hits: dict[str, dict[int, int]] | None,
    scope: str = "",
) -> list[UncheckedItem]:
    """The coverage half: which added lines nothing executed.

    ``changed`` is ``blame.changed_lines`` output (``{path: {new_line_no: text}}``, added
    lines only). ``line_hits`` is ``{path: {line_no: hits}}`` from the instrumented run, or
    **None** when no coverage provider is installed — in which case this returns nothing at
    all, so the feature degrades to risk rules instead of erroring or, worse, reporting
    everything as unchecked.

    ``scope`` is the project's ``[gate] dir`` (empty for a single-package repo). In a
    monorepo the runner only sees its own subtree, so a sibling package's ``.ts`` file
    shares the extension but is genuinely out of scope and must not be reported.
    """
    if line_hits is None:
        return []
    items: list[UncheckedItem] = []
    for path in scoped_paths(changed, line_hits, scope):
        added = changed[path]
        hits = line_hits.get(path)
        if hits is None:
            # Absent from the map entirely: no test imports this file. The stronger tier,
            # and the one a percentage would hide (an unimported file has no percentage).
            # Floored, because below it the row describes the file's history rather than
            # this change (see _MIN_ADDED_FOR_UNTESTED_FILE).
            if len(added) < _MIN_ADDED_FOR_UNTESTED_FILE:
                continue
            n = len(added)
            items.append(
                UncheckedItem(
                    kind="no_test_file", file=path, count=n,
                    detail=f"no test imports this file ({n} added line{'s' if n > 1 else ''})",
                )
            )
            continue
        # `hits.get(ln)` WITHOUT a default on purpose: a line absent from the map is
        # NON-COVERABLE (blank, comment, closing brace, type-only), not cold. Defaulting to
        # 0 counted every brace as "never ran" — which inflated this row and, worse, made it
        # disagree with Verified Hunks about the same file on the same screen (23 vs 13 on
        # the E2E's currency.js). `None == 0` is False, so absent lines now drop out.
        cold = [ln for ln in added if hits.get(ln) == 0]
        if cold:
            items.append(
                UncheckedItem(
                    kind="untested_lines", file=path, count=len(cold),
                    detail=f"{len(cold)} of {len(added)} added lines never ran",
                )
            )
    return items


def tamper_items(tamper_findings: list) -> list[UncheckedItem]:
    """Fold the tamper alarm's findings in rather than recomputing them, so the pane is the
    single answer to "what has nothing checked" instead of a fourth place to look. Accepts
    the dataclass or its pydantic twin (both carry ``kind``/``file``/``detail``/``test``)."""
    items: list[UncheckedItem] = []
    for f in tamper_findings or []:
        where = getattr(f, "test", None) or getattr(f, "file", "") or ""
        detail = getattr(f, "detail", "") or getattr(f, "kind", "")
        items.append(
            UncheckedItem(
                kind="suite_weakened",
                file=getattr(f, "file", "") or "",
                detail=f"{detail} ({where})" if where and where != getattr(f, "file", "") else detail,
            )
        )
    return items


def rewritten_items(rewrites: list) -> list[UncheckedItem]:
    """Fold ``tamper.rewrites`` in as ``assertion_rewritten`` rows.

    Separate from :func:`tamper_items` on purpose, because the two are different claims: a
    ``suite_weakened`` row says the suite got thinner, this one says a test now asserts
    something else under a new name. The row exists to get a human's eyes on whether the
    behaviour the base asserted is still true and still asserted *somewhere* — which is a
    question only a human can answer, and exactly why it never blocks."""
    items: list[UncheckedItem] = []
    for f in rewrites or []:
        test = getattr(f, "test", None) or ""
        detail = getattr(f, "detail", "") or "retitled and re-asserted vs base"
        items.append(
            UncheckedItem(
                kind="assertion_rewritten",
                file=getattr(f, "file", "") or "",
                detail=f"{test} — {detail}" if test else detail,
            )
        )
    return items


def summarize(items: list[UncheckedItem]) -> str | None:
    """The compact glance line ("3 files no test imports · 83 lines never ran · 1 new dep").
    None when clean, so callers can treat falsy as "nothing to say"."""
    if not items:
        return None
    parts: list[str] = []
    n = sum(1 for i in items if i.kind == "no_test_file")
    if n:
        parts.append(f"{n} file{'s' if n > 1 else ''} no test imports")
    cold = sum(i.count for i in items if i.kind == "untested_lines")
    if cold:
        parts.append(f"{cold} line{'s' if cold > 1 else ''} never ran")
    for kind, label in (("new_dep", "dep change"), ("secret", "secret touched"),
                        ("deleted", "deleted"), ("migration", "migration"),
                        ("suite_weakened", "suite weakened"),
                        ("assertion_rewritten", "assertion rewritten")):
        c = sum(1 for i in items if i.kind == kind)
        if c:
            parts.append(f"{c} {label}")
    return " · ".join(parts)


def analyze(
    diff_text: str,
    line_hits: dict[str, dict[int, int]] | None = None,
    tamper_findings: list | None = None,
    scope: str = "",
    tamper_rewrites: list | None = None,
) -> UncheckedReport:
    """Build the report for one diff. Never raises on malformed input: an empty or
    unparseable diff yields an empty report, because a broken signal must be silent rather
    than alarming (the same rule ``gate.run_gate`` applies around the whole block)."""
    from .blame import changed_lines  # local: blame imports nothing from us, keep it lazy

    file_diffs = parse_file_diffs(diff_text or "")
    changed = changed_lines(diff_text or "")
    items = tamper_items(tamper_findings or [])
    items += rewritten_items(tamper_rewrites or [])
    items += risk_items(file_diffs)
    items += coverage_items(changed, line_hits, scope=scope)
    # Tier first, then BIGGEST first inside a tier, then path for stability. Sorting by size
    # is what keeps a 142-line untested addition above a 3-line one, so the pane's first
    # rows are the ones worth acting on rather than whatever the diff happened to list first.
    items.sort(
        key=lambda i: (
            _KIND_ORDER.index(i.kind) if i.kind in _KIND_ORDER else 99,
            -i.count,
            i.file,
        )
    )
    return UncheckedReport(
        items=items,
        note=summarize(items),
        covered_files=covered_files(changed, line_hits, scope=scope),
    )
