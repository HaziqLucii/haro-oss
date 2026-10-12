import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/fs_sync.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/workbench_state.dart';

FsEvent event(List<(String, FsChange)> paths, {bool truncated = false}) =>
    FsEvent(
      'changed',
      paths: [for (final p in paths) FsPathChange(p.$1, p.$2)],
      truncated: truncated,
    );

void main() {
  group('planFsEffects', () {
    test('modified files are not structural', () {
      final fx = planFsEffects(event([('a.ts', FsChange.modified)]));
      expect(fx.structural, isFalse);
      expect(fx.refreshAll, isFalse);
      expect(fx.modified, {'a.ts'});
    });

    test('an added or deleted file is structural', () {
      expect(
        planFsEffects(event([('a.ts', FsChange.added)])).structural,
        isTrue,
      );
      expect(
        planFsEffects(event([('a.ts', FsChange.deleted)])).structural,
        isTrue,
      );
    });

    test(
      'an added path the tree already lists is a rewrite, not structural',
      () {
        final fx = planFsEffects(
          event([('a.ts', FsChange.added)]),
          known: {'a.ts', 'b.ts'},
        );
        expect(fx.structural, isFalse);
        expect(fx.modified, {'a.ts'});
        expect(fx.added, isEmpty);
      },
    );

    test('an added path the tree does not list is structural', () {
      final fx = planFsEffects(
        event([('a.ts', FsChange.added), ('new.ts', FsChange.added)]),
        known: {'a.ts'},
      );
      expect(fx.structural, isTrue);
      expect(fx.added, {'new.ts'});
      expect(fx.modified, {'a.ts'});
    });

    test('a known path deleted in the same burst stays a delete', () {
      final fx = planFsEffects(
        event([('a.ts', FsChange.added), ('a.ts', FsChange.deleted)]),
        known: {'a.ts'},
      );
      expect(fx.structural, isTrue);
      expect(fx.deleted, {'a.ts'});
      expect(fx.added, isEmpty);
    });

    test('a truncated event is structural and refreshes everything', () {
      final fx = planFsEffects(
        event([('a.ts', FsChange.modified)], truncated: true),
      );
      expect(fx.structural, isTrue);
      expect(fx.refreshAll, isTrue);
    });

    test('an event without paths is the old-backend fallback', () {
      final fx = planFsEffects(const FsEvent('changed'));
      expect(fx.structural, isTrue);
      expect(fx.refreshAll, isTrue);
    });

    test('delete then add of one path in a burst is an add, and the reverse a delete', () {
      final a = planFsEffects(
        event([('a.ts', FsChange.deleted), ('a.ts', FsChange.added)]),
      );
      expect(a.added, {'a.ts'});
      expect(a.deleted, isEmpty);
      final b = planFsEffects(
        event([('a.ts', FsChange.added), ('a.ts', FsChange.deleted)]),
      );
      expect(b.deleted, {'a.ts'});
      expect(b.added, isEmpty);
    });
  });

  test('directoryPaths collects every folder at any depth', () {
    final nodes = [
      FileNode(
        name: 'lib',
        path: 'lib',
        dir: true,
        children: [
          FileNode(
            name: 'sub',
            path: 'lib/sub',
            dir: true,
            children: [FileNode(name: 'a.ts', path: 'lib/sub/a.ts')],
          ),
        ],
      ),
      FileNode(name: 'README.md', path: 'README.md'),
    ];
    expect(directoryPaths(nodes), {'lib', 'lib/sub'});
  });

  group('pruneExpanded', () {
    test('drops folders that no longer exist and keeps the rest', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(workbenchProvider('w').notifier)
        ..toggleDir('lib')
        ..toggleDir('gone')
        ..toggleDir('lib/sub');
      n.pruneExpanded({'lib', 'lib/sub'});
      expect(c.read(workbenchProvider('w')).expanded, {'lib', 'lib/sub'});
    });

    test('changes nothing, and does not notify, when every folder exists', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(workbenchProvider('w').notifier)..toggleDir('lib');
      var notified = 0;
      c.listen(workbenchProvider('w'), (_, _) => notified++);
      n.pruneExpanded({'lib', 'other'});
      expect(notified, 0);
    });
  });
}
