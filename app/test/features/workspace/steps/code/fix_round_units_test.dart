import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/features/workspace/steps/code/code_buffers.dart';
import 'package:haro_app/features/workspace/steps/code/edit_buffer.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/changes_model.dart';
import 'package:haro_app/state/workspace_flow.dart';

String etagOf(String content) => 'e${content.hashCode}';

/// A fake disk with the backend's save check: a write that carries an etag is refused (409)
/// when the file is gone or no longer hashes to it.
class _Actions extends WorkspaceActions {
  _Actions(super.ref, super.workspaceId, this.disk, this.saved);

  final Map<String, String> disk;
  final List<(String, String)> saved;

  @override
  Future<FileContent> readFile(String path) async {
    final content = disk[path];
    if (content == null) throw const HaroApiException(404, 'not found');
    return FileContent(path: path, content: content, etag: etagOf(content));
  }

  @override
  Future<String?> saveFile(
    String path,
    String content, {
    String? expectedEtag,
  }) async {
    if (expectedEtag != null) {
      final now = disk[path];
      if (now == null) {
        throw const HaroApiException(
          409,
          'file changed on disk',
          body: {'reason': 'deleted'},
        );
      }
      if (etagOf(now) != expectedEtag) {
        throw const HaroApiException(
          409,
          'file changed on disk',
          body: {'reason': 'changed'},
        );
      }
    }
    saved.add((path, content));
    disk[path] = content;
    return etagOf(content);
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late ProviderContainer c;
  late ProviderSubscription<CodeBufferStore> sub;

  CodeBufferStore store() => c.read(codeBuffersProvider('w'));
  EditorTabsNotifier tabs() => c.read(editorTabsProvider('w').notifier);
  EditorTabsState state() => c.read(editorTabsProvider('w'));

  setUp(() {
    c = ProviderContainer();
    sub = c.listen(codeBuffersProvider('w'), (_, _) {});
  });
  tearDown(() {
    sub.close();
    c.dispose();
  });

  group('closeUnder', () {
    test(
      'pane 0 emptying while pane 1 holds tabs under the folder does not throw',
      () {
        tabs()
          ..open('lib/a.ts', preview: false)
          ..open('lib/b.ts', preview: false, toSide: true)
          ..open('lib/c.ts', preview: false)
          ..open('keep.md', preview: false);
        expect(state().panes, hasLength(2));
        expect(state().panes[0].tabs.map((t) => t.path), ['lib/a.ts']);

        tabs().closeUnder('lib');

        expect(state().panes, hasLength(1));
        expect(state().panes.single.tabs.map((t) => t.path), ['keep.md']);
        expect(state().activePath, 'keep.md');
        expect(state().focusedPane, 0);
      },
    );

    test('a file path removes exactly that tab, its neighbour takes over', () {
      tabs()
        ..open('a.ts', preview: false)
        ..open('b.ts', preview: false)
        ..open('c.ts', preview: false)
        ..activate('b.ts');
      tabs().closeUnder('b.ts');
      expect(state().focused.tabs.map((t) => t.path), ['a.ts', 'c.ts']);
      expect(state().activePath, 'c.ts');
    });

    test('a sibling that only shares the name prefix stays open', () {
      tabs()
        ..open('lib/a.ts', preview: false)
        ..open('lib2/b.ts', preview: false);
      tabs().closeUnder('lib');
      expect(state().focused.tabs.map((t) => t.path), ['lib2/b.ts']);
    });

    test('everything closing leaves one empty pane', () {
      tabs()
        ..open('lib/a.ts', preview: false)
        ..open('lib/b.ts', preview: false, toSide: true);
      tabs().closeUnder('lib');
      expect(state().panes, hasLength(1));
      expect(state().panes.single.tabs, isEmpty);
    });

    test('a pending jump into the removed file goes with it', () {
      tabs().open('lib/a.ts', line: 4);
      tabs().closeUnder('lib');
      expect(state().jump, isNull);
    });
  });

  group('movePath', () {
    test('a renamed file keeps its tab, place, pin, body and unsaved mark', () {
      tabs()
        ..open('a.ts', preview: false)
        ..open('b.ts', preview: false, mode: CodeMode.diff)
        ..setDirty('b.ts', true)
        ..open('c.ts', preview: false);
      tabs().movePath('b.ts', 'renamed.ts');
      final t = state().focused.tabs;
      expect(t.map((e) => e.path), ['a.ts', 'renamed.ts', 'c.ts']);
      expect(t[1].dirty, isTrue);
      expect(t[1].preview, isFalse);
      expect(t[1].mode, CodeMode.diff);
    });

    test('a renamed folder moves every tab below it, in both panes', () {
      tabs()
        ..open('lib/a.ts', preview: false)
        ..open('lib/b.ts', preview: false, toSide: true)
        ..open('lib2/c.ts', preview: false);
      tabs().movePath('lib', 'src');
      expect(
        state().panes.map((p) => p.tabs.map((t) => t.path).toList()).toList(),
        [
          ['src/a.ts'],
          ['src/b.ts', 'lib2/c.ts'],
        ],
      );
      expect(state().panes[0].activePath, 'src/a.ts');
    });

    test('a pending jump follows the file', () {
      tabs().open('a.ts', line: 3);
      tabs().movePath('a.ts', 'b.ts');
      expect(state().jump?.path, 'b.ts');
      expect(state().jump?.line, 3);
    });
  });

  group('jump', () {
    test('consumeJump clears it once; a stale serial does nothing', () {
      tabs().open('a.ts', line: 3);
      final first = state().jump!;
      tabs().open('a.ts', line: 9);
      tabs().consumeJump(first.serial);
      expect(state().jump?.line, 9, reason: 'the newer jump is untouched');
      tabs().consumeJump(state().jump!.serial);
      expect(state().jump, isNull);
      expect(state().activePath, 'a.ts');
    });

    test('opening another file without a line drops a jump nobody took', () {
      tabs().open('a.ts', line: 3);
      tabs().open('b.ts');
      expect(state().jump, isNull);
    });

    test('opening the same file without a line keeps it', () {
      tabs().open('a.ts', line: 3);
      tabs().open('a.ts', preview: false);
      expect(state().jump?.line, 3);
    });

    test('closing the file drops its pending jump', () {
      tabs().open('a.ts', line: 3);
      tabs().close('a.ts');
      expect(state().jump, isNull);
    });
  });

  group('store: rename and delete', () {
    test('moveUnder re-keys a dirty buffer and keeps its edits', () async {
      final b = store().ensure(
        'a.ts',
        () async => const FileContent(path: 'a.ts', content: '1\n'),
      );
      await settle();
      b.controller!.text = 'edited\n';
      store().moveUnder('a.ts', 'b.ts');
      expect(store().bufferFor('a.ts'), isNull);
      expect(store().bufferFor('b.ts'), same(b));
      expect(b.path, 'b.ts');
      expect(store().dirtyPaths, {'b.ts'});
      expect(b.controller!.text, 'edited\n');
    });

    test('moveUnder on a folder moves every buffer below it only', () async {
      for (final p in ['lib/a.ts', 'lib/deep/b.ts', 'lib2/c.ts']) {
        store().ensure(p, () async => FileContent(path: p, content: 'x\n'));
      }
      await settle();
      store().moveUnder('lib', 'src');
      expect(store().bufferFor('src/a.ts'), isNotNull);
      expect(store().bufferFor('src/deep/b.ts'), isNotNull);
      expect(store().bufferFor('lib2/c.ts'), isNotNull);
      expect(store().bufferFor('lib/a.ts'), isNull);
    });

    test('dirtyUnder counts unsaved files at or below a path', () async {
      final a = store().ensure(
        'lib/a.ts',
        () async => const FileContent(path: 'lib/a.ts', content: '1\n'),
      );
      store().ensure(
        'lib/b.ts',
        () async => const FileContent(path: 'lib/b.ts', content: '2\n'),
      );
      final o = store().ensure(
        'other.ts',
        () async => const FileContent(path: 'other.ts', content: '3\n'),
      );
      await settle();
      a.controller!.text = 'A\n';
      o.controller!.text = 'O\n';
      expect(store().dirtyUnder('lib'), {'lib/a.ts'});
      expect(store().dirtyUnder('lib/a.ts'), {'lib/a.ts'});
      expect(store().dirtyUnder('lib/b.ts'), isEmpty);
    });

    test('dropUnder discards dirty buffers so nothing is saved back', () async {
      final a = store().ensure(
        'lib/a.ts',
        () async => const FileContent(path: 'lib/a.ts', content: '1\n'),
      );
      await settle();
      a.controller!.text = 'A\n';
      store().dropUnder('lib');
      expect(store().bufferFor('lib/a.ts'), isNull);
      expect(store().dirtyPaths, isEmpty);

      final saved = <(String, String)>[];
      final actions = c.read(Provider((ref) => _Actions(ref, 'w', {}, saved)));
      await saveDirtyBuffers(store(), actions);
      expect(saved, isEmpty);
    });
  });

  group('EditBuffer.save', () {
    test(
      'a save asked for while one is in flight waits and writes once',
      () async {
        final b = store().ensure(
          'a.ts',
          () async => const FileContent(path: 'a.ts', content: '1\n'),
        );
        await settle();
        b.controller!.text = 'A\n';
        final gate = Completer<void>();
        final writes = <String>[];
        Future<String?> write(String s, String? etag) async {
          writes.add(s);
          await gate.future;
          return null;
        }

        final first = b.save(write);
        await settle();
        expect(b.saving, isTrue);
        final second = b.save(write);
        await settle();
        gate.complete();
        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(writes, ['A\n']);
        expect(b.dirty, isFalse);
      },
    );

    test(
      'an edit made while the first save runs is written by the second',
      () async {
        final b = store().ensure(
          'a.ts',
          () async => const FileContent(path: 'a.ts', content: '1\n'),
        );
        await settle();
        b.controller!.text = 'A\n';
        final gate = Completer<void>();
        final writes = <String>[];
        Future<String?> write(String s, String? etag) async {
          writes.add(s);
          if (writes.length == 1) await gate.future;
          return null;
        }

        final first = b.save(write);
        await settle();
        b.controller!.text = 'AB\n';
        final second = b.save(write);
        gate.complete();
        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(writes, ['A\n', 'AB\n']);
        expect(b.dirty, isFalse);
      },
    );
  });

  group('changed on disk', () {
    Future<EditBuffer> opened(String content, {String? etag = 'e1'}) async {
      final b = store().ensure(
        'a.ts',
        () async => FileContent(path: 'a.ts', content: content, etag: etag),
      );
      await settle();
      b.controller!.text = 'A\n';
      return b;
    }

    HaroApiException conflict(String reason) => HaroApiException(
      409,
      'file changed on disk',
      body: {'detail': 'file changed on disk', 'reason': reason},
    );

    test(
      'a save sends the etag it read, then the one the last write returned',
      () async {
        final b = await opened('1\n');
        final sent = <String?>[];
        Future<String?> write(String s, String? etag) async {
          sent.add(etag);
          return 'e${sent.length + 1}';
        }

        expect(await b.save(write), isTrue);
        b.controller!.text = 'B\n';
        expect(await b.save(write), isTrue);
        expect(sent, ['e1', 'e2']);
        expect(b.etag, 'e3');
      },
    );

    test('a backend without etags saves unguarded', () async {
      final b = await opened('1\n', etag: null);
      final sent = <String?>[];
      await b.save((s, etag) async {
        sent.add(etag);
        return null;
      });
      expect(sent, [null]);
      expect(b.etag, isNull);
    });

    test(
      'a 409 changed flags the conflict, keeps the edits, shows no error',
      () async {
        final b = await opened('1\n');
        final ok = await b.save((s, etag) async => throw conflict('changed'));
        expect(ok, isFalse);
        expect(b.diskConflict, isTrue);
        expect(b.missingOnDisk, isFalse);
        expect(b.saveError, isNull);
        expect(b.saving, isFalse);
        expect(b.dirty, isTrue);
        expect(b.controller!.text, 'A\n');
      },
    );

    test('a 409 deleted marks the file missing instead', () async {
      final b = await opened('1\n');
      final ok = await b.save((s, etag) async => throw conflict('deleted'));
      expect(ok, isFalse);
      expect(b.missingOnDisk, isTrue);
      expect(b.diskConflict, isFalse);
      expect(b.saveError, isNull);
    });

    test(
      'a missing file is not written until forced, and the force is unguarded',
      () async {
        final b = await opened('1\n');
        b.markMissing(true);
        final sent = <String?>[];
        Future<String?> write(String s, String? etag) async {
          sent.add(etag);
          return 'e9';
        }

        expect(await b.save(write), isFalse);
        expect(sent, isEmpty, reason: 'no silent recreate');
        expect(await b.save(write, force: true), isTrue);
        expect(sent, [null]);
        expect(b.missingOnDisk, isFalse);
        expect(b.etag, 'e9');
      },
    );

    test('a 409 from a force write cannot loop: force sends no etag', () async {
      final b = await opened('1\n');
      b.markDiskConflict(true);
      final sent = <String?>[];
      await b.save((s, etag) async {
        sent.add(etag);
        return 'e2';
      }, force: true);
      expect(sent, [null]);
      expect(b.diskConflict, isFalse);
    });

    test('refreshIfClean takes the disk text and etag, marks a 404, clears it when the file returns', () async {
      final b = store().ensure(
        'a.ts',
        () async => const FileContent(path: 'a.ts', content: '1\n', etag: 'e1'),
      );
      await settle();
      await b.refreshIfClean(
        () async =>
            const FileContent(path: 'a.ts', content: 'agent\n', etag: 'e2'),
      );
      expect(b.controller!.text, 'agent\n');
      expect(b.etag, 'e2');

      await b.refreshIfClean(
        () async => throw const HaroApiException(404, 'x'),
      );
      expect(b.missingOnDisk, isTrue);
      expect(b.controller!.text, 'agent\n', reason: 'the text stays');

      await b.refreshIfClean(
        () async =>
            const FileContent(path: 'a.ts', content: 'agent\n', etag: 'e2'),
      );
      expect(b.missingOnDisk, isFalse);
    });

    test('a 500 on refresh is not a deletion', () async {
      final b = store().ensure(
        'a.ts',
        () async => const FileContent(path: 'a.ts', content: '1\n'),
      );
      await settle();
      await b.refreshIfClean(
        () async => throw const HaroApiException(500, 'x'),
      );
      expect(b.missingOnDisk, isFalse);
    });

    test(
      'a dirty buffer whose file changed is flagged; the others still save',
      () async {
        final disk = {'a.ts': '1\n', 'b.ts': '2\n'};
        final saved = <(String, String)>[];
        final actions = c.read(
          Provider((ref) => _Actions(ref, 'w', disk, saved)),
        );
        final a = store().ensure('a.ts', () => actions.readFile('a.ts'));
        final b = store().ensure('b.ts', () => actions.readFile('b.ts'));
        await settle();
        a.controller!.text = 'A\n';
        b.controller!.text = 'B\n';
        disk['a.ts'] = 'agent\n';

        await expectLater(
          saveDirtyBuffers(store(), actions),
          throwsA(
            isA<HaroApiException>().having(
              (e) => e.message,
              'message',
              allOf(contains('a.ts'), contains('changed on disk')),
            ),
          ),
        );
        expect(saved, [('b.ts', 'B\n')]);
        expect(disk['a.ts'], 'agent\n', reason: 'the other change survives');
        expect(a.diskConflict, isTrue);
        expect(b.diskConflict, isFalse);
      },
    );

    test(
      'a dirty buffer whose file was deleted is flagged and not recreated',
      () async {
        final disk = {'a.ts': '1\n'};
        final saved = <(String, String)>[];
        final actions = c.read(
          Provider((ref) => _Actions(ref, 'w', disk, saved)),
        );
        final a = store().ensure('a.ts', () => actions.readFile('a.ts'));
        await settle();
        a.controller!.text = 'A\n';
        disk.remove('a.ts');

        await expectLater(
          saveDirtyBuffers(store(), actions),
          throwsA(
            isA<HaroApiException>().having(
              (e) => e.message,
              'message',
              allOf(contains('a.ts'), contains('deleted on disk')),
            ),
          ),
        );
        expect(saved, isEmpty);
        expect(disk, isEmpty);
        expect(a.missingOnDisk, isTrue);
      },
    );

    test('reloadFromDisk replaces the edits and clears the flag', () async {
      final disk = {'a.ts': '1\n'};
      final actions = c.read(Provider((ref) => _Actions(ref, 'w', disk, [])));
      final a = store().ensure('a.ts', () => actions.readFile('a.ts'));
      await settle();
      a.controller!.text = 'A\n';
      disk['a.ts'] = 'agent\n';
      a.markDiskConflict(true);
      await a.reloadFromDisk(() => actions.readFile('a.ts'));
      expect(a.controller!.text, 'agent\n');
      expect(a.dirty, isFalse);
      expect(a.diskConflict, isFalse);
    });

    test('undoing back to the saved text clears the conflict', () async {
      final a = store().ensure(
        'a.ts',
        () async => const FileContent(path: 'a.ts', content: '1\n'),
      );
      await settle();
      a.controller!.text = 'A\n';
      a.markDiskConflict(true);
      a.controller!.text = '1\n';
      expect(a.diskConflict, isFalse);
    });
  });

  group('git status json and the Changes checkbox model', () {
    test('partial and orig_path are read', () {
      final f = GitFileStatus.fromJson({
        'path': 'new name.ts',
        'index': 'renamed',
        'work': 'modified',
        'staged': true,
        'partial': true,
        'orig_path': 'old.ts',
      });
      expect(f.partial, isTrue);
      expect(f.origPath, 'old.ts');
      expect(GitFileStatus.fromJson({'path': 'x'}).partial, isFalse);
    });

    test('a partly staged file counts as staged, but not as all staged', () {
      final entries = changeEntries(
        GitStatusResponse(
          branch: 'b',
          baseRef: 'main',
          files: const [
            GitFileStatus(path: 'a.ts', index: 'modified', staged: true),
            GitFileStatus(
              path: 'b.ts',
              index: 'modified',
              work: 'modified',
              staged: true,
              partial: true,
            ),
          ],
        ),
        const [],
      );
      expect(stagedCount(entries), 2);
      expect(entries[1].partial, isTrue);
      expect(allFullyStaged(entries), isFalse);
      expect(allFullyStaged(entries.sublist(0, 1)), isTrue);
    });

    test('a merge conflict is carried through and left out of all staged', () {
      expect(
        GitFileStatus.fromJson({'path': 'c.ts', 'conflict': true}).conflict,
        isTrue,
      );
      final entries = changeEntries(
        GitStatusResponse(
          branch: 'b',
          baseRef: 'main',
          files: const [
            GitFileStatus(path: 'a.ts', index: 'modified', staged: true),
            GitFileStatus(path: 'c.ts', index: 'unmerged', conflict: true),
          ],
        ),
        const [],
      );
      expect(entries[1].conflict, isTrue);
      expect(allFullyStaged(entries), isTrue);
    });
  });

  group('withUnsavedEdits', () {
    NextAction gate() => const NextAction(NextActionKind.runGate, 'Run gate');

    test('the shortcut hint shows only when Run on save is on', () {
      final on = withUnsavedEdits(
        gate(),
        active: StepKey.code,
        dirty: true,
        runOnSave: true,
      );
      final off = withUnsavedEdits(gate(), active: StepKey.code, dirty: true);
      expect(on.kind, NextActionKind.saveAndRunGate);
      expect(on.saveShortcut, isTrue);
      expect(off.kind, NextActionKind.saveAndRunGate);
      expect(off.label, 'Save & run gate');
      expect(off.saveShortcut, isFalse);
    });
  });
}
