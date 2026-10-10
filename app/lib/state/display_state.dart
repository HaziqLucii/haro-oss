import 'dart:ui';

import '../theme/tokens.dart';

/// The one visible state of a workspace (§9.3). Sidebar glyphs, triage rows, the step bar
/// and the rail all read this, so they can never disagree.
enum DisplayState {
  idle('idle'),
  plan('plan'),
  agent('agent'),
  gate('gate'),
  red('red'),
  green('green'),
  merged('merged');

  const DisplayState(this.word);

  /// Short lowercase state word shown in the sidebar and triage rows.
  final String word;

  /// What the sidebar writes beside a workspace, or null for nothing. The square already
  /// carries idle, red and green by shape and colour, so those stay wordless; an agent run
  /// reads as plain "in progress". [override] is the test-first review word.
  String? sidebarWord([String? override]) => switch (this) {
    idle || red || green => null,
    agent => 'in progress',
    _ => override ?? word,
  };

  /// Filled square = settled; hollow = in progress or idle.
  bool get settled => this == red || this == green || this == merged;

  Color get color => switch (this) {
    red => HaroTokens.fail,
    green => HaroTokens.gate,
    merged => HaroTokens.merged,
    idle => HaroTokens.ink42,
    plan || agent || gate => HaroTokens.ink,
  };
}

enum TriageGroup { needsYou, running, readyToShip, idle, merged }
