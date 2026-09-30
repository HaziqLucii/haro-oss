/// Gutter and guide data derived from text and the diff, kept apart from the widgets so it is
/// testable: which lines changed since the base, which added lines the green suite ran, and
/// where indent guides go.
library;

import '../../../../../api/models/models.dart';
import '../diff_model.dart';
import '../proof.dart';

enum ChangeMark {
  /// Only added lines in this change block.
  added,

  /// Added lines that replace deleted ones.
  modified,
}

/// New-file line number to the kind of change that touched it. In a block that deletes `d`
/// lines and adds `a`, the first `min(d, a)` added lines replace deleted ones (modified) and the
/// rest are new. A pure deletion leaves no line to mark, so it has no entry.
Map<int, ChangeMark> changeMarks(DiffFile? file) {
  if (file == null || file.isBinary || file.tag == DiffFileTag.deleted) {
    return const {};
  }
  final out = <int, ChangeMark>{};
  for (final h in file.hunks) {
    var added = <int>[];
    var deleted = 0;
    void flush() {
      for (var i = 0; i < added.length; i++) {
        out[added[i]] = i < deleted ? ChangeMark.modified : ChangeMark.added;
      }
      added = [];
      deleted = 0;
    }

    for (final l in h.lines) {
      switch (l.kind) {
        case DiffLineKind.add:
          if (l.newNo != null) added.add(l.newNo!);
        case DiffLineKind.del:
          deleted++;
        case DiffLineKind.context:
          flush();
      }
    }
    flush();
  }
  return out;
}

/// Added lines (new-file numbers) that ran under the last green gate. Only lines the diff says
/// were added and the coverage map says were hit: any other line, and a stale file, gets no
/// dot, because a dot is a claim.
Set<int> ranLines(DiffFile? file, VerifiedFile? proof) {
  if (file == null || proof == null || proof.stale) return const {};
  final out = <int>{};
  for (final h in file.hunks) {
    for (final n in h.addedLineNos) {
      if (lineDot(proof, n) == LineDot.hit) out.add(n);
    }
  }
  return out;
}

/// The indent step of a file: the smallest leading-space run among its indented lines, capped
/// at 8 and defaulting to 2. Tab-indented files count a tab as one step.
int indentUnit(Iterable<String> lines, {int sample = 400}) {
  var best = 0;
  var seen = 0;
  for (final line in lines) {
    if (seen++ >= sample) break;
    if (line.isEmpty || line.trim().isEmpty) continue;
    var spaces = 0;
    while (spaces < line.length && line.codeUnitAt(spaces) == 0x20) {
      spaces++;
    }
    if (spaces == 0) continue;
    if (spaces == 1) continue;
    if (best == 0 || spaces < best) best = spaces;
    if (best == 2) break;
  }
  if (best == 0) return 2;
  return best > 8 ? 8 : best;
}

/// Columns (in characters from the left edge of the text) where a guide line is drawn for a
/// line indented [indent] columns: one per indent step the line is nested inside, so the
/// first level (column 0) is left out.
List<int> guideColumns(int indent, int unit) {
  if (unit <= 0 || indent <= unit) return const [];
  return [for (var c = unit; c < indent; c += unit) c];
}

/// Leading whitespace of [line] in columns, a tab counting as [tab].
int leadingColumns(String line, {int tab = 2}) {
  var n = 0;
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 0x20) {
      n++;
    } else if (c == 0x09) {
      n += tab;
    } else {
      break;
    }
  }
  return n;
}
