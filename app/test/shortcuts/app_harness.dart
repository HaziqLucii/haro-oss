import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';
import 'package:haro_app/shell/shell_models.dart' show ShellData;
import 'package:haro_app/shell/shell_providers.dart';
import 'package:haro_app/shortcuts/need_you.dart';

import '../features/workspace/harness.dart' show FixedDetail;
import '../shell/fake_shell_data.dart';

const needYouFixture = ['linux-attraction', 'electron-optimization'];

/// The real app (router + shell) over fake data, so the palette and shortcuts run in place.
Future<(GoRouter, ProviderContainer)> pumpApp(
  WidgetTester tester, {
  String initialLocation = '/',
  List<String> needYou = needYouFixture,
  ShellData shellData = fakeShellData,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(initialLocation: initialLocation);
  final container = ProviderContainer(
    overrides: [
      shellDataProvider.overrideWithValue(shellData),
      devicePrefsStoreProvider.overrideWithValue(MemoryDevicePrefsStore()),
      needYouIdsProvider.overrideWithValue(needYou),
      // Workspace routes build the real page; keep it off the network and its keep-alive timer.
      workspaceDetailProvider.overrideWith2(
        (id) => FixedDetail(id, WorkspaceDetail(id: id)),
      ),
      backendStatusProvider.overrideWith(
        (ref) => Stream.value(BackendStatus.up),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: HaroApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router, container);
}
