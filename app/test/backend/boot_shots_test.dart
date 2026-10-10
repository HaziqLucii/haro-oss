import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/backend/boot_splash.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/widgets/haro_skeleton.dart';

/// Local visual check, not part of the suite: renders the opening and closing splash at a few
/// moments with the real brand fonts.
///   HARO_SHOTS=/some/dir flutter test test/backend/boot_shots_test.dart
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

  Future<void> save(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/boot-$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Widget app(Widget home) => RepaintBoundary(
    key: key,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildHaroTheme(),
      home: home,
    ),
  );

  testWidgets('render the boot splash', (tester) async {
    await _font('SpaceMono', ['SpaceMono-400.ttf', 'SpaceMono-700.ttf']);
    await _font('Fraunces', ['Fraunces-500.ttf']);
    Directory(_out!).createSync(recursive: true);
    tester.view.physicalSize = const Size(960, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => HaroSkeleton.animate = false);
    HaroSkeleton.animate = true;

    await tester.pumpWidget(
      app(
        const BootSplash(
          ready: false,
          lines: [
            BootLine('running haro', 'none'),
            BootLine('bundled backend'),
          ],
        ),
      ),
    );
    var at = 0;
    for (final ms in [700, 1500, 2100, 3000]) {
      await tester.pump(Duration(milliseconds: ms - at));
      at = ms;
      await save(tester, 'open-$ms');
    }
    await tester.pumpWidget(const SizedBox());

    await tester.pumpWidget(
      app(
        const ClosingSplash(
          lines: ['stopping 2 agents and 1 gate', 'stopping backend'],
          stopped: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await save(tester, 'close-0');
    await tester.pumpWidget(
      app(
        const ClosingSplash(
          lines: ['stopping 2 agents and 1 gate', 'stopping backend'],
          stopped: true,
        ),
      ),
    );
    at = 0;
    for (final ms in [300, 700, 1100, 1500]) {
      await tester.pump(Duration(milliseconds: ms - at));
      at = ms;
      await save(tester, 'close-$ms');
    }
    await tester.pumpWidget(const SizedBox());
  }, skip: _out == null);
}
