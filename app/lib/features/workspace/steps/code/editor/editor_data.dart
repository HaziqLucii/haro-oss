import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../data/workspace_detail.dart';
import '../../../../../data/workspace_detail_lazy.dart';
import '../../../../../state/display_state.dart';
import '../diff_model.dart';
import '../proof.dart';

/// The workspace diff parsed once per fetch: the changed files in order and by path. The
/// editor shows a changed file on its diff and marks its gutter from the same data.
class ParsedDiff {
  const ParsedDiff(this.files, this.byPath);

  static const empty = ParsedDiff([], {});

  final List<DiffFile> files;
  final Map<String, DiffFile> byPath;
}

final parsedDiffProvider = Provider.autoDispose.family<ParsedDiff, String>((
  ref,
  id,
) {
  final diff = ref.watch(workspaceDetailProvider(id).select((d) => d.diff));
  if (diff == null) return ParsedDiff.empty;
  final files = parseUnifiedDiff(diff.diff);
  return ParsedDiff(files, {for (final f in files) f.path: f});
});

/// Per-line proof, only while the workspace is green or merged: a "line ran" claim about a
/// red or running tree would describe an older run.
final editorProofProvider = Provider.autoDispose.family<ProofIndex?, String>((
  ref,
  id,
) {
  final state = ref.watch(
    workspaceFlowProvider(id).select((f) => f?.displayState),
  );
  if (state != DisplayState.green && state != DisplayState.merged) return null;
  return indexProof(ref.watch(workspaceVerifiedHunksProvider(id)).value);
});

/// The proof for the legend and the diff view, which show it whenever the gate left data.
final diffProofProvider = Provider.autoDispose.family<ProofIndex?, String>(
  (ref, id) => indexProof(ref.watch(workspaceVerifiedHunksProvider(id)).value),
);
