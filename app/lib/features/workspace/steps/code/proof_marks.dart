import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/workspace_detail.dart';
import '../../../../lsp/lsp_diagnostics.dart';
import '../../../../data/workspace_detail_lazy.dart';
import '../../../../theme/tokens.dart';
import '../../terminal/panel_model.dart';
import '../verify/verify_model.dart';

/// What the gate knows about one line of the saved text, shown on the editor gutter, plus the
/// language server's live diagnostics (`error`, `warning`, `info`). Advisory evidence only:
/// nothing here reads or changes the verdict, saving or the step bar.
enum ProofMarkKind { mutant, eyes, error, warning, info }

class ProofMark {
  const ProofMark({
    required this.kind,
    required this.label,
    this.detail = '',
    this.blocking = false,
  });

  final ProofMarkKind kind;

  /// Mono uppercase tag from the Problems tab (`MUTANT SURVIVED`, `NO TEST RAN`...).
  final String label;
  final String detail;
  final bool blocking;

  /// The hover text: `MUTANT SURVIVED · == to !=`.
  String get text => detail.isEmpty ? label : '$label · $detail';

  @override
  bool operator ==(Object other) =>
      other is ProofMark &&
      other.kind == kind &&
      other.label == label &&
      other.detail == detail &&
      other.blocking == blocking;

  @override
  int get hashCode => Object.hash(kind, label, detail, blocking);
}

/// path to line (1-based, the saved text) to the marks on that line.
typedef ProofMarksByPath = Map<String, Map<int, List<ProofMark>>>;

/// Groups the Problems tab's rows by file and line. Rows without a path or a line (a coverage
/// note) have nowhere to sit and are left out.
ProofMarksByPath proofMarksFromRows(ProblemsView view) {
  final out = <String, Map<int, List<ProofMark>>>{};
  void add(ProblemRow r, ProofMarkKind kind) {
    final path = r.path;
    final line = r.line;
    if (path == null || line == null || line < 1) return;
    ((out[path] ??= {})[line] ??= []).add(
      ProofMark(
        kind: kind,
        label: r.label,
        detail: r.detail,
        blocking: r.blocking,
      ),
    );
  }

  for (final r in view.mutants) {
    add(r, ProofMarkKind.mutant);
  }
  for (final r in view.eyes) {
    add(r, ProofMarkKind.eyes);
  }
  return out;
}

/// One mark per line: gate evidence (mutant, then eyes) wins over language-server diagnostics,
/// which show worst first. The hover label still lists everything on the line.
ProofMarkKind kindOfLine(List<ProofMark> marks) {
  for (final k in ProofMarkKind.values) {
    if (marks.any((m) => m.kind == k)) return k;
  }
  return ProofMarkKind.eyes;
}

bool lineBlocks(List<ProofMark> marks) => marks.any((m) => m.blocking);

/// Ink for the gutter mark. Red only where a gate item blocks; diagnostics are never red.
Color proofMarkColor(List<ProofMark> marks) {
  if (lineBlocks(marks)) return HaroTokens.fail;
  return switch (kindOfLine(marks)) {
    ProofMarkKind.error => HaroTokens.ink86,
    ProofMarkKind.info => HaroTokens.ink42,
    _ => HaroTokens.ink66,
  };
}

/// TypeScript diagnostics as gutter marks by 1-based line, worst first. Hints are left out.
Map<int, List<ProofMark>> diagnosticMarks(List<LspDiagnostic> items) {
  final out = <int, List<ProofMark>>{};
  for (final d in [...items.where((d) => d.shown)]..sort(compareDiagnostics)) {
    (out[d.line + 1] ??= []).add(
      ProofMark(
        kind: switch (d.severity) {
          DiagnosticSeverity.error => ProofMarkKind.error,
          DiagnosticSeverity.warning => ProofMarkKind.warning,
          _ => ProofMarkKind.info,
        },
        label: [
          d.severity == DiagnosticSeverity.error
              ? 'ERROR'
              : d.severity == DiagnosticSeverity.warning
              ? 'WARNING'
              : 'INFO',
          ?d.codeLabel,
        ].join(' '),
        detail: d.headline,
      ),
    );
  }
  return out;
}

