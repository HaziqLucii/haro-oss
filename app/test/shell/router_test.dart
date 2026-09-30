import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';
import 'package:haro_app/shell/shell_providers.dart';

import '../features/workspace/harness.dart';
import 'fake_shell_data.dart';

void main() {
  testWidgets('routes render inside the shell', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = buildRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellDataProvider.overrideWithValue(fakeShellData),
          devicePrefsStoreProvider.overrideWithValue(MemoryDevicePrefsStore()),
          workspaceDetailProvider.overrideWith2(
            (wsId) => FixedDetail(wsId, WorkspaceDetail(id: wsId)),
          ),
          backendStatusProvider.overrideWith(
            (ref) => Stream.value(BackendStatus.up),
          ),
        ],
        child: HaroApp(router: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('TRIAGE'), findsWidgets);

    router.go('/w/mutation-gate/verify');
    await tester.pumpAndSettle();
    expect(find.text('LOADING WORKSPACE'), findsOneWidget);

    router.go('/first-run');
    await tester.pumpAndSettle();
    expect(find.text('FIRST RUN'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
