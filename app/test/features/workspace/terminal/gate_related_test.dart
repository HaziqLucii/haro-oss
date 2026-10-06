import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_detail_lazy.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/terminal/bottom_panel_provider.dart';
import 'package:haro_app/features/workspace/terminal/panel_model.dart';
import 'package:haro_app/features/workspace/terminal/related_tests.dart';
import 'package:haro_app/main.dart' show HaroApp;
import 'package:haro_app/state/live_gate.dart';

import '../../../state/builders.dart' as builders;
import '../harness.dart';

class _FakeApi extends HaroApi {
  _FakeApi({this.fail}) : super(Uri.parse('http://127.0.0.1:1'));

  final HaroApiException? fail;
  final calls = <(String, String)>[];

  @override
  Future<void> runRelated(String wsId, String path) async {
    calls.add((wsId, path));
    if (fail != null) throw fail!;
  }
}

ImpactResponse _impact({bool supported = true, String? error}) =>
    ImpactResponse(
      baseRef: 'main',
      supported: supported,
      error: error,
      changedFiles: const [ChangedFile(path: 'lib/rates.ts')],
    );

Rig _rig(_FakeApi api, {ImpactResponse? impact}) {
  final r = Rig(Preview.green);
  r.extra.addAll([
    haroApiProvider.overrideWithValue(api),
    workspaceImpactProvider.overrideWith(
      (ref, id) async => impact ?? _impact(),
    ),
    workspaceVerifiedHunksProvider.overrideWith((ref, id) async => null),
    workspaceReceiptProvider.overrideWith((ref, id) async => null),
  ]);
  return r;
}

Future<ProviderContainer> _openGate(WidgetTester t, Rig r, String? file) async {
  await r.pump(t);
  final c = ProviderScope.containerOf(t.element(find.byType(HaroApp)));
  c.read(bottomPanelProvider(id).notifier).show(BottomTab.gate);
  if (file != null) c.read(editorTabsProvider(id).notifier).open(file);
  await t.pumpAndSettle();
  return c;
}

void _setWatch(ProviderContainer c, LiveWatch w) {
  final n = c.read(workspaceDetailProvider(id).notifier);
  // ignore: invalid_use_of_protected_member
  n.state = n.state.copyWith(watch: w);
}

LiveWatch _settled(String runId, {int passed = 8}) => LiveWatch(
  run: builders.run(
    passed: passed,
    total: passed,
    overrides: {'id': runId, 'trigger': 'watch'},
  ),
);

Finder _row() => find.byKey(const ValueKey('panel-gate-related'));
Finder _status() => find.byKey(const ValueKey('panel-gate-related-status'));

