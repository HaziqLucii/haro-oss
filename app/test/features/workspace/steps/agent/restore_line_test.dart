import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/widgets/haro_button.dart';

import '../../../creation_harness.dart' as ch;
import 'agent_events.dart';
import 'agent_harness.dart';

Finder k(String key) => find.byKey(ValueKey(key));

Map<String, dynamic> restored({
  List<String> files = const ['a.ts', 'b.ts'],
  List<String> failed = const [],
  bool nothing = false,
}) => {
  'restored': files,
  'failed': failed,
  'saved_ref': nothing ? null : 'refs/haro/before-restore/ws_1/1',
  'nothing_to_restore': nothing,
};

Future<AgentRig> pump(
  WidgetTester tester, {
  List<AgentEvent>? events,
  dynamic Function()? answer,
}) async {
  final rig = AgentRig(
    Preview.idle,
    events:
        events ??
        [userEv('fix it'), metaEv(), tokEv('done'), editEv('a.ts'), doneEv()],
    backend: backend(restoreResponse: answer ?? () => jsonOk(restored())),
  );
  await rig.pump(tester, step: 'agent');
  return rig;
}

dynamic jsonOk(Map<String, dynamic> body) => ch.jsonRes(body);

void main() {
  testWidgets('the newest run offers to restore its start, in two steps', (
    tester,
  ) async {
    final rig = await pump(tester);
    expect(k('restore-start'), findsOneWidget);
    await tester.tap(k('restore-start'));
    await tester.pump();
    expect(k('restore-ask'), findsOneWidget);
    expect(
      tester.widget<Text>(k('restore-ask')).data,
      contains('What is there now is kept, and commits stay.'),
    );
    expect(rig.api.calls.where((c) => c.method == 'POST'), isEmpty);
    await tester.tap(k('restore-cancel'));
    await tester.pump();
    expect(k('restore-start'), findsOneWidget);
    expect(rig.api.calls.where((c) => c.path.contains('restore')), isEmpty);
  });

  testWidgets('confirming restores and says where the old files are kept', (
    tester,
  ) async {
    final rig = await pump(tester);
    await tester.tap(k('restore-start'));
    await tester.pump();
    await tester.tap(k('restore-confirm'));
    await tester.pumpAndSettle();
    expect(
      rig.api.calls.where((c) => c.path.endsWith('/restore-start')),
      hasLength(1),
    );
    expect(
      tester.widget<Text>(k('restore-note')).data,
      'Restored 2 files. What was there before is kept at refs/haro/before-restore/ws_1/1.',
    );
  });

  testWidgets('an unchanged worktree is said plainly', (tester) async {
    await pump(tester, answer: () => jsonOk(restored(nothing: true)));
    await tester.tap(k('restore-start'));
    await tester.pump();
    await tester.tap(k('restore-confirm'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(k('restore-note')).data,
      'The files already match how they were when the run started.',
    );
  });

  testWidgets('files that could not be restored are counted', (tester) async {
    await pump(
      tester,
      answer: () => jsonOk(restored(files: ['a.ts'], failed: ['b.ts'])),
    );
    await tester.tap(k('restore-start'));
    await tester.pump();
    await tester.tap(k('restore-confirm'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(k('restore-note')).data,
      contains('Restored 1 file, could not restore 1.'),
    );
  });

  testWidgets('only the newest run has it, and a plan run has none', (
    tester,
  ) async {
    await pump(
      tester,
      events: [
        userEv('one'),
        metaEv(),
        tokEv('a'),
        editEv('a.ts'),
        doneEv(),
        userEv('two', turn: 2),
        metaEv(turn: 2),
        tokEv('b', turn: 2),
        editEv('b.ts', turn: 2),
        doneEv(turn: 2),
      ],
    );
    expect(k('restore-start'), findsOneWidget);
    await pump(
      tester,
      events: [
        userEv('plan it'),
        metaEv(role: 'plan'),
        tokEv('1. a'),
        doneEv(plan: true),
      ],
    );
    expect(k('restore-start'), findsNothing);
  });

  testWidgets('the restore control and the review link are bone buttons', (
    tester,
  ) async {
    await pump(tester);
    for (final key in ['restore-start', 'review-in-code']) {
      final b = tester.widget<HaroButton>(k(key));
      expect(b.variant, HaroButtonVariant.control);
      expect(b.onPressed, isNotNull);
    }
  });
}
