import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/workspace/header/workspace_header.dart';
import 'package:haro_app/features/workspace/rail/workspace_rail.dart';
import 'package:haro_app/shell/shell_layout.dart';
import 'package:haro_app/shell/sidebar.dart';

import 'package:haro_app/features/settings/controls/toggle.dart';

import 'package:haro_app/shell/haro_shell.dart';
import 'package:haro_app/shell/shell_models.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:window_manager/window_manager.dart';

import 'harness.dart';
import 'steps/code/code_harness.dart';

import 'package:haro_app/features/workspace/steps/code/workbench/side_panel.dart';

Future<void> _toggleMinimal(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await tester.sendKeyEvent(LogicalKeyboardKey.period);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await tester.pumpAndSettle();
}

Rig _minimalRig(Preview p) {
  final rig = Rig(p);
  rig.prefs = MemoryDevicePrefsStore({
    'shell': {'minimal': true},
  });
  return rig;
}

void main() {
  group('shell layout state', () {
    test('minimal persists; peeks are session only and need minimal', () async {
      final store = MemoryDevicePrefsStore();
      final c = ProviderContainer(
        overrides: [devicePrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(shellLayoutProvider.notifier);

      n.peekSidebar(true);
      expect(c.read(shellLayoutProvider).peekSidebar, isFalse);

      n.setMinimal(true);
      n.peekSidebar(true);
      n.peekRail(true);
      expect(c.read(shellLayoutProvider).peekSidebar, isTrue);
      expect(c.read(shellLayoutProvider).peekRail, isTrue);

      n.peekSidebar(false);
      expect(c.read(shellLayoutProvider).peekSidebar, isFalse);

      n.toggleSidebar();
      expect(c.read(shellLayoutProvider).peekSidebar, isTrue);
      expect(c.read(shellLayoutProvider).sidebarOpen, isTrue);
      n.toggleSidebar();
      expect(c.read(shellLayoutProvider).peekSidebar, isFalse);

      n.setMinimal(false);
      expect(c.read(shellLayoutProvider).peekRail, isFalse);
      n.setMinimal(true);
      await n.writesSettled;
      expect((store.data['shell'] as Map)['minimal'], isTrue);
      expect((store.data['shell'] as Map)['sidebar_open'], isTrue);
      n.setMinimal(false);
      await n.writesSettled;
      expect((store.data['shell'] as Map).containsKey('minimal'), isFalse);
    });

    test('the sidebar and rail flags survive a round trip through minimal', () {
      final c = ProviderContainer(
        overrides: [
          devicePrefsStoreProvider.overrideWithValue(MemoryDevicePrefsStore()),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(shellLayoutProvider.notifier);
      n.toggleSidebar();
      n.setMinimal(true);
      n.setMinimal(false);
      expect(c.read(shellLayoutProvider).sidebarOpen, isFalse);
      expect(c.read(shellLayoutProvider).railOpen, isTrue);
    });
  });

  group('workspace in minimal view', () {
    testWidgets('one slim strip replaces the header and the step bar', (
      tester,
    ) async {
      await _minimalRig(Preview.green).pump(tester, step: 'code');
      expect(find.byKey(const ValueKey('minimal-strip')), findsOneWidget);
      expect(find.byType(WorkspaceHeader), findsNothing);
      expect(find.byKey(const ValueKey('minimal-step-name')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('minimal-step-name')))
            .data,
        'code',
      );
      expect(find.byKey(const ValueKey('minimal-gate')), findsOneWidget);
      expect(find.byKey(const ValueKey('step-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('next-action')), findsOneWidget);
    });

    testWidgets('Back and Proceed in the strip move between steps', (
      tester,
    ) async {
      final rig = _minimalRig(Preview.green);
      final router = await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('next-action')));
      await tester.pumpAndSettle();
      expect(pathOf(router), '/w/$id/verify');
      await tester.tap(find.byKey(const ValueKey('step-back')));
      await tester.pumpAndSettle();
      expect(pathOf(router), '/w/$id/code');
    });

    testWidgets('the sidebar and the rail are tucked away', (tester) async {
      await _minimalRig(Preview.green).pump(tester, step: 'verify');
      expect(find.byType(Sidebar), findsNothing);
      expect(find.byType(WorkspaceRail), findsNothing);
      expect(find.byKey(const ValueKey('top-settings')), findsOneWidget);
      expect(find.byKey(const ValueKey('top-search-compact')), findsOneWidget);
      expect(find.byKey(const ValueKey('top-need-you-square')), findsOneWidget);
      expect(find.byKey(const ValueKey('status-bar')), findsNothing);
    });

    testWidgets(
      'the pointer on a window edge slides that panel in, leaving closes',
      (tester) async {
        await _minimalRig(Preview.green).pump(tester, step: 'verify');
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(700, 400));
        await tester.pump();

        final stripWidth = tester
            .getSize(find.byKey(const ValueKey('minimal-strip')))
            .width;

        await mouse.moveTo(const Offset(15, 400));
        await tester.pumpAndSettle();
        expect(find.byType(Sidebar), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('minimal-strip'))).width,
          stripWidth,
          reason: 'the sidebar lies over the page, the page does not resize',
        );

        await mouse.moveTo(const Offset(700, 400));
        await tester.pumpAndSettle();
        expect(find.byType(Sidebar), findsNothing);

        await mouse.moveTo(const Offset(1385, 400));
        await tester.pumpAndSettle();
        expect(find.byType(WorkspaceRail), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('minimal-strip'))).width,
          stripWidth,
          reason: 'the rail lies over the page, the page does not resize',
        );

        await mouse.moveTo(const Offset(500, 400));
        await tester.pumpAndSettle();
        expect(find.byType(WorkspaceRail), findsNothing);
      },
    );

    testWidgets('the MINIMAL button and the shortcut toggle the view', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester, step: 'verify');
      expect(find.byKey(const ValueKey('minimal-strip')), findsNothing);
      expect(find.byType(Sidebar), findsOneWidget);

      await _toggleMinimal(tester);
      expect(find.byKey(const ValueKey('minimal-strip')), findsOneWidget);
      expect(find.byType(Sidebar), findsNothing);

      await tester.tap(find.byKey(const ValueKey('sidebar-toggle')));
      await tester.pumpAndSettle();
      expect(find.byType(Sidebar), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sidebar-toggle')));
      await tester.pumpAndSettle();
      expect(find.byType(Sidebar), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.period);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('minimal-strip')), findsNothing);
      expect(find.byType(Sidebar), findsOneWidget);
      expect(find.byType(WorkspaceHeader), findsOneWidget);
    });
  });

  group('Settings > Display', () {
    testWidgets('the Minimal UI row turns it on and off at once', (
      tester,
    ) async {
      await Rig(Preview.green).pump(tester, step: 'verify');
      expect(find.byKey(const ValueKey('minimal-strip')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('top-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Minimal UI'), findsOneWidget);
      final toggle = find.byWidgetPredicate(
        (w) => w is SettingToggle && w.semanticLabel == 'Minimal UI',
      );
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SettingToggle>(toggle).value, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('minimal-strip')), findsOneWidget);
    });
  });

  testWidgets(
    'inside the window resize handles, the edge target still catches the pointer',
    (tester) async {
      final peeks = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaroTheme(),
          home: DragToResizeArea(
            child: HaroShell(
              data: const ShellData(
                triageCount: 0,
                backlogOpen: 0,
                needYouCount: 0,
                projects: [],
              ),
              actions: ShellActions(
                onPeekSidebar: (on) => peeks.add('left:$on'),
                onPeekRail: (on) => peeks.add('right:$on'),
              ),
              crumb1: 'haro',
              minimal: true,
              railPeekable: true,
              draggable: false,
              macTrafficLights: false,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 300));
      await tester.pump();
      await mouse.moveTo(const Offset(3, 300));
      await tester.pump();
      expect(
        peeks,
        isEmpty,
        reason: 'the outer 8px belong to the resize handle',
      );
      await mouse.moveTo(const Offset(14, 300));
      await tester.pump();
      expect(peeks, ['left:true']);
      await mouse.moveTo(const Offset(790, 300));
      await tester.pump();
      expect(peeks, ['left:true', 'right:true']);
    },
  );

  group('code step in minimal view', () {
    testWidgets('the side panel is closed, and comes back when it ends', (
      tester,
    ) async {
      final rig = CodeRig();
      rig.prefs = MemoryDevicePrefsStore({
        'shell': {'minimal': true},
      });
      await rig.pump(tester, step: 'code');
      expect(find.byType(SidePanel), findsNothing);

      await _toggleMinimal(tester);
      expect(find.byType(SidePanel), findsOneWidget);
    });

    testWidgets(
      'closing and opening it in minimal view leaves the full view alone',
      (tester) async {
        final rig = CodeRig();
        await rig.pump(tester, step: 'code');
        expect(find.byType(SidePanel), findsOneWidget);

        await _toggleMinimal(tester);
        expect(find.byType(SidePanel), findsNothing);

        await tester.tap(find.byKey(const ValueKey('activity:files')));
        await tester.pumpAndSettle();
        expect(find.byType(SidePanel), findsOneWidget);

        await _toggleMinimal(tester);
        expect(
          find.byType(SidePanel),
          findsOneWidget,
          reason: 'it was open before',
        );

        await tester.tap(find.byKey(const ValueKey('activity:files')));
        await tester.pumpAndSettle();
        expect(find.byType(SidePanel), findsNothing);
        await _toggleMinimal(tester);
        expect(
          find.byType(SidePanel),
          findsNothing,
          reason: 'closed before, closed after',
        );
      },
    );
  });
}
