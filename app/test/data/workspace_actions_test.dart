import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/state/display_state.dart';

import '../api/fixtures.dart';
import '../state/builders.dart' show removedTest;
import 'detail_harness.dart';

Map<String, dynamic> agentRunJson() => {
  'id': 'run_9',
  'workspace_id': wsId,
  'status': 'running',
};

Future<(Harness, WorkspaceActions, FakeBackend)> setup([
  void Function(FakeBackend b)? tweak,
]) async {
  final b = FakeBackend();
  b.routes['POST /workspaces/$wsId/agent'] = (_) => agentRunJson();
  tweak?.call(b);
  final h = Harness(backend: b);
  await h.openAndLoad();
  return (h, h.container.read(workspaceActionsProvider(wsId)), b);
}

Map<String, dynamic> redSnapshot({
  List<Map<String, dynamic>> tamper = const [],
}) => {
  'channel': 'test',
  'kind': 'snapshot',
  'test': testRunJson(
    status: 'failed',
    total: 3,
    passed: 1,
    failed: 2,
    unchecked: null,
    tamper: tamper,
    cases: [
      caseJson('first', 'failed', message: 'expected 0'),
      caseJson('second', 'failed', message: 'expected 1'),
      caseJson('ok', 'passed'),
    ],
  ),
};

