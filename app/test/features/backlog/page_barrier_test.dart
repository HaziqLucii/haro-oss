import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';

import '../creation_harness.dart';
import 'backlog_test.dart' show backend, pumpShell;

/// A click on empty space on a page used to fall through to the route's own (non-dismissible)
/// ModalBarrier, which asks the OS for its alert sound: on macOS, the system beep.
void main() {
  setUpAll(loadBrandFonts);

  for (final loc in ['/backlog?project=p1', '/']) {
    for (final entry in {
      'haro': HaroPalette.haro,
      'material3': HaroPalette.material3,
      'paper': HaroPalette.paper,
    }.entries) {
      testWidgets(
        'clicking empty space on the Backlog plays no system sound (${entry.key})',
        (tester) async {
          HaroTokens.apply(entry.value);
          addTearDown(() => HaroTokens.apply(HaroPalette.haro));
          final calls = <String>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (c) async {
              calls.add(c.method);
              return null;
            },
          );
          await pumpShell(
            tester,
            backend(),
            [project('p1', 'haro')],
            location: loc,
            size: const Size(2400, 1000),
          );
          calls.clear();
          final w = tester.view.physicalSize;
          // The right and left margins of the page, and the gap under its headline.
          for (final p in [
            Offset(w.width - 20, 500),
            Offset(w.width - 60, 800),
            const Offset(250, 80),
          ]) {
            await tester.tapAt(p);
            await tester.pumpAndSettle();
          }
          expect(calls.where((c) => c.startsWith('SystemSound')), isEmpty);
        },
      );
    }
  }
}
