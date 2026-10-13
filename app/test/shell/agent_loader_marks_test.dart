import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';

import '../features/workspace/steps/agent/agent_events.dart';
import '../features/workspace/steps/agent/agent_harness.dart';

final _palettes = <String, HaroPalette>{
  'haro': HaroPalette.haro,
  'material3': HaroPalette.material3,
  'paper': HaroPalette.paper,
};

final _row = find.byKey(const ValueKey('sidebar-agent-loader'));
final _strip = find.byKey(const ValueKey('strip-agent-loader'));

void main() {
  setUpAll(loadBrandFonts);

  for (final entry in _palettes.entries) {
    group('a running agent in the ${entry.key} theme', () {
      setUp(() => HaroTokens.apply(entry.value));
      tearDown(() => HaroTokens.apply(HaroPalette.haro));

      testWidgets('is the loader in the sidebar row and the folded strip', (
        tester,
      ) async {
        final rig = AgentRig(
          Preview.idle,
          status: WorkspaceStatus.agentRunning,
          events: [userEv('go')],
        );
        await rig.pump(tester, step: 'agent');
        expect(_row, findsOneWidget);
        expect(find.text('in progress'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('sidebar-toggle')));
        await tester.pumpAndSettle();
        expect(_strip, findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('an idle workspace keeps its square', (tester) async {
        await AgentRig(
          Preview.idle,
          events: [userEv('go'), metaEv()],
        ).pump(tester, step: 'agent');
        expect(_row, findsNothing);
      });
    });
  }
}