void main() {
  group('agent', () {
    test('startAgent echoes the prompt, locks the workspace, and posts the request', () async {
      final (h, actions, b) = await setup();
      final run = await actions.startAgent(
        '  add a boundary test  ',
        model: 'sonnet-5',
        effort: 'high',
      );
      expect(run!.id, 'run_9');
      final call = b.last('POST', '/workspaces/$wsId/agent');
      final body = call.body! as Map;
      expect(body['task'], 'add a boundary test');
      expect(body['plan'], false);
      expect(body['role'], 'build');
      expect(body['model'], 'sonnet-5');
      expect(body['effort'], 'high');
      expect(h.detail.events.single.type, AgentEventType.user);
      expect(h.detail.events.single.text, 'add a boundary test');
      expect(h.detail.flow!.displayState, DisplayState.agent);
    });

    test('plan-first sends role plan', () async {
      final (_, actions, b) = await setup();
      await actions.startAgent('plan it', plan: true);
      final body = b.last('POST', '/workspaces/$wsId/agent').body! as Map;
      expect(body['plan'], true);
      expect(body['role'], 'plan');
    });

    test(
      'a failed start rolls back the echo and the status, and rethrows',
      () async {
        final (h, actions, _) = await setup((b) {
          b.routes['POST /workspaces/$wsId/agent'] = (_) =>
              FakeBackend.fail(409, 'an agent is already running');
        });
        await expectLater(
          actions.startAgent('go'),
          throwsA(
            isA<HaroApiException>()
                .having((e) => e.status, 'status', 409)
                .having(
                  (e) => e.message,
                  'message',
                  'an agent is already running',
                ),
          ),
        );
        expect(h.detail.events, isEmpty);
        expect(h.detail.workspace!.status, WorkspaceStatus.idle);
        expect(h.detail.flow!.displayState, DisplayState.idle);
      },
    );

    test('a blank task does nothing', () async {
      final (_, actions, b) = await setup();
      expect(await actions.startAgent('   '), isNull);
      expect(b.count('POST', '/workspaces/$wsId/agent'), 0);
    });

    test('the persisted prompt replaces the local echo on reload', () async {
      final (h, actions, b) = await setup();
      await actions.startAgent('go');
      final echoTs = h.detail.events.single.ts;
      b.events.add(
        eventJson(
          'user',
          ts: echoTs + 0.05,
          payload: {'text': 'go'},
          runId: 'user',
        ),
      );
      await h.container
          .read(workspaceDetailProvider(wsId).notifier)
          .reloadTranscript();
      expect(h.detail.events, hasLength(1));
      expect(h.detail.events.single.ts, echoTs + 0.05);
    });

    test('stopAgent posts to agent/stop and surfaces a 409', () async {
      final (_, actions, b) = await setup((b) {
        b.routes['POST /workspaces/$wsId/agent/stop'] = (_) =>
            FakeBackend.fail(409, 'no agent running in this session');
      });
      await expectLater(actions.stopAgent(), throwsA(isA<HaroApiException>()));
      expect(b.count('POST', '/workspaces/$wsId/agent/stop'), 1);
    });

    test('startAgent sends test_first only when asked for it', () async {
      final (_, actions, b) = await setup();
      await actions.startAgent('add shipping');
      expect(
        (b.last('POST', '/workspaces/$wsId/agent').body! as Map).containsKey(
          'test_first',
        ),
        isFalse,
      );
      await actions.startAgent('add shipping', testFirst: true);
      expect(
        (b.last('POST', '/workspaces/$wsId/agent').body! as Map)['test_first'],
        true,
      );
    });

    test('approveTestFirst posts the approval with the run arguments and locks the workspace', () async {
      final (h, actions, b) = await setup((b) {
        b.routes['POST /workspaces/$wsId/test-first/approve'] = (_) =>
            agentRunJson();
      });
      final run = await actions.approveTestFirst(
        model: 'sonnet',
        effort: 'high',
      );
      expect(run.id, 'run_9');
      final body =
          b.last('POST', '/workspaces/$wsId/test-first/approve').body! as Map;
      expect(body['model'], 'sonnet');
      expect(body['effort'], 'high');
      expect(h.detail.workspace!.status, WorkspaceStatus.agentRunning);
    });

    test(
      'leaveTestFirst posts the confirm flag and replaces the workspace copy',
      () async {
        final (h, actions, b) = await setup((b) {
          b.routes['POST /workspaces/$wsId/test-first/cancel'] = (_) =>
              workspaceJson(id: wsId);
        });
        await actions.leaveTestFirst(confirm: true);
        final body =
            b.last('POST', '/workspaces/$wsId/test-first/cancel').body! as Map;
        expect(body['confirm'], true);
        expect(h.detail.workspace!.testFirst, isNull);
      },
    );

    test(
      'a refused approval rolls the status back and surfaces the reason',
      () async {
        final (h, actions, _) = await setup((b) {
          b.routes['POST /workspaces/$wsId/test-first/approve'] = (_) =>
              FakeBackend.fail(
                409,
                'a drafted test file changed after it was proven red',
              );
        });
        final before = h.detail.workspace!.status;
        await expectLater(
          actions.approveTestFirst(),
          throwsA(isA<HaroApiException>()),
        );
        expect(h.detail.workspace!.status, before);
      },
    );

    test('approvePlan re-runs as build with the approval prompt', () async {
      final (_, actions, b) = await setup();
      await actions.approvePlan();
      final body = b.last('POST', '/workspaces/$wsId/agent').body! as Map;
      expect(body['task'], startsWith('The plan above is approved'));
      expect(body['plan'], false);
      expect(body['role'], 'build');
    });

    test('approvePlan passes the composer run arguments through', () async {
      final (_, actions, b) = await setup();
      await actions.approvePlan(
        model: 'haiku',
        effort: 'low',
        adapter: 'claude-code',
      );
      final body = b.last('POST', '/workspaces/$wsId/agent').body! as Map;
      expect(body['model'], 'haiku');
      expect(body['effort'], 'low');
      expect(body['adapter'], 'claude-code');
      expect(body['role'], 'build');
    });

    test(
      'sendFailuresToAgent builds one prompt from every failing test',
      () async {
        final (h, actions, b) = await setup();
        await h.send(redSnapshot());
        await h.send(
          statusMsg(
            'gate_red',
            gate: gateSummaryJson(status: 'failed', failed: 2),
          ),
        );
        await actions.sendFailuresToAgent();
        final task =
            (b.last('POST', '/workspaces/$wsId/agent').body! as Map)['task']
                as String;
        expect(task, startsWith('Address these 2 gate findings:'));
        expect(task, contains('test: first'));
        expect(task, contains('test: second'));
        expect(task, isNot(contains('test: ok')));
        expect(task, contains('make this test pass without weakening it'));
      },
    );

    test('sendFailuresToAgent is a no-op when nothing is failing', () async {
      final (_, actions, b) = await setup();
      expect(await actions.sendFailuresToAgent(), isNull);
      expect(b.count('POST', '/workspaces/$wsId/agent'), 0);
    });

    test('sendLookAtToAgent sends the chosen items only', () async {
      final (h, actions, b) = await setup();
      await h.send(redSnapshot());
      await h.send(
        statusMsg(
          'gate_red',
          gate: gateSummaryJson(status: 'failed', failed: 2),
        ),
      );
      final first = h.detail.flow!.lookAt.pending.first;
      await actions.sendLookAtToAgent([first]);
      final task =
          (b.last('POST', '/workspaces/$wsId/agent').body! as Map)['task']
              as String;
      expect(task, startsWith('Address this gate finding:'));
      expect(task, contains(first.review.target));
    });

    test(
      'restoreTests sends the tamper findings with restore instructions',
      () async {
        final (h, actions, b) = await setup();
        await h.send(redSnapshot(tamper: [removedTest]));
        await actions.restoreTests();
        final task =
            (b.last('POST', '/workspaces/$wsId/agent').body! as Map)['task']
                as String;
        expect(task, contains('restore this deleted test'));
        expect(task, contains(r'is free at exactly the $100 boundary'));
      },
    );
  });

  group('gate', () {
    test('runGate posts the scope and applies the returned run', () async {
      final (h, actions, b) = await setup((b) {
        b.routes['POST /workspaces/$wsId/tests'] = (_) =>
            testRunJson(total: 3, passed: 3);
      });
      await actions.runGate(impacted: true);
      expect(b.last('POST', '/workspaces/$wsId/tests').query, {
        'scope': 'impacted',
      });
      expect(h.detail.gate.run!.passed, 3);

      await actions.runGate();
      expect(b.last('POST', '/workspaces/$wsId/tests').query, {'scope': 'all'});
      await actions.runGate(failedOnly: true);
      expect(b.last('POST', '/workspaces/$wsId/tests').query, {
        'scope': 'failed',
      });
    });

    test(
      'runGate settles the status with no socket help (reloads the workspace)',
      () async {
        final (h, actions, b) = await setup((b) {
          b.routes['POST /workspaces/$wsId/tests'] = (_) =>
              testRunJson(total: 3, passed: 3);
          var gets = 0;
          b.routes['GET /workspaces/$wsId'] = (_) => workspaceJson(
            id: wsId,
            status: gets++ == 0 ? 'idle' : 'gate_green',
          );
        });
        await actions.runGate();
        expect(h.detail.workspace!.status, WorkspaceStatus.gateGreen);
        expect(h.detail.flow!.displayState, DisplayState.green);
      },
    );

    test(
      'runGate falls back to the run result when the reload fails',
      () async {
        final (h, actions, b) = await setup((b) {
          b.routes['POST /workspaces/$wsId/tests'] = (_) =>
              testRunJson(total: 3, passed: 2, failed: 1, status: 'failed');
          var gets = 0;
          b.routes['GET /workspaces/$wsId'] = (_) => gets++ == 0
              ? workspaceJson(id: wsId)
              : FakeBackend.fail(500, 'x');
        });
        await actions.runGate();
        expect(h.detail.workspace!.status, WorkspaceStatus.gateRed);
      },
    );

    test(
      'runGate locks the workspace while running and restores it on failure',
      () async {
        final (h, actions, b) = await setup((b) {
          b.routes['POST /workspaces/$wsId/tests'] = (_) =>
              FakeBackend.fail(409, 'an agent is running');
        });
        b.latency = const Duration(milliseconds: 40);
        final f = actions.runGate();
        await pumpEventQueue();
        expect(h.detail.flow!.displayState, DisplayState.gate);
        await expectLater(f, throwsA(isA<HaroApiException>()));
        expect(h.detail.workspace!.status, WorkspaceStatus.idle);
      },
    );

    test('toggleChecked ticks optimistically, posts the key, and adopts the server list', () async {
      final (h, actions, b) = await setup((b) {
        b.routes['POST /workspaces/$wsId/checked'] = (_) => {
          'checked_rows': ['untested_lines:lib/rates.ts:2', 'new_dep:x'],
        };
      });
      final keys = await actions.toggleChecked('new_dep:x');
      expect(keys, hasLength(2));
      expect(b.last('POST', '/workspaces/$wsId/checked').body, {
        'key': 'new_dep:x',
        'checked': true,
      });
      expect(h.detail.workspace!.checkedRows, contains('new_dep:x'));

      await actions.toggleChecked('untested_lines:lib/rates.ts:2');
      expect(b.last('POST', '/workspaces/$wsId/checked').body, {
        'key': 'untested_lines:lib/rates.ts:2',
        'checked': false,
      });
    });

    test('toggleChecked rolls back when the request fails', () async {
      final (h, actions, _) = await setup((b) {
        b.routes['POST /workspaces/$wsId/checked'] = (_) =>
            FakeBackend.fail(500, 'boom');
      });
      await expectLater(
        actions.toggleChecked('new_dep:x'),
        throwsA(isA<HaroApiException>()),
      );
      expect(h.detail.workspace!.checkedRows, [
        'untested_lines:lib/rates.ts:2',
      ]);
    });

    test(
      'mutation, coverage and flaky are on demand and record errors',
      () async {
        final (h, actions, b) = await setup((b) {
          b.routes['GET /workspaces/$wsId/coverage'] = (_) => {
            'supported': true,
            'base_ref': 'origin/main',
          };
          b.routes['POST /workspaces/$wsId/flaky'] = (_) =>
              FakeBackend.fail(409, 'the flaky check needs an idle workspace');
        });
        expect(b.count('GET', '/workspaces/$wsId/coverage'), 0);
        await actions.measureCoverage();
        expect(h.detail.analysis.coverage!.supported, isTrue);

        await expectLater(
          actions.checkFlaky(runs: 3),
          throwsA(isA<HaroApiException>()),
        );
        expect(b.last('POST', '/workspaces/$wsId/flaky').query, {'runs': '3'});
        expect(
          h.detail.analysis.errors[AnalysisKind.flaky],
          contains('idle workspace'),
        );
        expect(h.detail.analysis.isRunning(AnalysisKind.flaky), isFalse);
      },
    );

    test('addToBacklog files each item and reports the count', () async {
      final (h, actions, b) = await setup((b) {
        b.routes['POST /projects/$projectId/todo/items'] = (_) => {'ok': true};
      });
      await h.send(redSnapshot());
      await h.send(
        statusMsg(
          'gate_red',
          gate: gateSummaryJson(status: 'failed', failed: 2),
        ),
      );
      final n = await actions.addToBacklog(h.detail.flow!.lookAt.pending);
      expect(n, 2);
      expect(b.count('POST', '/projects/$projectId/todo/items'), 2);
      expect((b.calls.last.body! as Map)['title'], startsWith('test: '));
    });
  });

  group('ship', () {
    test(
      'commit and openPr hit git endpoints and bump the git revision',
      () async {
        final (h, actions, b) = await setup((b) {
          b.routes['POST /workspaces/$wsId/git/commit'] = (_) => {
            'committed': 'abc1234',
          };
          b.routes['POST /workspaces/$wsId/git/pr'] = (_) => {
            'created': true,
            'url': 'https://x/pr/1',
          };
        });
        final rev = h.detail.gitRevision;
        final c = await actions.commit('  ship it  ');
        expect(c.committed, 'abc1234');
        expect(b.last('POST', '/workspaces/$wsId/git/commit').body, {
          'message': 'ship it',
        });
        expect(h.detail.gitRevision, rev + 1);

        final pr = await actions.openPr();
        expect(pr.url, 'https://x/pr/1');
        expect(h.detail.gitRevision, rev + 2);
      },
    );

    test(
      'merge marks the workspace merged, refreshes it, and reloads the store',
      () async {
        var status = 'gate_green';
        final (h, actions, b) = await setup((b) {
          b.routes['GET /workspaces/$wsId'] = (_) => workspaceJson(
            id: wsId,
            status: status,
            overrides: {'last_pr_number': 232},
          );
          b.routes['POST /workspaces/$wsId/merge'] = (_) {
            status = 'merged';
            return {
              'merged': true,
              'method': 'gh',
              'pr_url': 'https://x/pull/232',
              'detail': 'ok',
            };
          };
        });
        final gateRev = h.detail.gateRevision;
        final res = await actions.merge();
        expect(res.merged, isTrue);
        expect(b.count('POST', '/workspaces/$wsId/merge'), 1);
        expect(h.detail.workspace!.status, WorkspaceStatus.merged);
        expect(h.detail.workspace!.lastPrNumber, 232);
        expect(h.detail.flow!.displayState, DisplayState.merged);
        expect(h.detail.gateRevision, greaterThan(gateRev));
        expect(b.count('GET', '/projects'), 1);
      },
    );

    test(
      'merge failure surfaces as HaroApiException and changes nothing',
      () async {
        final (h, actions, _) = await setup((b) {
          b.routes['POST /workspaces/$wsId/merge'] = (_) =>
              FakeBackend.fail(409, 'gate is not green');
        });
        await expectLater(
          actions.merge(),
          throwsA(
            isA<HaroApiException>().having(
              (e) => e.message,
              'message',
              'gate is not green',
            ),
          ),
        );
        expect(h.detail.workspace!.status, WorkspaceStatus.idle);
      },
    );

    test(
      'continueOnNewBranch posts /continue and reloads the workspace',
      () async {
        var status = 'merged';
        final (h, actions, b) = await setup((b) {
          b.routes['GET /workspaces/$wsId'] = (_) => workspaceJson(
            id: wsId,
            status: status,
            overrides: {'branch': 'feat/next'},
          );
          b.routes['POST /workspaces/$wsId/continue'] = (_) {
            status = 'idle';
            return {
              'branch': 'feat/next',
              'base_ref': 'origin/main',
              'prior_prs': [232],
              'detail': 'ok',
            };
          };
        });
        final res = await actions.continueOnNewBranch();
        expect(res.branch, 'feat/next');
        expect(b.count('POST', '/workspaces/$wsId/continue'), 1);
        expect(h.detail.workspace!.branch, 'feat/next');
        expect(h.detail.workspace!.status, WorkspaceStatus.idle);
      },
    );

    test('renameWorkspace patches name and branch', () async {
      final (h, actions, b) = await setup((b) {
        b.routes['PATCH /workspaces/$wsId'] = (_) => workspaceJson(
          id: wsId,
          overrides: {'name': 'renamed', 'branch': 'feat/renamed'},
        );
      });
      final w = await actions.renameWorkspace(
        name: 'renamed',
        branch: 'feat/renamed',
      );
      expect(w.name, 'renamed');
      expect(b.last('PATCH', '/workspaces/$wsId').body, {
        'name': 'renamed',
        'branch': 'feat/renamed',
      });
      expect(h.detail.workspace!.name, 'renamed');
    });

    test('archiveWorkspace deletes the workspace', () async {
      final (_, actions, b) = await setup((b) {
        b.routes['DELETE /workspaces/$wsId'] = (_) => null;
      });
      await actions.archiveWorkspace();
      expect(b.count('DELETE', '/workspaces/$wsId'), 1);
    });

    test('postReceiptToPr returns the comment url', () async {
      final (_, actions, b) = await setup((b) {
        b.routes['POST /workspaces/$wsId/receipt/pr-comment'] = (_) => {
          'posted': true,
          'url': 'https://x/c/1',
        };
      });
      expect(await actions.postReceiptToPr(), 'https://x/c/1');
      expect(b.count('POST', '/workspaces/$wsId/receipt/pr-comment'), 1);
    });
  });

  group('dev server and files', () {
    test(
      'start and stop hit /run and /run/stop, and start applies the result',
      () async {
        final (h, actions, b) = await setup((b) {
          b.routes['POST /workspaces/$wsId/run'] = (_) => {
            'running': true,
            'url': 'http://localhost:4500',
          };
          b.routes['POST /workspaces/$wsId/run/stop'] = (_) => {'ok': true};
        });
        await actions.startDevServer();
        expect(h.detail.app.running, isTrue);
        expect(h.detail.app.url, 'http://localhost:4500');
        expect(b.last('POST', '/workspaces/$wsId/run').query, isEmpty);

        await actions.startDevServer(runId: 'storybook');
        expect(b.last('POST', '/workspaces/$wsId/run').query, {
          'run_id': 'storybook',
        });
        expect(h.detail.runs['storybook']!.running, isTrue);

        await actions.stopDevServer();
        expect(b.count('POST', '/workspaces/$wsId/run/stop'), 1);
      },
    );

    test(
      'readFile and saveFile use /file, and a save schedules a diff refetch',
      () async {
        final (_, actions, b) = await setup((b) {
          b.routes['GET /workspaces/$wsId/file'] = (_) => {
            'path': 'lib/a.ts',
            'content': 'x',
            'binary': false,
          };
          b.routes['PUT /workspaces/$wsId/file'] = (_) => {'ok': true};
        });
        final f = await actions.readFile('lib/a.ts');
        expect(f.content, 'x');
        expect(b.last('GET', '/workspaces/$wsId/file').query, {
          'path': 'lib/a.ts',
        });

        await actions.saveFile('lib/a.ts', 'y');
        expect(b.last('PUT', '/workspaces/$wsId/file').body, {
          'path': 'lib/a.ts',
          'content': 'y',
        });
        await wait(150);
        expect(b.count('GET', '/workspaces/$wsId/diff'), 2);
      },
    );
  });
}
