import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/backlog/backlog_page.dart';
import 'package:haro_app/features/backlog/file_tree.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_pressable.dart';
import 'package:haro_app/widgets/path_line.dart';
import 'package:haro_app/widgets/shell_icons.dart';

import '../creation_harness.dart';
import 'backlog_test.dart' show backend;

Map<String, dynamic> _n(String path, String title) => {
  'path': path,
  'title': title,
  'modified': DateTime.now().millisecondsSinceEpoch / 1000,
  'size': 100,
  'snippets': <String>[],
};

MockBackend _vault() => backend()
  ..routes['GET /projects/p1/notes'] = ((_) => jsonRes({
    'notes': [
      _n('ideas.md', 'Ideas'),
      _n('client-a/overview.md', 'Overview'),
      _n('client-a/integration-item-10/plan.md', 'Plan ten'),
      _n('client-a/integration-item-2/plan.md', 'Plan two'),
      _n('client-a/integration-item-1/plan.md', 'Plan one'),
    ],
  }))
  ..routes['GET /projects/p1/notes/files'] = ((_) => jsonRes({
    'files': [
      {
        'path': 'client-a/integration-item-2/spec.pdf',
        'name': 'spec.pdf',
        'kind': 'pdf',
        'size': 2048,
        'modified': 1.0,
      },
    ],
  }))
  ..routes['GET /projects/p1/notes/file'] = ((c) => jsonRes({
    'path': c.query['path'] ?? 'ideas.md',
    'content': '# Plan\n',
    'etag': 'e1',
  }))
  ..routes['GET /projects/p1/notes/links'] = ((_) => jsonRes({
    'path': 'ideas.md',
    'tags': <String>[],
    'outgoing': <Map<String, dynamic>>[],
    'backlinks': <Map<String, dynamic>>[],
    'mentions': <Map<String, dynamic>>[],
  }));

Future<Harness> _open(WidgetTester tester, MockBackend b) async {
  final h = await pumpCreation(
    tester,
    backend: b,
    projects: [project('p1', 'haro')],
    size: const Size(1500, 1000),
    open: (c) => Navigator.of(c).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: BacklogPage()),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('bl-tab-notes')));
  await tester.pumpAndSettle();
  return h;
}

Finder _folder(String path) => find.byKey(Key('notes-folder-$path'));

final _palettes = <String, HaroPalette>{
  'haro': HaroPalette.haro,
  'material3': HaroPalette.material3,
  'paper': HaroPalette.paper,
};

