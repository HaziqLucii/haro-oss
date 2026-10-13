import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/backlog/backlog_page.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_tag.dart';

import '../creation_harness.dart';
import 'backlog_test.dart' show backend;

Map<String, dynamic> _plan(
  String id,
  String title,
  String ws,
  List<(String, bool)> steps, {
  bool saved = false,
  String? guard,
  double created = 1760000000,
}) => {
  'workspace_id': 'ws_$ws',
  'workspace_name': ws,
  'workspace_mode': 'manual',
  'plan': {
    'id': id,
    'title': title,
    'prompt': 'Plan $title',
    'steps': [
      for (final (t, d) in steps) {'text': t, 'done': d},
    ],
    'why': 'Smallest change first.',
    'model': 'opus',
    'effort': 'high',
    'cost_usd': 0.42,
    'created_at': created,
    'saved': saved,
    'guard_note': guard,
    'blocked_calls': <String>[],
  },
};

MockBackend _b(List<Map<String, dynamic>> plans) =>
    backend()
      ..routes['GET /projects/p1/plans'] = ((_) => jsonRes({'plans': plans}));

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
    group('the Plans tab in the ${entry.key} theme', () {
      setUp(() => HaroTokens.apply(entry.value));
      tearDown(() => HaroTokens.apply(HaroPalette.haro));

      testWidgets(
        'lists the plans with their workspace and progress, newest first',
        (tester) async {
          await _open(
            tester,
            _b([
              _plan('plan_b', 'Cache the price list', 'price-sync', [
                ('a', true),
                ('b', false),
              ], saved: true),
              _plan('plan_a', 'Fix rounding', 'cart', [
                ('x', false),
              ], created: 1.0),
            ]),
          );
          expect(
            find.descendant(
              of: find.byKey(const Key('bl-tab-plans')),
              matching: find.text('2'),
            ),
            findsOneWidget,
            reason: 'the tab count',
          );
          await tester.tap(find.byKey(const Key('bl-tab-plans')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('plan-plan_b')), findsOneWidget);
          expect(find.byKey(const Key('plan-plan_a')), findsOneWidget);
          expect(
            tester.getTopLeft(find.byKey(const Key('plan-plan_b'))).dy,
            lessThan(
              tester.getTopLeft(find.byKey(const Key('plan-plan_a'))).dy,
            ),
          );
          expect(find.widgetWithText(HaroTag, '1 of 2'), findsOneWidget);
          expect(find.widgetWithText(HaroTag, 'saved'), findsWidgets);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('the selected plan shows its steps, why and guard note', (
        tester,
      ) async {
        await _open(
          tester,
          _b([
            _plan('plan_b', 'Cache the price list', 'price-sync', [
              ('Read the SAP price list', true),
              ('Write the cache', false),
            ], guard: 'AI edits: unverified, the gate was running.'),
            _plan('plan_a', 'Fix rounding', 'cart', [
              ('Round half up', false),
            ], created: 1.0),
          ]),
        );
        await tester.tap(find.byKey(const Key('bl-tab-plans')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('plan-steps')), findsOneWidget);
        expect(find.text('Read the SAP price list'), findsOneWidget);
        expect(find.text('Smallest change first.'), findsOneWidget);
        expect(find.byKey(const Key('plan-guard-note')), findsOneWidget);
        await tester.tap(find.byKey(const Key('plan-plan_a')));
        await tester.pumpAndSettle();
        expect(find.text('Round half up'), findsOneWidget);
        expect(find.byKey(const Key('plan-guard-note')), findsNothing);
      });

      testWidgets('Open workspace goes to that workspace', (tester) async {
        final h = await _open(
          tester,
          _b([
            _plan('plan_a', 'Fix rounding', 'cart', [('x', false)]),
          ]),
        );
        await tester.tap(find.byKey(const Key('bl-tab-plans')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('plan-open-workspace')));
        await tester.pumpAndSettle();
        expect(h.location, '/w/ws_cart/code');
      });

      testWidgets('with no plans it says how to make one', (tester) async {
        await _open(tester, _b([]));
        await tester.tap(find.byKey(const Key('bl-tab-plans')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('plans-empty')), findsOneWidget);
      });
    });
  }
}
