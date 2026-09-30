import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/first_run/first_run_model.dart';

import '../creation_harness.dart';
import 'first_run_harness.dart';

/// Local visual check, not part of the suite:
///   HARO_SHOTS=/some/dir flutter test test/features/first_run/first_run_shots_test.dart
final _out = Platform.environment['HARO_SHOTS'];

void main() {
  Future<void> shot(
    WidgetTester tester,
    String name,
    MockBackend backend, {
    BaselineResult? baseline,
    Size size = const Size(1200, 800),
    bool preview = false,
  }) async {
    await tester.pumpWidget(const SizedBox());
    await pumpFirstRun(
      tester,
      backend: backend,
      baseline: baseline,
      size: size,
    );
    if (preview) {
      await tester.tap(find.byKey(const ValueKey('fr-fix-runner')));
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final boundary = find
          .byType(RepaintBoundary)
          .evaluate()
          .map((e) => e.renderObject! as RenderRepaintBoundary)
          .first;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/firstrun-$name.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  testWidgets('render states', (tester) async {
    await loadBrandFonts();
    Directory(_out!).createSync(recursive: true);
    await shot(tester, 'ready', backendFor());
    await shot(tester, 'ready-960', backendFor(), size: const Size(960, 640));
    await shot(
      tester,
      'missing-runner',
      backendFor(
        gate: gateJson(dir: ''),
        detection: detectionJson(),
      ),
    );
    await shot(
      tester,
      'unwritten-preset',
      backendFor(
        gate: gateJson(runner: 'pytest', dir: ''),
        scripts: scriptsJson(setup: null, run: null),
        detection: detectionJson(proposal: true),
      ),
      preview: true,
    );
    await shot(
      tester,
      'red-baseline',
      backendFor(),
      baseline: const BaselineResult(
        status: BaselineStatus.failed,
        passed: 125,
        failed: 3,
        total: 128,
        duration: Duration(milliseconds: 1400),
      ),
    );
  }, skip: _out == null);
}
