import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/backlog/backlog_page.dart';
import 'package:haro_app/features/backlog/quick_switcher.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_tag.dart';

import '../creation_harness.dart';
import 'backlog_test.dart' show backend;

const _note = '''---
title: Plan
tags:
  - sap
---

# Plan

Read [[source-materials/report.pdf]] first.

![[banners/hero.png]]
''';

MockBackend _vault({int files = 3}) => backend()
  ..routes['GET /projects/p1/notes'] = ((_) => jsonRes({
    'notes': [
      {
        'path': 'plan.md',
        'title': 'Plan',
        'modified': DateTime.now().millisecondsSinceEpoch / 1000,
        'size': 100,
        'snippets': <String>[],
      },
    ],
  }))
  ..routes['GET /projects/p1/notes/files'] = ((_) => jsonRes({
    'files': [
      for (var i = 0; i < files; i++)
        {
          'path': i == 0
              ? 'source-materials/report.pdf'
              : 'source-materials/file-$i.xlsx',
          'name': i == 0 ? 'report.pdf' : 'file-$i.xlsx',
          'kind': i == 0 ? 'pdf' : 'sheet',
          'size': 2048 * (i + 1),
          'modified': 1.0,
        },
    ],
  }))
  ..routes['POST /projects/p1/notes/files/open'] = ((_) =>
      jsonRes({'ok': true}))
  ..routes['GET /projects/p1/notes/file'] = ((_) =>
      jsonRes({'path': 'plan.md', 'content': _note, 'etag': 'e1'}))
  ..routes['GET /projects/p1/notes/links'] = ((c) => jsonRes({
    'path': 'plan.md',
    'tags': <String>[],
    'outgoing': [
      {
        'target': 'source-materials/report.pdf',
        'path': null,
        'file': 'source-materials/report.pdf',
      },
    ],
    'backlinks': <Map<String, dynamic>>[],
    'mentions': <Map<String, dynamic>>[],
  }));

Future<Harness> _open(WidgetTester tester, MockBackend b) => pumpCreation(
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

final _palettes = <String, HaroPalette>{
  'haro': HaroPalette.haro,
  'material3': HaroPalette.material3,
  'paper': HaroPalette.paper,
};

void main() {
  setUpAll(loadBrandFonts);

  for (final entry in _palettes.entries) {
    group('files beside the notes in the ${entry.key} theme', () {
      setUp(() => HaroTokens.apply(entry.value));
      tearDown(() => HaroTokens.apply(HaroPalette.haro));

      testWidgets('are listed under the notes and open with the system app', (
        tester,
      ) async {
        final b = _vault();
        await _open(tester, b);
        await tester.tap(find.byKey(const Key('bl-tab-notes')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('notes-tree')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('notes-folder-source-materials')),
            matching: find.widgetWithText(HaroTag, '3'),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('notes-file-source-materials/report.pdf')),
        );
        await tester.pumpAndSettle();
        final post = b.where('POST', '/projects/p1/notes/files/open').single;
        expect(post.body, {'path': 'source-materials/report.pdf'});
        expect(tester.takeException(), isNull);
      });

      testWidgets('a big tree starts folded and its folder opens it', (
        tester,
      ) async {
        await _open(tester, _vault(files: 45));
        await tester.tap(find.byKey(const Key('bl-tab-notes')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('notes-file-source-materials/file-1.xlsx')),
          findsNothing,
        );
        await tester.tap(
          find.byKey(const Key('notes-folder-source-materials')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('notes-file-source-materials/file-1.xlsx')),
          findsOneWidget,
        );
      });

      testWidgets(
        'a note shows its properties, and the files it links as buttons',
        (tester) async {
          final b = _vault();
          await _open(tester, b);
          await tester.tap(find.byKey(const Key('bl-tab-notes')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('note-plan.md')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('notes-properties')), findsOneWidget);
          expect(find.text('sap'), findsOneWidget);
          expect(find.byKey(const Key('notes-linked-files')), findsOneWidget);
          await tester.tap(
            find.byKey(
              const Key('notes-linked-file-source-materials/report.pdf'),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            b.where('POST', '/projects/p1/notes/files/open'),
            hasLength(1),
          );
          expect(
            find.textContaining('title: Plan'),
            findsNothing,
            reason: 'not shown as raw text',
          );
          expect(tester.takeException(), isNull);
        },
      );
    });
  }

  testWidgets(
    'the quick switcher opens a file result instead of changing page',
    (tester) async {
      final b = _vault()
        ..routes['GET /projects/p1/find'] = ((_) => jsonRes({
          'results': [
            {
              'kind': 'file',
              'title': 'report.pdf',
              'path': 'source-materials/report.pdf',
              'subtitle': 'source-materials/report.pdf',
              'snippet': 'VPN tunnel status',
              'tags': <String>[],
              'file_kind': 'pdf',
            },
          ],
        }));
      final h = await pumpCreation(
        tester,
        backend: b,
        projects: [project('p1', 'haro')],
        open: (c) => showQuickSwitcher(c),
      );
      await tester.enterText(find.byKey(const Key('switcher-field')), 'tunnel');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('report.pdf'));
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects/p1/notes/files/open').single.body, {
        'path': 'source-materials/report.pdf',
      });
      expect(h.location, isNot(startsWith('/backlog')));
    },
  );
}
