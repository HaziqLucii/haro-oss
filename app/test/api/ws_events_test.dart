import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';

import 'fixtures.dart';

void main() {
  group('parseWsEvent', () {
    test('agent channel keeps session id', () {
      final e = parseWsEvent({
        'channel': 'agent',
        'session_id': 'side',
        'event': {
          'run_id': 'run_1',
          'workspace_id': 'ws_1',
          'ts': 1.0,
          'type': 'token',
          'payload': {'text': 'hi'},
        },
      });
      expect(e, isA<AgentStreamEvent>());
      e as AgentStreamEvent;
      expect(e.sessionId, 'side');
      expect(e.event.text, 'hi');
    });

    test('agent channel without session id is the primary session', () {
      final e = parseWsEvent({
        'channel': 'agent',
        'event': {'type': 'done', 'payload': {}},
      }) as AgentStreamEvent;
      expect(e.sessionId, isNull);
    });

    test('test channel: run_started, cell, snapshot', () {
      expect(
        parseWsEvent({'channel': 'test', 'kind': 'run_started'}),
        isA<TestRunStarted>(),
      );
      final cell = parseWsEvent({
        'channel': 'test',
        'kind': 'cell',
        'cell': cellJson('c1', 'running'),
      });
      expect(cell, isA<TestCellEvent>());
      expect((cell as TestCellEvent).cell.status, CellStatus.running);
      final snap = parseWsEvent({
        'channel': 'test',
        'kind': 'snapshot',
        'test': testRunJson(),
      });
      expect((snap as TestSnapshotEvent).run.total, 3);
    });

    test('global feed test events carry workspace_id', () {
      final e = parseWsEvent({
        'channel': 'test',
        'kind': 'cell',
        'workspace_id': 'ws_9',
        'cell': cellJson('c1', 'passed'),
      }) as TestEvent;
      expect(e.workspaceId, 'ws_9');
    });

    test('watch channel is a WatchEvent, never a TestEvent', () {
      final e = parseWsEvent({
        'channel': 'watch',
        'kind': 'cell',
        'cell': cellJson('c1', 'failed'),
      });
      expect(e, isA<WatchEvent>());
      expect(e, isNot(isA<TestEvent>()));
      expect((e as WatchEvent).inner, isA<TestCellEvent>());
    });

    test('status channel: bare, setup-only and gate completion', () {
      final bare = parseWsEvent({
        'channel': 'status',
        'workspace_id': 'ws_1',
        'status': 'agent_running',
      }) as StatusEvent;
      expect(bare.status, WorkspaceStatus.agentRunning);
      expect(bare.gate, isNull);
      expect(bare.setup, isNull);

      expect(bare.mode, isNull);
      final withMode = parseWsEvent({
        'channel': 'status',
        'workspace_id': 'ws_1',
        'status': 'idle',
        'mode': 'manual',
      }) as StatusEvent;
      expect(withMode.mode, WorkspaceMode.manual);

      final setup = parseWsEvent({
        'channel': 'status',
        'workspace_id': 'ws_1',
        'setup': {'status': 'running', 'exit': null, 'note': null},
      }) as StatusEvent;
      expect(setup.status, isNull);
      expect(setup.setup!.status, SetupStatus.running);

      final done = parseWsEvent({
        'channel': 'status',
        'workspace_id': 'ws_1',
        'status': 'gate_red',
        'gate': gateSummaryJson(status: 'failed', passed: 591, failed: 3),
        'trust': {
          'enabled': false,
          'conditions': [],
          'streak': 0,
          'streak_required': 3,
          'auto_action': 'off',
          'met': false,
          'armed': false,
        },
      }) as StatusEvent;
      expect(done.gate!.failed, 3);
      expect(done.trust!.streakRequired, 3);
    });

    test('unknown status string does not throw', () {
      final e = parseWsEvent({
        'channel': 'status',
        'workspace_id': 'ws_1',
        'status': 'hibernating',
      }) as StatusEvent;
      expect(e.status, WorkspaceStatus.unknown);
      expect(e.statusRaw, 'hibernating');
    });

    test('run channel: state and log line', () {
      final state = parseWsEvent({
        'channel': 'run',
        'run_id': 'web',
        'running': true,
        'url': 'http://localhost:4500',
      }) as RunEvent;
      expect(state.running, isTrue);
      expect(state.isLogLine, isFalse);
      final line = parseWsEvent({
        'channel': 'run',
        'line': 'ready in 400ms',
      }) as RunEvent;
      expect(line.runId, 'app');
      expect(line.isLogLine, isTrue);
    });

    test('fs channel', () {
      final e = parseWsEvent({
        'channel': 'fs',
        'kind': 'changed',
        'workspace_id': 'ws_1',
      }) as FsEvent;
      expect(e.kind, 'changed');
      expect(e.paths, isEmpty);
      expect(e.truncated, isTrue, reason: 'no path list: refresh everything');
    });

    test('fs channel carries the changed paths', () {
      final e = parseWsEvent({
        'channel': 'fs',
        'kind': 'changed',
        'workspace_id': 'ws_1',
        'paths': [
          {'path': 'a/b.ts', 'change': 'added'},
          {'path': 'c.ts', 'change': 'deleted'},
          {'path': 'd.ts', 'change': 'modified'},
          {'path': 'e.ts', 'change': 'something-new'},
          {'change': 'added'},
        ],
        'truncated': false,
      }) as FsEvent;
      expect(
        [for (final p in e.paths) (p.path, p.change)],
        [
          ('a/b.ts', FsChange.added),
          ('c.ts', FsChange.deleted),
          ('d.ts', FsChange.modified),
          ('e.ts', FsChange.modified),
        ],
      );
      expect(e.truncated, isFalse);
    });

    test('fs channel: a truncated list says so', () {
      final e = parseWsEvent({
        'channel': 'fs',
        'kind': 'changed',
        'paths': [
          {'path': 'a.ts', 'change': 'modified'},
        ],
        'truncated': true,
      }) as FsEvent;
      expect(e.truncated, isTrue);
      expect(e.paths, hasLength(1));
    });

    test('notify kinds', () {
      expect(
        parseWsEvent({
          'channel': 'notify',
          'kind': 'agent_done',
          'workspace_id': 'w',
          'workspace_name': 'n',
          'status': 'done',
        }),
        isA<AgentDoneNotify>(),
      );
      final gate = parseWsEvent({
        'channel': 'notify',
        'kind': 'gate_red',
        'workspace_id': 'w',
        'workspace_name': 'n',
        'workspace_kind': 'adopted',
        'passed': 1,
        'failed': 2,
        'total': 3,
      }) as GateResultNotify;
      expect(gate.green, isFalse);
      expect(gate.workspaceKind, WorkspaceKind.adopted);
      expect(gate.failed, 2);
      final cost = parseWsEvent({
        'channel': 'notify',
        'kind': 'cost_warning',
        'workspace_id': 'w',
        'total_usd': 12.5,
        'threshold_usd': 10,
      }) as CostWarningNotify;
      expect(cost.thresholdUsd, 10);
      expect(
        (parseWsEvent({
          'channel': 'notify',
          'kind': 'rung',
          'workspace_id': 'w',
          'state': 'fired',
          'detail': 'PR opened',
          'streak': 3,
        }) as RungNotify).state,
        'fired',
      );
      expect(
        (parseWsEvent({
          'channel': 'notify',
          'kind': 'backlog_changed',
          'project_id': 'p',
        }) as BacklogChangedNotify).projectId,
        'p',
      );
      final aq = parseWsEvent({
        'channel': 'notify',
        'kind': 'archive_queue',
        'project_id': 'p',
        'run': {'id': 'aq', 'project_id': 'p', 'state': 'running', 'items': []},
      }) as ArchiveQueueNotify;
      expect(aq.run.isRunning, isTrue);
      expect(
        parseWsEvent({
          'channel': 'notify',
          'kind': 'update_status',
          'supported': true,
          'available': true,
          'mode': 'auto',
        }),
        isA<UpdateStatusNotify>(),
      );
      expect(
        parseWsEvent({'channel': 'notify', 'kind': 'update_applying'}),
        isA<UpdateApplyingNotify>(),
      );
    });

    test('removed-feature and unknown messages are ignorable, not errors', () {
      expect(
        parseWsEvent({
          'channel': 'notify',
          'kind': 'race_started',
          'project_id': 'p',
          'race': {},
        }),
        isA<UnknownNotify>(),
      );
      expect(
        parseWsEvent({'channel': 'quality', 'kind': 'x'}),
        isA<UnknownWsEvent>(),
      );
      expect(
        parseWsEvent({'channel': 'test', 'kind': 'mystery'}),
        isA<UnknownWsEvent>(),
      );
      expect(parseWsEvent({}), isA<UnknownWsEvent>());
    });
  });
}
