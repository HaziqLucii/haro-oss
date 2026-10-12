import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/open_in/open_in_notice.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:re_editor/re_editor.dart';

import '../../state/builders.dart';
import '../workspace/harness.dart';
import '../workspace/steps/code/code_harness.dart';
import '../workspace/steps/verify/verify_harness.dart';
import '../settings/settings_harness.dart' show loadBrandFonts;
import 'open_in_harness.dart';

Finder key(String k) => find.byKey(ValueKey(k));

Future<CodeRig> pumpCode(
  WidgetTester tester,
  OpenInBackend backend, {
  String? preferred,
  Map<String, FileContent> files = const {},
  Size size = const Size(1400, 900),
}) async {
  final rig = CodeRig(files: files);
  withOpenIn(rig, backend, preferred: preferred);
  await rig.pump(tester, step: 'code', size: size);
  await settleOpen(tester);
  return rig;
}

Map<String, dynamic> only(OpenInBackend b) => b.opens.single.body!;

void main() {
  setUpAll(loadBrandFonts);
  setUp(() => haroOverlayDepth.value = 0);

  group('split button label', () {
    testWidgets('Ask every time: one Open in… button, no caret', (
      tester,
    ) async {
      await pumpCode(tester, OpenInBackend());
      expect(find.text('Open in… ▾'), findsOneWidget);
      expect(key('open-in-caret'), findsNothing);
    });

    testWidgets('a preferred editor names the button and adds the caret', (
      tester,
    ) async {
      await pumpCode(tester, OpenInBackend(), preferred: 'zed');
      expect(find.text('Open in Zed'), findsOneWidget);
      expect(key('open-in-caret'), findsOneWidget);
    });

    testWidgets('a preferred editor that is not installed falls back to ask', (
      tester,
    ) async {
      await pumpCode(tester, OpenInBackend(), preferred: 'vscode');
      expect(find.text('Open in… ▾'), findsOneWidget);
    });

    testWidgets('picking from the menu sets the label for the session', (
      tester,
    ) async {
      await pumpCode(tester, OpenInBackend(), preferred: 'zed');
      await tester.tap(key('open-in-caret'));
      await settleOpen(tester);
      await tester.tap(find.text('Files'));
      await settleOpen(tester);
      expect(find.text('Open in Files'), findsOneWidget);
    });

    testWidgets('the button is secondary: no bone fill, no green', (
      tester,
    ) async {
      await pumpCode(tester, OpenInBackend(), preferred: 'zed');
      final box = tester.widget<Container>(key('open-in'));
      final deco = box.decoration! as BoxDecoration;
      expect(deco.color, isNull);
    });
  });

  group('opening', () {
    testWidgets('Diff mode posts the file and its first changed line', (
      tester,
    ) async {
      final be = OpenInBackend();
      await pumpCode(tester, be, preferred: 'zed');
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      expect(only(be), {'target': 'zed', 'path': 'lib/rates.ts', 'line': 2});
      expect(key('term-tab-shell'), findsNothing, reason: 'GUI: no terminal');
    });

    testWidgets('Edit mode posts the cursor line', (tester) async {
      final be = OpenInBackend();
      await pumpCode(
        tester,
        be,
        preferred: 'zed',
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'a\nb\nc\nd\n',
          ),
        },
      );
      await tester.tap(key('mode-edit'));
      await settleOpen(tester);
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      editor.controller!.selection = const CodeLineSelection.collapsed(
        index: 2,
        offset: 0,
      );
      await tester.pump();
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      expect(only(be), {'target': 'zed', 'path': 'lib/rates.ts', 'line': 3});
    });

    testWidgets('Ask lists available editors grouped, then opens once', (
      tester,
    ) async {
      final be = OpenInBackend();
      await pumpCode(tester, be);
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      expect(be.opens, isEmpty);
      for (final h in ['GUI', 'TERMINAL', 'FILE MANAGER']) {
        expect(find.text(h), findsOneWidget);
      }
      expect(find.text('Zed'), findsOneWidget);
      expect(find.text('Neovim'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('VS Code'), findsNothing, reason: 'not installed');

      await tester.tap(find.text('Zed'));
      await settleOpen(tester);
      expect(only(be)['target'], 'zed');
      expect(find.text('Open in… ▾'), findsOneWidget, reason: 'still asks');
    });

    testWidgets('a terminal editor types its command into the Shell tab', (
      tester,
    ) async {
      final be = OpenInBackend()
        ..reply = (body) => {
          'mode': 'shell',
          'command': 'nvim +${body['line']} ${body['path']}',
        };
      final rig = await pumpCode(tester, be);
      expect(key('term-tab-shell'), findsNothing);
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      await tester.tap(find.text('Neovim'));
      await settleOpen(tester);

      expect(only(be)['target'], 'neovim');
      expect(key('term-tab-shell'), findsOneWidget);
      expect(key('shell-view'), findsOneWidget, reason: 'Shell tab is active');
      expect(shellSent(rig).where((m) => m['t'] == 'in').map((m) => m['d']), [
        'nvim +2 lib/rates.ts\r',
      ]);
      expect(
        rig.net.uris.where((u) => u.path.contains('/terminal/')),
        hasLength(1),
      );
    });

    testWidgets('a second terminal open reuses the open shell', (tester) async {
      final be = OpenInBackend()
        ..reply = (_) => {'mode': 'shell', 'command': 'nvim a'};
      final rig = await pumpCode(tester, be, preferred: 'neovim');
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      expect(
        rig.net.uris.where((u) => u.path.contains('/terminal/')),
        hasLength(1),
      );
      expect(shellSent(rig).where((m) => m['t'] == 'in'), hasLength(2));
    });
  });

  group('errors', () {
    testWidgets('a refused open shows inline in red and clears itself', (
      tester,
    ) async {
      final be = OpenInBackend()
        ..openStatus = 404
        ..openDetail = 'file not found';
      await pumpCode(tester, be, preferred: 'zed');
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      final note = key('open-in-notice-code');
      expect(note, findsOneWidget);
      expect(tester.widget<Text>(note).data, 'file not found');
      expect(tester.widget<Text>(note).style!.color, const Color(0xFFE0685E));

      await tester.pump(openInNoticeDuration + const Duration(seconds: 1));
      expect(note, findsNothing);
    });

    testWidgets('a 400 launch failure shows the backend message', (
      tester,
    ) async {
      final be = OpenInBackend()
        ..openStatus = 400
        ..openDetail = 'could not launch Zed';
      await pumpCode(tester, be, preferred: 'zed');
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      expect(find.text('could not launch Zed'), findsOneWidget);
      await tester.pump(openInNoticeDuration + const Duration(seconds: 1));
    });

    testWidgets('a backend without /editors says it needs a restart', (
      tester,
    ) async {
      final be = OpenInBackend()..editorsStatus = 404;
      await pumpCode(tester, be);
      expect(find.text('Open in… ▾'), findsOneWidget, reason: 'no crash');
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      expect(find.text('Open in… needs a backend restart'), findsOneWidget);
      expect(be.opens, isEmpty);
      await tester.pump(openInNoticeDuration + const Duration(seconds: 1));
    });

    testWidgets('after a restart the next click loads the list again', (
      tester,
    ) async {
      final be = OpenInBackend()..editorsStatus = 404;
      await pumpCode(tester, be);
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      be.editorsStatus = null;
      await tester.pump(openInNoticeDuration + const Duration(seconds: 1));
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      expect(find.text('Zed'), findsOneWidget);
    });

    testWidgets('a terminal editor with no page to type into says so', (
      tester,
    ) async {
      final be = OpenInBackend()
        ..reply = (_) => {'mode': 'shell', 'command': null};
      await pumpCode(tester, be, preferred: 'neovim');
      await tester.tap(key('open-in-main'));
      await settleOpen(tester);
      expect(find.textContaining('no command'), findsOneWidget);
      await tester.pump(openInNoticeDuration + const Duration(seconds: 1));
    });
  });

  group('other entry points', () {
    testWidgets('file row right-click: Open in… lists editors at that file', (
      tester,
    ) async {
      final be = OpenInBackend();
      await pumpCode(tester, be);
      await showChanges(tester);
      await tester.tap(key('file-row:lib/rates.ts'), buttons: kSecondaryButton);
      await settleOpen(tester);
      expect(find.text('Also open in…'), findsWidgets);
      await tester.tap(find.text('Also open in…').last);
      await settleOpen(tester);
      await tester.tap(find.text('Zed'));
      await settleOpen(tester);
      expect(only(be), {'target': 'zed', 'path': 'lib/rates.ts', 'line': 2});
    });

    testWidgets('file row right-click offers the default editor first', (
      tester,
    ) async {
      final be = OpenInBackend();
      await pumpCode(tester, be, preferred: 'zed');
      await showChanges(tester);
      await tester.tap(key('file-row:lib/zones.ts'), buttons: kSecondaryButton);
      await settleOpen(tester);
      await tester.tap(find.text('Also open in Zed').last);
      await settleOpen(tester);
      expect(only(be), {'target': 'zed', 'path': 'lib/zones.ts', 'line': 2});
    });

    testWidgets('header ··· opens the worktree: no path, no line', (
      tester,
    ) async {
      final be = OpenInBackend();
      await pumpCode(tester, be);
      await tester.tap(key('open-worktree'));
      await settleOpen(tester);
      await tester.tap(find.text('Open worktree in…'));
      await settleOpen(tester);
      await tester.tap(find.text('Zed'));
      await settleOpen(tester);
      expect(only(be), {'target': 'zed', 'path': null, 'line': null});
    });

    testWidgets('header ··· with a preference opens straight away', (
      tester,
    ) async {
      final be = OpenInBackend();
      await pumpCode(tester, be, preferred: 'zed');
      await tester.tap(key('open-worktree'));
      await settleOpen(tester);
      await tester.tap(find.text('Open worktree in Zed'));
      await settleOpen(tester);
      expect(only(be)['target'], 'zed');
      expect(only(be)['path'], isNull);
    });

    testWidgets('header failures show under the sub-line', (tester) async {
      final be = OpenInBackend()
        ..openStatus = 400
        ..openDetail = 'worktree not found on disk';
      await pumpCode(tester, be, preferred: 'zed');
      await tester.tap(key('open-worktree'));
      await settleOpen(tester);
      await tester.tap(find.text('Open worktree in Zed'));
      await settleOpen(tester);
      expect(key('open-in-notice-header'), findsOneWidget);
      await tester.pump(openInNoticeDuration + const Duration(seconds: 1));
    });
  });

  group('verify step', () {
    Future<VerifyRig> pumpVerifyRig(
      WidgetTester tester,
      OpenInBackend be, {
      String? preferred,
    }) async {
      final rig = VerifyRig(
        Preview.green,
        state: verifyDetail(
          WorkspaceStatus.gateGreen,
          run: greenRun(unchecked: [untestedRow('lib/rates.ts', 2)]),
          cells: cells(594),
        ),
        hunks: sampleHunks(),
      );
      withOpenIn(rig, be, preferred: preferred);
      rig.router = await rig.pump(tester);
      await settleOpen(tester);
      return rig;
    }

    testWidgets('a Needs your review row opens its file in the editor', (
      tester,
    ) async {
      final be = OpenInBackend();
      await pumpVerifyRig(tester, be, preferred: 'zed');
      final f = key('look-editor-untested_lines:lib/rates.ts:2');
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await settleOpen(tester);
      expect(only(be)['target'], 'zed');
      expect(only(be)['path'], 'lib/rates.ts');
    });

    testWidgets('with Ask every time the row button shows the menu', (
      tester,
    ) async {
      final be = OpenInBackend();
      await pumpVerifyRig(tester, be);
      final f = key('look-editor-untested_lines:lib/rates.ts:2');
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await settleOpen(tester);
      expect(be.opens, isEmpty);
      expect(find.text('GUI'), findsOneWidget);
    });
  });

  group('⌘⇧O', () {
    Future<void> chord(WidgetTester tester) async {
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.shiftLeft,
        platform: 'macos',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO, platform: 'macos');
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.shiftLeft,
        platform: 'macos',
      );
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await settleOpen(tester);
    }

    Future<void> onMac(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('opens the worktree in the preferred editor', (tester) async {
      await onMac(() async {
        final be = OpenInBackend();
        await pumpCode(tester, be, preferred: 'zed');
        await chord(tester);
        expect(only(be), {'target': 'zed', 'path': null, 'line': null});
      });
    });

    testWidgets('asks with the menu when the preference is Ask', (
      tester,
    ) async {
      await onMac(() async {
        final be = OpenInBackend();
        await pumpCode(tester, be);
        await chord(tester);
        expect(be.opens, isEmpty);
        expect(find.text('GUI'), findsOneWidget);
        await tester.tap(find.text('Zed'));
        await settleOpen(tester);
        expect(only(be)['target'], 'zed');
      });
    });

    testWidgets('the palette carries the same action', (tester) async {
      await onMac(() async {
        final be = OpenInBackend();
        await pumpCode(tester, be, preferred: 'zed');
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK, platform: 'macos');
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        await settleOpen(tester);
        expect(find.text('Open worktree in Zed'), findsOneWidget);
        await tester.tap(find.text('Open worktree in Zed'));
        await settleOpen(tester);
        expect(only(be)['target'], 'zed');
        expect(only(be)['path'], isNull);
      });
    });
  });

  testWidgets('no overflow at 960x640 with the notice showing', (tester) async {
    final be = OpenInBackend()
      ..openStatus = 400
      ..openDetail = 'could not launch Zed: a long reason that keeps going';
    await pumpCode(tester, be, preferred: 'zed', size: const Size(960, 640));
    await tester.tap(key('open-in-main'));
    await settleOpen(tester);
    expect(find.byKey(const ValueKey('open-in-notice-code')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(openInNoticeDuration + const Duration(seconds: 1));
  });
}
