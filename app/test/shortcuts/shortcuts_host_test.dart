import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/workspace_ui.dart';
import 'package:haro_app/overlays/command_palette.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:haro_app/overlays/help_overlay.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

import 'app_harness.dart';

Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey mod,
  LogicalKeyboardKey key, {
  String platform = 'macos',
}) async {
  await tester.sendKeyDownEvent(mod, platform: platform);
  await tester.sendKeyEvent(key, platform: platform);
  await tester.sendKeyUpEvent(mod, platform: platform);
  await tester.pumpAndSettle();
}

Future<void> _onMac(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  setUp(() => haroOverlayDepth.value = 0);

  testWidgets('Command+K opens the palette on macOS, Esc closes it', (
    tester,
  ) async {
    await _onMac(() async {
      await pumpApp(tester);
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyK,
      );
      expect(find.byType(CommandPalette), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape, platform: 'macos');
      await tester.pumpAndSettle();
      expect(find.byType(CommandPalette), findsNothing);
    });
  });

  testWidgets('Ctrl+K opens the palette on Linux, Super+K does nothing', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpApp(tester);
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyK,
        platform: 'linux',
      );
      expect(find.byType(CommandPalette), findsNothing);

      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyK,
        platform: 'linux',
      );
      expect(find.byType(CommandPalette), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Ctrl+backquote toggles the terminal only inside a workspace', (
    tester,
  ) async {
    await _onMac(() async {
      final (router, c) = await pumpApp(tester);
      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.backquote,
      );
      expect(c.read(workspaceUiProvider).terminalOpen, isFalse);

      router.go('/w/linux-attraction/agent');
      await tester.pumpAndSettle();
      final before = c.read(workspaceUiProvider).terminalOpen;
      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.backquote,
      );
      expect(c.read(workspaceUiProvider).terminalOpen, !before);
    });
  });

  testWidgets('Command+J cycles the needs-you workspaces', (tester) async {
    await _onMac(() async {
      final (router, _) = await pumpApp(tester);
      String path() => router.routerDelegate.currentConfiguration.uri.path;

      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyJ,
      );
      expect(path(), '/w/linux-attraction/agent');
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyJ,
      );
      expect(path(), '/w/electron-optimization/agent');
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyJ,
      );
      expect(path(), '/w/linux-attraction/agent');
    });
  });

  testWidgets('Command+J with nothing waiting stays put', (tester) async {
    await _onMac(() async {
      final (router, _) = await pumpApp(tester, needYou: const []);
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyJ,
      );
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    });
  });

  testWidgets('the need-you pill does the same as Command+J', (tester) async {
    final (router, _) = await pumpApp(tester);
    await tester.tap(find.textContaining('NEED YOU'));
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/w/linux-attraction/agent',
    );
  });

  testWidgets('the Search button opens the palette', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Search or run a command'));
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsOneWidget);
  });

  testWidgets('? opens the shortcuts overlay, the ? button too', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    // Without shift there is no '?' character: nothing opens.
    await tester.pumpAndSettle();
    expect(find.byType(HelpOverlay), findsNothing);

    await tester.tap(find.byTooltip('Help and guide'));
    await tester.pumpAndSettle();
    expect(find.byType(HelpOverlay), findsOneWidget);
    // The ? button opens on the guide; the shortcuts are one tab away.
    expect(find.byKey(const ValueKey('help-guide')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('help-tab-keyboard shortcuts')));
    await tester.pumpAndSettle();
    expect(find.text('Next workspace that needs you'), findsOneWidget);
  });

  testWidgets('? types into a focused text field instead of opening help', (
    tester,
  ) async {
    await _onMac(() async {
      await pumpApp(tester);
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyK,
      );
      await tester.enterText(find.byType(TextField), 'a');
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.shiftLeft,
        platform: 'macos',
      );
      await tester.sendKeyEvent(
        LogicalKeyboardKey.slash,
        platform: 'macos',
        character: '?',
      );
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.shiftLeft,
        platform: 'macos',
      );
      await tester.pumpAndSettle();
      expect(find.byType(HelpOverlay), findsNothing);
    });
  });

  testWidgets('Command+1..4 do not jump between steps: Proceed and Back do', (
    tester,
  ) async {
    await _onMac(() async {
      final (router, _) = await pumpApp(tester);
      String path() => router.routerDelegate.currentConfiguration.uri.path;

      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.digit3,
      );
      expect(path(), '/');

      router.go('/w/mutation-gate/agent');
      await tester.pumpAndSettle();
      // Steps open with Proceed and Back, one at a time: the chords do nothing.
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.digit3,
      );
      expect(path(), '/w/mutation-gate/agent');
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.digit4,
      );
      expect(path(), '/w/mutation-gate/agent');
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.digit1,
      );
      expect(path(), '/w/mutation-gate/agent');
    });
  });

  testWidgets('registered commands receive the remaining shortcuts', (
    tester,
  ) async {
    await _onMac(() async {
      final (_, c) = await pumpApp(tester);
      final calls = <String>[];
      c
          .read(appCommandsProvider.notifier)
          .register(
            (cmds) => cmds.copyWith(
              runGate: () => calls.add('gate'),
              runDevServer: () => calls.add('dev'),
              focusComposer: () => calls.add('composer'),
              toggleTerminal: () => calls.add('terminal'),
              openNewWorkspace: (p) => calls.add('new:$p'),
            ),
          );
      const cmd = LogicalKeyboardKey.metaLeft;
      await _chord(tester, cmd, LogicalKeyboardKey.keyG);
      await _chord(tester, cmd, LogicalKeyboardKey.keyR);
      await _chord(tester, cmd, LogicalKeyboardKey.keyI);
      await _chord(tester, cmd, LogicalKeyboardKey.keyN);
      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.backquote,
      );
      expect(calls, ['gate', 'dev', 'composer', 'new:null', 'terminal']);
    });
  });

  testWidgets('global shortcuts stand down while an overlay is open', (
    tester,
  ) async {
    await _onMac(() async {
      final (_, c) = await pumpApp(tester);
      var gate = 0;
      c
          .read(appCommandsProvider.notifier)
          .register((cmds) => cmds.copyWith(runGate: () => gate++));
      c.read(appCommandsProvider).openShortcuts();
      await tester.pumpAndSettle();
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyG,
      );
      expect(gate, 0);
    });
  });

  testWidgets('shortcut overlay lists the spec entries', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Help and guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('help-tab-keyboard shortcuts')));
    await tester.pumpAndSettle();
    for (final label in [
      'Command palette',
      'New workspace',
      'Focus the prompt',
      'Run agent / commit',
      'Run gate',
      'Go to file',
      'Run dev server',
      'Toggle terminal',
      'Save all files (runs the gate with Run on save)',
      'Split editor',
      'Next workspace that needs you',
      'Close / exit',
    ]) {
      expect(
        find.descendant(
          of: find.byType(HelpOverlay),
          matching: find.text(label),
        ),
        findsOneWidget,
        reason: label,
      );
    }
    await tester.tap(find.text('✕'));
    await tester.pumpAndSettle();
    expect(find.byType(HelpOverlay), findsNothing);
  });

  testWidgets(
    'the guide command opens the guide, the shortcuts command the shortcuts',
    (tester) async {
      final (_, c) = await pumpApp(tester);
      c.read(appCommandsProvider).openGuide();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('help-guide')), findsOneWidget);
      await tester.tap(find.text('✕'));
      await tester.pumpAndSettle();
      c.read(appCommandsProvider).openShortcuts();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('help-shortcuts')), findsOneWidget);
      expect(find.byKey(const ValueKey('help-guide')), findsNothing);
    },
  );

  testWidgets('the help window switches between its two tabs', (tester) async {
    final (_, c) = await pumpApp(tester);
    c.read(appCommandsProvider).openGuide();
    await tester.pumpAndSettle();
    expect(find.text('What haro is'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('help-tab-keyboard shortcuts')));
    await tester.pumpAndSettle();
    expect(find.text('Command palette'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('help-tab-guide')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('guide-search')), findsOneWidget);
  });

  testWidgets('going to the shortcuts and back keeps your place in the guide', (
    tester,
  ) async {
    final (_, c) = await pumpApp(tester);
    c.read(appCommandsProvider).openGuide();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('guide-topic-words')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('guide-search')), 'terms');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('help-tab-keyboard shortcuts')));
    await tester.pumpAndSettle();
    expect(find.text('Command palette'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('help-tab-guide')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('guide-title'))).data,
      'Plain words',
    );
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('guide-search')),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, 'terms');
  });
}
