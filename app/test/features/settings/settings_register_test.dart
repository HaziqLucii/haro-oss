import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/settings_layers.dart';
import 'package:haro_app/features/settings/settings_register.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:haro_app/theme/haro_theme.dart';

import '../../api/fixtures.dart';
import 'settings_harness.dart';

class _FakeStore extends WorkspaceStore {
  @override
  WorkspaceSnapshot build() => WorkspaceSnapshot(
    loaded: true,
    projects: const [proj1, proj2],
    workspaces: {
      'p1': const [],
      'p2': [Workspace.fromJson(workspaceJson(id: 'w_sand'))],
    },
  );
}

class _Host extends ConsumerStatefulWidget {
  const _Host();

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  static WidgetRef? lastRef;

  @override
  void initState() {
    super.initState();
    lastRef = ref;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => registerSettingsCommands(ref, () => context),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  setUpAll(loadBrandFonts);

  Future<ProviderContainer> pump(WidgetTester tester, String location) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    haroOverlayDepth.value = 0;
    final backend = FakeBackend();
    backend.routes['/projects/p2/gate'] = {...gateJson(), 'gate_dir': 'web'};
    final container = ProviderContainer(
      overrides: [
        workspaceStoreProvider.overrideWith(_FakeStore.new),
        haroApiProvider.overrideWithValue(backend.api()),
        devicePrefsStoreProvider.overrideWithValue(MemoryDevicePrefsStore()),
        settingsLayersProvider.overrideWithValue(FakeLayers()),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(path: '/', builder: (_, _) => const _Host()),
        GoRoute(path: '/w/:id/:step', builder: (_, _) => const _Host()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildHaroTheme(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
    'off a workspace a project deep link waits for a pick, then lands on it',
    (tester) async {
      final c = await pump(tester, '/');
      c.read(appCommandsProvider).openSettings(SettingsTab.gate);
      await tester.pumpAndSettle();
      expect(find.text('Search settings'), findsOneWidget);
      expect(find.text('PROJECT · CHOOSE'), findsOneWidget);
      expect(find.textContaining('every Vitest test'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('project-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('haro · /x/haro'));
      await tester.pumpAndSettle();
      expect(find.text('Gate · haro'), findsOneWidget);
      expect(
        find.textContaining(
          'every Vitest test in frontend/ passes',
          findRichText: true,
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('openSettingsFor opens the given project on the requested tab', (
    tester,
  ) async {
    final c = await pump(tester, '/');
    final ctx = tester.element(find.byType(_Host));
    final ref = _HostState.lastRef!;
    openSettingsFor(ref, ctx, tab: SettingsTab.gate, projectId: 'p2');
    await tester.pumpAndSettle();
    expect(find.text('Gate · sandbox'), findsOneWidget);
    expect(find.text('PROJECT · SANDBOX'), findsOneWidget);
    expect(
      find.textContaining(
        'every Vitest test in web/ passes',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(c, isNotNull);
  });

  testWidgets('on a workspace route the current project is that workspace\'s', (
    tester,
  ) async {
    final c = await pump(tester, '/w/w_sand/verify');
    c.read(appCommandsProvider).openSettings(SettingsTab.gate);
    await tester.pumpAndSettle();
    expect(find.text('PROJECT · SANDBOX'), findsOneWidget);
    expect(find.text('Gate · sandbox'), findsOneWidget);
    expect(
      find.textContaining(
        'every Vitest test in web/ passes',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });
}
