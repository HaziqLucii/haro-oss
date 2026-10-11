import 'dart:async';

import 'package:flutter/material.dart' show Material, MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/workspace/rail/manual/manual_controller.dart';
import 'package:haro_app/features/workspace/rail/manual/manual_rail.dart';
import 'package:haro_app/features/workspace/rail/manual/manual_widgets.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/state/manual_rail.dart';
import 'package:haro_app/theme/haro_theme.dart';

import '../../api/fixtures.dart';
import 'harness.dart';
import 'steps/code/code_harness.dart';

const _plan = ManualPlan(
  id: 'plan_1',
  title: 'Wire the thing',
  steps: [
    PlanStep(text: 'Read the handler'),
    PlanStep(text: 'Add the table'),
    PlanStep(text: 'Dedupe in the transaction'),
  ],
  why: 'Read first, then change.',
);

const _guardNote =
    "haro couldn't check the files during this run because a gate, dev server or commit was writing to them (coverage.txt); the assistant had no edit tools.";

ManualPlan _noted({bool saved = false}) => ManualPlan(
  id: 'plan_1',
  title: 'Wire the thing',
  steps: _plan.steps,
  why: _plan.why,
  saved: saved,
  guardNote: _guardNote,
  blockedCalls: const ['Write', 'Bash', 'Write'],
);

const _footerZero = 'AI: plan and research only \u00b7 AI edits: 0';
const _footerUnverified =
    'AI: plan and research only \u00b7 AI edits: unverified';

class FakeAssistApi extends HaroApi {
  FakeAssistApi({this.pinned = const []})
    : super(Uri.parse('http://127.0.0.1:1'));

  final calls = <String>[];

  /// `kind:workspace` for every XP activity the client reported.
  final xp = <String>[];
  List<PinnedDoc> pinned;
  ManualPlan current = _plan;
  Object? failPatch;
  String? askJobId;

  /// What `GET /assist` answers (null: no job), and how often it and the workspace were read.
  AssistJob? job;
  Workspace? reloaded;
  int assistGets = 0;
  int workspaceGets = 0;

  /// When set, `GET /workspaces/{id}` waits for it (a resync that is still in flight).
  Completer<void>? workspaceGate;

  /// When set, `POST /assist/plan` waits for it.
  Completer<void>? planGate;

  /// When on, every patch waits for the test to settle it (true = saved, false = fails).
  bool gatePatches = false;
  final gates = <Completer<bool>>[];

  @override
  Future<AssistJob> assistPlan(
    String wsId,
    String prompt, {
    String? model,
    String? effort,
  }) async {
    calls.add('plan:$prompt|${model ?? '-'}|${effort ?? '-'}');
    await planGate?.future;
    return const AssistJob(id: 'job_1', kind: 'plan');
  }

  @override
  Future<AssistJob?> getAssistJob(String wsId) async {
    assistGets++;
    return job;
  }

  @override
  Future<Workspace> getWorkspace(String wsId) async {
    workspaceGets++;
    await workspaceGate?.future;
    return reloaded ?? (throw const HaroApiException(500, 'no workspace'));
  }

  @override
  Future<void> stopAssist(String wsId) async => calls.add('stop');

  @override
  Future<List<XpAward>> postXpActivity(
    String kind, {
    String? workspaceId,
    List<String> paths = const [],
  }) async {
    xp.add('$kind:$workspaceId');
    return const [];
  }

  @override
  Future<ManualPlan> patchPlan(
    String wsId,
    String planId, {
    String? title,
    List<PlanStep>? steps,
    bool? saved,
  }) async {
    calls.add(
      'patch:${title ?? '-'}|'
      '${steps == null ? '-' : steps.map((s) => '${s.text}:${s.done}').join(',')}|'
      '${saved ?? '-'}',
    );
    if (gatePatches) {
      final gate = Completer<bool>();
      gates.add(gate);
      if (!await gate.future) throw const HaroApiException(500, 'boom');
    }
    if (failPatch != null) throw failPatch!;
    current = current.copyWith(title: title, steps: steps, saved: saved);
    return current;
  }

  @override
  Future<void> deletePlan(String wsId, String planId) async =>
      calls.add('delete:$planId');

  @override
  Future<ResearchResponse> assistResearch(
    String wsId,
    String query, {
    String? model,
    String? effort,
  }) async {
    calls.add('ask:$query');
    return ResearchResponse(scope: 'ask', query: query, jobId: 'job_9');
  }

  @override
  Future<List<PinnedDoc>> getPinnedDocs(String projectId) async {
    calls.add('pinned:get');
    return pinned;
  }

  @override
  Future<List<PinnedDoc>> setPinnedDocs(
    String projectId,
    List<PinnedDoc> docs,
  ) async {
    calls.add('pinned:set:${docs.map((d) => d.url).join(',')}');
    pinned = [
      for (final d in docs)
        PinnedDoc(title: d.title.isEmpty ? 'link' : d.title, url: d.url),
    ];
    return pinned;
  }

  @override
  Future<ManPage> getManPage(String page) async {
    calls.add('man:$page');
    return ManPage(page: page, text: 'LS(1) manual text');
  }
}

Workspace _workspaceWith(
  List<ManualPlan> plans, {
  WorkspaceMode mode = WorkspaceMode.manual,
  Map<String, Object?>? researchLog,
}) => Workspace.fromJson(
  workspaceJson(
    id: id,
    status: 'idle',
    overrides: {
      'project_id': 'p1',
      'mode': mode.wire,
      'research_log': ?researchLog,
      'plans': [
        for (final p in plans)
          {
            'id': p.id,
            'title': p.title,
            'saved': p.saved,
            'why': p.why,
            'guard_note': p.guardNote,
            'blocked_calls': p.blockedCalls,
            'steps': [
              for (final s in p.steps) {'text': s.text, 'done': s.done},
            ],
          },
      ],
    },
  ),
);

/// The first Rig field that matters here: a manual workspace, plans optional, and the assist
/// channel driven by [events] (and its reconnect signal by [resync]).
Rig _rig(
  FakeAssistApi api,
  StreamController<AssistEvent> events, {
  List<ManualPlan> plans = const [],
  WorkspaceMode mode = WorkspaceMode.manual,
  bool code = false,
  StreamController<void>? resync,
  Map<String, Object?>? researchLog,
}) {
  final base = detailFor(Preview.idleWithChanges, mode: mode);
  final detail = base.copyWith(
    workspace: _workspaceWith(plans, mode: mode, researchLog: researchLog),
  );
  final rig = code
      ? CodeRig(mode: mode, preview: Preview.idleWithChanges)
      : Rig(Preview.idleWithChanges, detail: detail, mode: mode);
  rig.extra.addAll([
    haroApiProvider.overrideWithValue(api),
    assistEventsProvider.overrideWith((ref, wsId) => events.stream),
    if (resync != null)
      assistResyncProvider.overrideWith((ref, wsId) => resync.stream),
  ]);
  return rig;
}

Finder key(String k) => find.byKey(ValueKey(k));

Future<void> tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> emit(
  WidgetTester tester,
  StreamController<AssistEvent> events,
  AssistEvent e,
) async {
  events.add(e);
  await tester.pumpAndSettle();
}

