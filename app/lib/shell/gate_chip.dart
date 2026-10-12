import 'dart:ui' show Color;

import '../state/display_state.dart';
import '../state/workspace_flow.dart';
import '../theme/tokens.dart';

/// What the focus bar, the status bar and the strips show about the gate: the verdict word,
/// its colour and a short count.
class FocusGate {
  const FocusGate({
    required this.word,
    required this.color,
    required this.filled,
    this.count,
  });

  final String word;
  final Color color;
  final bool filled;
  final String? count;
}

/// The colour the gate square wears in the strips, the focus bar and the status bar: the
/// verdict's, except while the agent works or a plan waits, when the gate has nothing to say.
Color gateColor(DisplayState s) => switch (s) {
  DisplayState.agent || DisplayState.plan => HaroTokens.ink42,
  _ => s.color,
};

/// The gate chip for [flow]: word (`GREEN`), colour, and the tail of the verify step's line
/// (`412 passed`, `190 / 412`) when it has one.
FocusGate gateChipFor(WorkspaceFlow flow) {
  final state = flow.displayState;
  String? count;
  for (final s in flow.steps) {
    if (s.key != StepKey.verify) continue;
    final at = s.line.indexOf(' · ');
    if (at >= 0) count = s.line.substring(at + 3);
  }
  return FocusGate(
    word: flow.verdict.word,
    color: gateColor(state),
    filled: state.settled,
    count: count,
  );
}
