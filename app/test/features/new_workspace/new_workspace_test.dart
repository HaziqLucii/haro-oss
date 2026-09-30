import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/xp_store.dart';
import 'package:haro_app/features/new_workspace/new_workspace_overlay.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/widgets/haro_button.dart';

import '../../api/fixtures.dart';
import '../../api/xp_api_test.dart' show rulesJson;
import '../../shell/xp_shell_test.dart' show FakeXpStore;
import '../creation_harness.dart';

MockBackend backend({
  Handler? create,
  Map<String, Handler> more = const {},
}) => MockBackend({
  'GET /projects/p1/branches': (_) => jsonRes({
    'branches': ['origin/main', 'origin/dev'],
    'default': 'origin/main',
  }),
  'GET /projects/p2/branches': (_) => jsonRes({
    'branches': ['origin/trunk'],
    'default': 'origin/trunk',
  }),
  'POST /projects/p1/workspaces': create ?? (_) => jsonRes(createdWorkspace()),
  'POST /projects/p2/workspaces': create ?? (_) => jsonRes(createdWorkspace()),
  ...more,
});

String fieldText(WidgetTester tester, String key) {
  final inner = find.descendant(
    of: find.byKey(Key(key)),
    matching: find.byType(TextField),
  );
  final field = tester.any(inner)
      ? tester.widget<TextField>(inner)
      : tester.widget<TextField>(find.byKey(Key(key)));
  return field.controller!.text;
}

Future<Harness> open(
  WidgetTester tester,
  MockBackend b, {
  String? projectId,
  NewWorkspacePrefill? prefill,
  String? agentFails,
}) => pumpCreation(
  tester,
  backend: b,
  agentFails: agentFails,
  open: (c) => showNewWorkspace(c, projectId: projectId, prefill: prefill),
);

Future<void> typeTask(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('nw-task')), text);
  await tester.pump();
}

HaroButton submit(WidgetTester tester) =>
    tester.widget<HaroButton>(find.byKey(const Key('nw-submit')));

