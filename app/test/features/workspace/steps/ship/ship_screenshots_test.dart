import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';

import 'ship_harness.dart';

/// Local visual check, not part of the suite: renders PNGs with the real brand fonts.
///   HARO_SHOTS=/some/dir flutter test test/features/workspace/steps/ship/ship_screenshots_test.dart
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
    ShipRig rig, {
    Size size = const Size(1400, 900),
    bool terminal = false,
    double scroll = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    final router = buildRouter(initialLocation: '/w/$id/ship');
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
    router.go('/w/$id/ship');
    await tester.pumpAndSettle();
    if (terminal) {
      await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
      await tester.pumpAndSettle();
    }
    if (scroll > 0) {
      await tester.drag(
        find.byKey(const ValueKey('ship-scroll')),
        Offset(0, -scroll),
      );
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/ship-$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  testWidgets('render ship states', (tester) async {
    await _font('SpaceGrotesk', [
      'SpaceGrotesk-400.ttf',
      'SpaceGrotesk-500.ttf',
      'SpaceGrotesk-600.ttf',
      'SpaceGrotesk-700.ttf',
    ]);
    await _font('SpaceMono', ['SpaceMono-400.ttf', 'SpaceMono-700.ttf']);
    await _font('Fraunces', ['Fraunces-500.ttf']);
    Directory(_out!).createSync(recursive: true);

    await shot(tester, 'green', ShipRig(Preview.green, pr: openPr()));
    await shot(tester, 'green-nopr', ShipRig(Preview.green), scroll: 400);
    await shot(tester, 'red', ShipRig(Preview.red));
    await shot(
      tester,
      'merged',
      ShipRig(
        Preview.merged,
        pr: openPr(merged: true),
        git: gitStatus(ahead: 0),
      ),
    );
    await shot(
      tester,
      'dirty',
      ShipRig(Preview.green, git: gitStatus(dirty: 3)),
      scroll: 500,
    );
    await shot(
      tester,
      'green-narrow-terminal',
      ShipRig(Preview.green, pr: openPr()),
      size: const Size(900, 640),
      terminal: true,
    );
  }, skip: _out == null);
}
