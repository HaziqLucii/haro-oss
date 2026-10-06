import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/diff_model.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_marks.dart';

DiffFile fileOf(String raw) => parseUnifiedDiff(raw).single;

const _replace = '''diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -1,4 +1,8 @@
 keep
-old one
-old two
+new one
+new two
+extra
+extra 2
 keep2
+tail
''';

void main() {
  group('changeMarks', () {
    test('a block that replaces lines is modified, the surplus is added', () {
      final m = changeMarks(fileOf(_replace));
      expect(m[2], ChangeMark.modified);
      expect(m[3], ChangeMark.modified);
      expect(m[4], ChangeMark.added);
      expect(m[5], ChangeMark.added);
      expect(m[6], isNull, reason: 'context line');
      expect(m[7], ChangeMark.added);
    });

    test('a pure deletion marks nothing', () {
      final m = changeMarks(
        fileOf('''diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -1,3 +1,2 @@
 a
-gone
 b
'''),
      );
      expect(m, isEmpty);
    });

    test('a deleted file, a binary file and no file mark nothing', () {
      expect(changeMarks(null), isEmpty);
      expect(
        changeMarks(
          fileOf('''diff --git a/pic.png b/pic.png
index 1111111..2222222 100644
Binary files a/pic.png and b/pic.png differ
'''),
        ),
        isEmpty,
      );
      expect(
        changeMarks(
          fileOf('''diff --git a/gone.ts b/gone.ts
deleted file mode 100644
--- a/gone.ts
+++ /dev/null
@@ -1 +0,0 @@
-x
'''),
        ),
        isEmpty,
      );
    });

    test('a new file is all added', () {
      final m = changeMarks(
        fileOf('''diff --git a/n.ts b/n.ts
new file mode 100644
--- /dev/null
+++ b/n.ts
@@ -0,0 +1,2 @@
+a
+b
'''),
      );
      expect(m, {1: ChangeMark.added, 2: ChangeMark.added});
    });
  });

  group('ranLines', () {
    final file = fileOf(_replace);

    test('only added lines the suite hit get a dot', () {
      const proof = VerifiedFile(
        path: 'a.ts',
        inMap: true,
        lines: {1: 5, 2: 3, 3: 0, 4: null, 5: 1, 7: 2},
      );
      expect(ranLines(file, proof), {2, 5, 7});
    });

    test('context lines never get a dot even when hit', () {
      const proof = VerifiedFile(
        path: 'a.ts',
        inMap: true,
        lines: {1: 9, 6: 9},
      );
      expect(ranLines(file, proof), isEmpty);
    });

    test('a stale file, no proof or no file gives none', () {
      const stale = VerifiedFile(
        path: 'a.ts',
        inMap: true,
        stale: true,
        lines: {2: 3},
      );
      expect(ranLines(file, stale), isEmpty);
      expect(ranLines(file, null), isEmpty);
      expect(ranLines(null, stale), isEmpty);
    });
  });

  group('indent guides', () {
    test('unit is the smallest indent seen, two by default', () {
      expect(indentUnit(['a', '    b', '        c']), 4);
      expect(indentUnit(['a', '  b', '    c']), 2);
      expect(indentUnit(['a', 'b']), 2);
      expect(indentUnit(['a', ' b']), 2, reason: 'a single space is alignment');
    });

    test('guides fall at each nesting level, none for the first', () {
      expect(guideColumns(0, 2), isEmpty);
      expect(guideColumns(2, 2), isEmpty);
      expect(guideColumns(4, 2), [2]);
      expect(guideColumns(8, 4), [4]);
      expect(guideColumns(12, 4), [4, 8]);
    });

    test('leading columns count spaces and tabs', () {
      expect(leadingColumns('    x'), 4);
      expect(leadingColumns('\t\tx'), 4);
      expect(leadingColumns('\t  x', tab: 4), 6);
      expect(leadingColumns('x'), 0);
    });
  });
}
