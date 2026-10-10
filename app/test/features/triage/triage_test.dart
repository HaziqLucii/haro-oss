import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/review_queue_provider.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/data/xp_store.dart';
import 'package:haro_app/features/triage/triage_model.dart';
import 'package:haro_app/features/triage/projects_table.dart';
import 'package:haro_app/features/triage/triage_page.dart';
import 'package:haro_app/features/triage/triage_providers.dart';
import 'package:haro_app/features/triage/usage_meters.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/overlays/help_overlay.dart';
import 'package:haro_app/router.dart';
import 'package:haro_app/state/display_state.dart';

import '../../api/fixtures.dart';
import '../creation_harness.dart' as ch;
import '../../api/xp_api_test.dart' show xpJson;
import '../../shell/xp_shell_test.dart' show FakeXpStore;

class _FakeStore extends WorkspaceStore {
  _FakeStore(this.snapshot);

  final WorkspaceSnapshot snapshot;

  @override
  WorkspaceSnapshot build() => snapshot;
}

Workspace ws(
  String id, {
  String status = 'idle',
  Map<String, dynamic>? gate,
  String? name,
  double? createdAt,
  String project = 'p1',
  Map<String, dynamic>? overrides,
}) => Workspace.fromJson(
  workspaceJson(
    id: id,
    status: status,
    gate: gate,
    overrides: {
      'project_id': project,
      'name': name ?? id,
      'branch': 'feat/$id',
      'created_at': createdAt ?? 1790000000.5,
      ...?overrides,
    },
  ),
);

Project project(String id, String name) =>
    Project(id: id, name: name, path: '/x', defaultBranch: 'main');

WorkspaceSnapshot snapshot(
  List<Project> projects,
  Map<String, List<Workspace>> byProject,
) => WorkspaceSnapshot(loaded: true, projects: projects, workspaces: byProject);

/// 2 need you (red, green with two open look-at items), 1 running, 1 ready, 1 idle,
/// 2 merged.
WorkspaceSnapshot mixed() => snapshot(
  [project('p1', 'haro'), project('p2', 'gate-sandbox')],
  {
    'p1': [
      ws(
        'red-one',
        status: 'gate_red',
        gate: gateSummaryJson(status: 'failed', failed: 3, total: 16),
      ),
      ws('look-one', status: 'gate_green', gate: gateSummaryJson(unchecked: 2)),
      ws('run-one', status: 'agent_running'),
      ws(
        'ready-one',
        status: 'gate_green',
        gate: gateSummaryJson(unchecked: 0),
      ),
    ],
    'p2': [
      ws('idle-one'),
      ws('done-one', status: 'merged'),
      ws('done-two', status: 'merged'),
    ],
  },
);

Finder inPage(String text) =>
    find.descendant(of: find.byType(TriagePage), matching: find.text(text));

