import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/workspace_detail.dart';
import '../../../data/workspace_detail_lazy.dart';
import '../../../state/display_state.dart';
import '../../../state/workspace_flow.dart' show StepKey;
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_pressable.dart';
import '../../../widgets/status_square.dart';
import '../steps/code/editor/editor_tabs.dart';
import '../steps/code/run_on_save.dart';
import '../steps/verify/verify_model.dart';
import '../workspace_ui.dart';
import 'panel_model.dart';

const _maxSpots = 6;

TextStyle _body(Color color, {FontWeight weight = FontWeight.w400}) =>
    HaroText.mono(
      size: 12,
      color: color,
      tracking: 0,
      weight: weight,
      height: 1.75,
    );

TextStyle _tag(Color color) =>
    HaroText.mono(size: 10, color: color, tracking: .12);

/// Opens [path] in the editor at [line] and brings the code step forward, so a row clicked
/// from the agent or verify step lands on the file rather than on a hidden editor.
void openFileFromPanel(
  BuildContext context,
  WidgetRef ref,
  String workspaceId,
  String path, {
  int? line,
}) {
  ref.read(editorTabsProvider(workspaceId).notifier).open(path, line: line);
  GoRouter.maybeOf(context)?.go(workspaceStepPath(workspaceId, StepKey.code));
}

/// The Gate tab: the live verdict line, what the gate says about the focused editor file,
/// and where added lines never ran (each one opens the file at that line).
class GateTab extends ConsumerWidget {
  const GateTab({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(workspaceFlowProvider(workspaceId));
    if (flow == null) return const SizedBox.shrink();
    final d = workspaceDetailProvider(workspaceId);
    final diff = ref.watch(d.select((x) => x.diff?.diff ?? ''));
    final active = ref.watch(
      editorTabsProvider(workspaceId).select((s) => s.activePath),
    );
    final proof = ref.watch(workspaceVerifiedHunksProvider(workspaceId)).value;
    final impact = ref.watch(workspaceImpactProvider(workspaceId)).value;
    final onSave = runOnSaveEnabled(ref, workspaceId);

    final state = flow.displayState;
    final color = switch (state) {
      DisplayState.agent || DisplayState.plan => HaroTokens.ink42,
      _ => state.color,
    };
    final fileLine = fileProofLine(
      path: active,
      state: state,
      proof: proof,
      changed: changedPaths(diff),
    );
    final untested = state == DisplayState.green
        ? deriveUntested(proof, diff)
        : UntestedSummary.none;
    final spots = untested.available && !untested.stale
        ? untested.spots
        : const <UntestedSpot>[];
    final impactText = impactLine(active, impact);

    return SingleChildScrollView(
      key: const ValueKey('panel-gate'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusSquare(size: 8, color: color, filled: state.settled),
              const SizedBox(width: 10),
              Text(
                flow.verdict.word,
                key: const ValueKey('panel-gate-word'),
                style: HaroText.mono(
                  size: 12,
                  color: color,
                  tracking: .14,
                  height: 1.75,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  flow.verdict.rail,
                  key: const ValueKey('panel-gate-line'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _body(HaroTokens.ink),
                ),
              ),
            ],
          ),
          Text(
            'This file: $fileLine',
            key: const ValueKey('panel-gate-file'),
            style: _body(HaroTokens.ink66),
          ),
          Text(
            [runOnSaveLine(onSave), ?impactText].join(' '),
            key: const ValueKey('panel-gate-save'),
            style: _body(HaroTokens.ink42),
          ),
          if (spots.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '${untested.unexecuted} of ${untested.added} added lines never ran',
              style: _tag(HaroTokens.ink42),
            ),
            const SizedBox(height: 2),
            for (final s in spots.take(_maxSpots))
              _RowShell(
                key: ValueKey('panel-spot-${s.path}:${s.start}'),
                onTap: () => openFileFromPanel(
                  context,
                  ref,
                  workspaceId,
                  s.path,
                  line: s.start,
                ),
                semanticLabel: 'Open ${s.label}',
                mark: const _Mark.circle(),
                title: s.label,
                detail: s.unmapped
                    ? 'no test imports this file'
                    : '${s.lines} ${s.lines == 1 ? 'line' : 'lines'} never ran',
                trailing: s.path,
              ),
            if (spots.length > _maxSpots)
              Text(
                '${spots.length - _maxSpots} more in Verify',
                style: _body(HaroTokens.ink42),
              ),
          ],
          const SizedBox(height: 6),
          HaroPressable(
            key: const ValueKey('panel-gate-verify'),
            onTap: () =>
                GoRouter.maybeOf(context)
                    ?.go(workspaceStepPath(workspaceId, StepKey.verify)),
            semanticLabel: 'Open verify',
            builder: (context, hovered) => Text(
              'Open verify',
              style: _body(hovered ? HaroTokens.ink : HaroTokens.ink66),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Problems tab: surviving mutants and the open needs-your-eyes items. There are no
/// lint or type errors to list; lint was cut from the gate.
class ProblemsTab extends ConsumerWidget {
  const ProblemsTab({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(workspaceFlowProvider(workspaceId));
    if (flow == null) return const SizedBox.shrink();
    final d = workspaceDetailProvider(workspaceId);
    final live = ref.watch(d.select((x) => x.analysis.mutation));
    final receipt = ref.watch(workspaceReceiptProvider(workspaceId)).value;
    final mutation = mutationView(live, receipt?.receipt.mutation);
    final view = deriveProblems(flow.lookAt, mutation?.survivors ?? const []);

    if (view.isEmpty) {
      final ran = mutation != null && mutation.supported;
      return Padding(
        key: const ValueKey('panel-problems-empty'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in problemsEmptyLines(
              flow.displayState,
              mutationRan: ran,
            ))
              Text(line, style: _body(HaroTokens.ink42)),
          ],
        ),
      );
    }

    void open(ProblemRow r) {
      final path = r.path;
      if (path != null) {
        openFileFromPanel(context, ref, workspaceId, path, line: r.line);
      }
    }

    Widget section(String title, List<ProblemRow> rows) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text('$title · ${rows.length}', style: _tag(HaroTokens.ink42)),
        ),
        for (final r in rows)
          _RowShell(
            key: ValueKey('problem-${r.key}'),
            onTap: r.path == null ? null : () => open(r),
            semanticLabel: r.path == null ? r.title : 'Open ${r.title}',
            mark: r.mutant ? const _Mark.diamond() : const _Mark.circle(),
            title: r.title,
            tag: r.label,
            tagColor: r.blocking ? HaroTokens.fail : HaroTokens.ink42,
            detail: r.detail,
            trailing: r.path,
          ),
      ],
    );

    return SingleChildScrollView(
      key: const ValueKey('panel-problems'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (view.mutants.isNotEmpty)
            section('SURVIVING MUTANTS', view.mutants),
          if (view.eyes.isNotEmpty) section('NEEDS YOUR EYES', view.eyes),
        ],
      ),
    );
  }
}

