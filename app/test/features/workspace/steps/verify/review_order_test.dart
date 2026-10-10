import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/diff_model.dart';
import 'package:haro_app/features/workspace/steps/code/proof.dart'
    show ProofIndex;
import 'package:haro_app/features/workspace/steps/verify/review_order.dart';

DiffFile file(
  String path, {
  int add = 3,
  int del = 0,
  DiffFileTag tag = DiffFileTag.none,
  bool binary = false,
}) => DiffFile()
  ..newPath = path
  ..oldPath = path
  ..additions = add
  ..deletions = del
  ..tag = tag
  ..isBinary = binary;

void main() {
  group('fileRole', () {
    test('boundary files: CI, dependencies, config, schema, auth', () {
      expect(fileRole(file('.github/workflows/ci.yml')), FileRole.ci);
      expect(fileRole(file('package.json')), FileRole.deps);
      expect(fileRole(file('apps/web/requirements-dev.txt')), FileRole.deps);
      expect(fileRole(file('vitest.config.ts')), FileRole.config);
      expect(fileRole(file('Dockerfile')), FileRole.config);
      expect(fileRole(file('.env.example')), FileRole.config);
      expect(
        fileRole(file('db/migrations/0003_add_users.sql')),
        FileRole.schema,
      );
      expect(fileRole(file('prisma/schema.prisma')), FileRole.schema);
      expect(fileRole(file('src/auth/session.ts')), FileRole.auth);
      expect(fileRole(file('src/auth.ts')), FileRole.auth);
    });

    test('tests are recognised by folder and by name', () {
      expect(fileRole(file('lib/slug.test.ts')), FileRole.test);
      expect(fileRole(file('tests/test_slugs.py')), FileRole.test);
      expect(fileRole(file('src/__tests__/a.ts')), FileRole.test);
      expect(fileRole(file('app/foo_spec.rb')), FileRole.test);
      expect(fileRole(file('lib/latest.ts')), FileRole.source);
    });

    test('generated files, lockfiles, binaries and pure renames are noise', () {
      expect(fileRole(file('package-lock.json')), FileRole.noise);
      expect(fileRole(file('dist/app.js')), FileRole.noise);
      expect(fileRole(file('src/__snapshots__/a.snap')), FileRole.noise);
      expect(fileRole(file('lib/model.g.dart')), FileRole.noise);
      expect(fileRole(file('logo.png', binary: true)), FileRole.noise);
      expect(
        fileRole(file('b.ts', add: 0, tag: DiffFileTag.renamed)),
        FileRole.noise,
      );
      expect(
        fileRole(file('b.ts', add: 4, tag: DiffFileTag.renamed)),
        FileRole.source,
      );
    });

    test('look-alikes are not boundary or generated', () {
      expect(fileRole(file('src/build/pipeline.ts')), FileRole.source);
      expect(fileRole(file('lib/out/writer.py')), FileRole.source);
      expect(fileRole(file('src/authors.ts')), FileRole.source);
      expect(fileRole(file('docs/security/overview.md')), FileRole.source);
      expect(fileRole(file('lib/author_card.dart')), FileRole.source);
      expect(fileRole(file('build/app.js')), FileRole.noise);
    });

    test('a test in an auth or migrations folder is still a test', () {
      expect(fileRole(file('tests/auth/login_test.py')), FileRole.test);
      expect(fileRole(file('src/auth.test.ts')), FileRole.test);
      expect(fileRole(file('db/migrations/0003_test.py')), FileRole.test);
    });

    test('everything else is source', () {
      expect(fileRole(file('lib/slug.ts')), FileRole.source);
      expect(roleBadge(file('lib/slug.ts')), isNull);
    });
  });

  group('badges', () {
    test('say what the file is, and flag a test that lost lines', () {
      expect(roleBadge(file('package.json')), 'DEPENDENCIES');
      expect(roleBadge(file('.github/workflows/ci.yml')), 'CI');
      expect(roleBadge(file('lib/a.test.ts', tag: DiffFileTag.added)), 'TEST');
      expect(roleBadge(file('lib/a.test.ts', add: 1, del: 4)), 'TEST EDITED');
      expect(roleBadge(file('lib/a.test.ts', add: 5, del: 2)), 'TEST');
      expect(roleBadge(file('lib/a.test.ts', add: 5)), 'TEST');
      expect(roleBadge(file('yarn.lock')), 'GENERATED');
      expect(roleBadge(file('x.png', binary: true)), 'BINARY');
    });
  });

  group('reviewOrder', () {
    final files = [
      file('yarn.lock'),
      file('lib/zeta.ts'),
      file('lib/alpha.ts'),
      file('lib/new.test.ts', tag: DiffFileTag.added),
      file('lib/old.test.ts', add: 0, del: 4),
      file('package.json'),
      file('.github/workflows/ci.yml'),
    ];

    List<String> order(ProofIndex? proof) => [
      for (final f in reviewOrder(files, proof)) f.path,
    ];

    test('boundary files and edited tests, then new tests, then source, generated last', () {
      expect(order(null), [
        '.github/workflows/ci.yml',
        'lib/old.test.ts',
        'package.json',
        'lib/new.test.ts',
        'lib/alpha.ts',
        'lib/zeta.ts',
        'yarn.lock',
      ]);
    });

    test('a file with lines the suite never ran comes before all of them', () {
      final f = file('lib/zeta.ts')..hunks.add(_hunk());
      final proof = {
        'lib/zeta.ts': const VerifiedFile(
          path: 'lib/zeta.ts',
          inMap: true,
          lines: {10: 0},
        ),
      };
      final sorted = reviewOrder([
        ...files.where((x) => x.path != 'lib/zeta.ts'),
        f,
      ], proof);
      expect(sorted.first.path, 'lib/zeta.ts');
      expect(sorted.last.path, 'yarn.lock');
    });
  });

  group('reviewSize', () {
    test('counts changed lines and files, and leaves generated files out', () {
      final s = reviewSize([
        file('lib/a.ts', add: 120, del: 30),
        file('lib/b.ts', add: 50),
        file('package-lock.json', add: 5000, del: 4000),
        file('logo.png', binary: true),
      ]);
      expect((s.lines, s.files, s.skipped), (200, 2, 2));
      expect(s.over, isFalse);
    });

    test('over means past 400 lines or 20 files', () {
      expect(reviewSize([file('a.ts', add: 401)]).over, isTrue);
      expect(reviewSize([file('a.ts', add: 400)]).over, isFalse);
      expect(
        reviewSize([for (var i = 0; i < 21; i++) file('f$i.ts', add: 1)]).over,
        isTrue,
      );
    });

    test('read time is lines at 400 an hour, rounded up to 5 minutes', () {
      expect(reviewSize([file('a.ts', add: 0)]).minutes, 0);
      expect(reviewSize([file('a.ts', add: 100)]).minutes, 15);
      expect(reviewSize([file('a.ts', add: 400)]).minutes, 60);
      expect(readTime(25), '25 min');
      expect(readTime(60), '1 h');
      expect(readTime(90), '1.5 h');
    });
  });
}

DiffHunk _hunk() {
  final h = DiffHunk(
    oldStart: 1,
    newStart: 8,
    section: '',
    header: '@@ -1,1 +8,3 @@',
  );
  h.lines.addAll([const DiffLine(DiffLineKind.add, 'x', newNo: 10)]);
  return h;
}
