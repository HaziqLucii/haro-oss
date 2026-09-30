import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_detail_models.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';

import '../../../../state/builders.dart';
import '../../harness.dart';
import 'verify_harness.dart';

/// Local visual check, not part of the suite: renders PNGs with the real brand fonts.
///   HARO_SHOTS=/some/dir flutter test test/features/workspace/steps/verify/verify_shots_test.dart
final _out = Platform.environment['HARO_SHOTS'];

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File('assets/fonts/$f').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

void main() {
  final key = GlobalKey();

  Future<void> shot(
    WidgetTester tester,
    String name,
    Rig rig, {
    Size size = const Size(1400, 900),
    Future<void> Function()? before,
    bool terminal = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    final router = buildRouter(initialLocation: '/w/$id/verify');
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: rig.overrides,
        child: RepaintBoundary(
          key: key,
          child: HaroApp(router: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/w/$id/verify');
    await tester.pumpAndSettle();
    if (terminal) {
      await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
      await tester.pumpAndSettle();
    }
    if (before != null) {
      await before();
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/verify-$name.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
  }

  testWidgets('render verify states', (tester) async {
    await _font('SpaceGrotesk', [
      'SpaceGrotesk-400.ttf',
      'SpaceGrotesk-500.ttf',
      'SpaceGrotesk-600.ttf',
      'SpaceGrotesk-700.ttf',
    ]);
    await _font('SpaceMono', ['SpaceMono-400.ttf', 'SpaceMono-700.ttf']);
    await _font('Fraunces', ['Fraunces-500.ttf']);
    Directory(_out!).createSync(recursive: true);

    const config = GateConfig(gateDir: 'frontend');

    VerifyRig rig(WorkspaceDetail d, Preview p) =>
        VerifyRig(p, state: d, hunks: sampleHunks(), impact: sampleImpact());

    await shot(
      tester,
      'idle',
      rig(verifyDetail(WorkspaceStatus.idle, config: config), Preview.idle),
    );

    final running = verifyDetail(
      WorkspaceStatus.testsRunning,
      run: greenRun(),
      cells: cells(412, running: 4),
      expectedTotal: 594,
      config: config,
    );
    await shot(tester, 'running', rig(running, Preview.running));
    await shot(
      tester,
      'running-grid',
      rig(running, Preview.running),
      before: () async {
        final f = find.byKey(const ValueKey('evidence-head-grid'));
        await scrollTo(tester, f);
        await tester.tap(f);
      },
    );

    final red = verifyDetail(
      WorkspaceStatus.gateRed,
      run: failingRun(tamper: [removedTest]),
      config: config,
    );
    await shot(tester, 'red', rig(red, Preview.red));
    await shot(
      tester,
      'red-narrow',
      rig(red, Preview.red),
      size: const Size(900, 640),
      terminal: true,
    );

    final green = verifyDetail(
      WorkspaceStatus.gateGreen,
      run: greenRun(
        unchecked: [
          untestedRow('frontend/src/components/AgentStream.tsx', 1),
          {
            'kind': 'no_test_file',
            'file': 'frontend/src/components/ProjectSettingsModal.tsx',
            'detail': 'No test file imports this module · 5 added lines',
            'count': 5,
            'key': 'no_test_file:ProjectSettingsModal',
          },
        ],
      ),
      cells: cells(594),
      config: config,
      analysis: WorkspaceAnalysis(mutation: sampleMutation()),
    );
    await shot(tester, 'green', rig(green, Preview.green));
    await shot(
      tester,
      'green-evidence',
      rig(green, Preview.green),
      before: () async {
        for (final k in ['untested', 'grid', 'impact']) {
          final f = find.byKey(ValueKey('evidence-head-$k'));
          await scrollTo(tester, f);
          await tester.tap(f);
          await tester.pumpAndSettle();
        }
        await scrollTo(tester, find.byKey(const ValueKey('evidence-flaky')));
      },
    );

    final merged = verifyDetail(
      WorkspaceStatus.merged,
      run: greenRun(
        unchecked: [untestedRow('frontend/src/components/AgentStream.tsx', 1)],
      ),
      cells: cells(594),
      config: config,
      pr: 232,
    );
    await shot(tester, 'merged', rig(merged, Preview.merged));
  }, skip: _out == null);
}
