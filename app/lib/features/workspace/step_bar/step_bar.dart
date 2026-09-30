import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../shortcuts/platform_keys.dart';
import '../../../state/workspace_flow.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_button.dart';
import '../../../widgets/haro_pressable.dart';

const double _cellMin = 150;

Color _dotColor(StepStatus s) => switch (s) {
  StepStatus.pending => HaroTokens.line12,
  StepStatus.current => HaroTokens.ink,
  StepStatus.done => HaroTokens.ink42,
  StepStatus.red => HaroTokens.fail,
  StepStatus.green => HaroTokens.gate,
  StepStatus.merged => HaroTokens.merged,
};

Color _lineColor(StepStatus s) => switch (s) {
  StepStatus.pending || StepStatus.done => HaroTokens.ink42,
  StepStatus.current => HaroTokens.ink,
  StepStatus.red => HaroTokens.fail,
  StepStatus.green => HaroTokens.gate,
  StepStatus.merged => HaroTokens.merged,
};

/// Step bar (spec 5.1): four step cells plus the one primary action. The steps share the
/// row equally (never narrower than 150px) with the action at the trailing edge; when that
/// does not fit, the steps wrap into an auto-fit grid and the action takes its own row.
class StepBar extends StatelessWidget {
  const StepBar({
    super.key,
    required this.flow,
    required this.active,
    required this.onStep,
    required this.onNext,
    this.busy = false,
    this.next,
  });

  final WorkspaceFlow flow;

  /// The action to show instead of [WorkspaceFlow.nextAction] (unsaved edits on the code step).
  final NextAction? next;
  final StepKey active;
  final ValueChanged<StepKey> onStep;
  final VoidCallback onNext;

  /// A previous press is still in flight: look disabled, ignore taps.
  final bool busy;

  static TextStyle get _buttonText =>
      HaroText.ui(size: 13.5, weight: FontWeight.w500);

  @override
  Widget build(BuildContext context) {
    final next = this.next ?? flow.nextAction;
    final saves = next.kind == NextActionKind.saveAndRunGate;
    final label = saves ? next.label : '${next.label} →';
    // When the action lands on the step already open, that step renders it as the primary
    // (Merge, Continue, Run agent, Run gate). A second copy here would be a second button
    // for one irreversible action, so the bar drops it.
    final ownedByStep =
        next.step == active ||
        (next.kind == NextActionKind.continueOnNewBranch &&
            active == StepKey.ship);
    final nextButton = IntrinsicWidth(
      child: HaroButton(
        key: const ValueKey('next-action'),
        label: label,
        kbd: next.saveShortcut ? primaryLabel('S') : null,
        height: 34,
        fontSize: 13.5,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        variant: !next.enabled || busy
            ? HaroButtonVariant.tertiary
            : HaroButtonVariant.primary,
        foreground: HaroTokens.ink42,
        onPressed: next.enabled && !busy ? onNext : null,
      ),
    );
    final painter = TextPainter(
      text: TextSpan(text: label, style: _buttonText),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final nextWidth = ownedByStep ? 0.0 : painter.width + 32 + 32 + 2;
    painter.dispose();

    Widget cell(FlowStep s) => _StepCell(
      step: s,
      index: flow.steps.indexOf(s),
      active: s.key == active,
      onTap: () => onStep(s.key),
    );

    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border.symmetric(
          horizontal: BorderSide(color: HaroTokens.line12),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final count = flow.steps.length;
          final inline = w >= _cellMin * count + nextWidth;
          final nextCell = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Align(alignment: Alignment.centerRight, child: nextButton),
          );
          if (inline) {
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final s in flow.steps) Expanded(child: cell(s)),
                  if (!ownedByStep)
                    SizedBox(
                      width: nextWidth,
                      child: Center(child: nextCell),
                    ),
                ],
              ),
            );
          }
          final cols = math.max(1, math.min(count, w ~/ _cellMin));
          final rows = <Widget>[];
          for (var i = 0; i < flow.steps.length; i += cols) {
            final chunk = flow.steps.skip(i).take(cols).toList();
            rows.add(
              DecoratedBox(
                decoration: BoxDecoration(
                  border: i == 0
                      ? null
                      : const Border(top: BorderSide(color: HaroTokens.line08)),
                ),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final s in chunk) Expanded(child: cell(s)),
                      for (var k = chunk.length; k < cols; k++)
                        const Expanded(child: SizedBox.shrink()),
                    ],
                  ),
                ),
              ),
            );
          }
          if (!ownedByStep) {
            rows.add(
              DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: HaroTokens.line08)),
                ),
                child: SizedBox(width: double.infinity, child: nextCell),
              ),
            );
          }
          return Column(mainAxisSize: MainAxisSize.min, children: rows);
        },
      ),
    );
  }
}

class _StepCell extends StatelessWidget {
  const _StepCell({
    required this.step,
    required this.index,
    required this.active,
    required this.onTap,
  });

  final FlowStep step;
  final int index;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: '${step.label}, ${step.line}',
    builder: (context, hovered) => AnimatedContainer(
      key: ValueKey('step-${step.key.name}'),
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 13),
      decoration: BoxDecoration(
        color: active || hovered ? HaroTokens.panel : HaroTokens.transparent,
        border: Border(
          top: BorderSide(
            width: 2,
            color: active ? HaroTokens.ink : HaroTokens.transparent,
          ),
          right: const BorderSide(color: HaroTokens.line08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '0${index + 1}',
                style: HaroText.mono(
                  size: 10.5,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                dimension: 6,
                child: ColoredBox(color: _dotColor(step.status)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  step.label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.ui(
                    size: 15,
                    weight: FontWeight.w500,
                    color: active ? HaroTokens.ink : HaroTokens.ink66,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            step.line,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: HaroText.mono(
              size: 10.5,
              color: _lineColor(step.status),
              tracking: 0,
            ),
          ),
        ],
      ),
    ),
  );
}
