"""Verified Hunks — per-line proof in the diff (backlog/verified-hunks.md).

The gate proves *the suite passed*. This makes it prove something about **every line of
the diff**: "these 14 lines were executed by passing tests; these 40 were never touched."
The payoff is triage — the diff sorts untested hunks first and collapses gate-executed
ones, so reviewing a 1,200-line agent diff becomes reviewing the ~200-line residue the
suite never exercised.

**The honesty rule, and it is the whole feature.** An *executed* line is not an *asserted*
line. Nothing here says "verified", "proven" or "correct"; the vocabulary is ``executed``
and ``never executed``, full stop. Overclaiming burns reviewer trust permanently, and per
the kill conditions it does not get a second chance. The same naming law ``unchecked.py``
lives under, for the same reason.

Pure of IO like ``blame.py`` / ``tamper.py`` / ``unchecked.py``: hand it two diff strings
and a line-hit map, get a report. The endpoint in ``main.py`` supplies them.

## Why two diffs

The line-hit map was measured by a gate run against one particular working tree. The diff
the reviewer is looking at *now* may not be that tree — agent edits are uncommitted, so a
line can be inserted, shifting every line number below it, without HEAD ever moving. Reused
blindly, that would paint a green "executed" dot on a line the suite never saw, which is
precisely the overclaim this feature cannot afford.

So staleness is decided **per file**, by comparing the file's added lines at gate time with
its added lines now (``blame.changed_lines`` on both). A file that hasn't moved keeps its
proof; a file that has is reported as ``stale`` and carries **no line data at all** — the UI
says "the gate ran on an older version of this file" and draws nothing. Silence is the only
honest output for a line whose evidence no longer lines up with it.

## Three states a line can be in, and the third one matters

  * ``hits >= 1``  — executed under the passing suite.
  * ``hits == 0``  — coverable and never executed. The residue worth reviewing.
  * ``hits is None`` — **not coverable**: absent from istanbul's ``statementMap`` (a blank
    line, a comment, a closing brace, a type-only declaration). Counted separately and
    **never** as "untested", because "add a test for your closing brace" is the kind of
    noise that gets a whole signal switched off.

A file absent from the coverage map is its own case (``in_map=False``): nothing imports it,
so nothing in it ran — true at file level, but with no ``statementMap`` we cannot say which
of its lines were even coverable. It therefore reports a file-level count and an EMPTY line
map, rather than inventing a per-line claim. Same tiering as ``unchecked.py``'s
``no_test_file`` vs ``untested_lines``, on purpose: one signal, two vocabularies would be
one too many.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .blame import changed_lines
from .unchecked import is_source_file, runner_scope, _family  # noqa: PLC2701 — same package


@dataclass
class FileProof:
    """What the gate run can and cannot say about one file's added lines."""

    path: str
    #: The coverage map mentions this path at all, i.e. some test imports it.
    in_map: bool = True
    #: The file's added lines changed since the gate ran ⇒ no line data, no claims.
    stale: bool = False
    added: int = 0
    executed: int = 0
    unexecuted: int = 0
    noncoverable: int = 0
    #: ``{new_line_no: hits}``, ``None`` for a non-coverable line. Empty when ``stale`` or
    #: when the file is absent from the map (nothing to attribute per line).
    lines: dict[int, int | None] = field(default_factory=dict)


@dataclass
class VerifiedHunksReport:
    files: list[FileProof] = field(default_factory=list)
    #: True when ANY file's added lines moved since the gate ran. The UI's "gate ran on an
    #: older tree" state — surfaced at the top so the whole view is labelled, not just the
    #: files that moved.
    stale: bool = False
    #: Compact glance line for the diff toolbar. None when there is nothing to say.
    note: str | None = None