List<String> allText(WidgetTester tester, Finder within) => [
  for (final t in tester.widgetList<Text>(
    find.descendant(of: within, matching: find.byType(Text)),
  ))
    t.data ?? t.textSpan?.toPlainText() ?? '',
];

const _big = Size(1400, 1500);

void main() {
  late StreamController<AssistEvent> events;
  late FakeAssistApi api;

  setUp(() {
    events = StreamController<AssistEvent>.broadcast();
    api = FakeAssistApi();
  });

  tearDown(() => events.close());

  testWidgets('manual rail shows Plan, Search and Docs and the honest footer', (
    tester,
  ) async {
    await _rig(api, events).pump(tester, size: _big);
    expect(key('manual-rail'), findsOneWidget);
    for (final t in ['plan', 'search', 'docs']) {
      expect(key('manual-tab-$t'), findsOneWidget);
    }
    expect(find.text('Plan'), findsWidgets);
    expect(
      tester.widget<Text>(key('manual-footer')).data,
      'AI: plan and research only · AI edits: 0',
    );
    await tap(tester, key('manual-tab-search'));
    expect(key('search-input'), findsOneWidget);
    expect(key('manual-footer'), findsOneWidget);
    await tap(tester, key('manual-tab-docs'));
    expect(key('docs-empty'), findsOneWidget);
    expect(key('manual-footer'), findsOneWidget);
    await tap(tester, key('manual-tab-plan'));
    expect(key('plan-input'), findsOneWidget);
  });

  testWidgets(
    'in a tall window the manual rail fills the rail, not a fixed box',
    (tester) async {
      await _rig(api, events).pump(tester, size: const Size(1440, 1100));
      final h = tester.getSize(key('manual-rail')).height;
      expect(h, greaterThan(manualRailHeight));
    },
  );

  testWidgets('in a short window the manual rail keeps its fixed height', (
    tester,
  ) async {
    await _rig(api, events).pump(tester, size: const Size(1440, 640));
    expect(tester.getSize(key('manual-rail')).height, manualRailHeight);
  });

  testWidgets('an agent workspace has no manual rail', (tester) async {
    await _rig(api, events, mode: WorkspaceMode.agent).pump(tester, size: _big);
    expect(key('manual-rail'), findsNothing);
    expect(key('manual-footer'), findsNothing);
  });

  testWidgets('no agent wording anywhere in the manual rail', (tester) async {
    final rig = _rig(
      FakeAssistApi(
        pinned: const [PinnedDoc(title: 'Stripe API', url: 'https://s.io')],
      ),
      events,
      plans: [_plan.copyWith(saved: true)],
    );
    await rig.pump(tester, size: _big);
    final rail = key('manual-rail');
    final seen = <String>[];
    for (final tab in ['plan', 'search', 'docs']) {
      await tap(tester, key('manual-tab-$tab'));
      seen.addAll(allText(tester, rail));
    }
    await tap(tester, key('manual-tab-plan'));
    await tap(tester, key('plan-new'));
    seen.addAll(allText(tester, rail));
    expect(seen.where((t) => t.trim().isNotEmpty), isNotEmpty);
    for (final t in seen) {
      expect(t.toLowerCase(), isNot(contains('agent')), reason: t);
    }
  });

  group('plan flow', () {
    testWidgets('empty, running, review, saved, with a tick that persists', (
      tester,
    ) async {
      await _rig(api, events).pump(tester, size: _big);
      expect(key('plan-input'), findsOneWidget);
      expect(find.text('YOUR PLAN'), findsOneWidget);
      expect(find.text('@ files · # issues'), findsOneWidget);
      // Plan it is disabled until there is text.
      await tester.tap(key('plan-it'), warnIfMissed: false);
      await tester.pump();
      expect(api.calls, isEmpty);

      await tester.enterText(key('plan-input'), 'add webhook dedupe');
      await tester.pump();
      await tap(tester, key('plan-it'));
      expect(api.calls, ['plan:add webhook dedupe|-|-']);
      expect(key('plan-stop'), findsOneWidget);
      expect(key('plan-input'), findsNothing);

      await emit(
        tester,
        events,
        const AssistEvent(job: 'plan', kind: 'token', text: 'Reading the repo'),
      );
      expect(find.text('Reading the repo'), findsOneWidget);

      await tap(tester, key('plan-stop'));
      expect(api.calls.last, 'stop');

      await emit(
        tester,
        events,
        const AssistEvent(job: 'plan', kind: 'stopped'),
      );
      expect(key('plan-input'), findsOneWidget);
      // The typed text survived the stop.
      expect(find.text('add webhook dedupe'), findsOneWidget);
      await tap(tester, key('plan-it'));

      await emit(
        tester,
        events,
        const AssistEvent(job: 'plan', kind: 'done', plan: _plan),
      );
      expect(find.text('Wire the thing'), findsOneWidget);
      expect(find.text('Read the handler'), findsOneWidget);
      expect(find.text('WHY THIS ORDER'), findsOneWidget);
      expect(find.text('Read first, then change.'), findsOneWidget);
      expect(find.text('Finish plan → save to Docs'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('0/3'), findsOneWidget);

      await tap(tester, key('plan-finish'));
      expect(api.calls.last, startsWith('patch:-|-|true'));
      expect(find.text('Saved as wire-the-thing.md in Docs'), findsOneWidget);
      expect(find.text('PLAN BY HARO · CODE BY YOU'), findsOneWidget);
      expect(find.text('0 / 3'), findsOneWidget);

      await tap(
        tester,
        find.descendant(
          of: key('saved-step-1'),
          matching: find.byType(ManualCheck),
        ),
      );
      expect(
        api.calls.last,
        'patch:-|Read the handler:false,Add the table:true,'
        'Dedupe in the transaction:false|-',
      );
      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
    });

    testWidgets('a failed tick is rolled back and says so', (tester) async {
      api.failPatch = const HaroApiException(500, 'disk full');
      await _rig(
        api,
        events,
        plans: [_plan.copyWith(saved: true)],
      ).pump(tester, size: _big);
      expect(find.text('0 / 3'), findsOneWidget);
      await tap(
        tester,
        find.descendant(
          of: key('saved-step-0'),
          matching: find.byType(ManualCheck),
        ),
      );
      expect(find.text('0 / 3'), findsOneWidget);
      expect(find.text('disk full'), findsOneWidget);
    });

    Finder tick(int i) => find.descendant(
      of: key('saved-step-$i'),
      matching: find.byType(ManualCheck),
    );

    testWidgets(
      'a failed early tick does not undo a later tick the server saved',
      (tester) async {
        api.gatePatches = true;
        api.current = _plan.copyWith(saved: true);
        await _rig(
          api,
          events,
          plans: [_plan.copyWith(saved: true)],
        ).pump(tester, size: _big);
        await tap(tester, tick(0));
        await tap(tester, tick(1));
        expect(find.text('2 / 3'), findsOneWidget);
        // Ticks go out in order: only the first request is in flight.
        expect(api.gates, hasLength(1));

        api.gates[0].complete(false);
        await tester.pumpAndSettle();
        expect(api.gates, hasLength(2));
        // The newer tick is still pending, so the screen keeps both.
        expect(find.text('2 / 3'), findsOneWidget);

        api.gates[1].complete(true);
        await tester.pumpAndSettle();
        expect(find.text('2 / 3'), findsOneWidget);
        expect(find.text('2/3'), findsOneWidget);
      },
    );

    testWidgets('a failed newest tick goes back to what the server has', (
      tester,
    ) async {
      api.gatePatches = true;
      api.current = _plan.copyWith(saved: true);
      await _rig(
        api,
        events,
        plans: [_plan.copyWith(saved: true)],
      ).pump(tester, size: _big);
      await tap(tester, tick(0));
      await tap(tester, tick(1));
      api.gates[0].complete(true);
      await tester.pumpAndSettle();
      api.gates[1].complete(false);
      await tester.pumpAndSettle();
      // Step 0 was saved, step 1 was not.
      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.text('boom'), findsOneWidget);
    });

    testWidgets('model and effort picks ride along with the request', (
      tester,
    ) async {
      await _rig(api, events).pump(tester, size: _big);
      await tap(tester, key('plan-model'));
      await tap(tester, find.text('opus'));
      await tap(tester, key('plan-effort'));
      await tap(tester, find.text('high'));
      await tester.enterText(key('plan-input'), 'x');
      await tester.pump();
      await tap(tester, key('plan-it'));
      expect(api.calls, ['plan:x|opus|high']);
    });

    testWidgets('a start error is shown and the form comes back', (
      tester,
    ) async {
      final busy = _FailingStart();
      await _rig(busy, events).pump(tester, size: _big);
      await tester.enterText(key('plan-input'), 'x');
      await tester.pump();
      await tap(tester, key('plan-it'));
      expect(
        find.text('the assistant is already working on something'),
        findsOneWidget,
      );
      expect(key('plan-input'), findsOneWidget);
    });

    testWidgets('an assist error event ends the run with its message', (
      tester,
    ) async {
      await _rig(api, events).pump(tester, size: _big);
      await tester.enterText(key('plan-input'), 'x');
      await tester.pump();
      await tap(tester, key('plan-it'));
      await emit(
        tester,
        events,
        const AssistEvent(
          job: 'plan',
          kind: 'error',
          message: 'the assistant changed files: this should be impossible',
        ),
      );
      expect(
        find.text('the assistant changed files: this should be impossible'),
        findsOneWidget,
      );
      expect(key('plan-input'), findsOneWidget);
    });

    testWidgets('edit saves a new title and steps; discard deletes', (
      tester,
    ) async {
      await _rig(api, events, plans: [_plan]).pump(tester, size: _big);
      expect(key('plan-finish'), findsOneWidget);
      await tap(tester, key('plan-edit'));
      await tester.enterText(key('edit-title'), 'Better');
      await tester.enterText(key('edit-step-1'), 'Add the table first');
      await tap(tester, key('edit-remove-2'));
      await tap(tester, key('edit-save'));
      expect(
        api.calls.last,
        'patch:Better|Read the handler:false,Add the table first:false|-',
      );
      expect(find.text('Better'), findsOneWidget);
      expect(find.text('Add the table first'), findsOneWidget);
      await tap(tester, key('plan-discard'));
      expect(api.calls.last, 'delete:plan_1');
      expect(key('plan-input'), findsOneWidget);
    });
  });

  group('run notes', () {
    testWidgets(
      'a plan the guard could not check says so, in review and saved',
      (tester) async {
        api.current = _noted();
        await _rig(api, events, plans: [_noted()]).pump(tester, size: _big);
        expect(tester.widget<Text>(key('plan-guard-note')).data, _guardNote);
        expect(
          tester.widget<Text>(key('plan-blocked')).data,
          "tried Write, Bash: not available to haro's assistant",
        );
        expect(
          tester.widget<Text>(key('manual-footer')).data,
          _footerUnverified,
        );

        await tap(tester, key('plan-finish'));
        expect(key('saved-step-0'), findsOneWidget);
        expect(tester.widget<Text>(key('plan-guard-note')).data, _guardNote);
        expect(key('plan-blocked'), findsOneWidget);
        expect(
          tester.widget<Text>(key('manual-footer')).data,
          _footerUnverified,
        );

        // Leaving the plan brings the honest 0 back: nothing on screen is unverified.
        await tap(tester, key('plan-new'));
        expect(tester.widget<Text>(key('manual-footer')).data, _footerZero);
      },
    );

    testWidgets(
      'a plan with nothing to report shows no notes and the plain footer',
      (tester) async {
        await _rig(api, events, plans: [_plan]).pump(tester, size: _big);
        expect(key('plan-guard-note'), findsNothing);
        expect(key('plan-blocked'), findsNothing);
        expect(tester.widget<Text>(key('manual-footer')).data, _footerZero);
      },
    );

    testWidgets('a finished run delivers its note with the plan', (
      tester,
    ) async {
      await _rig(api, events).pump(tester, size: _big);
      await tester.enterText(key('plan-input'), 'x');
      await tester.pump();
      await tap(tester, key('plan-it'));
      await emit(
        tester,
        events,
        AssistEvent(job: 'plan', kind: 'done', plan: _noted()),
      );
      expect(key('plan-guard-note'), findsOneWidget);
      expect(tester.widget<Text>(key('manual-footer')).data, _footerUnverified);
    });

    testWidgets('an ask answer carries its note and the footer follows it', (
      tester,
    ) async {
      await _rig(api, events).pump(tester, size: _big);
      await tap(tester, key('manual-tab-search'));
      await tester.enterText(key('search-input'), 'where');
      await tap(tester, key('search-go'));
      await emit(
        tester,
        events,
        const AssistEvent(
          job: 'research',
          kind: 'done',
          answer: 'In rates.ts.',
          guardNote: _guardNote,
          blockedCalls: ['Write'],
        ),
      );
      expect(tester.widget<Text>(key('search-guard-note')).data, _guardNote);
      expect(key('search-blocked'), findsOneWidget);
      expect(tester.widget<Text>(key('manual-footer')).data, _footerUnverified);

      // The next search starts clean.
      await tester.enterText(key('search-input'), 'again');
      await tap(tester, key('search-go'));
      expect(key('search-guard-note'), findsNothing);
      expect(tester.widget<Text>(key('manual-footer')).data, _footerZero);
    });
  });

  group('search', () {
    const repoRow = ResearchRow(
      source: 'repo',
      title: 'lib/rates.ts:2',
      target: 'lib/rates.ts:2',
      why: 'const base = 2;',
      action: 'jump',
    );
    const gitRow = ResearchRow(
      source: 'git',
      title: 'a41c9e2 handle webhooks',
      target: 'lib/zones.ts',
      why: 'changed the text',
      action: 'jump',
    );
    const webRow = ResearchRow(
      source: 'web',
      title: 'react.dev docs',
      target: 'https://duckduckgo.com/?q=site%3Areact.dev%20x',
      why: 'official',
      action: 'open',
    );
    const manRow = ResearchRow(
      source: 'man',
      title: 'ls(1)',
      target: 'ls(1)',
      why: 'list directory contents',
      action: 'read',
    );

    Future<void> ask(WidgetTester tester, String q) async {
      await tap(tester, key('manual-tab-search'));
      await tester.enterText(key('search-input'), q);
      await tap(tester, key('search-go'));
    }

    Future<void> answered(
      WidgetTester tester,
      List<ResearchRow> rows, {
      String text = 'Look here.',
    }) => emit(
      tester,
      events,
      AssistEvent(job: 'research', kind: 'done', answer: text, rows: rows),
    );

    testWidgets('one box: no scope chips, no scope hint, an Ask button', (
      tester,
    ) async {
      await _rig(api, events).pump(tester, size: _big);
      await tap(tester, key('manual-tab-search'));
      expect(key('search-empty'), findsOneWidget);
      expect(find.text('Ask where to look…'), findsOneWidget);
      expect(find.text('Where should I look?'), findsNothing);
      for (final s in ['repo', 'git', 'man', 'web', 'ask']) {
        expect(key('scope-$s'), findsNothing);
      }
      expect(key('scope-hint'), findsNothing);
      expect(
        find.descendant(
          of: key('manual-rail'),
          matching: find.byWidgetPredicate(
            (w) => w.runtimeType.toString().startsWith('HaroSegmented'),
          ),
        ),
        findsNothing,
      );
      expect(allText(tester, key('search-go')), ['Ask']);
      expect(key('search-stop'), findsNothing);
    });

    testWidgets('Enter runs the ask', (tester) async {
      await _rig(api, events).pump(tester, size: _big);
      await tap(tester, key('manual-tab-search'));
      await tester.enterText(key('search-input'), 'where is rate computed');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(api.calls, ['ask:where is rate computed']);
      expect(key('search-busy'), findsOneWidget);
      expect(key('search-stop'), findsOneWidget);
    });

    testWidgets('the Ask button runs it, a blank box runs nothing', (
      tester,
    ) async {
      await _rig(api, events).pump(tester, size: _big);
      await ask(tester, '   ');
      expect(api.calls, isEmpty);
      await tester.enterText(key('search-input'), '  why is base 2  ');
      await tap(tester, key('search-go'));
      expect(api.calls, ['ask:why is base 2']);
    });

    testWidgets('the answer sits above its sources, grouped by source', (
      tester,
    ) async {
      await _rig(api, events).pump(tester, size: _big);
      await ask(tester, 'where is rate computed');
      expect(key('search-busy'), findsOneWidget);
      await emit(
        tester,
        events,
        const AssistEvent(
          job: 'research',
          kind: 'done',
          answer: 'It lives in rates.ts.',
          rows: [gitRow, repoRow],
          note: '1 source(s) dropped: they pointed at nothing',
        ),
      );
      expect(key('search-busy'), findsNothing);
      expect(key('search-stop'), findsNothing);
      expect(find.text('It lives in rates.ts.'), findsOneWidget);
      expect(find.text('YOUR REPO'), findsOneWidget);
      expect(find.text('GIT'), findsOneWidget);
      expect(find.text('lib/rates.ts:2'), findsOneWidget);
      expect(find.text('a41c9e2 handle webhooks'), findsOneWidget);
      expect(find.text('const base = 2;'), findsOneWidget);
      expect(find.text('jump'), findsNWidgets(2));
      expect(
        find.text('1 source(s) dropped: they pointed at nothing'),
        findsOneWidget,
      );
      final answer = tester.getTopLeft(key('search-answer')).dy;
      final repo = tester.getTopLeft(find.text('YOUR REPO')).dy;
      final git = tester.getTopLeft(find.text('GIT')).dy;
      expect(answer, lessThan(repo));
      expect(repo, lessThan(git));
    });

    testWidgets('Stop ends the wait for the answer', (tester) async {
      await _rig(api, events).pump(tester, size: _big);
      await ask(tester, 'q');
      await tap(tester, key('search-stop'));
      expect(api.calls, ['ask:q', 'stop']);
      await emit(
        tester,
        events,
        const AssistEvent(job: 'research', kind: 'stopped'),
      );
      expect(key('search-stop'), findsNothing);
      expect(key('search-go'), findsOneWidget);
    });

    testWidgets('no sources says so', (tester) async {
      await _rig(api, events).pump(tester, size: _big);
      await ask(tester, 'nothing');
      await emit(
        tester,
        events,
        const AssistEvent(job: 'research', kind: 'done'),
      );
      expect(key('search-none'), findsOneWidget);
    });

    testWidgets('a repo source jumps in the editor at the line', (
      tester,
    ) async {
      final rig = _rig(api, events, code: true);
      final router = await rig.pump(tester, size: _big, step: 'verify');
      await ask(tester, 'base');
      await answered(tester, [repoRow]);
      await tap(tester, key('result-repo-0'));
      expect(pathOf(router), '/w/$id/code');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ManualRail)),
      );
      expect(container.read(editorTabsProvider(id)).activePath, 'lib/rates.ts');
    });

    testWidgets('a git source jumps to its file', (tester) async {
      final rig = _rig(api, events, code: true);
      final router = await rig.pump(tester, size: _big, step: 'verify');
      await ask(tester, 'who touched zones');
      await answered(tester, [gitRow]);
      await tap(tester, key('result-git-0'));
      expect(pathOf(router), '/w/$id/code');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ManualRail)),
      );
      expect(container.read(editorTabsProvider(id)).activePath, 'lib/zones.ts');
    });

    testWidgets('a web source opens in the browser', (tester) async {
      final rig = _rig(api, events);
      await rig.pump(tester, size: _big);
      await ask(tester, 'x');
      await answered(tester, [webRow]);
      expect(find.text('open ↗'), findsOneWidget);
      await tap(tester, key('result-web-0'));
      expect(rig.opened.single.toString(), webRow.target);
    });

    testWidgets('a man source reads the page in Docs, offline and without AI', (
      tester,
    ) async {
      await _rig(api, events).pump(tester, size: _big);
      await ask(tester, 'list');
      await answered(tester, [manRow]);
      expect(find.text('MAN · OFFLINE'), findsOneWidget);
      await tap(tester, key('result-man-0'));
      expect(api.calls, contains('man:ls(1)'));
      expect(key('doc-man-ls(1)'), findsOneWidget);
      expect(find.text('LS(1) manual text'), findsOneWidget);
      expect(
        tester.widget<Text>(key('reader-footer')).data,
        'offline · no AI summary',
      );
    });

    testWidgets('reading a man page from Search reports a Docs read', (
      tester,
    ) async {
      await _rig(api, events).pump(tester, size: _big);
      await ask(tester, 'list');
      await answered(tester, [manRow]);
      expect(api.xp, isEmpty, reason: 'searching is not reading');
      await tap(tester, key('result-man-0'));
      expect(api.xp, ['docs_read:$id']);
    });
  });

  group('recent asks', () {
    final nowSecs = DateTime.now().millisecondsSinceEpoch / 1000;

    Map<String, Object?> logOf(List<Map<String, Object?>> entries) => {
      'count': entries.length,
      'unverified': false,
      'entries': entries,
    };

    Map<String, Object?> ask(
      String q, {
      String? answer,
      double? ago,
      String? guard,
      List<String> blocked = const [],
      List<Map<String, Object?>> rows = const [],
      String? note,
    }) => {
      'scope': 'ask',
      'query': q,
      'at': nowSecs - (ago ?? 120),
      'guard_note': guard,
      'answer': answer,
      'rows': rows,
      'note': note,
      'blocked_calls': blocked,
    };

    const rowJson = {
      'source': 'repo',
      'title': 'lib/rates.ts:2',
      'target': 'lib/rates.ts:2',
      'why': 'const base = 2;',
      'action': 'jump',
    };

    Future<void> openSearch(WidgetTester tester, Rig rig) async {
      await rig.pump(tester, size: _big);
      await tap(tester, key('manual-tab-search'));
    }

    testWidgets('nothing extra shows when there are no past asks', (
      tester,
    ) async {
      await openSearch(tester, _rig(api, events));
      expect(key('recent-header'), findsNothing);
      expect(key('recent-0'), findsNothing);
      expect(key('search-empty'), findsOneWidget);
    });

    testWidgets('entries without an answer and other scopes are not listed', (
      tester,
    ) async {
      final rig = _rig(
        api,
        events,
        researchLog: logOf([
          ask('old, aged out'),
          {'scope': 'repo', 'query': 'a repo lookup', 'at': nowSecs},
        ]),
      );
      await openSearch(tester, rig);
      expect(key('recent-header'), findsNothing);
    });

    testWidgets('lists the workspace asks newest first, one line each', (
      tester,
    ) async {
      final rig = _rig(
        api,
        events,
        researchLog: logOf([
          ask('first question', answer: 'A1.', ago: 7200),
          ask('second question', answer: 'A2.', ago: 300),
        ]),
      );
      await openSearch(tester, rig);
      expect(key('recent-header'), findsOneWidget);
      expect(
        allText(tester, key('recent-0')),
        containsAll(['second question', '5m ago']),
      );
      expect(
        allText(tester, key('recent-1')),
        containsAll(['first question', '2h ago']),
      );
      expect(key('recent-2'), findsNothing);
      final one = tester.widget<Text>(
        find.descendant(
          of: key('recent-0'),
          matching: find.text('second question'),
        ),
      );
      expect(one.maxLines, 1);
    });

    testWidgets('clicking one reopens its answer and sources', (tester) async {
      final rig = _rig(
        api,
        events,
        researchLog: logOf([
          ask(
            'where is rate computed',
            answer: 'It lives in rates.ts.',
            rows: const [rowJson],
            note: '1 source(s) dropped: they pointed at nothing',
          ),
        ]),
      );
      await openSearch(tester, rig);
      expect(key('search-answer'), findsNothing);
      await tap(tester, key('recent-0'));
      expect(api.calls, isEmpty, reason: 'reopening asks nothing');
      expect(find.text('It lives in rates.ts.'), findsOneWidget);
      expect(key('result-repo-0'), findsOneWidget);
      expect(
        find.text('1 source(s) dropped: they pointed at nothing'),
        findsOneWidget,
      );
      expect(key('search-guard-note'), findsNothing);
      expect(tester.widget<Text>(key('manual-footer')).data, _footerZero);
      final input = tester.widget<EditableText>(
        find.descendant(
          of: key('search-input'),
          matching: find.byType(EditableText),
        ),
      );
      expect(input.controller.text, 'where is rate computed');
    });

    testWidgets(
      'a guard-noted entry reopens with its note and the footer flips',
      (tester) async {
        final rig = _rig(
          api,
          events,
          researchLog: logOf([
            ask('clean one', answer: 'Clean.', ago: 900),
            ask(
              'noted one',
              answer: 'In rates.ts.',
              guard: _guardNote,
              blocked: const ['Write'],
              ago: 60,
            ),
          ]),
        );
        await openSearch(tester, rig);
        await tap(tester, key('recent-0'));
        expect(tester.widget<Text>(key('search-guard-note')).data, _guardNote);
        expect(key('search-blocked'), findsOneWidget);
        expect(
          tester.widget<Text>(key('manual-footer')).data,
          _footerUnverified,
        );

        await tap(tester, key('recent-1'));
        expect(find.text('Clean.'), findsOneWidget);
        expect(key('search-guard-note'), findsNothing);
        expect(key('search-blocked'), findsNothing);
        expect(tester.widget<Text>(key('manual-footer')).data, _footerZero);
      },
    );

    testWidgets('a new answer appears at the top and the list stays at ten', (
      tester,
    ) async {
      final rig = _rig(
        api,
        events,
        researchLog: logOf([
          for (var i = 0; i < 10; i++)
            ask('q$i', answer: 'A$i.', ago: 1000.0 - i),
        ]),
      );
      await openSearch(tester, rig);
      expect(key('recent-9'), findsOneWidget);
      await tester.enterText(key('search-input'), 'brand new');
      await tap(tester, key('search-go'));
      expect(key('recent-header'), findsNothing, reason: 'hidden while asking');
      await emit(
        tester,
        events,
        const AssistEvent(
          job: 'research',
          kind: 'done',
          answer: 'Fresh.',
          guardNote: _guardNote,
        ),
      );
      expect(allText(tester, key('recent-0')), contains('brand new'));
      expect(allText(tester, key('recent-1')), contains('q9'));
      expect(key('recent-10'), findsNothing);
      expect(allText(tester, key('recent-0')), contains('just now'));

      await tap(tester, key('recent-1'));
      expect(find.text('A9.'), findsOneWidget);
      expect(key('search-guard-note'), findsNothing);
      await tap(tester, key('recent-0'));
      expect(find.text('Fresh.'), findsOneWidget);
      expect(tester.widget<Text>(key('manual-footer')).data, _footerUnverified);
    });

    testWidgets('a stopped or failed ask adds nothing', (tester) async {
      await openSearch(tester, _rig(api, events));
      await tester.enterText(key('search-input'), 'q');
      await tap(tester, key('search-go'));
      await emit(
        tester,
        events,
        const AssistEvent(job: 'research', kind: 'stopped'),
      );
      expect(key('recent-header'), findsNothing);
      await tap(tester, key('search-go'));
      await emit(
        tester,
        events,
        const AssistEvent(job: 'research', kind: 'error', message: 'boom'),
      );
      expect(key('recent-header'), findsNothing);
    });

    testWidgets('the same question and answer twice is listed once', (
      tester,
    ) async {
      await openSearch(tester, _rig(api, events));
      for (var i = 0; i < 2; i++) {
        await tester.enterText(key('search-input'), 'same q');
        await tap(tester, key('search-go'));
        await emit(
          tester,
          events,
          const AssistEvent(job: 'research', kind: 'done', answer: 'Same.'),
        );
      }
      expect(allText(tester, key('recent-0')), contains('same q'));
      expect(key('recent-1'), findsNothing);
    });

    testWidgets('a resync whose list lacks a fresh answer keeps it', (
      tester,
    ) async {
      final resync = StreamController<void>.broadcast();
      addTearDown(resync.close);
      final rig = _rig(
        api,
        events,
        resync: resync,
        researchLog: logOf([ask('old one', answer: 'Old.', ago: 900)]),
      );
      await openSearch(tester, rig);
      await tester.enterText(key('search-input'), 'brand new');
      await tap(tester, key('search-go'));
      await emit(
        tester,
        events,
        const AssistEvent(job: 'research', kind: 'done', answer: 'Fresh.'),
      );
      expect(allText(tester, key('recent-0')), contains('brand new'));

      api.reloaded = _workspaceWith(
        const [],
        researchLog: logOf([ask('old one', answer: 'Old.', ago: 900)]),
      );
      resync.add(null);
      await tester.pumpAndSettle();
      expect(api.workspaceGets, 2, reason: 'mount plus the resync');
      expect(allText(tester, key('recent-0')), contains('brand new'));
      expect(allText(tester, key('recent-1')), contains('old one'));
      expect(key('recent-2'), findsNothing);
    });

    testWidgets('a resync that began before an answer settled leaves the list '
        'alone', (tester) async {
      final resync = StreamController<void>.broadcast();
      addTearDown(resync.close);
      final rig = _rig(
        api,
        events,
        resync: resync,
        researchLog: logOf([ask('old one', answer: 'Old.', ago: 900)]),
      );
      await openSearch(tester, rig);
      await tester.enterText(key('search-input'), 'brand new');
      await tap(tester, key('search-go'));

      api.workspaceGate = Completer<void>();
      api.reloaded = _workspaceWith(
        const [],
        researchLog: logOf([
          ask('older', answer: 'Older.', ago: 5000),
          ask('older two', answer: 'Older 2.', ago: 4000),
        ]),
      );
      resync.add(null);
      await tester.pump();
      await emit(
        tester,
        events,
        const AssistEvent(job: 'research', kind: 'done', answer: 'Fresh.'),
      );
      api.workspaceGate!.complete();
      await tester.pumpAndSettle();
      expect(allText(tester, key('recent-0')), contains('brand new'));
      expect(allText(tester, key('recent-1')), contains('old one'));
      expect(key('recent-2'), findsNothing);
    });
  });

  group('reattach after a reload, a switch or a reconnect', () {
    const running = AssistJob(
      id: 'job_1',
      kind: 'plan',
      text: 'Reading the repo',
    );
    late StreamController<void> resync;

    setUp(() => resync = StreamController<void>.broadcast());
    tearDown(() => resync.close());

    testWidgets('a plan running when the app reloaded shows running, then the '
        'result', (tester) async {
      api.job = running;
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      expect(api.assistGets, 1);
      expect(key('plan-stop'), findsOneWidget);
      expect(key('plan-input'), findsNothing);
      expect(find.text('Reading the repo'), findsOneWidget);

      await emit(
        tester,
        events,
        const AssistEvent(job: 'plan', kind: 'token', text: ' and the tests'),
      );
      expect(find.text('Reading the repo and the tests'), findsOneWidget);
      await tap(tester, key('plan-stop'));
      expect(api.calls, ['stop']);

      await emit(
        tester,
        events,
        const AssistEvent(job: 'plan', kind: 'done', plan: _plan),
      );
      expect(key('plan-stop'), findsNothing);
      expect(find.text('Wire the thing'), findsOneWidget);
      expect(find.text('Finish plan → save to Docs'), findsOneWidget);
    });

    testWidgets('a queued job shows the queued label', (tester) async {
      api.job = const AssistJob(id: 'job_1', kind: 'plan', status: 'queued');
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      expect(find.text('QUEUED'), findsOneWidget);
      expect(key('plan-stop'), findsOneWidget);
    });

    testWidgets('a reconnect clears a running state the server no longer has', (
      tester,
    ) async {
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      await tester.enterText(key('plan-input'), 'add dedupe');
      await tester.pump();
      await tap(tester, key('plan-it'));
      expect(key('plan-stop'), findsOneWidget);

      api.job = null;
      resync.add(null);
      await tester.pumpAndSettle();
      expect(key('plan-stop'), findsNothing);
      expect(key('plan-input'), findsOneWidget);
      expect(find.text('add dedupe'), findsOneWidget);
    });

    testWidgets('a stale running ask is cleared by a settled job of another '
        'kind', (tester) async {
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      await tap(tester, key('manual-tab-search'));
      await tester.enterText(key('search-input'), 'where is rate limiting');
      await tap(tester, key('search-go'));
      expect(key('search-busy'), findsOneWidget);

      api.job = const AssistJob(id: 'job_0', kind: 'plan', status: 'stopped');
      resync.add(null);
      await tester.pumpAndSettle();
      expect(key('search-busy'), findsNothing);
      expect(key('search-stop'), findsNothing);
      expect(key('search-go'), findsOneWidget);
    });

    testWidgets('a start in flight is not cleared by a resync that raced it', (
      tester,
    ) async {
      api.planGate = Completer<void>();
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      await tester.enterText(key('plan-input'), 'x');
      await tester.pump();
      await tester.tap(key('plan-it'));
      await tester.pump();
      expect(key('plan-stop'), findsOneWidget);

      resync.add(null);
      await tester.pump();
      await tester.pump();
      expect(key('plan-stop'), findsOneWidget);

      api.planGate!.complete();
      await tester.pumpAndSettle();
      expect(key('plan-stop'), findsOneWidget);
    });

    testWidgets('a plan that finished while away shows once', (tester) async {
      api
        ..job = const AssistJob(
          id: 'job_1',
          kind: 'plan',
          status: 'done',
          planId: 'plan_1',
        )
        ..reloaded = _workspaceWith([_plan]);
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      expect(find.text('Wire the thing'), findsOneWidget);
      expect(find.text('Finish plan → save to Docs'), findsOneWidget);
      expect(api.workspaceGets, 1);

      await tap(tester, key('manual-tab-docs'));
      resync.add(null);
      await tester.pumpAndSettle();
      expect(api.workspaceGets, 2);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ManualRail)),
      );
      final s = container.read(manualRailProvider(id));
      expect(s.plans.map((p) => p.id), ['plan_1']);
      expect(s.tab, ManualTab.docs);
    });

    testWidgets('a plan already on screen is not added twice', (tester) async {
      api.job = const AssistJob(
        id: 'job_1',
        kind: 'plan',
        status: 'done',
        planId: 'plan_1',
      );
      await _rig(
        api,
        events,
        plans: [_plan],
        resync: resync,
      ).pump(tester, size: _big);
      api.reloaded = _workspaceWith([_plan]);
      resync.add(null);
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ManualRail)),
      );
      expect(container.read(manualRailProvider(id)).plans, hasLength(1));
      expect(find.text('Wire the thing'), findsOneWidget);
    });

    testWidgets('a plan saved while the backend restarted still appears', (
      tester,
    ) async {
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      expect(key('plan-input'), findsOneWidget);

      api
        ..job = null
        ..reloaded = _workspaceWith([_plan]);
      resync.add(null);
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ManualRail)),
      );
      expect(container.read(manualRailProvider(id)).plans.map((p) => p.id), [
        'plan_1',
      ]);
      expect(find.text('Wire the thing'), findsOneWidget);
    });

    testWidgets('a new job never shows the old job\'s leftover text', (
      tester,
    ) async {
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      await tester.enterText(key('plan-input'), 'x');
      await tester.pump();
      await tap(tester, key('plan-it'));
      await emit(
        tester,
        events,
        const AssistEvent(
          job: 'plan',
          kind: 'token',
          jobId: 'job_a',
          text: 'old leftover',
        ),
      );
      expect(find.text('old leftover'), findsOneWidget);

      // Another client's job replaces it: the server text is taken outright.
      api.job = const AssistJob(id: 'job_b', kind: 'plan', text: 'new');
      resync.add(null);
      await tester.pumpAndSettle();
      expect(find.text('new'), findsOneWidget);
      expect(find.textContaining('old leftover'), findsNothing);

      // A stopped job's text does not survive into the next one.
      await emit(
        tester,
        events,
        const AssistEvent(
          job: 'plan',
          kind: 'token',
          jobId: 'job_b',
          text: ' more',
        ),
      );
      await emit(
        tester,
        events,
        const AssistEvent(job: 'plan', kind: 'stopped', jobId: 'job_b'),
      );
      api.job = const AssistJob(id: 'job_c', kind: 'plan');
      resync.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Reading the repo...'), findsOneWidget);
      expect(find.textContaining('new more'), findsNothing);
    });

    testWidgets('a token from a newer job replaces the previous job\'s text', (
      tester,
    ) async {
      api.job = const AssistJob(id: 'job_a', kind: 'plan', text: 'first');
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      expect(find.text('first'), findsOneWidget);
      await emit(
        tester,
        events,
        const AssistEvent(
          job: 'plan',
          kind: 'token',
          jobId: 'job_b',
          text: 'second',
        ),
      );
      expect(find.text('second'), findsOneWidget);
    });

    testWidgets('a reattached ask shows the dropped-sources note', (
      tester,
    ) async {
      api.job = const AssistJob(
        id: 'job_9',
        kind: 'research',
        status: 'done',
        answer: 'In rates.ts.',
        note: '1 source(s) dropped: they pointed at nothing',
      );
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      await tap(tester, key('manual-tab-search'));
      expect(
        find.text('1 source(s) dropped: they pointed at nothing'),
        findsOneWidget,
      );
    });

    testWidgets('switching A to B to A re-reads the job each time', (
      tester,
    ) async {
      final which = ValueNotifier<String>('ws_a');
      addTearDown(which.dispose);
      final feeds = {
        'ws_a': StreamController<AssistEvent>.broadcast(),
        'ws_b': StreamController<AssistEvent>.broadcast(),
      };
      addTearDown(() {
        for (final c in feeds.values) {
          c.close();
        }
      });
      final byWs = _PerWsAssist({
        'ws_a': const AssistJob(id: 'job_a', kind: 'plan', text: 'AAA'),
        'ws_b': null,
      });
      tester.view.physicalSize = _big;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            haroApiProvider.overrideWithValue(byWs),
            workspaceDetailProvider.overrideWith2(
              (wsId) => FixedDetail(
                wsId,
                detailFor(
                  Preview.idleWithChanges,
                  mode: WorkspaceMode.manual,
                ).copyWith(workspace: _workspaceWith(const [])),
              ),
            ),
            assistEventsProvider.overrideWith(
              (ref, wsId) => feeds[wsId]!.stream,
            ),
          ],
          child: MaterialApp(
            theme: buildHaroTheme(),
            home: Material(
              child: ValueListenableBuilder<String>(
                valueListenable: which,
                builder: (_, ws, _) => ManualRail(workspaceId: ws),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('AAA'), findsOneWidget);

      which.value = 'ws_b';
      await tester.pumpAndSettle();
      expect(key('plan-input'), findsOneWidget);
      expect(find.text('AAA'), findsNothing);

      // ws_a's job went on running while B was on screen.
      feeds['ws_a']!.add(
        const AssistEvent(job: 'plan', kind: 'token', text: 'AA'),
      );
      byWs.jobs['ws_a'] = const AssistJob(
        id: 'job_a',
        kind: 'plan',
        text: 'AAAAA',
      );
      which.value = 'ws_a';
      await tester.pumpAndSettle();
      expect(byWs.gets, ['ws_a', 'ws_b', 'ws_a']);
      expect(key('plan-stop'), findsOneWidget);
      expect(find.text('AAAAA'), findsOneWidget);
    });

    testWidgets('an ask that finished while away shows its answer once, and '
        'never over a newer search', (tester) async {
      const rows = [
        ResearchRow(
          source: 'repo',
          title: 'lib/rates.ts:2',
          target: 'lib/rates.ts:2',
          why: 'the base rate',
          action: 'jump',
        ),
      ];
      api.job = const AssistJob(
        id: 'job_9',
        kind: 'research',
        status: 'done',
        answer: 'The base rate lives in rates.ts.',
        rows: rows,
        blockedCalls: ['Write'],
      );
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      await tap(tester, key('manual-tab-search'));
      expect(find.text('The base rate lives in rates.ts.'), findsOneWidget);
      expect(find.text('lib/rates.ts:2'), findsOneWidget);
      expect(key('search-blocked'), findsOneWidget);

      await tester.enterText(key('search-input'), 'nothing');
      await tap(tester, key('search-go'));
      await emit(
        tester,
        events,
        const AssistEvent(job: 'research', kind: 'done'),
      );
      expect(key('search-none'), findsOneWidget);

      resync.add(null);
      await tester.pumpAndSettle();
      expect(key('search-none'), findsOneWidget);
      expect(find.text('The base rate lives in rates.ts.'), findsNothing);
    });

    testWidgets('an ask running at reload shows Stop, then its answer', (
      tester,
    ) async {
      api.job = const AssistJob(
        id: 'job_9',
        kind: 'research',
        query: 'where is rate limiting',
      );
      await _rig(api, events, resync: resync).pump(tester, size: _big);
      await tap(tester, key('manual-tab-search'));
      expect(key('search-stop'), findsOneWidget);
      expect(key('search-busy'), findsOneWidget);

      await emit(
        tester,
        events,
        const AssistEvent(
          job: 'research',
          kind: 'done',
          jobId: 'job_9',
          answer: 'In rates.ts.',
        ),
      );
      expect(key('search-stop'), findsNothing);
      expect(find.text('In rates.ts.'), findsOneWidget);
    });

    testWidgets('an unreachable backend leaves the state alone', (
      tester,
    ) async {
      final down = _DownAssist();
      await _rig(down, events, resync: resync).pump(tester, size: _big);
      await tester.enterText(key('plan-input'), 'x');
      await tester.pump();
      await tap(tester, key('plan-it'));
      resync.add(null);
      await tester.pumpAndSettle();
      expect(key('plan-stop'), findsOneWidget);
    });

    testWidgets('a replayed done with the plan as first written does not undo '
        'its ticks', (tester) async {
      const ticked = ManualPlan(
        id: 'plan_1',
        title: 'Wire the thing',
        steps: [
          PlanStep(text: 'Read the handler', done: true),
          PlanStep(text: 'Add the table', done: true),
          PlanStep(text: 'Dedupe in the transaction'),
        ],
        saved: true,
      );
      await _rig(api, events, plans: [ticked]).pump(tester, size: _big);
      expect(find.text('2/3'), findsOneWidget);

      await emit(
        tester,
        events,
        const AssistEvent(
          job: 'plan',
          kind: 'done',
          jobId: 'job_1',
          plan: ManualPlan(
            id: 'plan_1',
            title: 'Wire the thing',
            steps: [
              PlanStep(text: 'Read the handler'),
              PlanStep(text: 'Add the table'),
              PlanStep(text: 'Dedupe in the transaction'),
            ],
          ),
        ),
      );
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('0/3'), findsNothing);
    });

    testWidgets('a saved plan with ticks keeps them under a finished job', (
      tester,
    ) async {
      final ticked = ManualPlan(
        id: 'plan_1',
        title: 'Wire the thing',
        steps: const [
          PlanStep(text: 'Read the handler', done: true),
          PlanStep(text: 'Add the table', done: true),
          PlanStep(text: 'Dedupe in the transaction'),
        ],
        saved: true,
      );
      for (final job in [
        const AssistJob(
          id: 'job_9',
          kind: 'research',
          status: 'done',
          answer: 'In rates.ts.',
        ),
        const AssistJob(
          id: 'job_8',
          kind: 'plan',
          status: 'done',
          planId: 'plan_1',
        ),
      ]) {
        api
          ..job = job
          ..reloaded = _workspaceWith([ticked]);
        await _rig(
          api,
          events,
          plans: [ticked],
          resync: resync,
        ).pump(tester, size: _big);
        expect(find.text('2/3'), findsOneWidget, reason: job.kind);
        resync.add(null);
        await tester.pumpAndSettle();
        expect(find.text('2/3'), findsOneWidget, reason: job.kind);
      }
    });

    test('AssistJob reads the running text, blocked calls and the result', () {
      final j = AssistJob.fromJson({
        'id': 'job_1',
        'kind': 'research',
        'status': 'done',
        'text': 'so far',
        'plan_id': 'plan_1',
        'answer': 'a',
        'rows': [
          {'source': 'repo', 'title': 't', 'target': 'x:1', 'why': 'w'},
        ],
        'blocked_calls': ['Write', 'Bash'],
        'guard_note': 'n',
      });
      expect(j.text, 'so far');
      expect(j.planId, 'plan_1');
      expect(j.answer, 'a');
      expect(j.rows.single.target, 'x:1');
      expect(j.blockedCalls, ['Write', 'Bash']);
      expect(j.guardNote, 'n');
      expect(j.active, isFalse);
      expect(const AssistJob(id: 'j', kind: 'plan').active, isTrue);
    });
  });

  group('docs', () {
    testWidgets('lists saved plans, pinned links and man pages', (
      tester,
    ) async {
      api = FakeAssistApi(
        pinned: const [PinnedDoc(title: 'Stripe API', url: 'https://s.io/api')],
      );
      await _rig(
        api,
        events,
        plans: [
          _plan.copyWith(saved: true),
          const ManualPlan(id: 'plan_2', title: 'Draft', steps: []),
        ],
      ).pump(tester, size: _big);
      expect(find.text('2'), findsNothing);
      await tap(tester, key('manual-tab-docs'));
      expect(api.calls, contains('pinned:get'));
      expect(key('doc-plan-plan_1'), findsOneWidget);
      expect(key('doc-plan-plan_2'), findsNothing);
      expect(key('doc-pinned-https://s.io/api'), findsOneWidget);
      expect(find.text('wire-the-thing.md'), findsOneWidget);
      expect(find.text('yours'), findsOneWidget);
      expect(find.text('web · pinned'), findsOneWidget);
      // The tab badge counts the list.
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('a plan reads as a read-only checklist', (tester) async {
      await _rig(
        api,
        events,
        plans: [_plan.copyWith(saved: true)],
      ).pump(tester, size: _big);
      await tap(tester, key('manual-tab-docs'));
      await tap(tester, key('doc-plan-plan_1'));
      expect(key('reader-plan'), findsOneWidget);
      expect(find.text('Read the handler'), findsWidgets);
      final before = api.calls.length;
      await tester.tap(
        find
            .descendant(
              of: key('reader-plan'),
              matching: find.byType(ManualCheck),
            )
            .first,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(api.calls.length, before);
      await tap(tester, key('reader-tick'));
      expect(key('saved-step-0'), findsOneWidget);
    });

    testWidgets(
      'opening a doc reports one Docs read, a second the same day none',
      (tester) async {
        api = FakeAssistApi(
          pinned: const [
            PinnedDoc(title: 'Stripe API', url: 'https://s.io/api'),
          ],
        );
        await _rig(
          api,
          events,
          plans: [_plan.copyWith(saved: true)],
        ).pump(tester, size: _big);
        await tap(tester, key('manual-tab-docs'));
        expect(api.xp, isEmpty, reason: 'listing the docs is not reading one');
        await tap(tester, key('doc-plan-plan_1'));
        expect(api.xp, ['docs_read:$id']);
        await tap(tester, key('doc-pinned-https://s.io/api'));
        expect(api.xp, ['docs_read:$id']);
      },
    );

    testWidgets('pinning a link is not a Docs read', (tester) async {
      final rig = _rig(api, events);
      await rig.pump(tester, size: _big);
      await tap(tester, key('manual-tab-docs'));
      await tester.enterText(key('pin-input'), 'https://docs.stripe.com/api');
      await tap(tester, key('pin-go'));
      expect(api.xp, isEmpty);
    });

    testWidgets('pin a link, open it, unpin it; junk is refused', (
      tester,
    ) async {
      final rig = _rig(api, events);
      await rig.pump(tester, size: _big);
      await tap(tester, key('manual-tab-docs'));
      await tester.enterText(key('pin-input'), 'javascript:alert(1)');
      await tap(tester, key('pin-go'));
      expect(find.textContaining('Only http and https'), findsOneWidget);
      expect(api.calls.where((c) => c.startsWith('pinned:set')), isEmpty);

      await tester.enterText(key('pin-input'), 'https://docs.stripe.com/api');
      await tap(tester, key('pin-go'));
      expect(api.calls.last, 'pinned:set:https://docs.stripe.com/api');
      expect(key('doc-pinned-https://docs.stripe.com/api'), findsOneWidget);

      await tap(tester, key('doc-pinned-https://docs.stripe.com/api'));
      await tap(tester, key('reader-open'));
      expect(rig.opened.single.toString(), 'https://docs.stripe.com/api');
      await tap(tester, key('reader-unpin'));
      expect(api.calls.last, 'pinned:set:');
      expect(key('doc-pinned-https://docs.stripe.com/api'), findsNothing);
    });
  });
}

class _FailingStart extends FakeAssistApi {
  @override
  Future<AssistJob> assistPlan(
    String wsId,
    String prompt, {
    String? model,
    String? effort,
  }) async => throw const HaroApiException(
    409,
    'the assistant is already working on something',
  );
}

class _PerWsAssist extends FakeAssistApi {
  _PerWsAssist(this.jobs);

  final Map<String, AssistJob?> jobs;
  final gets = <String>[];

  @override
  Future<AssistJob?> getAssistJob(String wsId) async {
    gets.add(wsId);
    return jobs[wsId];
  }
}

class _DownAssist extends FakeAssistApi {
  @override
  Future<AssistJob?> getAssistJob(String wsId) async =>
      throw const HaroApiException(0, 'unreachable');
}
