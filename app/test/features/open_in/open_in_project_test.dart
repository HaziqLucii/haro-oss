import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/open_in/open_in_button.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'open_in_harness.dart';

class FakeProjectBackend {
  final opens = <Map<String, dynamic>>[];
  int? openStatus;
  String openDetail = 'Zed is not available on this machine';

  Future<http.Response> handle(http.Request r) async {
    http.Response json(Object v, [int s = 200]) => http.Response(
      jsonEncode(v),
      s,
      headers: {'content-type': 'application/json'},
    );
    if (r.method == 'GET' && r.url.path == '/editors') {
      return json(sampleEditors());
    }
    if (r.method == 'POST' && r.url.path == '/projects/p1/open') {
      opens.add(Map<String, dynamic>.from(jsonDecode(r.body) as Map));
      final s = openStatus;
      if (s != null) return json({'detail': openDetail}, s);
      return json({'mode': 'spawned', 'command': null});
    }
    return json({'detail': 'Not Found'}, 404);
  }
}

Future<FakeProjectBackend> pumpLink(
  WidgetTester tester, {
  String? preferred,
}) async {
  final backend = FakeProjectBackend();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        haroApiProvider.overrideWithValue(
          HaroApi(
            Uri.parse('http://127.0.0.1:8000'),
            client: MockClient(backend.handle),
          ),
        ),
        devicePrefsStoreProvider.overrideWithValue(
          MemoryDevicePrefsStore({
            'display': {'preferred_editor': ?preferred},
          }),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(
            child: ProjectFileOpenLink(
              projectId: 'p1',
              path: '.haro/instructions.md',
            ),
          ),
        ),
      ),
    ),
  );
  await settleOpen(tester);
  return backend;
}

void main() {
  setUp(() => haroOverlayDepth.value = 0);

  testWidgets('a preferred GUI editor opens the project file straight away', (
    tester,
  ) async {
    final be = await pumpLink(tester, preferred: 'zed');
    await tester.tap(find.text('Open in editor ↗'));
    await settleOpen(tester);
    expect(be.opens, [
      {'target': 'zed', 'path': '.haro/instructions.md'},
    ]);
  });

  testWidgets(
    'with no preference it asks, and never offers a terminal editor',
    (tester) async {
      final be = await pumpLink(tester);
      await tester.tap(find.text('Open in editor ↗'));
      await settleOpen(tester);
      expect(be.opens, isEmpty);
      expect(find.text('Zed'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Neovim'), findsNothing);
      await tester.tap(find.text('Zed'));
      await settleOpen(tester);
      expect(be.opens.single['target'], 'zed');
    },
  );

  testWidgets('a terminal editor preference falls back to the menu', (
    tester,
  ) async {
    final be = await pumpLink(tester, preferred: 'neovim');
    await tester.tap(find.text('Open in editor ↗'));
    await settleOpen(tester);
    expect(be.opens, isEmpty);
    expect(find.text('Zed'), findsOneWidget);
    expect(find.text('Neovim'), findsNothing);
  });

  testWidgets('a refused open shows the backend message beside the button', (
    tester,
  ) async {
    final be = await pumpLink(tester, preferred: 'zed');
    be.openStatus = 400;
    await tester.tap(find.text('Open in editor ↗'));
    await settleOpen(tester);
    expect(
      find.byKey(
        const ValueKey('open-in-notice-project:.haro/instructions.md'),
      ),
      findsOneWidget,
    );
  });
}
