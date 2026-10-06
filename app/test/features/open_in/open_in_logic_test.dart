import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/open_in/editors_provider.dart';
import 'package:haro_app/features/open_in/open_in_errors.dart';
import 'package:haro_app/features/open_in/open_in_launcher.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/workspace/steps/code/diff_model.dart';
import 'package:haro_app/features/workspace/terminal/terminal_sessions.dart';
import 'package:haro_app/api/haro_ws.dart';
import 'package:haro_app/overlays/palette_model.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

import '../../data/detail_harness.dart' show FakeWsNet;
import '../../shell/fake_shell_data.dart';
import 'open_in_harness.dart';

List<EditorInfo> editors() => [
  for (final e in sampleEditors()) EditorInfo.fromJson(e),
];

void main() {
  group('resolveDefaultEditor', () {
    test('Ask means no default, whatever was picked before', () {
      expect(
        resolveDefaultEditor(
          editors(),
          preferred: DisplayPrefs.askEditor,
          lastUsed: 'zed',
        ),
        isNull,
      );
    });

    test('a set preference is the default', () {
      expect(resolveDefaultEditor(editors(), preferred: 'zed')?.id, 'zed');
    });

    test('a menu pick this session wins over the preference', () {
      expect(
        resolveDefaultEditor(
          editors(),
          preferred: 'zed',
          lastUsed: 'neovim',
        )?.id,
        'neovim',
      );
    });

    test('an editor that is not installed is never the default', () {
      expect(resolveDefaultEditor(editors(), preferred: 'vscode'), isNull);
      expect(
        resolveDefaultEditor(
          editors(),
          preferred: 'zed',
          lastUsed: 'vscode',
        )?.id,
        'zed',
      );
    });

    test('availableEditors drops the unavailable ones', () {
      expect(availableEditors(editors()).map((e) => e.id), [
        'zed',
        'neovim',
        'file_manager',
      ]);
    });
  });

  group('openInMenuItems', () {
    test('groups GUI, Terminal, File manager and skips empty groups', () {
      final items = openInMenuItems(availableEditors(editors()), (_) {});
      expect(
        [for (final i in items) '${i.heading ? '#' : ''}${i.label}'],
        ['#GUI', 'Zed', '#Terminal', 'Neovim', '#File manager', 'Files'],
      );
      final guiOnly = openInMenuItems([editors()[1]], (_) {});
      expect(guiOnly.map((i) => i.label), ['GUI', 'Zed']);
    });

    test('a row calls back with its editor', () {
      EditorInfo? picked;
      final items = openInMenuItems(availableEditors(editors()), (e) {
        picked = e;
      });
      items.firstWhere((i) => i.label == 'Neovim').onSelected();
      expect(picked?.id, 'neovim');
    });
  });

  group('errors', () {
    test('a bare Not Found is the restart hint', () {
      const e = HaroApiException(404, 'Not Found');
      expect(editorsLoadError(e), editorsRestartHint);
      expect(openInError(e), editorsRestartHint);
    });

    test('a real 404 or 400 keeps the backend wording', () {
      expect(
        openInError(const HaroApiException(404, 'file not found')),
        'file not found',
      );
      expect(
        openInError(const HaroApiException(400, 'Zed is not installed')),
        'Zed is not installed',
      );
    });

    test('an unreachable backend is one short line', () {
      expect(
        editorsLoadError(const HaroApiException(0, 'Connection refused')),
        'Backend not reachable',
      );
    });
  });

  group('DisplayPrefs.preferredEditor', () {
    test('defaults to ask and round-trips as preferred_editor', () {
      expect(const DisplayPrefs().preferredEditor, 'ask');
      expect(DisplayPrefs.fromJson({}).preferredEditor, 'ask');
      final saved = const DisplayPrefs().copyWith(preferredEditor: 'zed');
      expect(saved.toJson()['preferred_editor'], 'zed');
      expect(DisplayPrefs.fromJson(saved.toJson()).preferredEditor, 'zed');
    });
  });

  group('DiffFile.firstChangedLine', () {
    test('first added line in the new file', () {
      final f = parseUnifiedDiff('''
diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -10,3 +10,4 @@
 keep
-old
+new
+more
 tail
''').single;
      expect(f.firstChangedLine, 11);
    });

    test('a pure deletion points at where it was removed', () {
      final f = parseUnifiedDiff('''
diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -5,3 +5,2 @@
 keep
-gone
 tail
''').single;
      expect(f.firstChangedLine, 5);
    });

    test('a deleted file has no line', () {
      final f = parseUnifiedDiff('''
diff --git a/a.ts b/a.ts
deleted file mode 100644
--- a/a.ts
+++ /dev/null
@@ -1,2 +0,0 @@
-a
-b
''').single;
      expect(f.firstChangedLine, isNull);
    });
  });

  group('palette', () {
    List<PaletteItem> build({String? worktreeLabel}) => buildPaletteItems(
      data: fakeShellData,
      commands: () => const AppCommands(),
      openWorkspace: (_, _) {},
      worktreeLabel: worktreeLabel,
    );

    test('has the worktree action only when a workspace is open', () {
      expect(build().any((i) => i.id == 'action:open-worktree'), isFalse);
      final item = build(worktreeLabel: 'Open worktree in Zed')
          .firstWhere((i) => i.id == 'action:open-worktree');
      expect(item.label, 'Open worktree in Zed');
      expect(item.meta, contains('O'));
    });

    test('running it calls openWorktree', () {
      var called = 0;
      final item = buildPaletteItems(
        data: fakeShellData,
        commands: () => AppCommands(openWorktree: () => called++),
        openWorkspace: (_, _) {},
        worktreeLabel: 'Open worktree in…',
      ).firstWhere((i) => i.id == 'action:open-worktree');
      item.run();
      expect(called, 1);
    });
  });

  group('ShellSession.sendCommand', () {
    test('opens the socket, then types the command and Enter', () async {
      final net = FakeWsNet();
      final ws = HaroWs(Uri.parse('http://x:1'), connector: net.connect);
      final s = ShellSession(connect: (sid) => ws.terminal('w', sid));
      addTearDown(s.dispose);
      s.sendCommand('nvim +3 a.ts');
      await pumpEventQueue();
      expect(net.channels, hasLength(1));
      expect(s.phase, ShellPhase.running);
      expect(
        net.latest.sent
            .map((m) => m as String)
            .where((m) => m.contains('nvim')),
        ['{"t":"in","d":"nvim +3 a.ts\\r"}'],
      );
    });

    test('an ended shell is restarted first', () async {
      final net = FakeWsNet();
      final ws = HaroWs(Uri.parse('http://x:1'), connector: net.connect);
      final s = ShellSession(connect: (sid) => ws.terminal('w', sid))..start();
      addTearDown(s.dispose);
      await net.latest.dropFromServer();
      await pumpEventQueue();
      expect(s.phase, ShellPhase.ended);
      s.sendCommand('hx a.ts');
      await pumpEventQueue();
      expect(net.channels, hasLength(2));
      expect(
        net.latest.sent.any((m) => (m as String).contains('hx a.ts')),
        isTrue,
      );
    });
  });

  group('ShellSessions registry', () {
    test('unregister only removes the session that registered', () {
      final net = FakeWsNet();
      final ws = HaroWs(Uri.parse('http://x:1'), connector: net.connect);
      ShellSession make() =>
          ShellSession(connect: (sid) => ws.terminal('w', sid));
      final a = make();
      final b = make();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final reg = ShellSessions()..register('w', a);
      expect(reg['w'], same(a));
      reg.register('w', b);
      reg.unregister('w', a);
      expect(reg['w'], same(b), reason: 'the replacement stays');
      reg.unregister('w', b);
      expect(reg['w'], isNull);
    });
  });
}
