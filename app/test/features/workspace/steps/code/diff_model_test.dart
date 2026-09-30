import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/code/diff_model.dart';
import 'package:haro_app/state/diff_stats.dart';

import 'code_harness.dart';

void main() {
  group('parseUnifiedDiff', () {
    test('files, counts, hunks and line numbers', () {
      final files = parseUnifiedDiff(rates);
      expect(files.map((f) => f.path), [
        'lib/rates.ts',
        'README.md',
        'lib/zones.ts',
        'lib/old.ts',
      ]);
      final f = files.first;
      expect((f.additions, f.deletions), (3, 1));
      expect(f.hunks, hasLength(1));
      final h = f.hunks.single;
      expect((h.oldStart, h.newStart), (1, 1));
      expect(h.section, 'export');
      expect(h.header, startsWith('@@ -1,5 +1,7 @@'));

      final kinds = h.lines.map((l) => l.kind).toList();
      expect(kinds, [
        DiffLineKind.context,
        DiffLineKind.del,
        DiffLineKind.add,
        DiffLineKind.add,
        DiffLineKind.add,
        DiffLineKind.context,
        DiffLineKind.context,
        DiffLineKind.context,
      ]);
      expect(h.lines[1].oldNo, 2);
      expect(h.lines[1].newNo, isNull);
      expect(h.lines[2].newNo, 2);
      expect(h.lines[4].newNo, 4);
      expect(h.lines[5].oldNo, 3);
      expect(h.lines[5].newNo, 5);
      expect(h.addedLineNos, [2, 3, 4]);
      expect(h.lines[0].text, "import { zone } from './zones';");
    });

    test('totals agree with parseDiffStats', () {
      final files = parseUnifiedDiff(rates);
      final stats = parseDiffStats(rates);
      expect(files.length, stats.files);
      expect(files.fold(0, (n, f) => n + f.additions), stats.added);
      expect(files.fold(0, (n, f) => n + f.deletions), stats.removed);
    });

    test('new, deleted and renamed files', () {
      const raw = '''diff --git a/a.txt b/a.txt
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/a.txt
@@ -0,0 +1 @@
+hi
diff --git a/b.txt b/b.txt
deleted file mode 100644
index 1111111..0000000
--- a/b.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
diff --git a/old/name.ts b/new/name.ts
similarity index 90%
rename from old/name.ts
rename to new/name.ts
index 1111111..2222222 100644
--- a/old/name.ts
+++ b/new/name.ts
@@ -1 +1 @@
-x
+y
''';
      final f = parseUnifiedDiff(raw);
      expect(f[0].tag, DiffFileTag.added);
      expect(f[0].path, 'a.txt');
      expect(f[1].tag, DiffFileTag.deleted);
      expect(f[1].path, 'b.txt');
      expect(f[2].tag, DiffFileTag.renamed);
      expect(f[2].oldPath, 'old/name.ts');
      expect(f[2].newPath, 'new/name.ts');
      expect(f[2].path, 'new/name.ts');
      expect(f[2].display, 'old/name.ts → new/name.ts');
    });

    test('rename with no content change has no hunks', () {
      const raw = '''diff --git a/x.ts b/y.ts
similarity index 100%
rename from x.ts
rename to y.ts
''';
      final f = parseUnifiedDiff(raw).single;
      expect(f.tag, DiffFileTag.renamed);
      expect(f.hunks, isEmpty);
      expect(f.isBinary, isFalse);
    });

    test('binary files', () {
      const raw = '''diff --git a/logo.png b/logo.png
index 1111111..2222222 100644
Binary files a/logo.png and b/logo.png differ
''';
      final f = parseUnifiedDiff(raw).single;
      expect(f.isBinary, isTrue);
      expect(f.hunks, isEmpty);
      expect(f.path, 'logo.png');
    });

    test(
      'no-newline marker annotates the line above, not a row of its own',
      () {
        const raw = '''diff --git a/n.txt b/n.txt
--- a/n.txt
+++ b/n.txt
@@ -1 +1 @@
-old
\\ No newline at end of file
+new
\\ No newline at end of file
''';
        final h = parseUnifiedDiff(raw).single.hunks.single;
        expect(h.lines, hasLength(2));
        expect(h.lines[0].noNewline, isTrue);
        expect(h.lines[1].noNewline, isTrue);
        expect(h.lines[1].text, 'new');
      },
    );

    test(
      'a removed line starting with dashes is content, not a file header',
      () {
        const raw = '''diff --git a/q.sql b/q.sql
--- a/q.sql
+++ b/q.sql
@@ -1,2 +1,2 @@
--- a comment
+-- a better comment
 select 1;
''';
        final f = parseUnifiedDiff(raw).single;
        expect(f.path, 'q.sql');
        expect(f.deletions, 1);
        expect(f.additions, 1);
        expect(f.hunks.single.lines.first.text, '-- a comment');
      },
    );

    test('the empty string after the final newline is not a context line', () {
      final f = parseUnifiedDiff(rates).last;
      expect(f.hunks.single.lines, hasLength(2));
    });

    test('empty and whitespace-only diffs parse to nothing', () {
      expect(parseUnifiedDiff(''), isEmpty);
      expect(parseUnifiedDiff('\n'), isEmpty);
    });

    test('CRLF line endings are stripped from displayed text', () {
      const raw =
          'diff --git a/w.txt b/w.txt\r\n--- a/w.txt\r\n+++ b/w.txt\r\n'
          '@@ -1 +1 @@\r\n-a\r\n+b\r\n';
      final h = parseUnifiedDiff(raw).single.hunks.single;
      expect(h.lines.map((l) => l.text), ['a', 'b']);
    });

    test('multiple hunks restart their line counters', () {
      const raw = '''diff --git a/m.txt b/m.txt
--- a/m.txt
+++ b/m.txt
@@ -1,2 +1,2 @@
 a
-b
+B
@@ -10,2 +10,3 @@
 j
+k
 l
''';
      final f = parseUnifiedDiff(raw).single;
      expect(f.hunks, hasLength(2));
      expect(f.hunks[1].newStart, 10);
      expect(f.hunks[1].lines[1].newNo, 11);
    });
  });

  test('basename and dirname', () {
    expect(basenameOf('a/b/c.ts'), 'c.ts');
    expect(dirnameOf('a/b/c.ts'), 'a/b');
    expect(basenameOf('c.ts'), 'c.ts');
    expect(dirnameOf('c.ts'), '');
  });
}
