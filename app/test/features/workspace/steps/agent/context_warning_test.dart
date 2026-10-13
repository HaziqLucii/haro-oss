import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/new_workspace/new_workspace_overlay.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

const _warning = ValueKey('context-warning');

final _palettes = <String, HaroPalette>{
  'haro': HaroPalette.haro,
  'material3': HaroPalette.material3,
  'paper': HaroPalette.paper,
};

AgentRig _rig({int tokens = 850000, int? warnAt}) {
  final rig = AgentRig(
    Preview.idle,
    events: [
      userEv('go'),
      metaEv(),
      tokEv('done it'),
      doneEv(contextTokens: tokens),
    ],
  );
  rig.api.routes['POST /workspaces/$id/sessions/clear'] = (_) =>
      jsonRes({'cleared': true});
  if (warnAt != null) {
    rig.prefs.data['notifications'] = {'context_warn_percent': warnAt};
  }
  return rig;
}

void main() {
  setUpAll(loadBrandFonts);

  for (final entry in _palettes.entries) {
    group('the context warning in the ${entry.key} theme', () {
      setUp(() => HaroTokens.apply(entry.value));
      tearDown(() => HaroTokens.apply(HaroPalette.haro));

      testWidgets('shows the figure above the composer past the threshold', (
        tester,
      ) async {
        await _rig().pump(tester, step: 'agent');
        expect(find.byKey(_warning), findsOneWidget);
        final inWarning = find.descendant(
          of: find.byKey(_warning),
          matching: find.textContaining(
            '850k of 1M tokens',
            findRichText: true,
          ),
        );
        expect(inWarning, findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_warning),
            matching: find.textContaining('85%', findRichText: true),
          ),
          findsOneWidget,
        );
        expect(
          tester.getBottomLeft(find.byKey(_warning)).dy,
          lessThan(
            tester.getTopLeft(find.byKey(const ValueKey('composer'))).dy,
          ),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('stays away below the threshold and when set to 0', (
        tester,
      ) async {
        await _rig(tokens: 300000).pump(tester, step: 'agent');
        expect(find.byKey(_warning), findsNothing);
      });

      testWidgets('Clear asks the backend and hides the strip', (tester) async {
        final rig = _rig();
        await rig.pump(tester, step: 'agent');
        await tester.tap(find.byKey(const ValueKey('context-clear')));
        await tester.pumpAndSettle();
        expect(
          rig.api.calls.where(
            (c) => c.method == 'POST' && c.path.endsWith('/sessions/clear'),
          ),
          hasLength(1),
        );
        expect(find.byKey(_warning), findsNothing);
      });

      testWidgets('Start in new workspace opens the New workspace modal', (
        tester,
      ) async {
        final rig = _rig();
        rig.api.routes['GET /projects/p1/branches'] = (_) => jsonRes({
          'branches': ['main'],
          'default': 'main',
        });
        await rig.pump(tester, step: 'agent');
        await tester.tap(find.byKey(const ValueKey('context-new-workspace')));
        await tester.pumpAndSettle();
        expect(find.byType(NewWorkspaceOverlay), findsOneWidget);
      });

      testWidgets('dismiss hides it', (tester) async {
        await _rig().pump(tester, step: 'agent');
        await tester.tap(find.byKey(const ValueKey('context-dismiss')));
        await tester.pumpAndSettle();
        expect(find.byKey(_warning), findsNothing);
      });
    });
  }

  testWidgets('a threshold of 0 turns it off, a higher one waits', (
    tester,
  ) async {
    await _rig(warnAt: 0).pump(tester, step: 'agent');
    await tester.pumpAndSettle();
    expect(find.byKey(_warning), findsNothing);
    await _rig(warnAt: 95).pump(tester, step: 'agent');
    await tester.pumpAndSettle();
    expect(find.byKey(_warning), findsNothing);
  });

  testWidgets('a cleared context hides it until the next run reports', (
    tester,
  ) async {
    final rig = AgentRig(
      Preview.idle,
      events: [userEv('go'), doneEv(contextTokens: 900000), contextClearedEv()],
    );
    await rig.pump(tester, step: 'agent');
    expect(find.byKey(_warning), findsNothing);
  });
}
