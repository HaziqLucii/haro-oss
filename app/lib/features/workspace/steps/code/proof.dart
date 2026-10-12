/// Per-line proof for the diff: which added lines ran under the last green gate. Ported from
/// the React `verifiedHunks.ts`. An executed line is not an asserted line, so no label here
/// says "verified" or "correct".
library;

import '../../../../api/models/models.dart';
import 'diff_model.dart';

typedef ProofIndex = Map<String, VerifiedFile>;

/// Null when there is no usable proof at all (unsupported runner, no files), which is also
/// when the legend and the marker column stay hidden.
ProofIndex? indexProof(VerifiedHunksResponse? v) {
  if (v == null || !v.supported || v.files.isEmpty) return null;
  return {for (final f in v.files) f.path: f};
}

enum LineDot { none, hit, cold }

/// Gutter marker for an ADDED line. A line absent from the map, or present but not
/// coverable (blank, comment, closing brace), gets nothing: a marker there is a claim.
LineDot lineDot(VerifiedFile? file, int? lineNo) {
  if (file == null || file.stale || lineNo == null) return LineDot.none;
  if (!file.lines.containsKey(lineNo)) return LineDot.none;
  final hits = file.lines[lineNo];
  if (hits == null) return LineDot.none;
  return hits >= 1 ? LineDot.hit : LineDot.cold;
}

enum HunkKind { executed, partial, unmapped, nonexec, stale }

class HunkProof {
  const HunkProof({
    required this.kind,
    required this.added,
    required this.executed,
    required this.unexecuted,
    required this.noncoverable,
  });

  final HunkKind kind;
  final int added;
  final int executed;
  final int unexecuted;
  final int noncoverable;
}

/// Tallied from the added lines the diff actually renders, so a badge can only ever be
/// wrong about the lines it sits above.
HunkProof? hunkProof(VerifiedFile? file, List<int> addedLineNos) {
  if (file == null || addedLineNos.isEmpty) return null;
  final n = addedLineNos.length;
  if (file.stale) {
    return HunkProof(
      kind: HunkKind.stale,
      added: n,
      executed: 0,
      unexecuted: 0,
      noncoverable: 0,
    );
  }
  if (!file.inMap) {
    return HunkProof(
      kind: HunkKind.unmapped,
      added: n,
      executed: 0,
      unexecuted: n,
      noncoverable: 0,
    );
  }
  var executed = 0;
  var unexecuted = 0;
  var noncoverable = 0;
  for (final no in addedLineNos) {
    final hits = file.lines[no];
    if (hits == null) {
      noncoverable++;
    } else if (hits >= 1) {
      executed++;
    } else {
      unexecuted++;
    }
  }
  final kind = unexecuted > 0
      ? HunkKind.partial
      : executed > 0
      ? HunkKind.executed
      : HunkKind.nonexec;
  return HunkProof(
    kind: kind,
    added: n,
    executed: executed,
    unexecuted: unexecuted,
    noncoverable: noncoverable,
  );
}

HunkProof? mergeProof(Iterable<HunkProof?> parts) {
  final live = [for (final p in parts) ?p];
  if (live.isEmpty) return null;
  final added = live.fold(0, (n, p) => n + p.added);
  if (live.any((p) => p.kind == HunkKind.stale)) {
    return HunkProof(
      kind: HunkKind.stale,
      added: added,
      executed: 0,
      unexecuted: 0,
      noncoverable: 0,
    );
  }
  final executed = live.fold(0, (n, p) => n + p.executed);
  final unexecuted = live.fold(0, (n, p) => n + p.unexecuted);
  final noncoverable = live.fold(0, (n, p) => n + p.noncoverable);
  final kind = live.every((p) => p.kind == HunkKind.unmapped)
      ? HunkKind.unmapped
      : unexecuted > 0
      ? HunkKind.partial
      : executed > 0
      ? HunkKind.executed
      : HunkKind.nonexec;
  return HunkProof(
    kind: kind,
    added: added,
    executed: executed,
    unexecuted: unexecuted,
    noncoverable: noncoverable,
  );
}

/// What the left list's proof square shows for a file.
enum ProofSquare {
  /// Every coverable added line ran in the green suite.
  ran,

  /// Some added lines never ran (or no test imports the file).
  partial,

  /// Not code, nothing coverable was added, or no data.
  none,
}

ProofSquare proofSquareFor(DiffFile file, ProofIndex? proof) {
  final vf = proof?[file.path];
  if (vf == null || file.hunks.isEmpty) return ProofSquare.none;
  final merged = mergeProof([
    for (final h in file.hunks) hunkProof(vf, h.addedLineNos),
  ]);
  return switch (merged?.kind) {
    HunkKind.executed => ProofSquare.ran,
    HunkKind.partial || HunkKind.unmapped => ProofSquare.partial,
    _ => ProofSquare.none,
  };
}

const executedTooltip =
    'executed is not asserted: these lines ran under passing tests, no assertion '
    'necessarily checked them';

/// The hunk badge as the reviewer reads it.
String? hunkBadgeLabel(HunkProof? p) {
  if (p == null) return null;
  return switch (p.kind) {
    HunkKind.stale => 'gate ran on an older version of this file',
    HunkKind.unmapped =>
      'no test imports this file · ${p.added} added line${p.added == 1 ? '' : 's'} never ran',
    HunkKind.nonexec => 'no executable lines added',
    HunkKind.partial => '${p.unexecuted} of ${p.added} added lines never ran',
    HunkKind.executed => 'ran in the green suite',
  };
}
