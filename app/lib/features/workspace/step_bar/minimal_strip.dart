import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/workspace_detail.dart';
import '../../../data/workspace_detail_lazy.dart';
import '../../../shell/gate_chip.dart';
import '../../../shortcuts/app_commands.dart';
import '../../../shortcuts/platform_keys.dart';
import '../../../state/workspace_flow.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_button.dart';
import '../../../widgets/haro_pressable.dart';
import '../../../widgets/shell_icons.dart';
import '../../../widgets/status_square.dart';
import '../rail/run_facts.dart';
import '../rail/workspace_rail.dart' show workspaceRunFactsProvider;
import 'step_bar.dart';

/// The step bar in minimal view: one 46px line. Step squares, the current step and its line,
/// then what the rail would have said (to review, the app, the terminal, the last run, the gate)
/// and Back / Proceed. The rail is tucked away, so its facts live here.
class MinimalStepStrip extends ConsumerWidget {
  const MinimalStepStrip({
    super.key,
    required this.workspaceId,
    required this.flow,
    required this.active,
    required this.onNext,
    required this.onVerify,
    required this.onToggleTerminal,
    required this.terminalOpen,
    this.back,
    this.busy = false,
    this.next,
  });

  final String workspaceId;
  final WorkspaceFlow flow;
  final StepKey active;
  final NextAction? next;
  final VoidCallback onNext;
  final VoidCallback onVerify;
  final VoidCallback onToggleTerminal;
  final bool terminalOpen;
  final StepBack? back;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = this.next ?? flow.nextAction;
    final index = flow.steps.indexWhere((s) => s.key == active);
    final step = flow.steps[index < 0 ? 0 : index];
    final gate = gateChipFor(flow);
    final facts = ref.watch(workspaceRunFactsProvider(workspaceId));
    final port = ref.watch(
      workspaceDetailProvider(workspaceId).select((d) => d.port),
    );
    final running = ref
        .watch(workspaceActiveRunProvider(workspaceId))
        .run
        .running;
    final runLine = _runLine(facts);
    final owned = nextOwnedByStep(next, active);
    final saves = next.kind == NextActionKind.saveAndRunGate;
    final proceedOn = next.enabled && !busy;

    return Container(
      key: const ValueKey('minimal-strip'),
      height: 46,
      padding: const EdgeInsets.only(left: 20, right: 12),
      decoration: BoxDecoration(
        border: Border.symmetric(
          horizontal: BorderSide(color: HaroTokens.line12),
        ),
      ),
      child: Row(
        children: [
          for (final s in flow.steps) ...[
            _StepSquare(status: s.status, current: s.key == active),
            const SizedBox(width: 5),
          ],
          const SizedBox(width: 9),
          Text(
            '0${flow.steps.indexOf(step) + 1}',
            style: HaroText.mono(
              size: 11,
              color: HaroTokens.ink42,
              tracking: 0,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            step.label,
            key: const ValueKey('minimal-step-name'),
            maxLines: 1,
            softWrap: false,
            style: HaroText.ui(size: 14.5, weight: FontWeight.w500),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              step.line,
              key: const ValueKey('minimal-step-line'),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 11,
                color: HaroTokens.ink42,
                tracking: 0,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (flow.openLookCount > 0)
                      _Chip(
                        key: const ValueKey('minimal-review'),
                        tooltip: 'Needs your review',
                        onTap: onVerify,
                        child: Text('${flow.openLookCount} to review'),
                      ),
                    if (port != null)
                      _Chip(
                        key: const ValueKey('minimal-app'),
                        tooltip:
                            '${running ? 'Stop' : 'Run'} the app (${primaryLabel('R')})',
                        onTap: () =>
                            ref.read(appCommandsProvider).runDevServer(),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            StatusSquare(
                              color: running
                                  ? HaroTokens.ink
                                  : HaroTokens.ink42,
                              filled: running,
                              size: 6,
                            ),
                            const SizedBox(width: 7),
                            Text(':$port ${running ? 'running' : 'stopped'}'),
                          ],
                        ),
                      ),
                    _Chip(
                      key: const ValueKey('minimal-terminal'),
                      tooltip: 'Terminal ${controlLabel('`')}',
                      onTap: onToggleTerminal,
                      on: terminalOpen,
                      child: ShellIconView(
                        ShellIcon.terminal,
                        size: 14,
                        color: HaroTokens.ink66,
                      ),
                    ),
                    if (runLine != null)
                      Tooltip(
                        message: 'Last agent run: model, spent, context',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            runLine,
                            key: const ValueKey('minimal-run'),
                            maxLines: 1,
                            softWrap: false,
                            style: HaroText.mono(
                              size: 10.5,
                              color: HaroTokens.ink42,
                              tracking: 0,
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        key: const ValueKey('minimal-gate'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StatusSquare(
                            color: gate.color,
                            filled: gate.filled,
                            size: 8,
                          ),
                          const SizedBox(width: 7),
                          Text(
                            gate.word,
                            style: HaroText.mono(
                              size: 10.5,
                              color: gate.color,
                              tracking: .1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (back != null)
                      HaroPressable(
                        onTap: busy ? null : back!.onTap,
                        semanticLabel: back!.label,
                        builder: (context, hovered) {
                          final color = hovered
                              ? HaroTokens.ink
                              : HaroTokens.ink66;
                          return Padding(
                            key: const ValueKey('step-back'),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ShellIconView(
                                  ShellIcon.chevronLeft,
                                  size: 14,
                                  color: color,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  back!.label,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: HaroText.ui(size: 13, color: color),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    if (!owned) ...[
                      const SizedBox(width: 6),
                      HaroButton(
                        key: const ValueKey('next-action'),
                        label: next.label,
                        kbd: next.saveShortcut ? primaryLabel('S') : null,
                        height: 30,
                        fontSize: 13,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        variant: proceedOn
                            ? HaroButtonVariant.primary
                            : HaroButtonVariant.tertiary,
                        foreground: HaroTokens.ink42,
                        onPressed: proceedOn ? onNext : null,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(next.label, maxLines: 1, softWrap: false),
                            if (!saves) ...[
                              const SizedBox(width: 8),
                              ShellIconView(
                                ShellIcon.arrowRight,
                                size: 14,
                                color: proceedOn
                                    ? HaroTokens.bg
                                    : HaroTokens.ink42,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `sonnet · $0.41 · 18%`: the last run's model, what the workspace has spent, how full the
/// context was. Null when the transcript has none of it.
String? _runLine(RunFacts f) {
  final parts = [
    if (f.model != null) f.model!,
    if (f.spentUsd != null) '\$${f.spentUsd!.toStringAsFixed(2)}',
    if (f.contextFraction != null) '${(f.contextFraction! * 100).round()}%',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

class _StepSquare extends StatelessWidget {
  const _StepSquare({required this.status, required this.current});

  final StepStatus status;
  final bool current;

  @override
  Widget build(BuildContext context) => StatusSquare(
    color: stepLineColor(status),
    filled: current || status == StepStatus.done,
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.on = false,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;
  final bool on;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: HaroPressable(
      onTap: onTap,
      tooltip: tooltip,
      semanticLabel: tooltip,
      builder: (context, hovered) => Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? HaroTokens.raised : HaroTokens.transparent,
          border: Border.all(
            color: hovered ? HaroTokens.line30 : HaroTokens.line14,
          ),
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: DefaultTextStyle(
          style: HaroText.mono(
            size: 10.5,
            color: hovered ? HaroTokens.ink : HaroTokens.ink86,
            tracking: 0,
          ),
          child: child,
        ),
      ),
    ),
  );
}
