import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart' show WorkspaceMode;
import 'package:haro_app/overlays/command_palette.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:haro_app/overlays/palette_model.dart';
import 'package:haro_app/shell/shell_models.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:haro_app/shortcuts/platform_keys.dart';
import 'package:haro_app/state/display_state.dart';

import '../shell/fake_shell_data.dart';
import '../shortcuts/app_harness.dart';

Future<void> _openPalette(WidgetTester tester, ProviderContainer c) async {
  c.read(appCommandsProvider).openPalette();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => haroOverlayDepth.value = 0);

  group('filterPalette', () {
    final items = buildPaletteItems(
      data: fakeShellData,
      commands: () => const AppCommands(),
      openWorkspace: (_, _) {},
      modifier: PrimaryModifier.meta,
    );

    List<String> labels(String q) => [
      for (final g in filterPalette(items, q)) ...g.$2.map((i) => i.label),
    ];

    test('empty query lists everything grouped in order', () {
      final groups = filterPalette(items, '');
      expect(groups.map((g) => g.$1), PaletteGroup.values);
      expect(groups[1].$2.map((i) => i.label), [
        'Next workspace that needs you',
        'New workspace',
        'Run gate',
        'Capture a todo',
        'Open backlog',
        'Toggle terminal',
        'Toggle sidebar',
        'Open the guide',
        'Keyboard shortcuts',
        'Delete merged workspaces',
        for (final p in fakeShellData.projects) 'Remove project · ${p.name}',
      ]);
      expect(groups[2].$2, hasLength(SettingsTab.values.length));
    });

    test('the mode switch is offered only with a workspace open', () {
      List<PaletteItem> build(WorkspaceMode? mode) => buildPaletteItems(
        data: fakeShellData,
        commands: () => const AppCommands(),
        openWorkspace: (_, _) {},
        modifier: PrimaryModifier.meta,
        openWorkspaceMode: mode,
      );
      String? label(List<PaletteItem> l) => [
        for (final i in l)
          if (i.id == 'action:switch-mode') i.label,
      ].firstOrNull;

      expect(label(build(null)), isNull);
      expect(label(build(WorkspaceMode.agent)), 'Switch to Manual mode');
      expect(label(build(WorkspaceMode.manual)), 'Switch to Agent mode');
    });

    test('running the mode item asks for the opposite mode', () {
      WorkspaceMode? asked;
      final item = buildPaletteItems(
        data: fakeShellData,
        commands: () => AppCommands(setWorkspaceMode: (m) => asked = m),
        openWorkspace: (_, _) {},
        openWorkspaceMode: WorkspaceMode.manual,
      ).firstWhere((i) => i.id == 'action:switch-mode');
      item.run();
      expect(asked, WorkspaceMode.agent);
    });

    test('fuzzy filters across groups and drops empty groups', () {
      final groups = filterPalette(items, 'mutgate');
      expect(groups, hasLength(1));
      expect(groups.single.$1, PaletteGroup.workspaces);
      expect(groups.single.$2.single.label, 'mutation gate');
    });

    test('a settings tab is reachable by name', () {
      expect(labels('notif'), contains('Notifications'));
    });

    test('the project name narrows workspaces', () {
      final hits = filterPalette(items, 'sandbox ship').first.$2;
      expect(hits.map((i) => i.label), [
        'shipping cost calculator',
        'free shipping threshold',
      ]);
    });

    test('scattered letters across label and meta do not match', () {
      final groups = filterPalette(items, 'run gate');
      expect(groups, hasLength(1));
      expect(groups.single.$2.single.label, 'Run gate');
    });

    test('no match yields nothing', () {
      expect(filterPalette(items, 'qqqq'), isEmpty);
    });

    test('shortcut hints follow the platform', () {
      final linux = buildPaletteItems(
        data: fakeShellData,
        commands: () => const AppCommands(),
        openWorkspace: (_, _) {},
        modifier: PrimaryModifier.control,
      );
      String meta(List<PaletteItem> l, String label) =>
          l.firstWhere((i) => i.label == label).meta;
      expect(meta(items, 'Next workspace that needs you'), '⌘J');
      expect(meta(linux, 'Next workspace that needs you'), 'Ctrl+J');
      expect(meta(items, 'Toggle terminal'), '⌃`');
      expect(meta(linux, 'Toggle terminal'), 'Ctrl+`');
    });

    test('workspace items open on their default step', () {
      String? opened;
      final list = buildPaletteItems(
        data: const ShellData(
          triageCount: 1,
          backlogOpen: 0,
          needYouCount: 0,
          projects: [
            SidebarProject(
              id: 'p',
              name: 'p',
              workspaces: [
                SidebarWorkspace(
                  id: 'w1',
                  name: 'one',
                  state: DisplayState.red,
                ),
              ],
            ),
          ],
        ),
        commands: () => const AppCommands(),
        openWorkspace: (id, step) => opened = '$id/$step',
      );
      list.first.run();
      expect(opened, 'w1/agent');
    });
  });

  group('palette widget', () {
    testWidgets('opens with the placeholder and footer, Esc closes', (
      tester,
    ) async {
      final (_, c) = await pumpApp(tester);
      await _openPalette(tester, c);
      expect(
        find.text('Jump to a workspace, run an action, open a setting…'),
        findsOneWidget,
      );
      expect(find.text('↑↓ move'), findsOneWidget);
      expect(find.text('↵ open'), findsOneWidget);
      expect(find.text('esc close'), findsOneWidget);
      expect(find.text('WORKSPACES'), findsOneWidget);
      expect(find.text('ACTIONS'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(CommandPalette), findsNothing);
    });

    testWidgets('typing filters the list', (tester) async {
      final (_, c) = await pumpApp(tester);
      await _openPalette(tester, c);
      await tester.enterText(find.byType(TextField), 'verified');
      await tester.pumpAndSettle();
      final palette = find.byType(CommandPalette);
      expect(
        find.descendant(of: palette, matching: find.text('verified hunks')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: palette, matching: find.text('mutation gate')),
        findsNothing,
      );
      expect(find.text('ACTIONS'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzzzq');
      await tester.pumpAndSettle();
      expect(find.text('NO MATCHES'), findsOneWidget);
    });

    testWidgets('arrows move, enter on a workspace navigates', (tester) async {
      final (router, c) = await pumpApp(tester);
      await _openPalette(tester, c);
      await tester.enterText(find.byType(TextField), 'shipping');
      await tester.pumpAndSettle();
      // Two workspaces match; down moves to the second, up back to the first.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.byType(CommandPalette), findsNothing);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/w/shipping-cost-calculator/agent',
      );
    });

    testWidgets('clicking a workspace navigates', (tester) async {
      final (router, c) = await pumpApp(tester);
      await _openPalette(tester, c);
      await tester.tap(find.text('kuro theme').last);
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/w/kuro-theme/agent',
      );
    });

    testWidgets('an action runs the registered callback after closing', (
      tester,
    ) async {
      final (_, c) = await pumpApp(tester);
      var ran = 0;
      c
          .read(appCommandsProvider.notifier)
          .register((cmds) => cmds.copyWith(runGate: () => ran++));
      await _openPalette(tester, c);
      await tester.enterText(find.byType(TextField), 'run gate');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(ran, 1);
      expect(find.byType(CommandPalette), findsNothing);
    });

    testWidgets('a settings entry deep-links with its tab', (tester) async {
      final (_, c) = await pumpApp(tester);
      SettingsTab? tab;
      c
          .read(appCommandsProvider.notifier)
          .register((cmds) => cmds.copyWith(openSettings: (t) => tab = t));
      await _openPalette(tester, c);
      await tester.enterText(find.byType(TextField), 'instructions');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tab, SettingsTab.instructions);
    });

    testWidgets('unbuilt actions are safe no-ops', (tester) async {
      final (_, c) = await pumpApp(tester);
      await _openPalette(tester, c);
      await tester.enterText(find.byType(TextField), 'delete merged');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CommandPalette), findsNothing);
    });

    testWidgets('keyboard shortcuts action swaps to the shortcuts overlay', (
      tester,
    ) async {
      final (_, c) = await pumpApp(tester);
      await _openPalette(tester, c);
      await tester.enterText(find.byType(TextField), 'keyboard');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsOneWidget);
      expect(find.byType(CommandPalette), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