def _in_scope(path: str, families: set[str], prefix: str) -> bool:
    """Can this runner speak about this file at all?

    Two guards, both learned the hard way by ``unchecked.py`` (see ``runner_scope``): a
    vitest coverage map holds only JS-family files, so a changed ``.py`` is not "untested",
    it is *unmeasured*; and in a monorepo the gate runs in one subtree (``[gate] dir``), so
    a sibling package's ``.ts`` shares the extension while being genuinely out of reach.
    Getting either wrong turns proof into noise across a language boundary.
    """
    if not is_source_file(path):
        return False
    if _family(path) not in families:
        return False
    if prefix and not path.replace("\\", "/").startswith(prefix):
        return False
    return True


def annotate(
    gate_diff: str,
    current_diff: str,
    line_hits: dict[str, dict[int, int]] | None,
    scope: str = "",
) -> VerifiedHunksReport:
    """Intersect the gate run's line hits with the diff's added lines.

    ``gate_diff`` is the diff the gate measured, ``current_diff`` the one being rendered.
    ``line_hits`` is ``VitestAdapter.coverage_lines`` output, or **None** when no coverage
    provider is installed — which yields an EMPTY report, never "everything is untested".
    Never raises: an unparseable diff yields an empty report, because a broken proof surface
    has to go quiet rather than start making claims.
    """
    if not line_hits:
        return VerifiedHunksReport()
    families = runner_scope(line_hits)
    if not families:
        return VerifiedHunksReport()  # nothing instrumented ⇒ nothing to say
    prefix = scope.strip("/") + "/" if scope.strip("/") else ""

    now = changed_lines(current_diff or "")
    then = changed_lines(gate_diff or "")

    files: list[FileProof] = []
    for path, added in sorted(now.items()):
        if not added or not _in_scope(path, families, prefix):
            continue
        # The file's added lines must be byte-identical to the ones the gate measured.
        # Comparing the whole {line: text} map (not just a count) is what makes an
        # insertion above the hunk — which silently renumbers everything below it —
        # register as a change instead of sliding the proof onto the wrong lines.
        if then.get(path) != added:
            files.append(FileProof(path=path, stale=True, added=len(added)))
            continue
        hits = line_hits.get(path)
        if hits is None:
            # Nothing imports it, so nothing in it ran. True at file level; unknowable per
            # line without a statementMap, hence the empty ``lines``.
            files.append(
                FileProof(path=path, in_map=False, added=len(added), unexecuted=len(added))
            )
            continue
        lines: dict[int, int | None] = {}
        executed = cold = noncoverable = 0
        for ln in sorted(added):
            h = hits.get(ln)
            lines[ln] = h
            if h is None:
                noncoverable += 1
            elif h >= 1:
                executed += 1
            else:
                cold += 1
        files.append(
            FileProof(
                path=path, added=len(added), executed=executed, unexecuted=cold,
                noncoverable=noncoverable, lines=lines,
            )
        )
    report = VerifiedHunksReport(files=files, stale=any(f.stale for f in files))
    report.note = summarize(report)
    return report


def summarize(report: VerifiedHunksReport) -> str | None:
    """The diff toolbar's one-liner ("172 of 210 added lines executed · 38 never executed").

    Leads with the *executed* count because that is the number that shrinks the review, and
    names the residue second because that is the number worth acting on. Neither is called
    verified.
    """
    live = [f for f in report.files if not f.stale]
    added = sum(f.added for f in live)
    parts: list[str] = []
    if added:
        executed = sum(f.executed for f in live)
        cold = sum(f.unexecuted for f in live)
        parts.append(f"{executed} of {added} added lines executed")
        if cold:
            parts.append(f"{cold} never executed")
    # Reported even when it is the ONLY thing to say. "Every file moved since the gate ran"
    # is the state where a silent surface reads as "nothing to flag", which is the worst
    # possible reading of "we have no evidence for any of this".
    n_stale = sum(1 for f in report.files if f.stale)
    if n_stale:
        parts.append(f"{n_stale} file{'s' if n_stale > 1 else ''} changed since the gate ran")
    return " · ".join(parts) or None
