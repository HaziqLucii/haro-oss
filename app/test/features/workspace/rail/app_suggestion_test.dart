import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/features/workspace/rail/workspace_rail.dart';
import 'package:haro_app/widgets/haro_button.dart';

import '../harness.dart';

AppSuggestion suggestion({
  String path = '/api/slug',
  bool auto = false,
  DateTime? at,
}) => AppSuggestion(
  url: 'http://localhost:4500$path',
  path: path,
  auto: auto,
  at: at ?? DateTime.now(),
);

Rig rigWith(AppSuggestion? s) => Rig(
  Preview.green,
  detail: detailFor(
    Preview.green,
    runs: const {'app': DevRun(running: true, url: 'http://localhost:4500')},
  ).copyWith(appSuggestion: s),
);

void push(WidgetTester tester, AppSuggestion s) {
  final detail = ProviderScope.containerOf(
    tester.element(find.byType(WorkspaceRail)),
  ).read(workspaceDetailProvider(id).notifier) as FixedDetail;
  detail.push((d) => d.copyWith(appSuggestion: s));
}

const line = ValueKey('rail-app-suggestion');
const open = ValueKey('rail-app-suggestion-open');
const dismiss = ValueKey('rail-app-suggestion-dismiss');

void main() {
  group('the agent suggests a page', () {
    testWidgets('no line without a suggestion', (tester) async {
      await rigWith(null).pump(tester);
      expect(find.byKey(line), findsNothing);
    });

    testWidgets('the line names the path and Open launches its address', (
      tester,
    ) async {
      final rig = rigWith(suggestion());
      await rig.pump(tester);
      expect(find.byKey(line), findsOneWidget);
      expect(find.text('Agent suggests /api/slug'), findsOneWidget);
      final button = tester.widget<HaroButton>(find.byKey(open));
      expect(button.variant, HaroButtonVariant.control);
      expect(button.height, 28);
      await tester.tap(find.byKey(open));
      await tester.pumpAndSettle();
      expect(rig.opened, [Uri.parse('http://localhost:4500/api/slug')]);
      expect(
        find.byKey(line),
        findsOneWidget,
        reason: 'opening keeps the line',
      );
    });

    testWidgets('dismiss hides the line and opens nothing', (tester) async {
      final rig = rigWith(suggestion());
      await rig.pump(tester);
      await tester.tap(find.byKey(dismiss));
      await tester.pumpAndSettle();
      expect(find.byKey(line), findsNothing);
      expect(rig.opened, isEmpty);
    });

    testWidgets('a newer suggestion replaces the line', (tester) async {
      await rigWith(suggestion()).pump(tester);
      push(tester, suggestion(path: '/health'));
      await tester.pumpAndSettle();
      expect(find.text('Agent suggests /health'), findsOneWidget);
      expect(find.text('Agent suggests /api/slug'), findsNothing);
    });

    testWidgets('without auto, a live suggestion only shows the line', (
      tester,
    ) async {
      final rig = rigWith(null);
      await rig.pump(tester);
      push(tester, suggestion());
      await tester.pumpAndSettle();
      expect(find.byKey(line), findsOneWidget);
      expect(rig.opened, isEmpty);
    });

    testWidgets('auto opens a live suggestion once and keeps the line', (
      tester,
    ) async {
      final rig = rigWith(null);
      await rig.pump(tester);
      final s = suggestion(auto: true);
      push(tester, s);
      await tester.pumpAndSettle();
      expect(rig.opened, [Uri.parse('http://localhost:4500/api/slug')]);
      expect(find.byKey(line), findsOneWidget);
      push(tester, s);
      await tester.pumpAndSettle();
      expect(rig.opened, hasLength(1), reason: 'the same suggestion, once');
    });

    testWidgets('auto does not open one that is already there on load', (
      tester,
    ) async {
      final rig = rigWith(suggestion(auto: true));
      await rig.pump(tester);
      expect(find.byKey(line), findsOneWidget);
      expect(rig.opened, isEmpty);
    });

    testWidgets('auto does not open an old one that arrives late', (
      tester,
    ) async {
      final rig = rigWith(null);
      await rig.pump(tester);
      push(
        tester,
        suggestion(
          auto: true,
          at: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(line), findsOneWidget);
      expect(rig.opened, isEmpty);
    });
  });
}
