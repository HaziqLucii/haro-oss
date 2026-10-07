import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/features/workspace/steps/code/code_buffers.dart';
import 'package:haro_app/features/workspace/steps/code/edit_buffer.dart';

class _Actions extends WorkspaceActions {
  _Actions(super.ref, super.workspaceId, this.saved, {this.failOn});

  final List<(String, String)> saved;
  final String? failOn;

  @override
  Future<String?> saveFile(
    String path,
    String content, {
    String? expectedEtag,
  }) async {
    if (path == failOn) throw const HaroApiException(500, 'disk full');
    saved.add((path, content));
    return null;
  }
}

Future<FileContent> Function() file(String path, String content) =>
    () async => FileContent(path: path, content: content);

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late ProviderContainer c;
  late ProviderSubscription<CodeBufferStore> sub;

  CodeBufferStore store() => c.read(codeBuffersProvider('w'));

  setUp(() {
    c = ProviderContainer();
    sub = c.listen(codeBuffersProvider('w'), (_, _) {});
  });
  tearDown(() => c.dispose());

  group('one buffer per path', () {
    test('ensure creates once and hands the same buffer back', () async {
      var reads = 0;
      Future<FileContent> read() async {
        reads++;
        return const FileContent(path: 'a', content: 'x\n');
      }

      final first = store().ensure('a', read);
      final again = store().ensure('a', read);
      await settle();
      expect(again, same(first));
      expect(reads, 1);
      expect(first.phase, BufferPhase.ready);
      expect(first.controller!.text, 'x\n');
    });

    test('different paths keep separate text', () async {
      final a = store().ensure('a', file('a', '1\n'));
      final b = store().ensure('b', file('b', '2\n'));
      await settle();
      a.controller!.text = 'one\n';
      expect(b.controller!.text, '2\n');
      expect(store().dirtyPaths, {'a'});
    });
  });

  group('unsaved edits are kept', () {
    test(
      'retainOnly drops clean buffers of closed tabs, never dirty ones',
      () async {
        final a = store().ensure('a', file('a', '1\n'));
        store().ensure('b', file('b', '2\n'));
        store().ensure('c', file('c', '3\n'));
        await settle();
        a.controller!.text = 'edited\n';

        store().retainOnly({'c'});
        expect(store().bufferFor('a'), same(a), reason: 'dirty');
        expect(store().bufferFor('b'), isNull);
        expect(store().bufferFor('c'), isNotNull);
      },
    );

    test('the store outlives its listener while something is dirty', () async {
      final a = store().ensure('a', file('a', '1\n'));
      await settle();
      a.controller!.text = 'edited\n';
      final held = store();

      sub.close();
      await settle();
      expect(c.read(codeBuffersProvider('w')), same(held));
      expect(held.bufferFor('a')!.controller!.text, 'edited\n');
    });

    test('a clean store is released once nothing listens', () async {
      final held = store();
      held.ensure('a', file('a', '1\n'));
      await settle();
      sub.close();
      await settle();
      expect(c.read(codeBuffersProvider('w')), isNot(same(held)));
    });

    test('discarding the last dirty buffer lets the store go', () async {
      final a = store().ensure('a', file('a', '1\n'));
      await settle();
      a.controller!.text = 'edited\n';
      final held = store();
      sub.close();
      await settle();

      held.drop('a');
      await settle();
      expect(c.read(codeBuffersProvider('w')), isNot(same(held)));
    });

    test('releaseClean keeps dirty buffers only', () async {
      final a = store().ensure('a', file('a', '1\n'));
      store().ensure('b', file('b', '2\n'));
      await settle();
      a.controller!.text = 'edited\n';
      store().releaseClean();
      expect(store().bufferFor('a'), isNotNull);
      expect(store().bufferFor('b'), isNull);
    });
  });

  group('refreshIfClean', () {
    test('swaps in what changed on disk and keeps the controller', () async {
      final b = store().ensure('a', file('a', 'old\n'));
      await settle();
      final controller = b.controller;
      await b.refreshIfClean(file('a', 'agent wrote this\n'));
      expect(b.controller, same(controller));
      expect(b.controller!.text, 'agent wrote this\n');
      expect(b.dirty, isFalse);
      expect(b.saved, 'agent wrote this\n');
    });

    test('never touches unsaved edits', () async {
      final b = store().ensure('a', file('a', 'old\n'));
      await settle();
      b.controller!.text = 'mine\n';
      await b.refreshIfClean(file('a', 'agent wrote this\n'));
      expect(b.controller!.text, 'mine\n');
      expect(b.dirty, isTrue);
    });

    test('an unreadable file leaves the buffer as it is', () async {
      final b = store().ensure('a', file('a', 'old\n'));
      await settle();
      await b.refreshIfClean(
        () async => const FileContent(path: 'a', error: 'binary'),
      );
      await b.refreshIfClean(
        () async => throw const HaroApiException(500, 'x'),
      );
      expect(b.controller!.text, 'old\n');
    });
  });

  group('saveDirtyBuffers', () {
    late List<(String, String)> saved;

    _Actions actions({String? failOn}) {
      saved = [];
      return c.read(
        Provider((ref) => _Actions(ref, 'w', saved, failOn: failOn)),
      );
    }

    test('writes every dirty file and none of the clean ones', () async {
      final a = store().ensure('a', file('a', '1\n'));
      final b = store().ensure('b', file('b', '2\n'));
      store().ensure('c', file('c', '3\n'));
      await settle();
      a.controller!.text = 'A\n';
      b.controller!.text = 'B\n';

      await saveDirtyBuffers(store(), actions());
      expect(saved.toSet(), {('a', 'A\n'), ('b', 'B\n')});
      expect(store().dirtyPaths, isEmpty);
    });

    test('stops on the first failure and says which file', () async {
      final a = store().ensure('a', file('a', '1\n'));
      await settle();
      a.controller!.text = 'A\n';
      await expectLater(
        saveDirtyBuffers(store(), actions(failOn: 'a')),
        throwsA(
          isA<HaroApiException>().having(
            (e) => e.message,
            'message',
            contains('disk full'),
          ),
        ),
      );
      expect(a.dirty, isTrue);
    });
  });
}
