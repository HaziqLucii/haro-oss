import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/backlog/backlog_page.dart';
import 'package:haro_app/features/backlog/list_loading.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/agent_loader.dart';
import 'package:http/http.dart' as http;

import '../creation_harness.dart';
import 'backlog_test.dart' show backend, issue;

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

http.Response _issues(String state) => jsonRes({
  'available': true,
  'issues': [
    issue(
      state == 'closed' ? 3 : 41,
      state == 'closed' ? 'Old thing' : 'Fix the total',
      state: state,
    ),
  ],
});

void main() {
  setUpAll(loadBrandFonts);

  for (final entry in _palettes.entries) {
    group('while a list is being fetched, in the ${entry.key} theme', () {
      setUp(() => HaroTokens.apply(entry.value));
      tearDown(() => HaroTokens.apply(HaroPalette.haro));

      testWidgets('the issue list shows the loader, again on every refetch', (
        tester,
      ) async {
        var pending = Completer<http.Response>();
        final b = backend()
          ..routes['GET /projects/p1/issues'] = ((c) => pending.future);
        await _open(tester, b);
        await tester.tap(find.byKey(const Key('bl-tab-issues')));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(ListLoading), findsOneWidget);
        expect(find.byType(AgentLoader), findsOneWidget);
        expect(find.text('Fix the total'), findsNothing);

        pending.complete(_issues('open'));
        await tester.pumpAndSettle();
        expect(find.byType(ListLoading), findsNothing);
        expect(
          find.text('Fix the total'),
          findsNWidgets(2),
          reason: 'the row and the detail pane',
        );

        pending = Completer<http.Response>();
        await tester.tap(find.byKey(const Key('bl-state-closed')));
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          find.byType(ListLoading),
          findsOneWidget,
          reason: 'a new filter, a new fetch',
        );
        expect(
          find.text('Fix the total'),
          findsNWidgets(1),
          reason: 'only the detail pane: the list shows no old rows',
        );
        pending.complete(_issues('closed'));
        await tester.pumpAndSettle();
        expect(find.byType(ListLoading), findsNothing);
        expect(find.text('Old thing'), findsWidgets);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the TODOs list shows it while the files load', (
        tester,
      ) async {
        final pending = Completer<http.Response>();
        final b = backend()
          ..routes['GET /projects/p1/todo'] = ((c) => pending.future);
        await _open(tester, b);
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(ListLoading), findsOneWidget);
        pending.complete(
          jsonRes({'files': <Object>[], 'orphaned': <Object>[]}),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ListLoading), findsNothing);
      });

      testWidgets('the Notes list shows it, and so does a search', (
        tester,
      ) async {
        var pending = Completer<http.Response>();
        final b = backend()
          ..routes['GET /projects/p1/notes'] = ((c) => pending.future);
        await _open(tester, b);
        await tester.tap(find.byKey(const Key('bl-tab-notes')));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(ListLoading), findsOneWidget);
        pending.complete(jsonRes({'notes': <Object>[]}));
        await tester.pumpAndSettle();
        expect(find.byType(ListLoading), findsNothing);

        pending = Completer<http.Response>();
        await tester.enterText(find.byKey(const Key('notes-search')), 'redis');
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(ListLoading), findsOneWidget);
        pending.complete(jsonRes({'notes': <Object>[]}));
        await tester.pumpAndSettle();
        expect(find.byType(ListLoading), findsNothing);
      });

      testWidgets('the Plans list shows it', (tester) async {
        final pending = Completer<http.Response>();
        final b = backend()
          ..routes['GET /projects/p1/plans'] = ((c) => pending.future);
        await _open(tester, b);
        await tester.tap(find.byKey(const Key('bl-tab-plans')));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(ListLoading), findsOneWidget);
        pending.complete(jsonRes({'plans': <Object>[]}));
        await tester.pumpAndSettle();
        expect(find.byType(ListLoading), findsNothing);
      });
    });
  }
}
