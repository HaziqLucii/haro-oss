import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/backend/backend_health.dart';

import 'fake_shell_data.dart';

import 'package:haro_app/shell/haro_shell.dart';
import 'package:haro_app/shell/shell_models.dart';
import 'package:haro_app/shell/sidebar_fold.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/theme/haro_theme.dart';

Widget _app({
  ShellData data = fakeShellData,
  ShellActions actions = const ShellActions(),
  BackendStatus status = BackendStatus.up,
  bool mac = false,
  String crumb2 = 'electron optimization',
}) => MaterialApp(
  theme: buildHaroTheme(),
  home: HaroShell(
    data: data,
    actions: actions,
    crumb1: 'haro',
    crumb2: crumb2,
    selectedWorkspaceId: 'mutation-gate',
    backendStatus: status,
    backendHost: '127.0.0.1:8000',
    macTrafficLights: mac,
    draggable: false,
    child: const SizedBox.expand(),
  ),
);

/// The shell with the real fold notifier behind it, the way ShellHost wires it.
Widget _foldApp({
  String? selected = 'mutation-gate',
  ShellData data = fakeShellData,
}) => ProviderScope(
  child: MaterialApp(
    theme: buildHaroTheme(),
    home: _FoldShell(data: data, selected: selected),
  ),
);

class _FoldShell extends ConsumerWidget {
  const _FoldShell({required this.data, required this.selected});

  final ShellData data;
  final String? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(sidebarFoldProvider.notifier);
    return HaroShell(
      data: data,
      actions: ShellActions(
        onToggleProject: notifier.toggleProject,
        onToggleMerged: notifier.toggleMerged,
      ),
      fold: ref.watch(sidebarFoldProvider),
      crumb1: 'haro',
      selectedWorkspaceId: selected,
      macTrafficLights: false,
      draggable: false,
      child: const SizedBox.expand(),
    );
  }
}