void main() {
  group('canRunRelated', () {
    test('needs a supporting runner and a non-test script source file', () {
      expect(canRunRelated('lib/rates.ts', _impact()), isTrue);
      expect(canRunRelated('src/App.tsx', _impact()), isTrue);
      expect(canRunRelated('lib/rates.test.ts', _impact()), isFalse);
      expect(canRunRelated('lib/rates.spec.js', _impact()), isFalse);
      expect(canRunRelated('lib/__tests__/rates.ts', _impact()), isFalse);
      expect(canRunRelated('tests/rates.ts', _impact()), isFalse);
      expect(canRunRelated('README.md', _impact()), isFalse);
      expect(canRunRelated('lib/rates.ts', _impact(supported: false)), isFalse);
      expect(canRunRelated('lib/rates.ts', _impact(error: 'boom')), isFalse);
      expect(canRunRelated('lib/rates.ts', null), isFalse);
      expect(canRunRelated(null, _impact()), isFalse);
    });

    test('test paths across runners', () {
      for (final p in [
        'a.test.tsx',
        'b.spec.ts',
        'test_rates.py',
        'rates_test.go',
        'x/__tests__/y.js',
      ]) {
        expect(isTestPath(p), isTrue, reason: p);
      }
      expect(isTestPath('lib/rates.ts'), isFalse);
      expect(isTestPath('lib/latest.ts'), isFalse);
    });
  });

  group('HaroApi.runRelated', () {
    test('POSTs the path as a query and surfaces 409 and 400', () async {
      http.Request? seen;
      var status = 200;
      final api = HaroApi(
        Uri.parse('http://127.0.0.1:8000'),
        client: MockClient((req) async {
          seen = req;
          return http.Response(
            status == 200 ? '{"started": true}' : '{"detail": "busy"}',
            status,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await api.runRelated('ws_1', 'lib/rates.ts');
      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/workspaces/ws_1/watch/related');
      expect(seen!.url.queryParameters, {'path': 'lib/rates.ts'});

      status = 409;
      await expectLater(
        api.runRelated('ws_1', 'a.ts'),
        throwsA(isA<HaroApiException>().having((e) => e.status, 'status', 409)),
      );
      expect(await startRelatedRun(api, 'ws_1', 'a.ts'), contains('busy'));
    });
  });

  group('related run copy', () {
    test('409 and 400 are plain words', () {
      expect(
        relatedRunMessage(409, 'busy'),
        'The gate is busy. Try again once it finishes.',
      );
      expect(
        relatedRunMessage(400, 'pytest has no related mode'),
        'pytest has no related mode',
      );
      expect(
        relatedRunMessage(400, ''),
        'This runner cannot run the tests for one file.',
      );
      expect(relatedRunMessage(0, 'x'), 'Could not reach haro.');
    });

    test('the advisory line counts cells while running, then the run', () {
      expect(advisoryRunLine(LiveWatch.empty), isNull);
      const running = [
        Cell(id: 'a', file: 'f', name: 'a', status: CellStatus.passed),
        Cell(id: 'b', file: 'f', name: 'b', status: CellStatus.running),
        Cell(id: 'c', file: 'f', name: 'c', status: CellStatus.running),
      ];
      expect(
        advisoryRunLine(const LiveWatch(cells: running)),
        'Related run: 1 of 3 done.',
      );
      expect(
        advisoryRunLine(LiveWatch(run: builders.run(passed: 8, total: 8))),
        'Related run: 8 passed.',
      );
      expect(
        advisoryRunLine(
          LiveWatch(run: builders.run(status: 'failed', passed: 6, failed: 2)),
        ),
        'Related run: 2 failed, 6 passed.',
      );
    });
  });

  group('Gate tab row', () {
    testWidgets('shows for a source file and calls runRelated with its path', (
      t,
    ) async {
      final api = _FakeApi();
      await _openGate(t, _rig(api), 'lib/rates.ts');
      expect(_row(), findsOneWidget);
      await t.tap(_row());
      await t.pumpAndSettle();
      expect(api.calls, [(id, 'lib/rates.ts')]);
      expect(_status(), findsOneWidget);
      expect(find.text('Related run started.'), findsOneWidget);
    });

    testWidgets('a Live Gate run this row did not start shows no line', (
      t,
    ) async {
      final c = await _openGate(t, _rig(_FakeApi()), 'lib/rates.ts');
      _setWatch(c, _settled('live1'));
      await t.pumpAndSettle();
      expect(_row(), findsOneWidget);
      expect(_status(), findsNothing);
    });

    testWidgets(
      'after Run, the run already showing is skipped and the new one is the line',
      (t) async {
        final api = _FakeApi();
        final c = await _openGate(t, _rig(api), 'lib/rates.ts');
        _setWatch(c, _settled('old', passed: 3));
        await t.pumpAndSettle();
        await t.tap(_row());
        await t.pumpAndSettle();
        expect(find.text('Related run started.'), findsOneWidget);
        expect(find.text('Related run: 3 passed.'), findsNothing);

        _setWatch(c, _settled('new'));
        await t.pumpAndSettle();
        expect(find.text('Related run: 8 passed.'), findsOneWidget);
      },
    );

    testWidgets('another file never shows the evidence of this file\'s run', (
      t,
    ) async {
      final api = _FakeApi();
      final c = await _openGate(t, _rig(api), 'lib/rates.ts');
      await t.tap(_row());
      await t.pumpAndSettle();
      _setWatch(c, _settled('new'));
      await t.pumpAndSettle();
      expect(find.text('Related run: 8 passed.'), findsOneWidget);

      c.read(editorTabsProvider(id).notifier).open('lib/zones.ts');
      await t.pumpAndSettle();
      expect(_row(), findsOneWidget);
      expect(_status(), findsNothing);

      c.read(editorTabsProvider(id).notifier).open('lib/rates.ts');
      await t.pumpAndSettle();
      expect(_status(), findsNothing, reason: 'reset when the file changes');
    });

    testWidgets('hides for a test file, a non-script file and no file', (
      t,
    ) async {
      final api = _FakeApi();
      final c = await _openGate(t, _rig(api), null);
      expect(_row(), findsNothing);
      final tabs = c.read(editorTabsProvider(id).notifier);
      tabs.open('lib/rates.test.ts');
      await t.pumpAndSettle();
      expect(_row(), findsNothing);
      tabs.open('README.md');
      await t.pumpAndSettle();
      expect(_row(), findsNothing);
      tabs.open('lib/zones.ts');
      await t.pumpAndSettle();
      expect(_row(), findsOneWidget);
    });

    testWidgets('hides when the runner cannot name tests', (t) async {
      final api = _FakeApi();
      await _openGate(
        t,
        _rig(api, impact: _impact(supported: false)),
        'lib/rates.ts',
      );
      expect(_row(), findsNothing);
    });

    testWidgets('a busy gate says so in place', (t) async {
      final api = _FakeApi(fail: const HaroApiException(409, 'run in flight'));
      await _openGate(t, _rig(api), 'lib/rates.ts');
      await t.tap(_row());
      await t.pumpAndSettle();
      expect(
        find.text('The gate is busy. Try again once it finishes.'),
        findsOneWidget,
      );
    });

    testWidgets('an unsupported runner shows the backend reason', (t) async {
      final api = _FakeApi(
        fail: const HaroApiException(400, 'This runner has no related mode.'),
      );
      await _openGate(t, _rig(api), 'lib/rates.ts');
      await t.tap(_row());
      await t.pumpAndSettle();
      expect(find.text('This runner has no related mode.'), findsOneWidget);
    });
  });
}
