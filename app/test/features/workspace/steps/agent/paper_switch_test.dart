import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/display_prefs_provider.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_step.dart';
import 'package:haro_app/main.dart' show HaroApp;
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

List<(String, Color)> painted(WidgetTester tester, Finder within) {
  final out = <(String, Color)>[];
  void walk(InlineSpan span, TextStyle inherited) {
    if (span is TextSpan) {
      final style = inherited.merge(span.style);
      final t = span.text;
      if (t != null && t.trim().isNotEmpty && style.color != null) {
        out.add((t.trim(), style.color!));
      }
      for (final c in span.children ?? const <InlineSpan>[]) {
        walk(c, style);
      }
    }
  }

  for (final r in tester.widgetList<RichText>(
    find.descendant(of: within, matching: find.byType(RichText)),
  )) {
    walk(r.text, const TextStyle());
  }
  return out;
}

void main() {
  setUpAll(loadBrandFonts);
  tearDown(() => HaroTokens.apply(HaroPalette.haro));

  testWidgets(
    'switching to Paper in a running app repaints the agent stream dark',
    (tester) async {
      await AgentRig(
        Preview.idle,
        events: prototypeTranscript(),
      ).pump(tester, step: 'agent');
      await tester.pumpAndSettle();
      ProviderScope.containerOf(tester.element(find.byType(HaroApp)))
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(theme: 'paper'));
      await tester.pumpAndSettle();
      expect(HaroTokens.palette.id, 'paper');
      final text = painted(tester, find.byType(AgentStep));
      expect(text, isNotEmpty);
      // White is the label of a dark button (Review changes, Restore), which is right.
      final light = [
        for (final (t, c) in text)
          if (c.computeLuminance() > .5 && c != const Color(0xFFFFFFFF))
            '$t -> ${c.toARGB32().toRadixString(16)}',
      ];
      expect(light, isEmpty, reason: 'light text on Paper: $light');
    },
  );
}