class _RowShell extends StatelessWidget {
  const _RowShell({
    super.key,
    required this.onTap,
    required this.semanticLabel,
    required this.mark,
    required this.title,
    this.tag,
    this.tagColor = HaroTokens.ink42,
    this.detail = '',
    this.trailing,
  });

  final VoidCallback? onTap;
  final String semanticLabel;
  final _Mark mark;
  final String title;
  final String? tag;
  final Color tagColor;
  final String detail;
  final String? trailing;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: semanticLabel,
    builder: (context, hovered) => Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      color: hovered ? HaroTokens.raised : HaroTokens.transparent,
      child: Row(
        children: [
          mark,
          const SizedBox(width: 10),
          Text(title, style: _body(HaroTokens.ink86)),
          if (tag != null) ...[
            const SizedBox(width: 10),
            Text(tag!, style: _tag(tagColor)),
          ],
          if (detail.isNotEmpty) ...[
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _body(HaroTokens.ink66),
              ),
            ),
          ],
          const Spacer(),
          if (trailing != null)
            Flexible(
              child: Text(
                trailing!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: _body(HaroTokens.ink42),
              ),
            ),
        ],
      ),
    ),
  );
}

enum _MarkShape { diamond, circle }

/// A drawn 8px mark (a diamond for a mutant, a hollow circle for a flagged item), in ink.
class _Mark extends StatelessWidget {
  const _Mark.diamond() : _shape = _MarkShape.diamond;
  const _Mark.circle() : _shape = _MarkShape.circle;

  final _MarkShape _shape;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 8,
    child: CustomPaint(painter: _MarkPainter(_shape)),
  );
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.shape);

  final _MarkShape shape;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = HaroTokens.ink66;
    final rect = Offset.zero & size;
    final box = rect.deflate(.5);
    switch (shape) {
      case _MarkShape.diamond:
        canvas.drawPath(
          Path()
            ..moveTo(box.center.dx, box.top)
            ..lineTo(box.right, box.center.dy)
            ..lineTo(box.center.dx, box.bottom)
            ..lineTo(box.left, box.center.dy)
            ..close(),
          paint,
        );
      case _MarkShape.circle:
        canvas.drawOval(box, paint);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.shape != shape;
}
