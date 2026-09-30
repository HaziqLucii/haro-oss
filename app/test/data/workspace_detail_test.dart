import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_detail_lazy.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/workspace/rail/manual/manual_controller.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/state/workspace_flow.dart';

import '../api/fixtures.dart';
import 'detail_harness.dart';

Future<void> until(bool Function() cond, {int ms = 5000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in ${ms}ms');
    await wait(10);
  }
}

Map<String, dynamic> snapshotMsg(
  Map<String, dynamic> run, {
  String channel = 'test',
}) => {'channel': channel, 'kind': 'snapshot', 'test': run};

Map<String, dynamic> redRunJson() => testRunJson(
  status: 'failed',
  total: 2,
  passed: 1,
  failed: 1,
  unchecked: null,
  cases: [
    caseJson('a', 'failed', message: 'expected 0, received 499'),
    caseJson('b', 'passed'),
  ],
);

void main() {
  group('initial load', () {
    test('loads workspace, transcript, diff and derives the flow', () async {
      final b = FakeBackend()
        ..events.addAll([
          eventJson(
            'user',
            ts: 1790000000,
            payload: {'text': 'do it'},
            runId: 'user',
          ),
          eventJson('token', ts: 1790000001, payload: {'text': 'ok'}),
          eventJson('done', ts: 1790000090, payload: {'duration_ms': 84000}),
        ]);
      b.routes['GET /workspaces/$wsId/diff'] = (_) =>
          b.diffJson(files: 2, added: 3, removed: 1);
      final h = Harness(backend: b);
      await h.openAndLoad();

      final d = h.detail;
      expect(d.loaded, isTrue);
      expect(d.workspace!.id, wsId);
      expect(d.events, hasLength(3));
      expect(d.agentPhase, AgentPhase.done);
      expect(d.agentElapsed, const Duration(seconds: 84));
      expect(d.diffStats.files, 2);
      expect(d.diffStats.added, 6);
      expect(d.flow, isNotNull);
      expect(d.flow!.step(StepKey.agent).line, 'done · 1m');
      expect(d.flow!.step(StepKey.code).line, contains('2 files'));
      expect(h.net.workspaceSockets, 1);
    });

    test(
      'a missing workspace surfaces the error and leaves flow null',
      () async {
        final b = FakeBackend();
        b.routes['GET /workspaces/$wsId'] = (_) =>
            FakeBackend.fail(404, 'no such workspace');
        final h = Harness(backend: b);
        await h.openAndLoad();
        expect(h.detail.error, 'no such workspace');
        expect(h.detail.flow, isNull);
      },
    );

    test('a failing side load does not blank the workspace', () async {
      final b = FakeBackend();
      b.routes['GET /workspaces/$wsId/events'] = (_) =>
          FakeBackend.fail(500, 'boom');
      final h = Harness(backend: b);
      await h.openAndLoad();
      expect(h.detail.loaded, isTrue);
      expect(h.detail.error, isNull);
      expect(h.detail.flow, isNotNull);
    });

    test(
      'a REST gate snapshot does not overwrite live cells that beat it',
      () async {
        final b = FakeBackend();
        b.latency = const Duration(milliseconds: 60);
        b.routes['GET /workspaces/$wsId/tests'] = (_) => redRunJson();
        final h = Harness(backend: b);
        h.open();
        await until(() => h.net.channels.isNotEmpty);
        await h.send({
          'channel': 'test',
          'kind': 'cell',
          'cell': cellJson('live', 'running'),
        });
        await h.settleLoad();
        await until(() => h.detail.loaded);
        expect(h.detail.gate.cells.map((c) => c.id), ['live']);
      },
    );
  });

  group('live gate', () {
    test('cells stream the flow from running to red', () async {
      final h = Harness();
      await h.openAndLoad();
      expect(h.detail.flow!.displayState, DisplayState.idle);

      await h.send(statusMsg('tests_running'));
      await h.send({'channel': 'test', 'kind': 'run_started'});
      await h.send(cellMsg('test', 'a', 'running'));
      await h.send(cellMsg('test', 'b', 'running'));
      expect(h.detail.flow!.displayState, DisplayState.gate);
      expect(h.detail.flow!.step(StepKey.verify).line, contains('running'));

      await h.send(cellMsg('test', 'a', 'failed'));
      await h.send(cellMsg('test', 'b', 'passed'));
      expect(h.detail.gate.cells.map((c) => c.status), [
        CellStatus.failed,
        CellStatus.passed,
      ]);
      expect(h.detail.flow!.displayState, DisplayState.gate);

      await h.send(snapshotMsg(redRunJson()));
      await h.send(
        statusMsg(
          'gate_red',
          gate: gateSummaryJson(
            status: 'failed',
            total: 2,
            passed: 1,
            failed: 1,
          ),
        ),
      );
      final flow = h.detail.flow!;
      expect(flow.displayState, DisplayState.red);
      expect(flow.nextAction.kind, NextActionKind.sendFailures);
      expect(flow.lookAt.pending.where((i) => i.isFailure), hasLength(1));
      expect(h.detail.gate.run!.failed, 1);
    });

    test('watch events never change gate state or the flow', () async {
      final h = Harness();
      await h.openAndLoad();
      await h.send(snapshotMsg(redRunJson()));
      await h.send(
        statusMsg(
          'gate_red',
          gate: gateSummaryJson(
            status: 'failed',
            total: 2,
            passed: 1,
            failed: 1,
          ),
        ),
      );
      final gate = h.detail.gate;
      final flow = h.detail.flow;
      expect(flow!.displayState, DisplayState.red);

      await h.send({'channel': 'watch', 'kind': 'run_started'});
      await h.send(cellMsg('watch', 'w1', 'passed'));
      await h.send(
        snapshotMsg(
          testRunJson(
            total: 1,
            passed: 1,
            cases: [caseJson('w', 'passed')],
            overrides: {'trigger': 'watch'},
          ),
          channel: 'watch',
        ),
      );

      expect(h.detail.watch.cells.map((c) => c.id), ['w1']);
      expect(h.detail.watch.run, isNotNull);
      expect(identical(h.detail.gate, gate), isTrue);
      expect(identical(h.detail.flow, flow), isTrue);
      expect(h.detail.gate.cells, isEmpty);
      expect(h.detail.flow!.displayState, DisplayState.red);
    });

    test('a new settled run drops a stale mutation score', () async {
      final b = FakeBackend();
      b.routes['POST /workspaces/$wsId/mutation'] = (_) => {
        'base_ref': 'origin/main',
        'supported': true,
        'score': 80.0,
        'killed': 4,
        'survived': 1,
        'survivors': [
          {'path': 'a.ts', 'line': 3, 'operator': 'flip'},
        ],
      };
      final h = Harness(backend: b);
      await h.openAndLoad();
      await h.send(snapshotMsg(testRunJson()));
      await h.container.read(workspaceActionsProvider(wsId)).runMutation();
      expect(h.detail.analysis.mutation!.survived, 1);
      expect(h.detail.analysis.isRunning(AnalysisKind.mutation), isFalse);

      await h.send(
        snapshotMsg(testRunJson(overrides: {'ended_at': 1790000999.0})),
      );
      expect(h.detail.analysis.mutation, isNull);
    });

    test('batched flush applies a burst of cells once and in order', () async {
      final h = Harness(
        tuning: const WorkspaceDetailTuning(
          diffDebounce: Duration(milliseconds: 40),
          liveFlush: Duration(milliseconds: 30),
          tickElapsed: false,
        ),
      );
      await h.openAndLoad();
      var notifications = 0;
      h.container.listen(
        workspaceDetailProvider(wsId),
        (_, _) => notifications++,
      );
      for (var i = 0; i < 20; i++) {
        h.net.send(cellMsg('test', 'c$i', 'passed'));
      }
      await pumpEventQueue();
      expect(h.detail.gate.cells, isEmpty);
      await until(() => h.detail.gate.cells.length == 20);
      expect(h.detail.gate.cells.first.id, 'c0');
      expect(notifications, 1);
    });
  });

  group('transcript', () {
    test('appends agent events and ignores other sessions', () async {
      final h = Harness();
      await h.openAndLoad();
      await h.send(agentMsg('token', payload: {'text': 'hi'}));
      await h.send(
        agentMsg('token', payload: {'text': 'other'}, sessionId: 's2'),
      );
      await h.send(
        agentMsg('token', payload: {'text': 'no session'}, sessionId: null),
      );
      expect(h.detail.events.map((e) => e.text), ['hi', 'no session']);
    });

    test('tokens do not re-derive the flow', () async {
      final h = Harness();
      await h.openAndLoad();
      await h.send(agentMsg('tool_call', payload: {'tool': 'Edit'}));
      final flow = h.detail.flow;
      await h.send(agentMsg('token', payload: {'text': 'x'}));
      expect(identical(h.detail.flow, flow), isTrue);
      expect(h.detail.events, hasLength(2));
    });

    test('reloads the durable transcript after a reconnect', () async {
      final b = FakeBackend()
        ..events.add(eventJson('user', payload: {'text': 'a'}, runId: 'user'));
      final h = Harness(backend: b);
      await h.openAndLoad();
      expect(h.detail.events, hasLength(1));
      expect(b.count('GET', '/workspaces/$wsId/events'), 1);

      await h.send({'channel': 'run', 'line': 'stale line'});
      expect(h.detail.devLog.lines, ['stale line']);

      b.events.add(
        eventJson(
          'token',
          ts: 1790000010,
          payload: {'text': 'missed while offline'},
        ),
      );
      await h.net.latest.dropFromServer();
      await until(() => h.net.channels.length == 2);
      await until(() => h.detail.events.length == 2);

      expect(b.count('GET', '/workspaces/$wsId/events'), 2);
      expect(h.detail.events.last.text, 'missed while offline');
      expect(h.detail.devLog.lines, isEmpty);
      expect(h.net.workspaceSockets, 2);
    });

    test('a reconnect tells the assist mirror to re-read its job', () async {
      final h = Harness(backend: FakeBackend());
      await h.openAndLoad();
      var pings = 0;
      final sub = h.container
          .read(workspaceDetailProvider(wsId).notifier)
          .assistResync
          .listen((_) => pings++);
      addTearDown(sub.cancel);

      await h.net.latest.dropFromServer();
      await until(() => h.net.channels.length == 2);
      await until(() => pings == 1);
      expect(pings, 1);
    });

    test('the manual rail follows a rebuilt workspace notifier (away over '
        'keepAlive)', () async {
      final b = FakeBackend();
      b.routes['GET /workspaces/$wsId/assist'] = (_) => {
        'id': 'job_1',
        'kind': 'plan',
        'status': 'running',
        'text': 'AB',
      };
      final h = Harness(
        backend: b,
        tuning: const WorkspaceDetailTuning(
          liveFlush: Duration.zero,
          tickElapsed: false,
          keepAlive: Duration(milliseconds: 100),
        ),
      );
      final screen = h.open();
      await h.settleLoad();
      final rail = h.container.listen(manualRailProvider(wsId), (_, _) {});
      addTearDown(rail.close);
      Future<void> token(String text) => h.send({
        'channel': 'assist',
        'job': 'plan',
        'kind': 'token',
        'job_id': 'job_1',
        'text': text,
      });
      await token('A');
      expect(rail.read().runText, 'A');

      screen.close();
      await wait(400);
      expect(h.net.latest.closed, isTrue);

      // Back on the workspace: a fresh notifier and socket, then the rail mounts.
      h.open();
      await h.settleLoad();
      expect(h.net.workspaceSockets, 2);
      await h.container.read(manualRailProvider(wsId).notifier).resync();
      expect(rail.read().planRunning, isTrue);
      expect(rail.read().runText, 'AB');

      await token('C');
      expect(rail.read().runText, 'ABC');
    });

    test('live events newer than the snapshot survive a reload', () async {
      final b = FakeBackend()
        ..events.add(eventJson('token', ts: 100, payload: {'text': 'old'}));
      final h = Harness(backend: b);
      await h.openAndLoad();
      await h.send(agentMsg('token', payload: {'text': 'newer'}, ts: 200));
      await h.container
          .read(workspaceDetailProvider(wsId).notifier)
          .reloadTranscript();
      expect(h.detail.events.map((e) => e.text), ['old', 'newer']);
    });

    test(
      'derives running phase and live elapsed from the newest user turn',
      () async {
        var now = DateTime.fromMillisecondsSinceEpoch(1790000030 * 1000);
        final b = FakeBackend()
          ..events.add(
            eventJson(
              'user',
              ts: 1790000000,
              payload: {'text': 'go'},
              runId: 'user',
            ),
          );
        b.routes['GET /workspaces/$wsId'] = (_) =>
            workspaceJson(id: wsId, status: 'agent_running');
        final h = Harness(
          backend: b,
          tuning: WorkspaceDetailTuning(
            diffDebounce: fastTuning.diffDebounce,
            liveFlush: Duration.zero,
            tickElapsed: false,
            now: () => now,
          ),
        );
        await h.openAndLoad();
        expect(h.detail.agentPhase, AgentPhase.running);
        expect(h.detail.agentElapsed, const Duration(seconds: 30));
        expect(h.detail.flow!.step(StepKey.agent).line, 'working · 30s');

        now = now.add(const Duration(seconds: 12));
        await h.send(agentMsg('tool_call', payload: {'tool': 'Edit'}));
        expect(h.detail.agentElapsed, const Duration(seconds: 42));
      },
    );
  });

  group('diff refetch', () {
    test('a burst of edits and fs events is one debounced refetch', () async {
      final b = FakeBackend();
      var n = 0;
      b.routes['GET /workspaces/$wsId/diff'] = (_) =>
          b.diffJson(files: ++n, added: 1);
      final h = Harness(backend: b);
      await h.openAndLoad();
      expect(b.count('GET', '/workspaces/$wsId/diff'), 1);
      expect(h.detail.diffStats.files, 1);

      await h.send(
        agentMsg('file_edit', payload: {'path': 'a.ts', 'tool': 'Edit'}),
      );
      await wait(15);
      await h.send({'channel': 'fs', 'kind': 'changed'});
      await wait(15);
      await h.send(
        agentMsg('file_edit', payload: {'path': 'b.ts', 'tool': 'Edit'}),
      );
      expect(b.count('GET', '/workspaces/$wsId/diff'), 1);

      await until(() => b.count('GET', '/workspaces/$wsId/diff') == 2);
      await wait(120);
      expect(b.count('GET', '/workspaces/$wsId/diff'), 2);
      expect(h.detail.diffStats.files, 2);
      expect(h.detail.fsRevision, 1);
    });

    test('agent done and a gate settling each schedule a refetch', () async {
      final b = FakeBackend();
      final h = Harness(backend: b);
      await h.openAndLoad();
      await h.send(agentMsg('done'));
      await until(() => b.count('GET', '/workspaces/$wsId/diff') == 2);
      await h.send(statusMsg('gate_green'));
      await until(() => b.count('GET', '/workspaces/$wsId/diff') == 3);
    });

    test('an edit during an in-flight fetch queues exactly one more', () async {
      final b = FakeBackend();
      final h = Harness(backend: b);
      await h.openAndLoad();
      b.latency = const Duration(milliseconds: 80);
      await h.send({'channel': 'fs', 'kind': 'changed'});
      await wait(60);
      await h.send({'channel': 'fs', 'kind': 'changed'});
      await wait(400);
      expect(b.count('GET', '/workspaces/$wsId/diff'), 3);
    });
  });

  group('dev run', () {
    test(
      'tracks run state, clears the log on a fresh run, and caps the buffer',
      () async {
        final h = Harness(
          tuning: const WorkspaceDetailTuning(
            liveFlush: Duration.zero,
            tickElapsed: false,
            logCap: 50,
          ),
        );
        await h.openAndLoad();
        expect(h.detail.app.running, isFalse);

        await h.send({
          'channel': 'run',
          'running': true,
          'url': 'http://localhost:4500',
        });
        expect(h.detail.app.running, isTrue);
        expect(h.detail.app.url, 'http://localhost:4500');

        for (var i = 0; i < 120; i++) {
          h.net.send({'channel': 'run', 'line': 'l$i'});
        }
        await pumpEventQueue();
        final lines = h.detail.devLog.lines;
        expect(lines.length, lessThanOrEqualTo(50));
        expect(lines.last, 'l119');
        expect(lines.first, isNot('l0'));

        await h.send({'channel': 'run', 'running': false, 'error': 'exited 1'});
        expect(h.detail.app.running, isFalse);
        expect(h.detail.app.error, 'exited 1');

        await h.send({'channel': 'run', 'running': true});
        expect(h.detail.devLog.lines, isEmpty);
      },
    );

    test('default cap is 5000 lines', () async {
      final h = Harness();
      await h.openAndLoad();
      for (var i = 0; i < 5600; i++) {
        h.net.send({'channel': 'run', 'line': 'l$i'});
      }
      await pumpEventQueue();
      expect(h.detail.devLog.lines.length, lessThanOrEqualTo(5000));
      expect(h.detail.devLog.lines.last, 'l5599');
    });
  });

  group('sync and lifecycle', () {
    test('follows the workspace store', () async {
      final b = FakeBackend();
      b.routes['GET /projects'] = (_) => [
        {'id': projectId, 'name': 'p', 'path': '/x'},
      ];
      b.routes['GET /projects/$projectId/workspaces'] = (_) => [
        workspaceJson(id: wsId),
      ];
      b.routes['GET /projects/$projectId/todo'] = (_) => {
        'files': [],
        'orphaned': [],
      };
      final h = Harness(backend: b);
      final store = h.container.read(workspaceStoreProvider.notifier);
      await store.reload();
      await h.openAndLoad();
      expect(b.count('GET', '/workspaces/$wsId'), 0);
      expect(h.detail.workspace!.status, WorkspaceStatus.idle);

      store.updateWorkspace(
        h.detail.workspace!.copyWith(status: WorkspaceStatus.gateRed),
      );
      await pumpEventQueue();
      expect(h.detail.workspace!.status, WorkspaceStatus.gateRed);
      expect(h.detail.flow!.displayState, DisplayState.red);
    });

    test(
      'workspace socket status events patch the workspace and bump revisions',
      () async {
        final h = Harness();
        await h.openAndLoad();
        final d0 = h.detail;
        await h.send(statusMsg('agent_running'));
        expect(h.detail.flow!.displayState, DisplayState.agent);
        expect(h.detail.gitRevision, d0.gitRevision + 1);
        expect(h.detail.gateRevision, d0.gateRevision);

        await h.send(statusMsg('gate_green', gate: gateSummaryJson()));
        expect(h.detail.gateRevision, d0.gateRevision + 1);
        expect(h.detail.workspace!.gate!.passed, 594);
      },
    );

    test('one socket per workspace, kept across a brief unlisten, closed after keepAlive', () async {
      final h = Harness(
        tuning: const WorkspaceDetailTuning(
          liveFlush: Duration.zero,
          tickElapsed: false,
          keepAlive: Duration(milliseconds: 120),
        ),
      );
      final sub = h.open();
      await h.settleLoad();
      expect(h.net.workspaceSockets, 1);

      sub.close();
      await wait(40);
      final again = h.open();
      await wait(200);
      expect(h.net.workspaceSockets, 1);
      expect(h.net.latest.closed, isFalse);

      again.close();
      await wait(400);
      expect(h.net.latest.closed, isTrue);
      await h.settleLoad();
    });

    test(
      'lazy providers refetch when the gate settles and blame only runs on red',
      () async {
        final b = FakeBackend();
        b.routes['GET /workspaces/$wsId/verified-hunks'] = (_) => {
          'base_ref': 'origin/main',
          'supported': true,
          'files': [],
        };
        b.routes['GET /workspaces/$wsId/blame'] = (_) => {
          'base_ref': 'origin/main',
          'supported': true,
          'entries': [],
        };
        final h = Harness(backend: b);
        h.container.listen(workspaceVerifiedHunksProvider(wsId), (_, _) {});
        h.container.listen(workspaceBlameProvider(wsId), (_, _) {});
        await h.settleLoad();
        await pumpEventQueue();
        expect(b.count('GET', '/workspaces/$wsId/verified-hunks'), 1);
        expect(b.count('GET', '/workspaces/$wsId/blame'), 0);

        await h.send(
          statusMsg(
            'gate_red',
            gate: gateSummaryJson(status: 'failed', failed: 1),
          ),
        );
        await until(
          () => b.count('GET', '/workspaces/$wsId/verified-hunks') == 2,
        );
        await until(() => b.count('GET', '/workspaces/$wsId/blame') >= 1);
        final hunks = await h.container.read(
          workspaceVerifiedHunksProvider(wsId).future,
        );
        expect(hunks!.supported, isTrue);
      },
    );

    test('git providers refetch on a status change', () async {
      final b = FakeBackend();
      b.routes['GET /workspaces/$wsId/git/status'] = (_) => {
        'branch': 'b',
        'base_ref': 'origin/main',
        'ahead': 1,
      };
      final h = Harness(backend: b);
      h.container.listen(workspaceGitStatusProvider(wsId), (_, _) {});
      await h.settleLoad();
      await pumpEventQueue();
      expect(b.count('GET', '/workspaces/$wsId/git/status'), 1);
      await h.send(statusMsg('agent_running'));
      await until(() => b.count('GET', '/workspaces/$wsId/git/status') == 2);
    });
  });
}
