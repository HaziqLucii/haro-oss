import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/diff_model.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/changes_model.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/explorer_model.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/search_model.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/workbench_icons.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/workbench_state.dart';

FileNode f(String path) => FileNode(name: path.split('/').last, path: path);

FileNode d(String path, List<FileNode> kids) =>
    FileNode(name: path.split('/').last, path: path, dir: true, children: kids);

DiffFile change(String path, {DiffFileTag tag = DiffFileTag.none}) => DiffFile()
  ..newPath = path
  ..oldPath = path
  ..tag = tag;

final tree = [
  d('src', [
    d('src/billing', [f('src/billing/webhooks.ts'), f('src/billing/util.ts')]),
    f('src/index.ts'),
  ]),
  d('test', [f('test/a.test.ts')]),
  f('README.md'),
  f('Zed.md'),
];

List<String> paths(List<ExplorerRow> rows) => [for (final r in rows) r.path];

void main() {
  group('svg path parser', () {
    test('absolute and relative lines close into the expected bounds', () {
      final b = parseSvgPath('M2 3h4v5H2z').getBounds();
      expect(b, const Rect.fromLTRB(2, 3, 6, 8));
      final r = parseSvgPath('M1 1l3 0 0 2-3 0z').getBounds();
      expect(r, const Rect.fromLTRB(1, 1, 4, 3));
    });

    test('implicit repeats after M become lines', () {
      final b = parseSvgPath('M0 0 4 0 4 4').getBounds();
      expect(b, const Rect.fromLTRB(0, 0, 4, 4));
    });

    test('a relative curve is offset from the current point', () {
      final b = parseSvgPath('M5 5c0 3-4 3-6 6').getBounds();
      expect(b.left, lessThanOrEqualTo(-1));
      expect(b.bottom, closeTo(11, .01));
    });

    test('numbers glued by a minus sign split', () {
      final b = parseSvgPath('M4 9.5l3.2 3.2 6.8-7.4').getBounds();
      expect(b.right, closeTo(14, .01));
    });

    test('an unsupported command fails loudly', () {
      expect(() => parseSvgPath('M0 0 A5 5 0 0 1 9 9'), throwsFormatException);
      expect(() => parseSvgPath('5 5'), throwsFormatException);
    });

    test('every workbench icon parses and stays on the 18 grid', () {
      for (final icon in WorkbenchIcon.values) {
        for (final d in workbenchIconPaths(icon)) {
          final b = parseSvgPath(d).getBounds();
          expect(b.left, greaterThanOrEqualTo(0), reason: '$icon $d');
          expect(b.top, greaterThanOrEqualTo(0), reason: '$icon $d');
          expect(b.right, lessThanOrEqualTo(18), reason: '$icon $d');
          expect(b.bottom, lessThanOrEqualTo(18), reason: '$icon $d');
        }
      }
    });
  });

  group('explorer rows', () {
    final changed = {
      'src/billing/webhooks.ts': change('src/billing/webhooks.ts'),
      'README.md': change('README.md', tag: DiffFileTag.added),
    };

    test('collapsed: dirs first, then files by name, case-insensitive', () {
      final rows = allFilesRows(tree, expanded: {}, changed: changed);
      expect(paths(rows), ['src', 'test', 'README.md', 'Zed.md']);
    });

    test('an expanded folder shows its children, dirs first', () {
      final rows = allFilesRows(
        tree,
        expanded: {'src', 'src/billing'},
        changed: changed,
      );
      expect(paths(rows), [
        'src',
        'src/billing',
        'src/billing/util.ts',
        'src/billing/webhooks.ts',
        'src/index.ts',
        'test',
        'README.md',
        'Zed.md',
      ]);
      expect(rows[2].depth, 2);
      expect(rows[1].expanded, isTrue);
    });

    test('folders above a change carry the dot, files carry their letter', () {
      final rows = allFilesRows(
        tree,
        expanded: {'src', 'src/billing'},
        changed: changed,
      );
      ExplorerRow at(String p) => rows.firstWhere((r) => r.path == p);
      expect(at('src').hasChanges, isTrue);
      expect(at('src/billing').hasChanges, isTrue);
      expect(at('test').hasChanges, isFalse);
      expect(at('src/billing/webhooks.ts').letter, ChangeLetter.modified);
      expect(at('README.md').letter, ChangeLetter.added);
      expect(at('src/index.ts').letter, isNull);
    });

    test('a filter keeps matching files and the folders above, all open', () {
      final rows = allFilesRows(
        tree,
        expanded: {},
        changed: changed,
        filter: ' WEBHOOK ',
      );
      expect(paths(rows), ['src', 'src/billing', 'src/billing/webhooks.ts']);
      expect(
        allFilesRows(tree, expanded: {}, changed: {}, filter: 'zzz'),
        isEmpty,
      );
    });

    test('dirsWithChanges lists every ancestor once', () {
      expect(dirsWithChanges(['a/b/c.ts', 'a/d.ts', 'top.ts']), {'a', 'a/b'});
    });

    test('letters follow the diff tag', () {
      expect(letterOf(change('a')), ChangeLetter.modified);
      expect(
        letterOf(change('a', tag: DiffFileTag.deleted)),
        ChangeLetter.deleted,
      );
      expect(
        letterOf(change('a', tag: DiffFileTag.renamed)),
        ChangeLetter.renamed,
      );
      expect(ChangeLetter.added.text, 'A');
    });
  });

  group('changes list', () {
    test('grouped under their folder, root files first, filterable', () {
      final rows = changedRows([
        change('lib/zones.ts'),
        change('README.md'),
        change('lib/rates.ts'),
        change('app/main.ts'),
      ]);
      expect(paths(rows), [
        'README.md',
        '#app',
        'app/main.ts',
        '#lib',
        'lib/rates.ts',
        'lib/zones.ts',
      ]);
      expect(rows[1].isGroup, isTrue);
      expect(rows[2].depth, 1);
      expect(rows[0].depth, 0);
      expect(
        paths(
          changedRows([
            change('lib/zones.ts'),
            change('README.md'),
          ], filter: 'zon'),
        ),
        ['#lib', 'lib/zones.ts'],
      );
    });
  });

  group('keyboard navigation', () {
    final rows = allFilesRows(tree, expanded: {'src'}, changed: {});

    TreeNav press(String? cursor, TreeNavKey key, [List<ExplorerRow>? r]) =>
        navigateTree(r ?? rows, cursor, key);

    test('down and up walk the rows and stop at the ends', () {
      expect(press(null, TreeNavKey.down).cursor, 'src');
      expect(press('src', TreeNavKey.down).cursor, 'src/billing');
      expect(press('src/index.ts', TreeNavKey.down).cursor, 'test');
      expect(press(null, TreeNavKey.up).cursor, 'Zed.md');
      expect(press('Zed.md', TreeNavKey.down).cursor, isNull);
      expect(press('src', TreeNavKey.up).cursor, isNull);
    });

    test('right opens a closed folder, then steps into an open one', () {
      expect(press('test', TreeNavKey.right).expand, 'test');
      expect(press('src', TreeNavKey.right).cursor, 'src/billing');
      expect(press('README.md', TreeNavKey.right), same(TreeNav.none));
    });

    test('left closes an open folder, else jumps to the parent', () {
      expect(press('src', TreeNavKey.left).collapse, 'src');
      expect(press('src/index.ts', TreeNavKey.left).cursor, 'src');
      expect(press('README.md', TreeNavKey.left), same(TreeNav.none));
    });

    test('enter toggles a folder and opens a file', () {
      expect(press('src', TreeNavKey.enter).toggle, 'src');
      expect(press('src/index.ts', TreeNavKey.enter).open, 'src/index.ts');
      expect(press(null, TreeNavKey.enter), same(TreeNav.none));
    });

    test('group headings are skipped', () {
      final grouped = changedRows([change('a/x.ts'), change('b/y.ts')]);
      expect(press(null, TreeNavKey.down, grouped).cursor, 'a/x.ts');
      expect(press('a/x.ts', TreeNavKey.down, grouped).cursor, 'b/y.ts');
      expect(press('b/y.ts', TreeNavKey.up, grouped).cursor, 'a/x.ts');
    });
  });

  group('workbench state', () {
    test('ancestorsOf is outermost first', () {
      expect(ancestorsOf('a/b/c.ts'), ['a', 'a/b']);
      expect(ancestorsOf('c.ts'), isEmpty);
    });

    test('the side width is clamped to 220-460', () {
      expect(clampSideWidth(100), 220);
      expect(clampSideWidth(900), 460);
      expect(clampSideWidth(300), 300);
    });

    test('a narrow window shrinks the panel before the editor', () {
      expect(fitSideWidth(250, 1000), 250);
      expect(fitSideWidth(250, 452), 192);
      expect(fitSideWidth(250, 300), 140);
    });
  });

  group('search', () {
    SearchMatch m(String file, int line, String text) =>
        SearchMatch(file: file, line: line, text: text);

    test('a hit is cut around the query, case kept from the line', () {
      final h = snippetFor(
        m('a.ts', 7, '      const Rate = computeRate(zone);'),
        'rate',
      );
      expect(h.line, 7);
      expect(h.pre, 'const ');
      expect(h.match, 'Rate');
      expect(h.post, ' = computeRate(zone);');
    });

    test('a pattern that is not on the line marks nothing', () {
      final h = snippetFor(m('a.ts', 1, 'foo123'), r'\d+');
      expect(h.match, isEmpty);
      expect(h.post, 'foo123');
    });

    test('grouped by file in first-seen order', () {
      final groups = groupMatches([
        m('b.ts', 3, 'x'),
        m('a.ts', 1, 'x'),
        m('b.ts', 9, 'x'),
      ], 'x');
      expect([for (final g in groups) g.file], ['b.ts', 'a.ts']);
      expect([for (final h in groups.first.hits) h.line], [3, 9]);
    });

    test('the summary counts results and files, singular and truncated', () {
      SearchGroup g(String file, int n) => SearchGroup(file, [
        for (var i = 0; i < n; i++)
          SearchHit(line: i + 1, pre: '', match: '', post: ''),
      ]);
      expect(searchSummary([]), 'No results');
      expect(searchSummary([g('a', 1)]), '1 result in 1 file');
      expect(searchSummary([g('a', 2), g('b', 3)]), '5 results in 2 files');
      expect(
        searchSummary([g('a', 2), g('b', 3)], truncated: true),
        '5+ results in 2 files',
      );
    });
  });

  group('changes model', () {
    GitFileStatus st(String path, {String index = '', String work = ''}) =>
        GitFileStatus(
          path: path,
          index: index,
          work: work,
          staged: index.isNotEmpty && index != 'untracked',
        );

    test('letters come from git status, counts from the branch diff', () {
      final rates = change('lib/rates.ts')..additions = 3;
      final entries = changeEntries(
        GitStatusResponse(
          branch: 'b',
          baseRef: 'main',
          files: [
            st('new.ts', work: 'untracked'),
            st('lib/rates.ts', work: 'modified'),
            st('gone.ts', index: 'deleted'),
            st('moved.ts', index: 'renamed'),
          ],
        ),
        [rates],
      );
      expect(
        [for (final e in entries) e.path],
        ['gone.ts', 'lib/rates.ts', 'moved.ts', 'new.ts'],
      );
      expect([for (final e in entries) e.letter.text], ['D', 'M', 'R', 'A']);
      expect(entries[1].additions, 3);
      expect(entries[1].dir, 'lib');
      expect(entries[1].name, 'rates.ts');
    });

    test('staged count, commit gating and untracked folders', () {
      final entries = changeEntries(
        GitStatusResponse(
          branch: 'b',
          baseRef: 'main',
          files: [
            st('a.ts', index: 'modified'),
            st('assets/', work: 'untracked'),
          ],
        ),
        const [],
      );
      expect(stagedCount(entries), 1);
      expect(canCommit(entries, ''), isFalse);
      expect(canCommit(entries, '  '), isFalse);
      expect(canCommit(entries, 'msg'), isTrue);
      expect(canCommit(entries.sublist(1), 'msg'), isFalse);
      expect(entries[1].isDirectory, isTrue);
      expect(entries[1].name, 'assets/');
    });

    test('no status yet is an empty list', () {
      expect(changeEntries(null, const []), isEmpty);
    });
  });
}
