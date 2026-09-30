import 'package:flutter/widgets.dart';

import '../../../../state/display_state.dart';
import '../../../../state/verdict.dart';
import '../../../../state/workspace_flow.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/status_square.dart';
import 'verify_model.dart';
import 'verify_widgets.dart';

/// Zone 1 (spec 5.6): the verdict word, the headline, one sentence, the metrics row and the
/// buttons. The state colour lives on the square and the word only.
class VerdictBlock extends StatelessWidget {
  const VerdictBlock({
    super.key,
    required this.state,
    required this.verdict,
    required this.meta,
    required this.metrics,
    required this.next,
    required this.nextIsPrimary,
    required this.busy,
    required this.onNext,
    required this.onRerun,
    required this.onImpacted,
    this.progress,
    this.showRerun = true,
    this.hideRerunButton = false,
    this.rerunEnabled = true,
    this.rerunLabel = 'Run again',
    this.error,
    this.acceptanceLine,
  });

  final DisplayState state;
  final VerdictCopy verdict;
  final String meta;
  final List<Metric> metrics;
  final NextAction next;

  /// The step bar steps its own button down when the action lands on the open step, so
  /// this copy takes the bone fill then and keeps one on screen.
  final bool nextIsPrimary;
  final bool busy;
  final VoidCallback onNext;
  final VoidCallback onRerun;
  final VoidCallback onImpacted;

  /// 0 to 1 while the gate runs, else null.
  final double? progress;

  /// Off for a merged tree, where re-running the gate answers nothing.
  final bool showRerun;

  /// The next action is already a gate re-run, so a second button would say the same thing.
  final bool hideRerunButton;
  final bool rerunEnabled;
  final String rerunLabel;
  final String? error;

  /// Test-first receipt line, only on a workspace with an approved acceptance test.
  final String? acceptanceLine;

  Color get _color => switch (state) {
    DisplayState.agent || DisplayState.plan => HaroTokens.ink42,
    _ => state.color,
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final narrow = c.maxWidth < narrowWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 6,
            children: [
              StatusSquare(size: 10, color: _color, filled: state.settled),
              Text(
                verdict.word,
                key: const ValueKey('verify-verdict-word'),
                style: HaroText.mono(
                  size: 12,
                  weight: FontWeight.w700,
                  color: _color,
                  tracking: .22,
                ),
              ),
              Text(
                meta,
                key: const ValueKey('verify-meta'),
                style: HaroText.mono(
                  size: 11,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            verdict.headline,
            key: const ValueKey('verify-headline'),
            style: HaroText.ui(
              size: narrow ? 32 : 44,
              weight: FontWeight.w500,
              height: 1.08,
            ).copyWith(letterSpacing: (narrow ? 32 : 44) * -.025),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Text(
              verdict.sub,
              key: const ValueKey('verify-sub'),
              style: HaroText.ui(
                size: 16,
                color: HaroTokens.ink66,
                height: 1.55,
              ),
            ),
          ),
          if (acceptanceLine != null) ...[
            const SizedBox(height: 10),
            Text(
              acceptanceLine!,
              key: const ValueKey('verify-acceptance'),
              style: HaroText.mono(
                size: 11.5,
                color: HaroTokens.ink66,
                tracking: 0,
              ),
            ),
          ],
          if (progress != null) ...[
            const SizedBox(height: 22),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: _Progress(progress!),
            ),
          ],
          const SizedBox(height: 28),
          _MetricsRow(metrics),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Fit(
                child: HaroButton(
                  key: const ValueKey('verify-next'),
                  label: next.label,
                  height: 36,
                  fontSize: 14,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  variant: !next.enabled || busy
                      ? HaroButtonVariant.tertiary
                      : nextIsPrimary
                      ? HaroButtonVariant.primary
                      : HaroButtonVariant.secondary,
                  foreground: next.enabled && !busy
                      ? HaroTokens.ink86
                      : HaroTokens.ink42,
                  onPressed: next.enabled && !busy ? onNext : null,
                ),
              ),
              if (showRerun && !hideRerunButton)
                Fit(
                  child: HaroButton(
                    key: const ValueKey('verify-rerun'),
                    label: rerunLabel,
                    height: 36,
                    fontSize: 14,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    foreground: rerunEnabled && !busy
                        ? HaroTokens.ink86
                        : HaroTokens.ink42,
                    onPressed: rerunEnabled && !busy ? onRerun : null,
                  ),
                ),
              if (showRerun)
                Fit(
                  child: HaroButton(
                    key: const ValueKey('verify-impacted'),
                    label: 'Impacted tests only',
                    height: 36,
                    fontSize: 14,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    variant: HaroButtonVariant.tertiary,
                    foreground: rerunEnabled && !busy
                        ? HaroTokens.ink66
                        : HaroTokens.ink42,
                    onPressed: rerunEnabled && !busy ? onImpacted : null,
                  ),
                ),
            ],
          ),
          if (error != null) ...[const SizedBox(height: 12), ErrorLine(error!)],
        ],
      );
    },
  );
}

class _Progress extends StatelessWidget {
  const _Progress(this.value);

  final double value;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 2,
    child: Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: HaroTokens.line12)),
        Positioned.fill(
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              key: const ValueKey('verify-progress'),
              widthFactor: value.clamp(0, 1).toDouble(),
              child: const SizedBox(
                height: 2,
                child: ColoredBox(color: HaroTokens.ink),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _MetricsRow extends StatelessWidget {
  const _MetricsRow(this.metrics);

  final List<Metric> metrics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final cols = (c.maxWidth / 120).floor().clamp(1, metrics.length);
      final cellWidth = c.maxWidth / cols;
      return DecoratedBox(
        decoration: const BoxDecoration(
          border: Border.symmetric(
            horizontal: BorderSide(color: HaroTokens.line12),
          ),
        ),
        child: Wrap(
          children: [
            for (final m in metrics)
              SizedBox(
                width: cellWidth,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    border: Border(right: BorderSide(color: HaroTokens.line08)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 8, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.label.toUpperCase(),
                          style: HaroText.mono(
                            size: 10,
                            color: HaroTokens.ink42,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          m.value,
                          key: ValueKey('metric-${m.label.toLowerCase()}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HaroText.ui(
                            size: m.tone == MetricTone.dim && m.value.length > 2
                                ? 13
                                : 20,
                            weight: FontWeight.w500,
                            color: toneColor(m.tone),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
