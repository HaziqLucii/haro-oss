import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/features/workspace/steps/code/code_buffers.dart';
import 'package:haro_app/features/workspace/steps/code/code_step.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart'
    show codeEditorHighlighting;
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/fs_sync.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/workbench_state.dart';

import '../../harness.dart';
import 'code_harness.dart';

const _path = 'lib/rates.ts';

class FsDetail extends FixedDetail {
  FsDetail(super.id, super.value);

  int gitBumps = 0;

  @override
  void bumpGit() => gitBumps++;

  void emit(
    List<(String, FsChange)> paths, {
    bool truncated = false,
    bool noPaths = false,
  }) => state = state.copyWith(
    fsRevision: state.fsRevision + 1,
    lastFs: FsEvent(
      'changed',
      workspaceId: id,
      paths: [for (final p in paths) FsPathChange(p.$1, p.$2)],
      truncated: noPaths || truncated,
    ),
  );
}

ProviderContainer containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeStep)));

CodeBufferStore store(WidgetTester t) =>
    containerOf(t).read(codeBuffersProvider(id));

Finder key(String k) => find.byKey(ValueKey(k));

Map<String, FileContent> files() => {
  _path: const FileContent(path: _path, content: 'one\n'),
};

final tree = [
  dir('lib', [file(_path), file('lib/zones.ts')]),
  file('README.md'),
];

Future<FsDetail> openRates(
  WidgetTester tester,
  CodeRig Function(FsDetail Function(String, WorkspaceDetail)) build,
) async {
  late FsDetail detail;
  final rig = build((i, d) => detail = FsDetail(i, d));
  await rig.pump(tester, step: 'code');
  await tester.tap(key('mode-edit').first);
  await tester.pumpAndSettle();
  expect(store(tester).bufferFor(_path)!.controller!.text, 'one\n');
  return detail;
}

