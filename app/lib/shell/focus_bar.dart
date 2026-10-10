import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../data/workspace_detail.dart';
import '../state/workspace_flow.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_mark.dart';
import '../widgets/haro_pressable.dart';
import '../widgets/status_square.dart';
import 'gate_chip.dart';
import 'top_bar.dart' show trafficLightInset;
import 'window_controls.dart';

/// The 34px bar that replaces the top bar and step bar in focus mode: wordmark, the workspace
/// and step, the live gate chip and the way out.
class FocusBar extends StatelessWidget {
  const FocusBar({
    super.key,
    required this.title,
    required this.gate,
    required this.onExit,
    this.trafficLightRoom = false,
    this.draggable = true,
    this.windowControls,
  });

  /// See `TopBar.windowControls`.
  final bool? windowControls;

  /// `<name> · 02 CODE · FOCUS`, already assembled.
  final String title;
  final FocusGate? gate;
  final VoidCallback onExit;
  final bool trafficLightRoom;
  final bool draggable;

  @override
  Widget build(BuildContext context) {
    const rule = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: HaroTokens.line12)),
      ),
      child: SizedBox.expand(),
    );
    final gate = this.gate;
    final controls = windowControls ?? useWindowControls;
    final content = Padding(
      padding: EdgeInsets.only(
        left: 16 + (trafficLightRoom ? trafficLightInset : 0),
        right: controls ? 6 : 12,
      ),
      child: Row(
        children: [
          const HaroWordmark(fontSize: 16),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              key: const ValueKey('focus-title'),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 10.5,
                color: HaroTokens.ink42,
                tracking: .1,
              ),
            ),
          ),
          if (gate != null) ...[
            const SizedBox(width: 14),
            StatusSquare(color: gate.color, filled: gate.filled),
            const SizedBox(width: 7),
            Text(
              gate.word,
              key: const ValueKey('focus-gate'),
              maxLines: 1,
              softWrap: false,
              style: HaroText.mono(
                size: 10.5,
                color: gate.color,
                tracking: .14,
              ),
            ),
            if (gate.count != null) ...[
              const SizedBox(width: 7),
              Text(
                gate.count!,
                maxLines: 1,
                softWrap: false,
                style: HaroText.mono(
                  size: 10.5,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
            ],
          ],
          const SizedBox(width: 14),
          HaroPressable(
            onTap: onExit,
            semanticLabel: 'Exit focus',
            builder: (context, hovered) => AnimatedContainer(
              key: const ValueKey('focus-exit'),
              duration: HaroTokens.fadeFast,
              curve: HaroTokens.curve,
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(
                  color: hovered ? HaroTokens.line30 : HaroTokens.line20,
                ),
                borderRadius: BorderRadius.circular(HaroTokens.radius),
              ),
              child: Text(
                'Exit focus Esc',
                maxLines: 1,
                softWrap: false,
                style: HaroText.mono(
                  size: 10.5,
                  color: HaroTokens.ink,
                  tracking: 0,
                ),
              ),
            ),
          ),
          if (controls) ...[const SizedBox(width: 10), const WindowControls()],
        ],
      ),
    );
    return SizedBox(
      height: HaroTokens.focusBarHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (draggable) const DragToMoveArea(child: rule) else rule,
          content,
        ],
      ),
    );
  }
}

/// [FocusBar] for a workspace: its name, the code step's number (01 in manual, which has no
/// agent step, else 02) and the live gate.
class WorkspaceFocusBar extends ConsumerWidget {
  const WorkspaceFocusBar({
    super.key,
    required this.workspaceId,
    required this.name,
    required this.onExit,
    this.trafficLightRoom = false,
    this.draggable = true,
  });

  final String workspaceId;
  final String name;
  final VoidCallback onExit;
  final bool trafficLightRoom;
  final bool draggable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(workspaceFlowProvider(workspaceId));
    final number = flow == null
        ? 2
        : visibleSteps(flow.mode).indexOf(StepKey.code) + 1;
    return FocusBar(
      title: '${name.toUpperCase()} · 0$number CODE · FOCUS',
      gate: flow == null ? null : gateChipFor(flow),
      onExit: onExit,
      trafficLightRoom: trafficLightRoom,
      draggable: draggable,
    );
  }
}
