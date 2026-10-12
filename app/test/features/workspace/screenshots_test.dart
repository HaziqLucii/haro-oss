import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/data/workspace_detail_models.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';

import 'harness.dart';

/// Local visual check, not part of the suite: renders PNGs with the real brand fonts.
///   HARO_SHOTS=/some/dir flutter test test/features/workspace/screenshots_test.dart
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
    Rig rig,
    String step, {
    bool terminal = false,
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    final router = buildRouter(initialLocation: '/w/$id/$step');
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
    router.go('/w/$id/$step');
    await tester.pumpAndSettle();
    if (terminal) {
      await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('term-tab-devlog')));
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/workspace-$name.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  testWidgets('render states', (tester) async {
    await _font('SpaceGrotesk', [
      'SpaceGrotesk-400.ttf',
      'SpaceGrotesk-500.ttf',
      'SpaceGrotesk-600.ttf',
      'SpaceGrotesk-700.ttf',
    ]);
    await _font('SpaceMono', ['SpaceMono-400.ttf', 'SpaceMono-700.ttf']);
    await _font('Fraunces', ['Fraunces-500.ttf']);
    Directory(_out!).createSync(recursive: true);

    await shot(tester, 'idle', Rig(Preview.idle), 'agent');
    await shot(tester, 'running', Rig(Preview.running), 'verify');
    await shot(tester, 'red', Rig(Preview.red), 'verify');
    await shot(tester, 'green', Rig(Preview.green), 'verify');
    await shot(tester, 'merged', Rig(Preview.merged), 'ship');
    final log = DevLogBuffer()
      ..add('> haro-frontend@0.1.0 dev')
      ..add('  VITE v5.4.2  ready in 312 ms')
      ..add('  Local:   http://localhost:4500/');
    await shot(
      tester,
      'green-terminal',
      Rig(
        Preview.green,
        detail: detailFor(Preview.green, devLog: log.snapshot()),
      ),
      'verify',
      terminal: true,
    );
    await shot(
      tester,
      'red-narrow',
      Rig(Preview.red),
      'verify',
      size: const Size(900, 640),
    );
  }, skip: _out == null);
}