void main() {
  setUpAll(loadBrandFonts);

  test('default project: given, else open workspace, else first', () {
    final ps = [project('a', 'A'), project('b', 'B')];
    expect(defaultProjectId(projects: ps, given: 'b'), 'b');
    expect(defaultProjectId(projects: ps, openWorkspaceProjectId: 'b'), 'b');
    expect(defaultProjectId(projects: ps, given: 'zzz'), 'a');
    expect(defaultProjectId(projects: const []), isNull);
  });

  testWidgets('opens on the given project and loads its branches', (
    tester,
  ) async {
    final b = backend();
    await open(tester, b, projectId: 'p2');
    expect(find.text('SANDBOX'), findsOneWidget);
    expect(find.text('origin/trunk'), findsOneWidget);
    expect(b.where('GET', '/projects/p2/branches'), hasLength(1));
    expect(b.where('GET', '/projects/p1/branches'), isEmpty);
  });

  testWidgets('opens on the open workspace project when none is given', (
    tester,
  ) async {
    final b = backend();
    await pumpCreation(
      tester,
      backend: b,
      initialLocation: '/w/ws_in_p2/agent',
      workspaces: {
        'p2': [
          Workspace.fromJson(
            workspaceJson(id: 'ws_in_p2', overrides: {'project_id': 'p2'}),
          ),
        ],
      },
      open: (c) => showNewWorkspace(c),
    );
    expect(find.text('SANDBOX'), findsOneWidget);
    expect(b.where('GET', '/projects/p2/branches'), hasLength(1));
  });

  testWidgets('branch follows the task, prefix chips switch, edits stop it', (
    tester,
  ) async {
    await open(tester, backend());
    expect(fieldText(tester, 'nw-branch'), 'feat/task-name');

    await typeTask(tester, 'Add multiply helper');
    expect(fieldText(tester, 'nw-branch'), 'feat/add-multiply-helper');

    await tester.tap(find.text('fix/'));
    await tester.pump();
    expect(fieldText(tester, 'nw-branch'), 'fix/add-multiply-helper');

    await typeTask(tester, 'Add divide helper');
    expect(fieldText(tester, 'nw-branch'), 'fix/add-divide-helper');

    await tester.enterText(find.byKey(const Key('nw-branch')), 'fix/mine');
    await typeTask(tester, 'Something else entirely');
    expect(fieldText(tester, 'nw-branch'), 'fix/mine');

    await tester.tap(find.text('docs/'));
    await tester.pump();
    expect(fieldText(tester, 'nw-branch'), 'docs/mine');
  });

  testWidgets(
    'create and run: creates the workspace, starts the agent, opens it',
    (tester) async {
      final b = backend();
      final h = await open(tester, b);
      expect(find.text('Create & run agent'), findsOneWidget);
      expect(submit(tester).onPressed, isNull);

      await typeTask(tester, 'Add multiply helper');
      await tester.tap(find.byKey(const Key('nw-submit')));
      await tester.pumpAndSettle();

      final posts = b.where('POST', '/projects/p1/workspaces');
      expect(posts, hasLength(1));
      expect(posts.single.body, {
        'name': 'Add multiply helper',
        'base_ref': 'origin/main',
        'branch': 'feat/add-multiply-helper',
        'seed_key': null,
        'mode': 'agent',
      });
      expect(h.started, [('ws_new', 'Add multiply helper')]);
      expect(h.store.reloads, 1);
      expect(h.location, '/w/ws_new/agent');
      expect(find.byKey(const Key('nw-task')), findsNothing);
    },
  );

  group('who writes it', () {
    Future<void> pickManual(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('nw-who-manual')));
      await tester.pump();
    }

    testWidgets('defaults to Agent with the run checkbox', (tester) async {
      await open(tester, backend());
      expect(find.text('Who writes it'), findsOneWidget);
      expect(find.byKey(const Key('nw-run')), findsOneWidget);
      expect(find.byKey(const Key('nw-hint')), findsNothing);
      expect(find.text('Create & run agent'), findsOneWidget);
    });

    testWidgets('Manual: hint, CTA, no agent option', (tester) async {
      await open(tester, backend());
      await typeTask(tester, 'Add multiply helper');
      await pickManual(tester);

      expect(find.text(manualHint), findsOneWidget);
      expect(find.byKey(const Key('nw-run')), findsNothing);
      expect(find.text('Create & start writing'), findsOneWidget);
      expect(find.text('Create & run agent'), findsNothing);
    });

    testWidgets('the prefix follows the task, not who writes it', (
      tester,
    ) async {
      await open(tester, backend());
      await typeTask(tester, 'Add multiply helper');
      await pickManual(tester);
      expect(fieldText(tester, 'nw-branch'), 'feat/add-multiply-helper');
      await typeTask(tester, 'Fix rounding in totals');
      expect(fieldText(tester, 'nw-branch'), 'fix/fix-rounding-in-totals');
      await tester.tap(find.byKey(const ValueKey('nw-who-agent')));
      await tester.pump();
      expect(fieldText(tester, 'nw-branch'), 'fix/fix-rounding-in-totals');
      await typeTask(tester, 'Add a prefix helper');
      expect(fieldText(tester, 'nw-branch'), 'feat/add-a-prefix-helper');
    });

    testWidgets('switching back keeps the agent prefix and CTA', (
      tester,
    ) async {
      await open(tester, backend());
      await typeTask(tester, 'Add multiply helper');
      await pickManual(tester);
      await tester.tap(find.byKey(const ValueKey('nw-who-agent')));
      await tester.pump();

      expect(fieldText(tester, 'nw-branch'), 'feat/add-multiply-helper');
      expect(find.text('Create & run agent'), findsOneWidget);
    });

    testWidgets('a prefix the user picked survives the switch', (tester) async {
      await open(tester, backend());
      await typeTask(tester, 'Add multiply helper');
      await tester.tap(find.text('docs/'));
      await tester.pump();
      await pickManual(tester);
      expect(fieldText(tester, 'nw-branch'), 'docs/add-multiply-helper');
    });

    testWidgets('manual submit sends mode, starts no agent, opens code', (
      tester,
    ) async {
      final b = backend();
      final h = await open(tester, b);
      await typeTask(tester, 'Add multiply helper');
      await pickManual(tester);
      await tester.tap(find.byKey(const Key('nw-submit')));
      await tester.pumpAndSettle();

      final posts = b.where('POST', '/projects/p1/workspaces');
      expect(posts.single.body, {
        'name': 'Add multiply helper',
        'base_ref': 'origin/main',
        'branch': 'feat/add-multiply-helper',
        'seed_key': null,
        'mode': 'manual',
      });
      expect(h.started, isEmpty);
      expect(h.location, '/w/ws_new/code');
    });
  });

  group('start from a test', () {
    Future<void> pickManual(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('nw-who-manual')));
      await tester.pump();
    }

    final rules = XpState(rules: XpRules.fromJson(rulesJson()));

    Future<void> openManual(
      WidgetTester tester,
      MockBackend b, {
      XpState? xp,
      Json? prefs,
    }) async {
      await pumpCreation(
        tester,
        backend: b,
        overrides: [
          xpStoreProvider.overrideWith(() => FakeXpStore(xp ?? rules)),
          devicePrefsStoreProvider.overrideWithValue(
            MemoryDevicePrefsStore(prefs),
          ),
        ],
        open: (c) => showNewWorkspace(c),
      );
      await pickManual(tester);
    }

    testWidgets('only manual mode offers it, with the XP from the rules', (
      tester,
    ) async {
      await openManual(tester, backend());
      expect(find.byKey(const Key('nw-test-first')), findsOneWidget);
      expect(
        find.text('Start from a test: write the failing test first'),
        findsOneWidget,
      );
      expect(find.text('+30 XP'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nw-who-agent')));
      await tester.pump();
      expect(find.byKey(const Key('nw-test-first')), findsNothing);
    });

    testWidgets('manual mode with the checkbox fits 960x640', (tester) async {
      await openManual(tester, backend());
      expect(find.byKey(const Key('nw-test-first')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unchecked by default: the request carries no flag', (
      tester,
    ) async {
      final b = backend();
      await openManual(tester, b);
      await typeTask(tester, 'Add multiply helper');
      await tester.tap(find.byKey(const Key('nw-submit')));
      await tester.pumpAndSettle();
      expect(
        b.where('POST', '/projects/p1/workspaces').single.body,
        isNot(contains('start_from_test')),
      );
    });

    testWidgets('checked: start_from_test goes out with the manual mode', (
      tester,
    ) async {
      final b = backend();
      await openManual(tester, b);
      await typeTask(tester, 'Add multiply helper');
      await tester.tap(find.byKey(const Key('nw-test-first')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('nw-submit')));
      await tester.pumpAndSettle();
      final body = b.where('POST', '/projects/p1/workspaces').single.body!;
      expect(body['mode'], 'manual');
      expect(body['start_from_test'], isTrue);
    });

    testWidgets('a checked box is dropped when the mode goes back to agent', (
      tester,
    ) async {
      final b = backend();
      await openManual(tester, b);
      await typeTask(tester, 'Add multiply helper');
      await tester.tap(find.byKey(const Key('nw-test-first')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nw-who-agent')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('nw-submit')));
      await tester.pumpAndSettle();
      expect(
        b.where('POST', '/projects/p1/workspaces').single.body,
        isNot(contains('start_from_test')),
      );
    });

    testWidgets('no XP note before the rules load or with Show XP off', (
      tester,
    ) async {
      await openManual(tester, backend(), xp: const XpState());
      expect(find.byKey(const Key('nw-test-first')), findsOneWidget);
      expect(find.text('+30 XP'), findsNothing);
    });

    testWidgets('Show XP off keeps the checkbox but drops the XP note', (
      tester,
    ) async {
      await openManual(
        tester,
        backend(),
        prefs: {
          'xp': {'show_xp': false},
        },
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nw-test-first')), findsOneWidget);
      expect(find.text('+30 XP'), findsNothing);
    });
  });

  testWidgets('unchecked: creates only, never starts the agent', (
    tester,
  ) async {
    final b = backend();
    final h = await open(tester, b);
    await tester.tap(find.text('Start the agent with this task right away'));
    await tester.pump();
    expect(find.text('Create workspace'), findsOneWidget);

    await typeTask(tester, 'Just a worktree');
    await tester.tap(find.byKey(const Key('nw-submit')));
    await tester.pumpAndSettle();

    expect(b.where('POST', '/projects/p1/workspaces'), hasLength(1));
    expect(h.started, isEmpty);
    expect(h.location, '/w/ws_new/agent');
  });

  testWidgets('base branch select changes base_ref', (tester) async {
    final b = backend();
    await open(tester, b);
    await tester.tap(find.byKey(const Key('nw-base')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('origin/dev').last);
    await tester.pumpAndSettle();
    await typeTask(tester, 'x');
    await tester.tap(find.byKey(const Key('nw-submit')));
    await tester.pumpAndSettle();
    expect(
      b.where('POST', '/projects/p1/workspaces').single.body!['base_ref'],
      'origin/dev',
    );
  });

  testWidgets('project picker switches project and branches', (tester) async {
    final b = backend();
    await open(tester, b);
    await tester.tap(find.text('HARO'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sandbox').last);
    await tester.pumpAndSettle();
    expect(find.text('origin/trunk'), findsOneWidget);
    await typeTask(tester, 'On sandbox');
    await tester.tap(find.byKey(const Key('nw-submit')));
    await tester.pumpAndSettle();
    expect(b.where('POST', '/projects/p2/workspaces'), hasLength(1));
    expect(b.where('POST', '/projects/p1/workspaces'), isEmpty);
  });

  testWidgets('a create error is shown inline and nothing else runs', (
    tester,
  ) async {
    final b = backend(create: (_) => errorRes('branch already exists'));
    final h = await open(tester, b);
    await typeTask(tester, 'Clash');
    await tester.tap(find.byKey(const Key('nw-submit')));
    await tester.pumpAndSettle();

    expect(find.text('branch already exists'), findsOneWidget);
    expect(find.byKey(const Key('nw-task')), findsOneWidget);
    expect(h.started, isEmpty);
    expect(h.location, '/');

    await typeTask(tester, 'Clash 2');
    expect(find.text('branch already exists'), findsNothing);
  });

  testWidgets(
    'an agent failure keeps the overlay and retries without creating twice',
    (tester) async {
      final b = backend();
      final h = await open(tester, b, agentFails: 'agent busy');
      await typeTask(tester, 'Add helper');
      await tester.tap(find.byKey(const Key('nw-submit')));
      await tester.pumpAndSettle();

      expect(
        find.text('Workspace created, but the agent did not start: agent busy'),
        findsOneWidget,
      );
      expect(find.text('Start the agent'), findsOneWidget);
      expect(h.location, '/');

      await tester.tap(find.byKey(const Key('nw-submit')));
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects/p1/workspaces'), hasLength(1));
      expect(h.started, hasLength(2));
    },
  );

  testWidgets('primary modifier + Enter submits from the task field', (
    tester,
  ) async {
    final b = backend();
    final h = await open(tester, b);
    await typeTask(tester, 'Keyboard task');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();
    expect(b.where('POST', '/projects/p1/workspaces'), hasLength(1));
    expect(h.location, '/w/ws_new/agent');
  });

  testWidgets(
    'prefill: title in the input, full brief to the agent, seed key sent',
    (tester) async {
      final b = backend();
      final h = await open(
        tester,
        b,
        prefill: const NewWorkspacePrefill(
          title: 'Live gate',
          task: 'Stream results as tests finish.\n\nReference: backlog/live-gate.md',
          seedKey: 'backlog/live-gate.md::item',
        ),
      );
      expect(fieldText(tester, 'nw-task'), 'Live gate');
      expect(fieldText(tester, 'nw-branch'), 'feat/live-gate');

      await tester.tap(find.byKey(const Key('nw-submit')));
      await tester.pumpAndSettle();

      expect(
        b.where('POST', '/projects/p1/workspaces').single.body!['seed_key'],
        'backlog/live-gate.md::item',
      );
      expect(h.started.single.$2, contains('Reference: backlog/live-gate.md'));
    },
  );

  testWidgets('prefill edited by hand sends what was typed', (tester) async {
    final b = backend();
    final h = await open(
      tester,
      b,
      prefill: const NewWorkspacePrefill(
        title: 'Live gate',
        task: 'long brief',
      ),
    );
    await typeTask(tester, 'Something narrower');
    await tester.tap(find.byKey(const Key('nw-submit')));
    await tester.pumpAndSettle();
    expect(h.started.single.$2, 'Something narrower');
  });

  testWidgets('no overflow at 960x640, with an error and every control', (
    tester,
  ) async {
    final b = backend(create: (_) => errorRes('x' * 120));
    await open(tester, b, projectId: 'p1');
    await typeTask(
      tester,
      'A fairly long task name that goes on and on and on',
    );
    await tester.tap(find.byKey(const Key('nw-submit')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('no project: offers Add project instead of a form', (
    tester,
  ) async {
    await pumpCreation(
      tester,
      backend: backend(),
      projects: const [],
      open: (c) => showNewWorkspace(c),
    );
    expect(find.text('No project yet.'), findsOneWidget);
    expect(find.byKey(const Key('nw-task')), findsNothing);
  });
}