void main() {
  group('view', () {
    test('groups and filter counts', () {
      final v = buildTriageView(mixed());
      expect(v.workspaceCount, 7);
      expect(v.projectCount, 2);
      expect(v.countOf(TriageFilter.all), 7);
      expect(v.countOf(TriageFilter.needsYou), 2);
      expect(v.countOf(TriageFilter.running), 1);
      expect(v.countOf(TriageFilter.readyToShip), 1);
      expect(v.countOf(TriageFilter.idle), 1);
      expect(v.countOf(TriageFilter.merged), 2);
      expect(v.inGroup(TriageGroup.needsYou).map((r) => r.id), [
        'red-one',
        'look-one',
      ]);
      expect(v.inGroup(TriageGroup.needsYou).first.projectName, 'haro');
    });

    test('search matches name, branch and project, case-insensitively', () {
      final v = buildTriageView(mixed());
      expect(v.search('RED').rows.map((r) => r.id), ['red-one']);
      expect(v.search('feat/look').rows.map((r) => r.id), ['look-one']);
      expect(v.search('sandbox').rows.map((r) => r.id), [
        'idle-one',
        'done-one',
        'done-two',
      ]);
      expect(v.search('  ').rows, hasLength(7));
      expect(v.search('nothing like it').rows, isEmpty);
      expect(v.search('red').countOf(TriageFilter.needsYou), 1);
      expect(v.search('red').projects, v.projects);
    });

    test('headline wording', () {
      expect(triageHeadline(3), '3 workspaces need you.');
      expect(triageHeadline(1), '1 workspace needs you.');
      expect(triageHeadline(0), 'Nothing needs you.');
    });

    test('a test-first workspace awaiting approval needs you', () {
      final review = ws(
        'tf',
        overrides: {
          'test_first': {
            'phase': 'review',
            'cases': [
              {'file': 'a', 'name': 'n'},
            ],
          },
        },
      );
      final v = buildTriageView(
        snapshot(
          [project('p1', 'haro')],
          {
            'p1': [review],
          },
        ),
      );
      final row = v.inGroup(TriageGroup.needsYou).single;
      expect(row.flow.rowAction, 'Review acceptance test');
      expect(
        row.flow.rowDetail,
        'Acceptance test ready to approve · 1 red on base',
      );
    });

    test(
      'timestamp: gate end for settled, created for idle, none while live',
      () {
        final v = buildTriageView(mixed());
        double? at(String id) => v.rows.firstWhere((r) => r.id == id).at;
        expect(at('red-one'), 1790000100.0);
        expect(at('idle-one'), 1790000000.5);
        expect(at('run-one'), isNull);
      },
    );
  });

  group('page', () {
    Future<GoRouter> pump(
      WidgetTester tester,
      WorkspaceSnapshot snap, {
      Size size = const Size(1200, 800),
      List<Override> overrides = const [],
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = buildRouter();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            workspaceStoreProvider.overrideWith(() => _FakeStore(snap)),
            devicePrefsStoreProvider.overrideWithValue(
              MemoryDevicePrefsStore(),
            ),
            backendStatusProvider.overrideWith(
              (ref) => Stream.value(BackendStatus.up),
            ),
            ...overrides,
          ],
          child: HaroApp(router: router),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('header, chips and groups', (tester) async {
      await pump(tester, mixed(), size: const Size(1200, 2000));
      expect(find.textContaining('WORKSPACES · '), findsNothing);
      expect(find.textContaining('MONOCHROME'), findsNothing);
      expect(find.byType(RotatedBox), findsNothing);
      expect(find.text('2 workspaces need you.'), findsOneWidget);
      for (final t in [
        'NEEDS YOU',
        'RUNNING',
        'READY TO SHIP',
        'IDLE',
        'MERGED',
      ]) {
        expect(find.text(t), findsWidgets, reason: t);
      }
      expect(inPage('red-one'), findsOneWidget);
      expect(find.text('3 of 16 tests failing'), findsOneWidget);
      expect(inPage('done-one'), findsNothing, reason: 'merged is collapsed');
    });

    testWidgets('the header says how much work waits for review', (
      tester,
    ) async {
      await pump(
        tester,
        mixed(),
        size: const Size(1200, 2000),
        overrides: [
          reviewQueueProvider.overrideWith(
            (ref) async => const ReviewQueue(
              cap: 1,
              totalLines: 1240,
              workspaces: [
                ReviewQueueItem(workspaceId: 'a', lines: 900),
                ReviewQueueItem(workspaceId: 'b', lines: 340),
              ],
            ),
          ),
        ],
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('triage-review-queue')))
            .data,
        '2 WORKSPACES WAITING FOR YOUR REVIEW · 1,240 CHANGED LINES · OVER THE REVIEW LIMIT OF 1',
      );
    });

    testWidgets('hovering the queue line explains it', (tester) async {
      await pump(
        tester,
        mixed(),
        size: const Size(1200, 2000),
        overrides: [
          reviewQueueProvider.overrideWith(
            (ref) async => const ReviewQueue(
              cap: 3,
              totalLines: 648,
              workspaces: [ReviewQueueItem(workspaceId: 'a', lines: 648)],
            ),
          ),
        ],
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('triage-review-queue'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.textContaining('lines added plus removed'), findsOneWidget);
      expect(find.textContaining('review_cap'), findsOneWidget);
    });

    testWidgets('no queue line when nothing waits or the backend cannot say', (
      tester,
    ) async {
      await pump(tester, mixed(), size: const Size(1200, 2000));
      expect(find.byKey(const ValueKey('triage-review-queue')), findsNothing);
    });

    testWidgets('merged expands, filter narrows and is remembered', (
      tester,
    ) async {
      final router = await pump(tester, mixed(), size: const Size(1200, 2000));
      await tester.tap(find.text('SHOW'));
      await tester.pumpAndSettle();
      expect(inPage('done-one'), findsOneWidget);

      await tester.tap(find.text('Running'));
      await tester.pumpAndSettle();
      expect(inPage('run-one'), findsOneWidget);
      expect(inPage('red-one'), findsNothing);
      expect(inPage('ready-one'), findsNothing);

      router.go('/first-run');
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      expect(inPage('red-one'), findsNothing);
      expect(inPage('run-one'), findsOneWidget);
    });

    testWidgets('row click opens the default step', (tester) async {
      final router = await pump(tester, mixed(), size: const Size(1200, 2000));
      await tester.tap(inPage('red-one'));
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/w/red-one/verify',
      );
    });

    testWidgets('no streak nudge under the header, whatever today holds', (
      tester,
    ) async {
      for (final today in [false, true]) {
        await pump(
          tester,
          mixed(),
          size: const Size(1200, 2000),
          overrides: [
            xpStoreProvider.overrideWith(
              () => FakeXpStore(
                XpState(
                  status: XpStatus.fromJson(xpJson(days: 5, today: today)),
                ),
              ),
            ),
          ],
        );
        expect(find.textContaining('Finish one by hand today'), findsNothing);
        expect(find.byKey(const ValueKey('xp-nudge')), findsNothing);
      }
    });

    testWidgets(
      'wide header shows usage meters and the orb; narrow drops them',
      (tester) async {
        final usage = UsageResponse(
          available: true,
          limits: const [
            UsageLimit(kind: 'session', label: 'Current session', percent: 3),
            UsageLimit(
              kind: 'weekly_all',
              label: 'Weekly (all models)',
              percent: 84,
              severity: 'warning',
            ),
            UsageLimit(
              kind: 'weekly_scoped',
              label: 'Weekly (Fable)',
              percent: 0,
            ),
          ],
        );
        final over = [
          dashboardUsageProvider.overrideWith((ref) async => usage),
        ];
        await pump(
          tester,
          mixed(),
          size: const Size(1400, 2000),
          overrides: over,
        );
        expect(find.byKey(const ValueKey('usage-meters')), findsOneWidget);
        expect(find.text('SESSION'), findsOneWidget);
        expect(find.text('WEEK'), findsOneWidget);
        expect(find.text('84%'), findsOneWidget);
        expect(
          find.textContaining('FABLE'),
          findsNothing,
          reason: 'untouched window',
        );
        expect(find.byKey(const ValueKey('dithered-orb')), findsOneWidget);

        await pump(
          tester,
          mixed(),
          size: const Size(1100, 2000),
          overrides: over,
        );
        expect(find.byKey(const ValueKey('usage-meters')), findsOneWidget);
        expect(find.byKey(const ValueKey('dithered-orb')), findsNothing);

        await pump(
          tester,
          mixed(),
          size: const Size(900, 2000),
          overrides: over,
        );
        expect(find.byKey(const ValueKey('usage-meters')), findsNothing);
      },
    );

    testWidgets('no usage login means no meters, and nothing else moves', (
      tester,
    ) async {
      await pump(
        tester,
        mixed(),
        size: const Size(1200, 2000),
        overrides: [
          dashboardUsageProvider.overrideWith(
            (ref) async =>
                const UsageResponse(available: false, reason: 'no_credentials'),
          ),
        ],
      );
      expect(find.byKey(const ValueKey('usage-meters')), findsNothing);
      expect(find.text('2 workspaces need you.'), findsOneWidget);
    });

    testWidgets('empty state before load', (tester) async {
      await pump(tester, const WorkspaceSnapshot());
      expect(find.text('LOADING WORKSPACES'), findsOneWidget);
    });

    testWidgets('empty state with no workspaces', (tester) async {
      await pump(tester, snapshot([project('p1', 'haro')], {'p1': []}));
      expect(find.text('NO WORKSPACES YET'), findsOneWidget);
    });

    testWidgets('an empty dashboard points a newcomer at the guide', (
      tester,
    ) async {
      await pump(tester, snapshot([project('p1', 'haro')], {'p1': []}));
      expect(find.byKey(const ValueKey('triage-guide')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('triage-guide')));
      await tester.pumpAndSettle();
      expect(find.byType(HelpOverlay), findsOneWidget);
      expect(find.byKey(const ValueKey('help-guide')), findsOneWidget);
    });

    testWidgets('with no project at all there is a guide link too', (
      tester,
    ) async {
      await pump(tester, snapshot(const [], {}));
      expect(find.byKey(const ValueKey('triage-guide')), findsOneWidget);
    });

    testWidgets('while loading there is no guide link yet', (tester) async {
      await pump(tester, const WorkspaceSnapshot());
      expect(find.byKey(const ValueKey('triage-guide')), findsNothing);
    });

    testWidgets('no overflow at 900x640 inside the shell', (tester) async {
      await pump(tester, mixed(), size: const Size(900, 640));
      expect(tester.takeException(), isNull);
      final scrollable = find
          .descendant(
            of: find.byType(TriagePage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('SHOW'),
        300,
        scrollable: scrollable,
      );
      await tester.ensureVisible(find.text('SHOW'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SHOW'));
      await tester.pumpAndSettle();
      await tester.drag(scrollable, const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(inPage('done-one'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('layout', () {
    late ch.MockBackend backend;

    Future<void> pump(
      WidgetTester tester,
      WorkspaceSnapshot snap, {
      Size size = const Size(1200, 2000),
    }) async {
      backend = ch.MockBackend({
        'GET /projects/p1/sync': (_) => ch.jsonRes({'state': null}),
        'GET /projects/p2/sync': (_) => ch.jsonRes({'state': null}),
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            haroApiProvider.overrideWithValue(backend.api),
            workspaceStoreProvider.overrideWith(() => _FakeStore(snap)),
            devicePrefsStoreProvider.overrideWithValue(
              MemoryDevicePrefsStore(),
            ),
            backendStatusProvider.overrideWith(
              (ref) => Stream.value(BackendStatus.up),
            ),
          ],
          child: HaroApp(router: buildRouter()),
        ),
      );
      await tester.pumpAndSettle();
    }

    WorkspaceSnapshot idleMany(int n) => snapshot(
      [project('p1', 'haro')],
      {
        'p1': [for (var i = 0; i < n; i++) ws('idle-$i')],
      },
    );

    Finder search() => find.byKey(const ValueKey('triage-search'));

    testWidgets('workspaces and projects are two tabs with their counts', (
      tester,
    ) async {
      await pump(tester, mixed());
      expect(inPage('WORKSPACES'), findsOneWidget);
      expect(inPage('PROJECTS'), findsOneWidget);
      expect(inPage('NEEDS YOU'), findsOneWidget);
      expect(find.byType(ProjectsTable), findsNothing);
      await tester.tap(inPage('PROJECTS'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectsTable), findsOneWidget);
      expect(inPage('NEEDS YOU'), findsNothing);
      expect(inPage('gate-sandbox'), findsOneWidget);
      await tester.tap(inPage('WORKSPACES'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectsTable), findsNothing);
      expect(inPage('NEEDS YOU'), findsOneWidget);
    });

    testWidgets('with no workspaces the projects are still one tab away', (
      tester,
    ) async {
      await pump(tester, snapshot([project('p1', 'haro')], {'p1': []}));
      expect(inPage('NO WORKSPACES YET'), findsOneWidget);
      await tester.tap(inPage('PROJECTS'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectsTable), findsOneWidget);
    });

    testWidgets(
      'search filters the rows and the chip counts, and says when nothing matches',
      (tester) async {
        await pump(tester, mixed());
        await tester.enterText(search(), 'red');
        await tester.pumpAndSettle();
        expect(inPage('red-one'), findsOneWidget);
        expect(inPage('run-one'), findsNothing);
        expect(
          find
              .descendant(of: find.byType(TriagePage), matching: find.text('1'))
              .evaluate()
              .length,
          greaterThan(0),
        );
        await tester.enterText(search(), 'zzz');
        await tester.pumpAndSettle();
        expect(inPage('NO WORKSPACE MATCHES "ZZZ"'), findsOneWidget);
        await tester.enterText(search(), '');
        await tester.pumpAndSettle();
        expect(inPage('run-one'), findsOneWidget);
      },
    );

    testWidgets(
      'a search finds a merged workspace without opening Merged by hand',
      (tester) async {
        await pump(tester, mixed());
        expect(inPage('done-one'), findsNothing);
        await tester.enterText(search(), 'done-on');
        await tester.pumpAndSettle();
        expect(inPage('done-one'), findsOneWidget);
      },
    );

    testWidgets('a group folds from its header, needs-you cannot', (
      tester,
    ) async {
      await pump(tester, mixed());
      expect(inPage('idle-one'), findsOneWidget);
      await tester.tap(inPage('Waiting for a task'));
      await tester.pumpAndSettle();
      expect(inPage('idle-one'), findsNothing);
      await tester.tap(inPage('Waiting for a task'));
      await tester.pumpAndSettle();
      expect(inPage('idle-one'), findsOneWidget);
      await tester.tap(inPage('Decide, review or unblock'));
      await tester.pumpAndSettle();
      expect(inPage('red-one'), findsOneWidget);
    });

    testWidgets('a long idle list shows eight and a show-more line', (
      tester,
    ) async {
      await pump(tester, idleMany(12));
      expect(inPage('idle-0'), findsOneWidget);
      expect(inPage('idle-7'), findsOneWidget);
      expect(inPage('idle-8'), findsNothing);
      expect(inPage('SHOW 4 MORE'), findsOneWidget);
      await tester.tap(inPage('SHOW 4 MORE'));
      await tester.pumpAndSettle();
      expect(inPage('idle-11'), findsOneWidget);
      expect(inPage('SHOW 4 MORE'), findsNothing);
    });

    testWidgets('a group with something to do is never cut at eight', (
      tester,
    ) async {
      final ready = snapshot(
        [project('p1', 'haro')],
        {
          'p1': [
            for (var i = 0; i < 12; i++)
              ws(
                'ready-$i',
                status: 'gate_green',
                gate: gateSummaryJson(unchecked: 0),
              ),
          ],
        },
      );
      await pump(tester, ready, size: const Size(1200, 4000));
      expect(inPage('ready-11'), findsOneWidget);
      expect(inPage('SHOW 4 MORE'), findsNothing);
    });

    testWidgets(
      'a chip or a search that forces a group open takes its fold toggle away',
      (tester) async {
        await pump(tester, idleMany(3));
        expect(inPage('HIDE'), findsOneWidget);
        await tester.tap(inPage('Idle'));
        await tester.pumpAndSettle();
        expect(inPage('HIDE'), findsNothing);
      },
    );

    test('the fold state starts with merged folded and toggles per group', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(triageFoldProvider).closed, {TriageGroup.merged});
      c.read(triageFoldProvider.notifier).toggle(TriageGroup.idle);
      c.read(triageFoldProvider.notifier).toggle(TriageGroup.merged);
      expect(c.read(triageFoldProvider).closed, {TriageGroup.idle});
      c.read(triageFoldProvider.notifier).expand(TriageGroup.idle);
      expect(c.read(triageFoldProvider).expanded, {TriageGroup.idle});
    });

    testWidgets('its chip or a search shows the whole group', (tester) async {
      await pump(tester, idleMany(12));
      await tester.tap(inPage('Idle'));
      await tester.pumpAndSettle();
      expect(inPage('idle-11'), findsOneWidget);
      await tester.tap(inPage('All'));
      await tester.pumpAndSettle();
      expect(inPage('idle-11'), findsNothing);
      await tester.enterText(search(), 'idle');
      await tester.pumpAndSettle();
      expect(inPage('idle-11'), findsOneWidget);
    });

    testWidgets('needs-you and running are never cut short', (tester) async {
      final many = snapshot(
        [project('p1', 'haro')],
        {
          'p1': [
            for (var i = 0; i < 12; i++)
              ws(
                'red-$i',
                status: 'gate_red',
                gate: gateSummaryJson(status: 'failed', failed: 1, total: 4),
              ),
            for (var i = 0; i < 12; i++) ws('run-$i', status: 'agent_running'),
          ],
        },
      );
      await pump(tester, many, size: const Size(1200, 4000));
      expect(inPage('red-11'), findsOneWidget);
      expect(inPage('run-11'), findsOneWidget);
    });

    testWidgets('fits the smallest window with the tabs and search', (
      tester,
    ) async {
      await pump(tester, mixed(), size: const Size(960, 640));
      expect(tester.takeException(), isNull);
      await tester.tap(inPage('PROJECTS'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
