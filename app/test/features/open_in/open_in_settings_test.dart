import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/controls/select.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/overlays/overlay.dart';

import '../settings/settings_harness.dart';
import 'open_in_harness.dart';

Finder get _select => find.byWidgetPredicate(
  (w) => w is SettingSelect<String> && w.options.first.$1 == 'ask',
);

Future<void> _tapSelect(WidgetTester tester) async {
  await tester.ensureVisible(_select);
  await tester.pumpAndSettle();
  await tester.tap(_select);
  await tester.pumpAndSettle();
}

Future<Opened> _open(
  WidgetTester tester, {
  int? failStatus,
  MemoryDevicePrefsStore? prefs,
}) async {
  final be = FakeBackend();
  if (failStatus != null) {
    be.failingGet['/editors'] = failStatus;
  } else {
    be.routes['/editors'] = sampleEditors();
  }
  return openSettings(tester, backend: be, prefs: prefs);
}

void main() {
  setUpAll(loadBrandFonts);
  setUp(() => haroOverlayDepth.value = 0);

  testWidgets('the select lists only available editors plus Ask every time', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('Used by Open in…'), findsOneWidget);
    final select = tester.widget<SettingSelect<String>>(_select);
    expect(select.onChanged, isNotNull);
    expect(select.options.map((o) => o.$2), [
      'Ask every time',
      'Zed',
      'Neovim',
      'Files',
    ]);
    expect(select.value, 'ask');

    await _tapSelect(tester);
    expect(find.text('VS Code'), findsNothing);
    expect(find.text('Zed'), findsOneWidget);
  });

  testWidgets('picking an editor persists preferred_editor on Save', (
    tester,
  ) async {
    final o = await _open(tester);
    await _tapSelect(tester);
    await tester.tap(find.text('Zed'));
    await tester.pumpAndSettle();
    expect(o.prefs.data['display'], isNull, reason: 'not saved yet');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((o.prefs.data['display'] as Map)['preferred_editor'], 'zed');
  });

  testWidgets('a stored choice is shown, and one no longer installed says so', (
    tester,
  ) async {
    await _open(
      tester,
      prefs: MemoryDevicePrefsStore({
        'display': {'preferred_editor': 'vscode'},
      }),
    );
    final select = tester.widget<SettingSelect<String>>(_select);
    expect(select.value, 'vscode');
    expect(find.text('vscode (not found)'), findsOneWidget);
  });

  testWidgets('a backend without /editors: reason in the help, control dim', (
    tester,
  ) async {
    await _open(tester, failStatus: 404);
    expect(find.text('Used by Open in…'), findsNothing);
    expect(find.text('backend said no'), findsOneWidget);
    final select = tester.widget<SettingSelect<String>>(_select);
    expect(select.onChanged, isNull);
    expect(
      tester
          .widget<Opacity>(
            find.descendant(of: _select, matching: find.byType(Opacity)),
          )
          .opacity,
      lessThan(1),
    );
    await _tapSelect(tester);
    expect(find.text('Zed'), findsNothing, reason: 'nothing to open');
  });

  testWidgets('no detected editors leaves the row off with a reason', (
    tester,
  ) async {
    final be = FakeBackend()
      ..routes['/editors'] = [editor('zed', 'Zed', 'gui', available: false)];
    await openSettings(tester, backend: be);
    expect(find.text('No editors found on this machine'), findsOneWidget);
    expect(tester.widget<SettingSelect<String>>(_select).onChanged, isNull);
  });

  testWidgets('no overflow at 960x640', (tester) async {
    await openSettings(
      tester,
      backend: FakeBackend()..routes['/editors'] = sampleEditors(),
      size: const Size(960, 640),
    );
    expect(tester.takeException(), isNull);
  });
}