void main() {
  setUpAll(loadBrandFonts);

  group('the tree model', () {
    test('natural order: item-2 before item-10, folders before items', () {
      expect(compareNatural('item-2', 'item-10'), lessThan(0));
      expect(compareNatural('B', 'a'), greaterThan(0));
      expect(compareNatural('a1', 'a1'), 0);
      final root = buildTree<String>([
        'z.md',
        'a/x.md',
        'a/b/y.md',
        'item-10/p.md',
        'item-2/p.md',
      ], (p) => p);
      expect(root.folders.map((f) => f.name), ['a', 'item-2', 'item-10']);
      expect(root.items, ['z.md']);
      expect(root.folders.first.folders.single.path, 'a/b');
      expect(root.total, 5);
      expect(root.folders.first.total, 2);
    });

    test('a small tree opens fully, a big one only down to the open note', () {
      final small = buildTree<String>(['a/b/c.md', 'd/e.md'], (p) => p);
      expect(defaultExpanded(small, null), {'a', 'a/b', 'd'});
      final big = buildTree<String>([
        for (var i = 0; i < 50; i++) 'f$i/n.md',
      ], (p) => p);
      expect(defaultExpanded(big, null), isEmpty);
      expect(defaultExpanded(big, 'f7/n.md'), {'f7'});
      expect(ancestorsOf('a/b/c.md'), {'a', 'a/b'});
    });
  });

  for (final entry in _palettes.entries) {
    group('the notes tree in the ${entry.key} theme', () {
      setUp(() => HaroTokens.apply(entry.value));
      tearDown(() => HaroTokens.apply(HaroPalette.haro));

      testWidgets('nests folders, orders them naturally and opens a note', (
        tester,
      ) async {
        await _open(tester, _vault());
        for (final p in [
          'client-a',
          'client-a/integration-item-1',
          'client-a/integration-item-2',
          'client-a/integration-item-10',
        ]) {
          expect(_folder(p), findsOneWidget, reason: p);
        }
        final y = [
          for (final n in [1, 2, 10])
            tester.getTopLeft(_folder('client-a/integration-item-$n')).dy,
        ];
        expect(y, [...y]..sort());
        expect(
          tester.getTopLeft(_folder('client-a/integration-item-1')).dx,
          lessThan(
            tester
                    .getTopLeft(
                      find.byKey(const Key('note-client-a/overview.md')),
                    )
                    .dx +
                1,
          ),
        );
        expect(
          find.byKey(
            const Key('notes-file-client-a/integration-item-2/spec.pdf'),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('note-client-a/integration-item-2/plan.md')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Plan'), findsWidgets);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a folder folds and opens, with Lucide chevrons', (
        tester,
      ) async {
        await _open(tester, _vault());
        ShellIcon chevron() => tester
            .widgetList<ShellIconView>(
              find.descendant(
                of: _folder('client-a'),
                matching: find.byType(ShellIconView),
              ),
            )
            .first
            .icon;
        expect(chevron(), ShellIcon.chevronDown);
        await tester.tap(_folder('client-a'));
        await tester.pumpAndSettle();
        expect(chevron(), ShellIcon.chevronRight);
        expect(_folder('client-a/integration-item-1'), findsNothing);
        expect(
          find.byKey(const Key('note-client-a/overview.md')),
          findsNothing,
        );
        expect(find.byKey(const Key('note-ideas.md')), findsOneWidget);
        await tester.tap(_folder('client-a'));
        await tester.pumpAndSettle();
        expect(_folder('client-a/integration-item-1'), findsOneWidget);
        for (final glyph in ['▸', '▾', '›', '▶', '>']) {
          expect(
            find.descendant(
              of: find.byKey(const Key('notes-tree')),
              matching: find.text(glyph),
            ),
            findsNothing,
          );
        }
      });

      testWidgets('right-click a folder: New note here prefills its path', (
        tester,
      ) async {
        await _open(tester, _vault());
        await tester.tap(
          _folder('client-a/integration-item-2'),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('New note here'));
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(const Key('notes-name')),
            matching: find.byType(TextField),
          ),
        );
        expect(field.controller!.text, 'client-a/integration-item-2/');
      });

      testWidgets('Collapse all and Expand all act on the folder under it', (
        tester,
      ) async {
        await _open(tester, _vault());
        await tester.tap(_folder('client-a'), buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Collapse all'));
        await tester.pumpAndSettle();
        expect(_folder('client-a'), findsOneWidget);
        expect(_folder('client-a/integration-item-1'), findsNothing);
        await tester.tap(_folder('client-a'), buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Expand all'));
        await tester.pumpAndSettle();
        expect(_folder('client-a/integration-item-10'), findsOneWidget);
      });

      testWidgets(
        'a rename shows in the row (the file name), not only the path',
        (tester) async {
          var renamed = false;
          final b = _vault()
            ..routes['POST /projects/p1/notes/rename'] = ((_) {
              renamed = true;
              return jsonRes({'ok': true});
            })
            ..routes['GET /projects/p1/notes'] = ((_) => jsonRes({
              'notes': [
                _n(
                  renamed ? 'meeting-notes.md' : 'ideas.md',
                  'Questions to ask',
                ),
              ],
            }));
          await _open(tester, b);
          expect(find.text('ideas'), findsOneWidget);
          expect(find.text('Questions to ask'), findsNothing);
          await tester.tap(find.byKey(const Key('note-ideas.md')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('note-ideas.md')),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Rename'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.descendant(
              of: find.byKey(const Key('notes-name')),
              matching: find.byType(TextField),
            ),
            'meeting-notes',
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(find.text('meeting-notes'), findsOneWidget);
          expect(find.text('ideas'), findsNothing);
          expect(find.byKey(const Key('notes-path')), findsOneWidget);
          expect(
            tester.widget<PathLine>(find.byType(PathLine)).path,
            'meeting-notes.md',
          );
        },
      );

      testWidgets('searching leaves the tree for the flat list', (
        tester,
      ) async {
        final b = _vault()
          ..routes['GET /projects/p1/notes'] = ((c) => jsonRes({
            'notes': [
              _n('client-a/overview.md', 'Overview')
                ..['snippets'] = ['the vpn line'],
            ],
          }));
        await _open(tester, b);
        await tester.enterText(find.byKey(const Key('notes-search')), 'vpn');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('notes-tree')), findsNothing);
        expect(find.text('the vpn line'), findsOneWidget);
      });
    });
  }

  testWidgets('Expressive: a folder row ripples inside its own row', (
    tester,
  ) async {
    HaroTokens.apply(HaroPalette.material3);
    addTearDown(() => HaroTokens.apply(HaroPalette.haro));
    await _open(tester, _vault());
    final row = _folder('client-a');
    final size = tester.getSize(row);
    final press = await tester.startGesture(tester.getCenter(row));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));
    final clip = rippleClipBounds(
      tester
          .widget<CustomPaint>(
            find.descendant(
              of: row,
              matching: find.byKey(const ValueKey('ripple')),
            ),
          )
          .painter,
    )!.single;
    expect(clip.size, size);
    expect(size.height, 30);
    await press.cancel();
  });
}