void main() {
  for (final size in const [Size(900, 640), Size(960, 640)]) {
    for (final mac in [false, true]) {
      testWidgets(
        'no overflow at ${size.width.toInt()}x${size.height.toInt()} mac=$mac',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(_app(mac: mac, status: BackendStatus.down));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('long names and a big count do not overflow', (tester) async {
    tester.view.physicalSize = const Size(960, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const long =
        'a very long workspace name that must be truncated with an ellipsis';
    await tester.pumpWidget(
      _app(
        crumb2: long * 3,
        mac: true,
        data: const ShellData(
          triageCount: 1234,
          backlogOpen: 5678,
          needYouCount: 999,
          projects: [
            SidebarProject(
              id: 'p',
              name: 'a-very-long-project-name-indeed',
              workspaces: [
                SidebarWorkspace(
                  id: 'w',
                  name: long,
                  state: DisplayState.green,
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('fires callbacks', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <String>[];
    await tester.pumpWidget(
      _app(
        actions: ShellActions(
          onSettings: () => calls.add('settings'),
          onOpenWorkspace: (id) => calls.add('open:$id'),
          onNewWorkspace: (id) => calls.add('new:$id'),
          onAddProject: () => calls.add('add'),
          onNeedYou: () => calls.add('need'),
        ),
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.tap(find.text('verified hunks'));
    await tester.tap(find.text('New workspace'));
    await tester.tap(find.text('Add project'));
    await tester.tap(find.textContaining('NEED YOU'));
    await tester.tap(find.text('+').first);
    expect(calls, [
      'settings',
      'open:verified-hunks',
      'new:null',
      'add',
      'need',
      'new:haro',
    ]);
  });

  testWidgets('backend note shows only when down', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(status: BackendStatus.down));
    expect(find.text('BACKEND DOWN'), findsOneWidget);
    await tester.pumpWidget(_app(status: BackendStatus.up));
    expect(find.text('BACKEND DOWN'), findsNothing);
  });

  testWidgets('Dashboard and Backlog carry no count', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Backlog'), findsOneWidget);
    expect(find.text('10'), findsNothing);
    expect(find.text('52 open'), findsNothing);
  });

  testWidgets(
    'red and green rows are wordless, an agent run reads in progress',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          data: const ShellData(
            triageCount: 0,
            backlogOpen: 0,
            needYouCount: 0,
            projects: [
              SidebarProject(
                id: 'p',
                name: 'p',
                workspaces: [
                  SidebarWorkspace(
                    id: 'a',
                    name: 'one',
                    state: DisplayState.red,
                  ),
                  SidebarWorkspace(
                    id: 'b',
                    name: 'two',
                    state: DisplayState.green,
                  ),
                  SidebarWorkspace(
                    id: 'c',
                    name: 'three',
                    state: DisplayState.agent,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      expect(find.text('red'), findsNothing);
      expect(find.text('green'), findsNothing);
      expect(find.text('agent'), findsNothing);
      expect(find.text('in progress'), findsOneWidget);
    },
  );

  testWidgets('idle rows show no state word, merged rows are dimmed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_foldApp());
    expect(find.text('merged'), findsNothing);
    await tester.tap(find.text('2 MERGED'));
    await tester.pumpAndSettle();
    expect(find.text('idle'), findsNothing);
    expect(find.text('merged'), findsNWidgets(2));
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('kuro theme'), matching: find.byType(Opacity))
          .first,
    );
    expect(opacity.opacity, .55);
  });

  group('sidebar fold', () {
    Finder headerOf(String id) => find.byKey(ValueKey('project-header-$id'));

    Future<void> pumpFold(
      WidgetTester tester, {
      String? selected = 'mutation-gate',
    }) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_foldApp(selected: selected));
      await tester.pumpAndSettle();
    }

    testWidgets('merged workspaces are one line until you open it', (
      tester,
    ) async {
      await pumpFold(tester);
      expect(find.text('kuro theme'), findsNothing);
      expect(find.text('2 MERGED'), findsOneWidget);
      await tester.tap(find.text('2 MERGED'));
      await tester.pumpAndSettle();
      expect(find.text('kuro theme'), findsOneWidget);
      expect(find.text('live gate'), findsOneWidget);
      await tester.tap(find.text('HIDE MERGED'));
      await tester.pumpAndSettle();
      expect(find.text('kuro theme'), findsNothing);
    });

    testWidgets(
      'a project folds to its header and a count, keeping the open and the live ones',
      (tester) async {
        await pumpFold(tester, selected: 'verified-hunks');
        expect(find.text('electron optimization'), findsOneWidget);
        await tester.tap(headerOf('haro'));
        await tester.pumpAndSettle();
        // idle, green and merged ones go; the open one, a plan and a gate at work stay
        expect(find.text('electron optimization'), findsNothing);
        expect(find.text('jev research'), findsNothing);
        expect(find.text('2 MERGED'), findsNothing);
        expect(find.text('verified hunks'), findsOneWidget);
        expect(find.text('linux attraction'), findsOneWidget);
        expect(find.text('mutation gate'), findsOneWidget);
        expect(find.text('7'), findsOneWidget);
        expect(find.text('free shipping threshold'), findsOneWidget);
        await tester.tap(headerOf('haro'));
        await tester.pumpAndSettle();
        expect(find.text('electron optimization'), findsOneWidget);
      },
    );

    testWidgets('folding one project leaves the others alone', (tester) async {
      await pumpFold(tester, selected: null);
      await tester.tap(headerOf('gate-sandbox'));
      await tester.pumpAndSettle();
      expect(find.text('agent-haro'), findsNothing);
      expect(find.text('free shipping threshold'), findsOneWidget);
      expect(find.text('electron optimization'), findsOneWidget);
    });

    testWidgets(
      'the open merged workspace stays listed while merged is hidden',
      (tester) async {
        await pumpFold(tester, selected: 'kuro-theme');
        expect(find.text('kuro theme'), findsOneWidget);
        expect(find.text('live gate'), findsNothing);
        expect(find.text('1 MERGED'), findsOneWidget);
      },
    );

    testWidgets('no overflow at the smallest window', (tester) async {
      tester.view.physicalSize = const Size(960, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_foldApp());
      await tester.tap(headerOf('haro'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
