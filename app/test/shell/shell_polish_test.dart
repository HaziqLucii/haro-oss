import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/workspace/rail/workspace_rail.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/features/workspace/terminal/bottom_panel.dart';
import 'package:haro_app/overlays/command_palette.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:haro_app/shell/focus_bar.dart';
import 'package:haro_app/shell/haro_shell.dart';
import 'package:haro_app/shell/shell_layout.dart';
import 'package:haro_app/shell/shell_models.dart';
import 'package:haro_app/shell/shell_slots.dart';
import 'package:haro_app/shell/sidebar.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:haro_app/shortcuts/key_bindings.dart';
import 'package:haro_app/shortcuts/platform_keys.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:re_editor/re_editor.dart';

import '../features/workspace/harness.dart';
import '../features/workspace/steps/code/code_harness.dart';
import 'fake_shell_data.dart';

ProviderContainer _container(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(HaroShell)));

Future<void> _chord(
  WidgetTester t,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.meta);
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shift);
  await t.sendKeyDownEvent(key);
  await t.sendKeyUpEvent(key);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shift);
  await t.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await t.pumpAndSettle();
}

Future<void> _focusChord(WidgetTester t) =>
    _chord(t, LogicalKeyboardKey.enter, shift: true);

Future<void> _esc(WidgetTester t) async {
  await t.sendKeyEvent(LogicalKeyboardKey.escape);
  await t.pumpAndSettle();
}

final _sidebarToggle = find.byKey(const ValueKey('sidebar-toggle'));
final _strip = find.byKey(const ValueKey('sidebar-strip'));
final _railStrip = find.byKey(const ValueKey('rail-strip'));
final _railCollapse = find.byKey(const ValueKey('rail-collapse'));
final _railExpand = find.byKey(const ValueKey('rail-expand'));
final _focusTitle = find.byKey(const ValueKey('focus-title'));
final _paletteInput = find.descendant(
  of: find.byType(CommandPalette),
  matching: find.byType(TextField),
);
Future<void> _openPaletteFor(WidgetTester t, String query) async {
  ProviderScope.containerOf(t.element(find.byType(HaroShell)))
      .read(appCommandsProvider)
      .openPalette();
  await t.pumpAndSettle();
  await t.enterText(_paletteInput, query);
  await t.pumpAndSettle();
}

final _statusBar = find.byKey(const ValueKey('status-bar'));

CodeLineEditingController _controller(WidgetTester t) =>
    t.widget<CodeEditor>(find.byType(CodeEditor)).controller!;

