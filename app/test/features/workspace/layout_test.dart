import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  for (final size in const [Size(900, 640), Size(960, 640), Size(1400, 900)]) {
    for (final preview in Preview.values) {
      for (final terminal in [false, true]) {
        testWidgets('no overflow ${size.width.toInt()}x${size.height.toInt()} '
            '${preview.name} terminal=$terminal', (tester) async {
          final rig = Rig(preview);
          for (final step in ['agent', 'verify', 'ship']) {
            await rig.pump(tester, size: size, step: step);
            if (terminal) {
              await tester.tap(
                find.byKey(const ValueKey('rail-terminal-toggle')),
              );
              await tester.pumpAndSettle();
            }
            expect(tester.takeException(), isNull, reason: step);
          }
        });
      }
    }
  }

  testWidgets('long names do not overflow at 900x640', (tester) async {
    final rig = Rig(Preview.red);
    await rig.pump(tester, size: const Size(900, 640));
    await tester.tap(find.byKey(const ValueKey('rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'x' * 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the shell survives step changes', (tester) async {
    final rig = Rig(Preview.green);
    await rig.pump(tester);
    await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
    await tester.pumpAndSettle();
    for (final s in ['agent', 'code', 'ship', 'verify']) {
      await tester.tap(find.text(s).first);
      await tester.pumpAndSettle();
    }
    expect(
      rig.net.uris.where((u) => u.path.contains('/terminal/')),
      hasLength(1),
    );
    expect(rig.net.channels.where((c) => c.closed), isEmpty);
  });
}