/// [base] with [extra]'s marks appended per line; either may be empty.
Map<int, List<ProofMark>> mergeProofMarks(
  Map<int, List<ProofMark>> base,
  Map<int, List<ProofMark>> extra,
) {
  if (extra.isEmpty) return base;
  if (base.isEmpty) return extra;
  return {
    for (final line in {...base.keys, ...extra.keys})
      line: [...?base[line], ...?extra[line]],
  };
}

/// Lines of [path] with a surviving mutant, for the diff's hover label.
Set<int> mutantLines(Map<int, List<ProofMark>>? marks) => {
  if (marks != null)
    for (final e in marks.entries)
      if (e.value.any((m) => m.kind == ProofMarkKind.mutant)) e.key,
};

/// The Problems tab's rows plus whether a mutation run exists, derived once for the tab and
/// the gutter so they cannot disagree.
class CodeProblems {
  const CodeProblems(this.view, {required this.mutationRan});

  final ProblemsView view;
  final bool mutationRan;
}

final codeProblemsProvider = Provider.autoDispose.family<CodeProblems, String>((
  ref,
  id,
) {
  final lookAt = ref.watch(workspaceFlowProvider(id).select((f) => f?.lookAt));
  final live = ref.watch(
    workspaceDetailProvider(id).select((d) => d.analysis.mutation),
  );
  final receipt = ref.watch(workspaceReceiptProvider(id)).value;
  final mutation = mutationView(live, receipt?.receipt.mutation);
  if (lookAt == null) {
    return CodeProblems(
      ProblemsView.none,
      mutationRan: mutation != null && mutation.supported,
    );
  }
  return CodeProblems(
    deriveProblems(lookAt, mutation?.survivors ?? const []),
    mutationRan: mutation != null && mutation.supported,
  );
});

final codeProofMarksProvider = Provider.autoDispose
    .family<ProofMarksByPath, String>(
      (ref, id) => proofMarksFromRows(
        ref.watch(codeProblemsProvider(id).select((p) => p.view)),
      ),
    );

/// The shared 8px mark: a hollow diamond (mutant), hollow circle (needs your eyes), cross
/// (TS error), hollow triangle (TS warning) or dash (TS info), 1px stroke. Colour is ink, or the failure red where the item blocks.
class ProofMarkPainter extends CustomPainter {
  const ProofMarkPainter(this.kind, {this.color = HaroTokens.ink66});

  final ProofMarkKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    final box = (Offset.zero & size).deflate(.5);
    switch (kind) {
      case ProofMarkKind.mutant:
        canvas.drawPath(
          Path()
            ..moveTo(box.center.dx, box.top)
            ..lineTo(box.right, box.center.dy)
            ..lineTo(box.center.dx, box.bottom)
            ..lineTo(box.left, box.center.dy)
            ..close(),
          paint,
        );
      case ProofMarkKind.eyes:
        canvas.drawOval(box, paint);
      case ProofMarkKind.error:
        canvas.drawPath(
          Path()
            ..moveTo(box.left, box.top)
            ..lineTo(box.right, box.bottom)
            ..moveTo(box.right, box.top)
            ..lineTo(box.left, box.bottom),
          paint,
        );
      case ProofMarkKind.warning:
        canvas.drawPath(
          Path()
            ..moveTo(box.center.dx, box.top)
            ..lineTo(box.right, box.bottom)
            ..lineTo(box.left, box.bottom)
            ..close(),
          paint,
        );
      case ProofMarkKind.info:
        canvas.drawLine(box.centerLeft, box.centerRight, paint);
    }
  }

  @override
  bool shouldRepaint(ProofMarkPainter old) =>
      old.kind != kind || old.color != color;
}
