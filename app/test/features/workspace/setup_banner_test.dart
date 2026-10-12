import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_store.dart' show haroApiProvider;

import 'harness.dart';
import 'steps/verify/verify_harness.dart';

class _Api extends HaroApi {
  _Api(this.calls) : super(Uri.parse('http://127.0.0.1:1'));

  final List<String> calls;

  @override
  Future<void> rerunSetup(String wsId) async => calls.add('rerunSetup:$wsId');
}

Future<(VerifyRig, List<String>)> pump(
  WidgetTester tester,
  SetupState? setup, {
  String step = 'verify',
}) async {
  final calls = <String>[];
  final d = verifyDetail(WorkspaceStatus.idle).copyWith(setup: setup);
  final rig = VerifyRig(Preview.idleWithChanges, state: d);
  rig.extra.add(haroApiProvider.overrideWithValue(_Api(calls)));
  await rig.pump(tester, step: step);
  return (rig, calls);
}

Finder key(String k) => find.byKey(ValueKey(k));

void main() {
  const failed = SetupState(
    status: SetupStatus.failed,
    exit: 127,
    note: 'bun install',
    tail: 'installing\nbun: command not found',
  );

  testWidgets('a failed setup shows its exit code, last lines and a re-run', (
    tester,
  ) async {
    final (_, calls) = await pump(tester, failed);
    expect(
      tester.widget<Text>(key('setup-banner-title')).data,
      'SETUP FAILED · EXIT 127',
    );
    expect(
      tester.widget<Text>(key('setup-banner-detail')).data,
      'installing\nbun: command not found',
    );
    await tester.tap(key('setup-banner-rerun'));
    await tester.pump();
    expect(calls, ['rerunSetup:$id']);
    await tester.tap(key('setup-banner-rerun'), warnIfMissed: false);
    await tester.pump();
    expect(calls, hasLength(1));
  });

  testWidgets('it shows on the other steps too', (tester) async {
    await pump(tester, failed, step: 'code');
    expect(key('setup-banner'), findsOneWidget);
  });

  testWidgets('a running, passing or unknown setup shows nothing', (
    tester,
  ) async {
    for (final s in [
      const SetupState(status: SetupStatus.running),
      const SetupState(status: SetupStatus.ok, exit: 0),
      null,
    ]) {
      await pump(tester, s);
      expect(key('setup-banner'), findsNothing);
    }
  });

  testWidgets('without output it falls back to the command that failed', (
    tester,
  ) async {
    await pump(
      tester,
      const SetupState(status: SetupStatus.failed, note: 'bun install'),
    );
    expect(tester.widget<Text>(key('setup-banner-title')).data, 'SETUP FAILED');
    expect(tester.widget<Text>(key('setup-banner-detail')).data, 'bun install');
  });
}