String _text(WidgetTester t, String key) =>
    t.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  setUpAll(() => codeEditorHighlighting = false);
  setUp(() => haroOverlayDepth.value = 0);

  group('collapse toggles', () {
    testWidgets('the menu button swaps the 220px sidebar for the 52px strip', (
      tester,
    ) async {
      await Rig(Preview.green).pump(tester);
      expect(tester.getSize(find.byType(Sidebar)).width, 220);
      expect(_strip, findsNothing);
      expect(find.text('Triage'), findsOneWidget);

      await tester.tap(_sidebarToggle);
      await tester.pumpAndSettle();
      expect(tester.getSize(_strip).width, 52);
      expect(find.byType(Sidebar), findsNothing);
      expect(find.text('Triage'), findsNothing);

      await tester.tap(_sidebarToggle);
      await tester.pumpAndSettle();
      expect(_strip, findsNothing);
      expect(tester.getSize(find.byType(Sidebar)).width, 220);
    });

    testWidgets('the strip has its own expand button', (tester) async {
      await Rig(Preview.green).pump(tester);
      await tester.tap(_sidebarToggle);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-expand')));
      await tester.pumpAndSettle();
      expect(_strip, findsNothing);
    });

    testWidgets('the rail folds to a 44px strip and back', (tester) async {
      await Rig(Preview.green).pump(tester);
      expect(tester.getSize(find.byType(WorkspaceRail)).width, 290);
      expect(_railStrip, findsNothing);

      await tester.tap(_railCollapse);
      await tester.pumpAndSettle();
      expect(tester.getSize(_railStrip).width, 44);
      expect(find.byType(WorkspaceRail), findsNothing);

      await tester.tap(_railExpand);
      await tester.pumpAndSettle();
      expect(_railStrip, findsNothing);
      expect(tester.getSize(find.byType(WorkspaceRail)).width, 290);
    });

    testWidgets('the fade never leaves two sidebars laid out', (tester) async {
      await Rig(Preview.green).pump(tester);
      await tester.tap(_sidebarToggle);
      await tester.pump(HaroTokens.fade ~/ 2);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('persistence', () {
    testWidgets('both collapse states are written to the device prefs', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester);
      await tester.tap(_sidebarToggle);
      await tester.pumpAndSettle();
      await tester.tap(_railCollapse);
      await tester.pumpAndSettle();
      expect(rig.prefs.data['shell'], {
        'sidebar_open': false,
        'rail_open': false,
      });
    });

    testWidgets('a saved state is restored on launch', (tester) async {
      final rig = Rig(Preview.green);
      rig.prefs.data['shell'] = {'sidebar_open': false, 'rail_open': false};
      await rig.pump(tester);
      expect(_strip, findsOneWidget);
      expect(_railStrip, findsOneWidget);
    });

    testWidgets('keys Settings owns survive a shell write', (tester) async {
      final rig = Rig(Preview.green);
      rig.prefs.data['display'] = {'density': 'compact'};
      await rig.pump(tester);
      await tester.tap(_sidebarToggle);
      await tester.pumpAndSettle();
      expect(rig.prefs.data['display'], {'density': 'compact'});
      expect((rig.prefs.data['shell'] as Map)['sidebar_open'], false);
    });

    test('no shell key means both open, and focus never persists', () async {
      final store = MemoryDevicePrefsStore();
      final c = ProviderContainer(
        overrides: [devicePrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      c.read(shellLayoutProvider);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(shellLayoutProvider).sidebarOpen, isTrue);
      expect(c.read(shellLayoutProvider).railOpen, isTrue);

      final n = c.read(shellLayoutProvider.notifier);
      n.enterFocus('w1');
      n.toggleRail();
      await n.writesSettled;
      expect(store.data['shell'], {'sidebar_open': true, 'rail_open': false});
    });
  });

  group('strip contents', () {
    testWidgets('one square per workspace, named in a tooltip, and a + at the '
        'foot', (tester) async {
      await Rig(Preview.green).pump(tester);
      await tester.tap(_sidebarToggle);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('strip-ws:ws_1')), findsOneWidget);
      expect(find.byTooltip('electron optimization · green'), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-new-workspace')), findsOneWidget);
      expect(find.byType(StripBadgeSlot), findsOneWidget);
    });

    testWidgets('clicking a square opens the workspace; + asks for a new one', (
      tester,
    ) async {
      final opened = <String>[];
      final asked = <String?>[];
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaroTheme(),
          home: HaroShell(
            data: fakeShellData,
            actions: ShellActions(
              onOpenWorkspace: opened.add,
              onNewWorkspace: asked.add,
            ),
            crumb1: 'haro',
            draggable: false,
            macTrafficLights: false,
            sidebarOpen: false,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('strip-ws:mutation-gate')));
      await tester.tap(find.byKey(const ValueKey('strip-new-workspace')));
      expect(opened, ['mutation-gate']);
      expect(asked, [null]);
    });

    testWidgets('a manual workspace wears a marker, an agent one does not', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaroTheme(),
          home: HaroShell(
            data: const ShellData(
              triageCount: 2,
              backlogOpen: 0,
              needYouCount: 0,
              projects: [
                SidebarProject(
                  id: 'p',
                  name: 'p',
                  workspaces: [
                    SidebarWorkspace(
                      id: 'a',
                      name: 'a',
                      state: DisplayState.idle,
                    ),
                    SidebarWorkspace(
                      id: 'm',
                      name: 'm',
                      state: DisplayState.idle,
                      mode: WorkspaceMode.manual,
                    ),
                  ],
                ),
              ],
            ),
            crumb1: 'p',
            draggable: false,
            macTrafficLights: false,
            sidebarOpen: false,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('strip-manual:m')), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-manual:a')), findsNothing);
    });

    testWidgets('the expanded sidebar reserves the XP footer slot', (
      tester,
    ) async {
      await Rig(Preview.green).pump(tester);
      expect(find.byType(SidebarFooterSlot), findsOneWidget);
    });

    testWidgets('the rail strip: gate square, eyes count, mode, terminal', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      await rig.pump(tester);
      await tester.tap(_railCollapse);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rail-strip-gate')), findsOneWidget);
      expect(_text(tester, 'rail-strip-eyes'), '2');
      expect(_text(tester, 'rail-strip-mode'), 'AGENT');
      expect(find.byKey(const ValueKey('rail-strip-terminal')), findsOneWidget);
      final box =
          tester
                  .widget<Container>(
                    find.byKey(const ValueKey('rail-strip-gate')),
                  )
                  .decoration!
              as BoxDecoration;
      expect(box.color, HaroTokens.gate);
    });

    testWidgets('the rail strip gate goes to verify, its terminal toggles', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      final router = await rig.pump(tester, step: 'agent');
      await tester.tap(_railCollapse);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rail-strip-terminal')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomPanel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rail-strip-gate')));
      await tester.pumpAndSettle();
      expect(pathOf(router), '/w/$id/verify');
    });

    testWidgets('a manual workspace reads MANUAL in the rail strip', (
      tester,
    ) async {
      await Rig(Preview.green, mode: WorkspaceMode.manual).pump(tester);
      await tester.tap(_railCollapse);
      await tester.pumpAndSettle();
      expect(_text(tester, 'rail-strip-mode'), 'MANUAL');
    });
  });

  group('focus mode', () {
    testWidgets('the chord hides the chrome and Esc brings it back', (
      tester,
    ) async {
      final rig = CodeRig();
      await rig.pump(tester, step: 'code');
      expect(_sidebarToggle, findsOneWidget);
      expect(find.byKey(const ValueKey('next-action')), findsOneWidget);

      await _focusChord(tester);
      expect(_sidebarToggle, findsNothing);
      expect(find.byType(Sidebar), findsNothing);
      expect(_strip, findsNothing);
      expect(find.byKey(const ValueKey('next-action')), findsNothing);
      expect(find.byType(WorkspaceRail), findsNothing);
      expect(_railStrip, findsNothing);
      expect(
        tester.getSize(find.byType(FocusBar)).height,
        HaroTokens.focusBarHeight,
      );
      expect(_statusBar, findsOneWidget);

      await _esc(tester);
      expect(_focusTitle, findsNothing);
      expect(_sidebarToggle, findsOneWidget);
      expect(find.byType(WorkspaceRail), findsOneWidget);
    });

    testWidgets('the same chord leaves it, and the bar names the step', (
      tester,
    ) async {
      final rig = CodeRig();
      await rig.pump(tester, step: 'code');
      await _focusChord(tester);
      expect(
        _text(tester, 'focus-title'),
        'ELECTRON OPTIMIZATION · 02 CODE · FOCUS',
      );
      expect(_text(tester, 'focus-gate'), 'GREEN');
      await _focusChord(tester);
      expect(_focusTitle, findsNothing);
    });

    testWidgets('manual mode is step 01', (tester) async {
      final rig = CodeRig(mode: WorkspaceMode.manual);
      await rig.pump(tester, step: 'code');
      await _focusChord(tester);
      expect(
        _text(tester, 'focus-title'),
        'ELECTRON OPTIMIZATION · 01 CODE · FOCUS',
      );
    });

    testWidgets('Exit focus on the bar leaves it', (tester) async {
      await CodeRig().pump(tester, step: 'code');
      await _focusChord(tester);
      await tester.tap(find.byKey(const ValueKey('focus-exit')));
      await tester.pumpAndSettle();
      expect(_focusTitle, findsNothing);
    });

    testWidgets('the activity bar and editor toolbar buttons toggle it', (
      tester,
    ) async {
      await CodeRig().pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('activity:focus')));
      await tester.pumpAndSettle();
      expect(_focusTitle, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('activity:focus')));
      await tester.pumpAndSettle();
      expect(_focusTitle, findsNothing);

      await tester.tap(find.byKey(const ValueKey('toolbar-focus')));
      await tester.pumpAndSettle();
      expect(_focusTitle, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('toolbar-focus')));
      await tester.pumpAndSettle();
      expect(_focusTitle, findsNothing);
    });

    testWidgets('the palette has Toggle focus mode on the code step only', (
      tester,
    ) async {
      final rig = CodeRig();
      final router = await rig.pump(tester, step: 'code');
      _container(tester).read(appCommandsProvider).openPalette();
      await tester.pumpAndSettle();
      await tester.enterText(_paletteInput, 'focus mode');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Toggle focus mode'));
      await tester.pumpAndSettle();
      expect(_focusTitle, findsOneWidget);

      await _esc(tester);
      router.go('/w/$id/verify');
      await tester.pumpAndSettle();
      _container(tester).read(appCommandsProvider).openPalette();
      await tester.pumpAndSettle();
      await tester.enterText(_paletteInput, 'focus mode');
      await tester.pumpAndSettle();
      expect(find.text('Toggle focus mode'), findsNothing);
    });

    testWidgets('focus mode hides the toolbar rail toggle and the palette '
        'rail action', (tester) async {
      final rig = CodeRig();
      final router = await rig.pump(tester, step: 'code');
      expect(find.byKey(const ValueKey('toolbar-rail')), findsOneWidget);
      await _openPaletteFor(tester, 'right rail');
      expect(find.text('Toggle right rail'), findsOneWidget);
      await _esc(tester);

      await _focusChord(tester);
      expect(find.byKey(const ValueKey('toolbar-rail')), findsNothing);
      await _openPaletteFor(tester, 'right rail');
      expect(find.text('Toggle right rail'), findsNothing);
      await _esc(tester);

      await _focusChord(tester);
      router.go('/');
      await tester.pumpAndSettle();
      await _openPaletteFor(tester, 'right rail');
      expect(find.text('Toggle right rail'), findsNothing);
    });

    testWidgets('the chord does nothing off the code step', (tester) async {
      await CodeRig().pump(tester, step: 'verify');
      await _focusChord(tester);
      expect(_focusTitle, findsNothing);
      expect(_sidebarToggle, findsOneWidget);
    });

    testWidgets('leaving the code step ends it', (tester) async {
      final rig = CodeRig();
      final router = await rig.pump(tester, step: 'code');
      await _focusChord(tester);
      expect(_focusTitle, findsOneWidget);
      router.go('/w/$id/verify');
      await tester.pumpAndSettle();
      expect(_focusTitle, findsNothing);
      expect(_sidebarToggle, findsOneWidget);
      expect(
        _container(tester).read(shellLayoutProvider).focusWorkspaceId,
        isNull,
      );

      router.go('/w/$id/code');
      await tester.pumpAndSettle();
      expect(_focusTitle, findsNothing);
    });

    testWidgets('focus does not touch the saved collapse states', (
      tester,
    ) async {
      final rig = CodeRig();
      await rig.pump(tester, step: 'code');
      await _focusChord(tester);
      await _focusChord(tester);
      expect(rig.prefs.data['shell'], isNull);
    });

    testWidgets('a menu on top keeps its own Esc', (tester) async {
      await CodeRig().pump(tester, step: 'code');
      await _focusChord(tester);
      await tester.tap(find.byKey(const ValueKey('explorer-scope:changes')));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('file-row:lib/rates.ts'))),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy path'), findsOneWidget);
      await _esc(tester);
      expect(find.text('Copy path'), findsNothing);
      expect(_focusTitle, findsOneWidget);
    });
  });

  group('status bar', () {
    testWidgets('branch, gate and terminal on a workspace step', (
      tester,
    ) async {
      final rig = Rig(Preview.green);
      final router = await rig.pump(tester, step: 'agent');
      expect(tester.getSize(_statusBar).height, HaroTokens.statusBarHeight);
      expect(_text(tester, 'status-branch'), 'feat/electron-optimization');
      expect(find.text('gate green'), findsOneWidget);
      expect(find.byKey(const ValueKey('status-position')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('status-terminal')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomPanel), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('status-gate')));
      await tester.pumpAndSettle();
      expect(pathOf(router), '/w/$id/verify');
    });

    testWidgets('the gate chip follows the verdict', (tester) async {
      await Rig(Preview.red).pump(tester, step: 'agent');
      expect(find.text('gate red'), findsOneWidget);
    });

    testWidgets('the code step adds cursor, indent, language, encoding and '
        'save state', (tester) async {
      final rig = CodeRig(
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'function a() {\n    return 1;\n}\n',
          ),
        },
      );
      await rig.pump(tester, step: 'code');
      expect(find.byKey(const ValueKey('status-position')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      expect(_text(tester, 'status-position'), 'Ln 1, Col 1');
      expect(_text(tester, 'status-spaces'), 'Spaces: 4');
      expect(_text(tester, 'status-language'), 'TypeScript');
      expect(_text(tester, 'status-encoding'), 'UTF-8 · LF');
      expect(_text(tester, 'status-save'), 'saved');

      _controller(tester).selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 6,
      );
      await tester.pumpAndSettle();
      expect(_text(tester, 'status-position'), 'Ln 2, Col 7');

      _controller(tester).text = 'function a() {\n    return 2;\n}\n';
      await tester.pumpAndSettle();
      expect(_text(tester, 'status-save'), '● unsaved');
    });

    testWidgets('a CRLF file reads CRLF and a tab-less file defaults to 2', (
      tester,
    ) async {
      final rig = CodeRig(
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'a\r\nb\r\n',
          ),
        },
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      expect(_text(tester, 'status-encoding'), 'UTF-8 · CRLF');
      expect(_text(tester, 'status-spaces'), 'Spaces: 2');
    });

    testWidgets('the diff body has no cursor, so no editor fields', (
      tester,
    ) async {
      await CodeRig().pump(tester, step: 'code');
      expect(find.byKey(const ValueKey('status-position')), findsNothing);
      expect(find.byKey(const ValueKey('status-branch')), findsOneWidget);
    });

    testWidgets('the editor fields go with the code step', (tester) async {
      final rig = CodeRig();
      final router = await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('status-position')), findsOneWidget);
      router.go('/w/$id/verify');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('status-position')), findsNothing);
    });

    testWidgets('triage shows only what applies: the backend', (tester) async {
      final rig = Rig(Preview.green);
      final router = await rig.pump(tester, step: 'agent');
      router.go('/');
      await tester.pumpAndSettle();
      expect(_statusBar, findsOneWidget);
      expect(find.byKey(const ValueKey('status-backend')), findsOneWidget);
      expect(find.byKey(const ValueKey('status-terminal')), findsNothing);
      expect(find.byKey(const ValueKey('status-gate')), findsNothing);
    });
  });

  group('layouts do not overflow', () {
    for (final size in const [Size(900, 640), Size(960, 640)]) {
      for (final (label, sidebarOpen, railOpen) in const [
        ('expanded', true, true),
        ('sidebar strip', false, true),
        ('rail strip', true, false),
        ('both strips', false, false),
      ]) {
        for (final step in ['agent', 'code', 'verify', 'ship']) {
          testWidgets('$label ${size.width.toInt()}x${size.height.toInt()} '
              '$step', (tester) async {
            final rig = CodeRig();
            rig.prefs.data['shell'] = {
              'sidebar_open': sidebarOpen,
              'rail_open': railOpen,
            };
            await rig.pump(tester, size: size, step: step);
            expect(tester.takeException(), isNull);
            if (step == 'code') {
              await tester.tap(find.byKey(const ValueKey('mode-edit')));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }
          });
        }
      }

      testWidgets('focus ${size.width.toInt()}x${size.height.toInt()}', (
        tester,
      ) async {
        final rig = CodeRig();
        await rig.pump(tester, size: size, step: 'code');
        await tester.tap(find.byKey(const ValueKey('mode-edit')));
        await tester.pumpAndSettle();
        await _focusChord(tester);
        expect(_focusTitle, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('status-terminal')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('key bindings', () {
    ShortcutAction? resolve(
      LogicalKeyboardKey key, {
      bool shift = false,
      bool meta = true,
      bool onWorkspace = true,
    }) => resolveShortcut(
      key: key,
      meta: meta,
      control: false,
      shift: shift,
      alt: false,
      modifier: PrimaryModifier.meta,
      textFieldFocused: false,
      onWorkspace: onWorkspace,
    );

    test('primary + shift + enter is focus mode, on a workspace only', () {
      expect(
        resolve(LogicalKeyboardKey.enter, shift: true),
        ShortcutAction.toggleFocus,
      );
      expect(
        resolve(LogicalKeyboardKey.enter, shift: true, onWorkspace: false),
        isNull,
      );
    });

    test('plain primary + enter and shift + enter stay with their widgets', () {
      expect(resolve(LogicalKeyboardKey.enter), isNull);
      expect(
        resolve(LogicalKeyboardKey.enter, shift: true, meta: false),
        isNull,
      );
    });

    test('on Linux the primary modifier is Control', () {
      expect(
        resolveShortcut(
          key: LogicalKeyboardKey.enter,
          meta: false,
          control: true,
          shift: true,
          alt: false,
          modifier: PrimaryModifier.control,
          textFieldFocused: false,
          onWorkspace: true,
        ),
        ShortcutAction.toggleFocus,
      );
    });
  });

  group('shortcuts', () {
    testWidgets('the overlay lists the focus chord', (tester) async {
      await Rig(Preview.green).pump(tester, step: 'code');
      _container(tester).read(appCommandsProvider).openShortcuts();
      await tester.pumpAndSettle();
      expect(find.text('Focus the editor'), findsOneWidget);
    });
  });
}