Future<void> settleDebounce(WidgetTester tester) async {
  await tester.pump(fsTreeDebounce + const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

Future<void> saveKey(WidgetTester t) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await t.sendKeyDownEvent(LogicalKeyboardKey.keyS);
  await t.sendKeyUpEvent(LogicalKeyboardKey.keyS);
  await t.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  group('the tree follows structural fs events', () {
    testWidgets(
      'an added path refetches the tree once, expanded folders intact',
      (tester) async {
        late FsDetail detail;
        final rig = CodeRig(
          tree: tree,
          files: files(),
          makeDetail: (i, d) => detail = FsDetail(i, d),
        );
        await rig.pump(tester, step: 'code');
        containerOf(tester)
            .read(workbenchProvider(id).notifier)
            .toggleDir('lib', force: true);
        await tester.pumpAndSettle();
        expect(key('tree-row:$_path'), findsOneWidget);
        final loads = rig.treeLoads;

        detail.emit([('lib/new.ts', FsChange.added)]);
        detail.emit([('lib/new2.ts', FsChange.added)]);
        await tester.pump(const Duration(milliseconds: 400));
        expect(rig.treeLoads, loads, reason: 'debounced');
        await settleDebounce(tester);

        expect(rig.treeLoads, loads + 1, reason: 'a burst is one refetch');
        expect(containerOf(tester).read(workbenchProvider(id)).expanded, {
          'lib',
        });
        expect(key('tree-row:$_path'), findsOneWidget);
      },
    );

    testWidgets(
      'an atomic save (added for a listed file) does not refetch the tree or bump git',
      (tester) async {
        late FsDetail detail;
        final rig = CodeRig(
          tree: tree,
          files: files(),
          makeDetail: (i, d) => detail = FsDetail(i, d),
        );
        await rig.pump(tester, step: 'code');
        containerOf(tester)
            .read(workbenchProvider(id).notifier)
            .toggleDir('lib', force: true);
        await tester.pumpAndSettle();
        final loads = rig.treeLoads;
        final bumps = detail.gitBumps;

        detail.emit([(_path, FsChange.added)]);
        await settleDebounce(tester);
        expect(rig.treeLoads, loads);
        expect(detail.gitBumps, bumps);

        detail.emit([('lib/brand-new.ts', FsChange.added)]);
        await settleDebounce(tester);
        expect(rig.treeLoads, loads + 1);
        expect(detail.gitBumps, bumps + 1);
      },
    );

    testWidgets('a deleted path and an event without a path list refetch too', (
      tester,
    ) async {
      late FsDetail detail;
      final rig = CodeRig(
        tree: tree,
        files: files(),
        makeDetail: (i, d) => detail = FsDetail(i, d),
      );
      await rig.pump(tester, step: 'code');
      var loads = rig.treeLoads;
      detail.emit([('README.md', FsChange.deleted)]);
      await settleDebounce(tester);
      expect(rig.treeLoads, loads + 1);

      loads = rig.treeLoads;
      detail.emit(const [], noPaths: true);
      await settleDebounce(tester);
      expect(rig.treeLoads, loads + 1);
    });

    testWidgets(
      'modified files never refetch the tree, but the open file is re-read',
      (tester) async {
        late FsDetail detail;
        final rig = CodeRig(
          tree: tree,
          files: files(),
          makeDetail: (i, d) => detail = FsDetail(i, d),
        );
        await rig.pump(tester, step: 'code');
        await tester.tap(key('mode-edit').first);
        await tester.pumpAndSettle();
        final loads = rig.treeLoads;
        final reads = rig.reads.where((p) => p == _path).length;

        rig.files[_path] = const FileContent(path: _path, content: 'two\n');
        detail.emit([(_path, FsChange.modified)]);
        await settleDebounce(tester);

        expect(rig.treeLoads, loads);
        expect(rig.reads.where((p) => p == _path).length, reads + 1);
        expect(store(tester).bufferFor(_path)!.controller!.text, 'two\n');
      },
    );

    testWidgets('a modified file that is not open is not read', (tester) async {
      late FsDetail detail;
      final rig = CodeRig(
        tree: tree,
        files: files(),
        makeDetail: (i, d) => detail = FsDetail(i, d),
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(key('mode-edit').first);
      await tester.pumpAndSettle();
      final before = rig.reads.length;
      detail.emit([('README.md', FsChange.modified)]);
      await settleDebounce(tester);
      expect(rig.reads.length, before);
    });

    testWidgets('a dirty buffer keeps its edits through a modified event', (
      tester,
    ) async {
      late FsDetail detail;
      final rig = CodeRig(
        tree: tree,
        files: files(),
        makeDetail: (i, d) => detail = FsDetail(i, d),
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(key('mode-edit').first);
      await tester.pumpAndSettle();
      store(tester).bufferFor(_path)!.controller!.text = 'mine\n';
      await tester.pumpAndSettle();
      rig.files[_path] = const FileContent(path: _path, content: 'two\n');
      detail.emit([(_path, FsChange.modified)]);
      await settleDebounce(tester);
      expect(store(tester).bufferFor(_path)!.controller!.text, 'mine\n');
    });
  });

  group('deleted on disk', () {
    testWidgets('a deleted open file dims its tab and shows the bar', (
      tester,
    ) async {
      final detail = await openRates(
        tester,
        (make) => CodeRig(tree: tree, files: files(), makeDetail: make),
      );
      expect(key('deleted-bar'), findsNothing);
      detail.emit([(_path, FsChange.deleted)]);
      await settleDebounce(tester);

      expect(key('deleted-bar'), findsOneWidget);
      expect(find.text('This file was deleted on disk.'), findsOneWidget);
      expect(key('tab-missing:$_path'), findsOneWidget);
      expect(tester.widget<Text>(key('tab-missing:$_path')).data, 'D');
    });

    testWidgets('the file coming back clears the bar and takes the new text', (
      tester,
    ) async {
      late CodeRig rig;
      final detail = await openRates(
        tester,
        (make) => rig = CodeRig(tree: tree, files: files(), makeDetail: make),
      );
      detail.emit([(_path, FsChange.deleted)]);
      await settleDebounce(tester);
      expect(key('deleted-bar'), findsOneWidget);

      rig.files[_path] = const FileContent(path: _path, content: 'back\n');
      detail.emit([(_path, FsChange.added)]);
      await settleDebounce(tester);
      expect(key('deleted-bar'), findsNothing);
      expect(store(tester).bufferFor(_path)!.controller!.text, 'back\n');
    });

    testWidgets(
      'an event without a path list marks an open file whose read is a 404',
      (tester) async {
        late CodeRig rig;
        final detail = await openRates(
          tester,
          (make) => rig = CodeRig(tree: tree, files: files(), makeDetail: make),
        );
        rig.deleted.add(_path);
        detail.emit(const [], noPaths: true);
        await settleDebounce(tester);
        expect(key('deleted-bar'), findsOneWidget);
      },
    );

    testWidgets('Save anyway recreates the file with an unguarded write', (
      tester,
    ) async {
      late CodeRig rig;
      final detail = await openRates(
        tester,
        (make) => rig = CodeRig(tree: tree, files: files(), makeDetail: make),
      );
      rig.deleted.add(_path);
      detail.emit([(_path, FsChange.deleted)]);
      await settleDebounce(tester);

      await tester.tap(key('deleted-save-anyway'));
      await tester.pumpAndSettle();
      expect(rig.saves, [(_path, 'one\n')]);
      expect(rig.writeEtags, [null]);
      expect(rig.deleted, isEmpty);
      expect(key('deleted-bar'), findsNothing);
    });

    testWidgets('Close drops a clean tab', (tester) async {
      final detail = await openRates(
        tester,
        (make) => CodeRig(tree: tree, files: files(), makeDetail: make),
      );
      detail.emit([(_path, FsChange.deleted)]);
      await settleDebounce(tester);
      await tester.tap(key('deleted-close'));
      await tester.pumpAndSettle();
      expect(key('deleted-bar'), findsNothing);
      final tabs = containerOf(tester).read(editorTabsProvider(id));
      expect(tabs.openPaths, isNot(contains(_path)));
    });

    testWidgets('Close on a tab with edits still asks before discarding them', (
      tester,
    ) async {
      final detail = await openRates(
        tester,
        (make) => CodeRig(tree: tree, files: files(), makeDetail: make),
      );
      store(tester).bufferFor(_path)!.controller!.text = 'mine\n';
      await tester.pumpAndSettle();
      detail.emit([(_path, FsChange.deleted)]);
      await settleDebounce(tester);
      await tester.tap(key('deleted-close'));
      await tester.pumpAndSettle();
      expect(key('unsaved-bar'), findsOneWidget);
      expect(store(tester).bufferFor(_path)!.controller!.text, 'mine\n');
    });
  });

  group('a stale deleted flag never lets a write through unchecked', () {
    Future<(CodeRig, FsDetail)> dirtyDeleted(WidgetTester tester) async {
      late CodeRig rig;
      final detail = await openRates(
        tester,
        (make) => rig = CodeRig(tree: tree, files: files(), makeDetail: make),
      );
      store(tester).bufferFor(_path)!.controller!.text = 'mine\n';
      await tester.pumpAndSettle();
      rig.deleted.add(_path);
      detail.emit([(_path, FsChange.deleted)]);
      await settleDebounce(tester);
      expect(key('deleted-bar'), findsOneWidget);
      return (rig, detail);
    }

    void recreate(CodeRig rig, String content) {
      rig.deleted.remove(_path);
      rig.files[_path] = FileContent(path: _path, content: content);
    }

    testWidgets(
      'a truncated event finds the file back: conflict bar, edits kept, nothing written',
      (tester) async {
        final (rig, detail) = await dirtyDeleted(tester);
        recreate(rig, 'agent\n');
        detail.emit(const [], noPaths: true);
        await settleDebounce(tester);

        expect(key('deleted-bar'), findsNothing);
        expect(key('disk-conflict-bar'), findsOneWidget);
        final b = store(tester).bufferFor(_path)!;
        expect(b.controller!.text, 'mine\n');
        expect(b.dirty, isTrue);
        expect(rig.saves, isEmpty);

        await saveKey(tester);
        expect(rig.saves, isEmpty, reason: 'a plain save still hits the 409');
        expect(rig.writeEtags, [FileActions.etagOf('one\n')]);
        expect(key('disk-conflict-bar'), findsOneWidget);

        await tester.tap(key('conflict-overwrite'));
        await tester.pumpAndSettle();
        expect(rig.files[_path]!.content, 'mine\n');
        expect(rig.writeEtags.last, isNull);
        expect(key('disk-conflict-bar'), findsNothing);
      },
    );

    testWidgets(
      'Save anyway on a file that came back asks through the conflict bar instead',
      (tester) async {
        final (rig, _) = await dirtyDeleted(tester);
        recreate(rig, 'agent\n');

        await tester.tap(key('deleted-save-anyway'));
        await tester.pumpAndSettle();

        expect(rig.saves, isEmpty);
        expect(rig.writeEtags, isEmpty, reason: 'no write of any kind');
        expect(rig.files[_path]!.content, 'agent\n');
        expect(key('deleted-bar'), findsNothing);
        expect(key('disk-conflict-bar'), findsOneWidget);
        expect(store(tester).bufferFor(_path)!.controller!.text, 'mine\n');

        await tester.tap(key('conflict-overwrite'));
        await tester.pumpAndSettle();
        expect(rig.saves, [(_path, 'mine\n')]);
        expect(rig.writeEtags, [null]);
      },
    );

    testWidgets(
      'Save anyway on a clean tab whose file came back takes the file',
      (tester) async {
        late CodeRig rig;
        final detail = await openRates(
          tester,
          (make) => rig = CodeRig(tree: tree, files: files(), makeDetail: make),
        );
        rig.deleted.add(_path);
        detail.emit([(_path, FsChange.deleted)]);
        await settleDebounce(tester);
        recreate(rig, 'agent\n');

        await tester.tap(key('deleted-save-anyway'));
        await tester.pumpAndSettle();
        expect(rig.saves, isEmpty);
        expect(key('deleted-bar'), findsNothing);
        expect(store(tester).bufferFor(_path)!.controller!.text, 'agent\n');
      },
    );

    testWidgets('a file that is still gone is recreated by Save anyway', (
      tester,
    ) async {
      final (rig, _) = await dirtyDeleted(tester);
      final reads = rig.reads.length;
      await tester.tap(key('deleted-save-anyway'));
      await tester.pumpAndSettle();
      expect(rig.reads.length, reads + 1, reason: 're-read before the write');
      expect(rig.saves, [(_path, 'mine\n')]);
      expect(rig.writeEtags, [null]);
      expect(rig.deleted, isEmpty);
      expect(key('deleted-bar'), findsNothing);
    });

    testWidgets(
      'a file back with the text the buffer last saved is no conflict',
      (tester) async {
        final (rig, detail) = await dirtyDeleted(tester);
        recreate(rig, 'one\n');
        detail.emit(const [], noPaths: true);
        await settleDebounce(tester);
        expect(key('deleted-bar'), findsNothing);
        expect(key('disk-conflict-bar'), findsNothing);
        await saveKey(tester);
        expect(rig.files[_path]!.content, 'mine\n');
        expect(rig.writeEtags, [FileActions.etagOf('one\n')]);
      },
    );

    testWidgets(
      'coming back to the Code step re-checks a buffer flagged deleted',
      (tester) async {
        late FsDetail detail;
        final rig = CodeRig(
          tree: tree,
          files: files(),
          makeDetail: (i, d) => detail = FsDetail(i, d),
        );
        final router = await rig.pump(tester, step: 'code');
        await tester.tap(key('mode-edit').first);
        await tester.pumpAndSettle();
        store(tester).bufferFor(_path)!.controller!.text = 'mine\n';
        await tester.pumpAndSettle();
        rig.deleted.add(_path);
        detail.emit([(_path, FsChange.deleted)]);
        await settleDebounce(tester);
        expect(key('deleted-bar'), findsOneWidget);

        router.go('/w/$id/verify');
        await tester.pumpAndSettle();
        recreate(rig, 'agent\n');
        router.go('/w/$id/code');
        await tester.pumpAndSettle();

        expect(key('deleted-bar'), findsNothing);
        expect(key('disk-conflict-bar'), findsOneWidget);
        expect(store(tester).bufferFor(_path)!.controller!.text, 'mine\n');
        expect(rig.saves, isEmpty);
      },
    );

    testWidgets('a buffer that cannot be written offers only Close', (
      tester,
    ) async {
      final rig = CodeRig(
        tree: tree,
        files: {
          ...files(),
          'lib/zones.ts': const FileContent(
            path: 'lib/zones.ts',
            content: '',
            error: 'binary file',
            size: 12,
          ),
        },
        makeDetail: FsDetail.new,
      );
      await rig.pump(tester, step: 'code');
      containerOf(tester)
          .read(editorTabsProvider(id).notifier)
          .open('lib/zones.ts', preview: false, mode: CodeMode.edit);
      await tester.pumpAndSettle();
      store(tester).bufferFor('lib/zones.ts')!.markMissing(true);
      await tester.pumpAndSettle();
      expect(key('deleted-bar'), findsOneWidget);
      expect(key('deleted-save-anyway'), findsNothing);
      expect(key('deleted-close'), findsOneWidget);
    });
  });

  group('conflict-safe save', () {
    Future<CodeRig> dirty(WidgetTester tester) async {
      late CodeRig rig;
      await openRates(
        tester,
        (make) => rig = CodeRig(tree: tree, files: files(), makeDetail: make),
      );
      store(tester).bufferFor(_path)!.controller!.text = 'mine\n';
      await tester.pumpAndSettle();
      return rig;
    }

    testWidgets(
      'a save sends the etag it read; the conflict comes from the 409',
      (tester) async {
        final rig = await dirty(tester);
        rig.files[_path] = const FileContent(path: _path, content: 'agent\n');
        final reads = rig.reads.length;

        await saveKey(tester);
        expect(rig.writeEtags, [FileActions.etagOf('one\n')]);
        expect(rig.reads.length, reads, reason: 'no client pre-read');
        expect(key('disk-conflict-bar'), findsOneWidget);
        expect(
          rig.files[_path]!.content,
          'agent\n',
          reason: 'nothing overwritten',
        );
        expect(store(tester).bufferFor(_path)!.saveError, isNull);
      },
    );

    testWidgets('Overwrite writes unguarded', (tester) async {
      final rig = await dirty(tester);
      rig.files[_path] = const FileContent(path: _path, content: 'agent\n');
      await saveKey(tester);
      await tester.tap(key('conflict-overwrite'));
      await tester.pumpAndSettle();
      expect(rig.writeEtags, [FileActions.etagOf('one\n'), null]);
      expect(rig.files[_path]!.content, 'mine\n');
      expect(key('disk-conflict-bar'), findsNothing);
    });

    testWidgets(
      'Reload swaps the text, clears the bar, and the next save is guarded by the new etag',
      (tester) async {
        final rig = await dirty(tester);
        rig.files[_path] = const FileContent(path: _path, content: 'agent\n');
        await saveKey(tester);
        await tester.tap(key('conflict-reload'));
        await tester.pumpAndSettle();
        final b = store(tester).bufferFor(_path)!;
        expect(b.controller!.text, 'agent\n');
        expect(b.dirty, isFalse);
        expect(key('disk-conflict-bar'), findsNothing);

        b.controller!.text = 'next\n';
        await saveKey(tester);
        expect(rig.writeEtags.last, FileActions.etagOf('agent\n'));
        expect(rig.files[_path]!.content, 'next\n');
      },
    );

    testWidgets(
      'a 409 deleted shows the deleted bar and does not recreate the file',
      (tester) async {
        final rig = await dirty(tester);
        rig.deleted.add(_path);
        await saveKey(tester);
        expect(key('deleted-bar'), findsOneWidget);
        expect(key('disk-conflict-bar'), findsNothing);
        expect(rig.deleted, {_path});
        expect(store(tester).bufferFor(_path)!.dirty, isTrue);

        await saveKey(tester);
        expect(
          rig.writeEtags,
          hasLength(1),
          reason: 'a second save does not retry blind',
        );
        expect(rig.saves, isEmpty);
      },
    );
  });
}
