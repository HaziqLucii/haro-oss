import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';

import 'fixtures.dart';

void main() {
  group('Workspace', () {
    test('parses a full payload including gate, trust and checked rows', () {
      final ws = Workspace.fromJson(
        workspaceJson(
          status: 'gate_green',
          gate: gateSummaryJson(tamperCount: 1, unchecked: 2),
        ),
      );
      expect(ws.id, 'ws_1a2b3c4d');
      expect(ws.status, WorkspaceStatus.gateGreen);
      expect(ws.kind, WorkspaceKind.managed);
      expect(ws.port, 4500);
      expect(ws.priorPrs, [229]);
      expect(ws.checkedRows, ['untested_lines:lib/rates.ts:2']);
      expect(ws.createdAt, 1790000000.5);
      expect(ws.trust!.streakRequired, 3);
      expect(ws.gate!.status, TestRunStatus.passed);
      expect(ws.gate!.tamperCount, 1);
      expect(ws.gate!.tamperNote, '1 removed');
      expect(ws.gate!.uncheckedCount, 2);
    });

    test('unchecked_count null stays null (the pass never ran)', () {
      final ws = Workspace.fromJson(
        workspaceJson(gate: gateSummaryJson(unchecked: null)),
      );
      expect(ws.gate!.uncheckedCount, isNull);
    });

    test('unknown status does not throw and keeps the raw string', () {
      final ws = Workspace.fromJson(workspaceJson(status: 'hibernating'));
      expect(ws.status, WorkspaceStatus.unknown);
      expect(ws.statusRaw, 'hibernating');
    });

    test('missing optional keys fall back to defaults', () {
      final ws = Workspace.fromJson({'id': 'ws_x', 'status': 'agent_running'});
      expect(ws.status, WorkspaceStatus.agentRunning);
      expect(ws.name, '');
      expect(ws.gate, isNull);
      expect(ws.priorPrs, isEmpty);
      expect(ws.kind, WorkspaceKind.managed);
    });

    test('mode defaults to agent when missing or unknown', () {
      expect(Workspace.fromJson({'id': 'ws_x'}).mode, WorkspaceMode.agent);
      final old = workspaceJson()..remove('mode');
      expect(Workspace.fromJson(old).mode, WorkspaceMode.agent);
      expect(Workspace.fromJson(old).modeSwitches, isEmpty);
      expect(
        Workspace.fromJson(workspaceJson(overrides: {'mode': 'telepathy'}))
            .mode,
        WorkspaceMode.agent,
      );
    });

    test('manual mode and its switches parse', () {
      final ws = Workspace.fromJson(
        workspaceJson(
          overrides: {
            'mode': 'manual',
            'mode_switches': [
              {'to': 'manual', 'at': '2026-09-29T10:32:00Z', 'sha': 'abc'},
              {'to': 'agent', 'at': 'not a date', 'sha': 'def'},
            ],
          },
        ),
      );
      expect(ws.mode, WorkspaceMode.manual);
      expect(ws.manual, isTrue);
      expect(ws.modeSwitches.map((s) => s.to), [
        WorkspaceMode.manual,
        WorkspaceMode.agent,
      ]);
      expect(ws.modeSwitches.first.sha, 'abc');
      expect(ws.modeSwitches.first.at!.toUtc().hour, 10);
      expect(ws.modeSwitches.last.at, isNull);
    });

    test('copyWith carries the mode', () {
      final ws = Workspace.fromJson(workspaceJson());
      expect(
        ws.copyWith(mode: WorkspaceMode.manual).mode,
        WorkspaceMode.manual,
      );
      expect(
        ws.copyWith(status: WorkspaceStatus.idle).mode,
        WorkspaceMode.agent,
      );
    });

    test('adopted kind', () {
      final ws = Workspace.fromJson(
        workspaceJson(overrides: {'kind': 'adopted', 'source': 'claude-code'}),
      );
      expect(ws.adopted, isTrue);
      expect(ws.source, 'claude-code');
    });

    test('copyWith merges a status feed update', () {
      final ws = Workspace.fromJson(workspaceJson());
      final next = ws.copyWith(
        status: WorkspaceStatus.gateRed,
        statusRaw: 'gate_red',
        gate: GateSummary.fromJson(
          gateSummaryJson(status: 'failed', passed: 591, failed: 3),
        ),
      );
      expect(next.status, WorkspaceStatus.gateRed);
      expect(next.gate!.failed, 3);
      expect(next.name, ws.name);
    });
  });

  group('AgentRun / AgentEvent', () {
    test('AgentRun parses effort and plan flag', () {
      final r = AgentRun.fromJson({
        'id': 'run_1',
        'workspace_id': 'ws_1',
        'adapter': 'claude-code',
        'model': 'sonnet',
        'effort': 'high',
        'task': 'add multiply',
        'plan': true,
        'fast': false,
        'role': 'plan',
        'status': 'queued',
        'tokens_in': 10,
        'tokens_out': 20,
        'cost_usd': null,
        'started_at': 1.5,
        'ended_at': null,
      });
      expect(r.status, AgentRunStatus.queued);
      expect(r.plan, isTrue);
      expect(r.effort, 'high');
      expect(r.costUsd, isNull);
    });

    test('unknown run status and event type', () {
      expect(
        AgentRun.fromJson({'status': 'weird'}).status,
        AgentRunStatus.unknown,
      );
      expect(
        AgentEvent.fromJson({'type': 'thinking', 'payload': {}}).type,
        AgentEventType.unknown,
      );
    });

    test('done event with plan flag is plan-done', () {
      final e = AgentEvent.fromJson({
        'run_id': 'run_1',
        'workspace_id': 'ws_1',
        'ts': 12.0,
        'type': 'done',
        'payload': {'result': 'the plan', 'plan': true, 'duration_ms': 1200},
        'turn': 3,
      });
      expect(e.isPlanDone, isTrue);
      expect(e.turn, 3);
    });

    test('file_edit accessors', () {
      final e = AgentEvent.fromJson({
        'type': 'file_edit',
        'payload': {
          'tool': 'Edit',
          'path': 'lib/rates.ts',
          'added': 3,
          'removed': 1,
        },
      });
      expect(e.tool, 'Edit');
      expect(e.path, 'lib/rates.ts');
    });

    test('TurnMarker.derive follows the backend rule', () {
      AgentEvent user(String runId, int? turn, String text) =>
          AgentEvent.fromJson({
            'run_id': runId,
            'type': 'user',
            'ts': 1,
            'turn': turn,
            'payload': {'text': text},
          });
      final turns = TurnMarker.derive([
        user('user', 1, 'first'),
        user('autofix', 2, 'auto'),
        user('user', null, 'legacy without a marker'),
        AgentEvent.fromJson({'type': 'token', 'turn': 2, 'payload': {}}),
      ]);
      expect(turns.map((t) => t.kind), ['user', 'autofix']);
      expect(turns.first.prompt, 'first');
    });
  });

  group('TestRun', () {
    test('parses cases, tamper findings and tri-state unchecked items', () {
      final run = TestRun.fromJson(
        testRunJson(
          status: 'failed',
          total: 3,
          passed: 2,
          failed: 1,
          cases: [
            caseJson('a', 'passed'),
            caseJson('b', 'failed', message: 'expected 0, received 499'),
            caseJson('c', 'skipped'),
          ],
          tamper: [
            {
              'kind': 'removed',
              'file': 'lib/shipping.test.ts',
              'detail': 'test deleted',
              'test': 'is free at exactly the \$100 boundary',
            },
          ],
          unchecked: [
            {
              'kind': 'untested_lines',
              'file': 'lib/rates.ts',
              'detail': '2 added lines never executed',
              'count': 2,
              'key': 'untested_lines:lib/rates.ts:2',
            },
          ],
        ),
      );
      expect(run.status, TestRunStatus.failed);
      expect(run.cases[1].status, CellStatus.failed);
      expect(run.cases[1].message, 'expected 0, received 499');
      expect(run.cases[2].status, CellStatus.skipped);
      expect(run.tamperFindings.single.kind, 'removed');
      expect(run.uncheckedItems!.single.count, 2);
      expect(run.durationMs, 2013.4);
      expect(run.degraded, isFalse);
    });

    test('unchecked_items null vs empty are kept distinct', () {
      expect(
        TestRun.fromJson(testRunJson(unchecked: null)).uncheckedItems,
        isNull,
      );
      expect(TestRun.fromJson(testRunJson()).uncheckedItems, isNull);
      expect(
        TestRun.fromJson(testRunJson(unchecked: <Object>[])).uncheckedItems,
        isEmpty,
      );
    });

    test('error run with error_kind', () {
      final run = TestRun.fromJson(
        testRunJson(
          status: 'error',
          overrides: {'error': 'boom', 'error_kind': 'setup'},
        ),
      );
      expect(run.errorKind, GateErrorKind.setup);
      expect(run.error, 'boom');
    });

    test('unknown status and error kind degrade instead of throwing', () {
      final run = TestRun.fromJson(
        testRunJson(status: 'exploded', overrides: {'error_kind': 'cosmic'}),
      );
      expect(run.status, TestRunStatus.unknown);
      expect(run.errorKind, GateErrorKind.runner);
    });

    test('degraded reasons', () {
      final run = TestRun.fromJson(
        testRunJson(
          overrides: {
            'degraded_reasons': ['coverage tool missing'],
          },
        ),
      );
      expect(run.degraded, isTrue);
    });

    test('toCell synthesizes a stable id', () {
      final c = TestCaseResult.fromJson(caseJson('x', 'passed')).toCell(4);
      expect(c.id, 'lib/shipping.test.ts::x::4');
    });

    test('WatchState with and without a run', () {
      expect(WatchState.fromJson({'enabled': false, 'run': null}).run, isNull);
      final w = WatchState.fromJson({
        'enabled': true,
        'run': testRunJson(overrides: {'trigger': 'watch'}),
      });
      expect(w.run!.trigger, 'watch');
    });
  });

  group('Verify evidence', () {
    test(
      'VerifiedFile keeps null (not coverable) distinct from a hit count',
      () {
        final f = VerifiedFile.fromJson({
          'path': 'lib/rates.ts',
          'in_map': true,
          'stale': false,
          'added': 4,
          'executed': 2,
          'unexecuted': 1,
          'noncoverable': 1,
          'lines': {'10': 3, '11': 0, '12': null, 'bad': 1},
        });
        expect(f.lines, {10: 3, 11: 0, 12: null});
        expect(f.lines.containsKey(12), isTrue);
      },
    );

    test('MutationResponse', () {
      final m = MutationResponse.fromJson({
        'base_ref': 'origin/main',
        'gate_sha': 'abc123',
        'supported': true,
        'score': 82.0,
        'killed': 41,
        'survived': 9,
        'skipped': 0,
        'total_mutants': 50,
        'budget_capped': false,
        'survivors': [
          {'path': 'lib/rates.ts', 'line': 12, 'operator': '>= to >'},
        ],
        'note': null,
      });
      expect(m.score, 82);
      expect(m.survivors.single.operator, '>= to >');
    });

    test('Receipt reads written_by, empty from an older backend', () {
      expect(
        Receipt.fromJson({'workspace_id': 'w', 'written_by': 'HaziqLucii'})
            .writtenBy,
        'HaziqLucii',
      );
      expect(Receipt.fromJson({'workspace_id': 'w'}).writtenBy, '');
    });

    test('ReceiptResponse ignores quality and review sections', () {
      final r = ReceiptResponse.fromJson({
        'receipt': {
          'workspace_id': 'ws_1',
          'branch': 'feat/x',
          'base_ref': 'origin/main',
          'verdict': 'green',
          'gate_sha': 'abc',
          'degraded_reasons': <String>[],
          'suite': {
            'runner': 'vitest',
            'scope': 'all',
            'total': 594,
            'passed': 594,
            'failed': 0,
            'skipped': 0,
            'impacted_count': null,
          },
          'tamper': {
            'measured': true,
            'clean': true,
            'findings_count': 0,
            'note': null,
          },
          'quality': {
            'measured': false,
            'blocked': false,
            'findings_count': 0,
            'blocking_count': 0,
            'note': null,
            'plan_compliance': {},
          },
          'review': {'ran': false},
          'verified_hunks': {
            'supported': true,
            'percentage': 98.4,
            'untested_files': ['a.ts'],
            'note': null,
          },
          'mutation': {
            'supported': true,
            'ran': true,
            'stale': false,
            'score': 82.0,
            'survivors': [],
            'note': null,
          },
          'agent': {'model': 'sonnet', 'effort': 'high', 'cost_usd': 9.89},
          'generated_at': 1.0,
        },
        'markdown': '## haro gate receipt',
      });
      expect(r.receipt.verdict, 'green');
      expect(r.receipt.suite.passed, 594);
      expect(r.receipt.verifiedHunks.percentage, 98.4);
      expect(r.receipt.agent.costUsd, 9.89);
      expect(r.markdown, startsWith('## haro'));
    });

    test('CoverageResponse with partial delta', () {
      final c = CoverageResponse.fromJson({
        'supported': true,
        'base_ref': 'origin/main',
        'current': {
          'lines': 91.2,
          'statements': null,
          'functions': null,
          'branches': null,
        },
        'baseline': {'lines': 89.8},
        'delta': {'lines': 1.4},
        'note': null,
      });
      expect(c.delta!.lines, 1.4);
      expect(c.delta!.branches, isNull);
    });

    test('TrustReport exposes a summary', () {
      final t = TrustReport.fromJson({
        'enabled': true,
        'conditions': [
          {
            'key': 'green',
            'met': true,
            'detail': 'gate green',
            'required': true,
            'fix': null,
          },
          {
            'key': 'coverage',
            'met': false,
            'detail': 'guard off',
            'required': true,
            'fix': 'gate_settings',
          },
        ],
        'streak': 1,
        'streak_required': 3,
        'auto_action': 'auto_pr',
        'met': false,
        'armed': false,
      });
      expect(t.conditions.last.fix, 'gate_settings');
      expect(t.summary.autoAction, 'auto_pr');
    });
  });

  group('Project config', () {
    test('GateConfig round-trips an unknown runner untouched', () {
      final g = GateConfig.fromJson({
        'runner': 'nextest',
        'command': 'cargo nextest',
        'format': 'junit',
        'gate_dir': '',
        'default_scope': 'impacted',
        'merge_result': true,
        'flaky_rerun': false,
        'coverage_guard': 'warn',
        'coverage_tolerance': 0.5,
        'tamper_alarm': 'block',
        'code_to_check': 'warn',
        'watch': true,
        'verified_hunks': true,
      });
      final json = g.toJson();
      expect(json['runner'], 'nextest');
      expect(json['coverage_tolerance'], 0.5);
      expect(json['tamper_alarm'], 'block');
      expect(GateConfig.fromJson(json).watch, isTrue);
    });

    test('AgentConfig carries protect_tests, default off', () {
      expect(AgentConfig.fromJson({}).protectTests, 'off');
      final c = AgentConfig.fromJson({'protect_tests': 'existing'});
      expect(c.toJson()['protect_tests'], 'existing');
    });

    test('AgentConfig and RolesConfig toJson keys', () {
      expect(
        const AgentConfig(
          defaultModel: 'fable',
          maxParallel: 2,
        ).toJson()['default_model'],
        'fable',
      );
      final roles = RolesConfig.fromJson({
        'enabled': true,
        'plan': 'opus:high',
        'build': 'sonnet:high',
        'review': '',
        'scout': 'haiku',
        'review_enforce': 'off',
        'review_max_rounds': 2,
      });
      expect(roles.toJson()['plan'], 'opus:high');
    });

    test('GateConfig secrets_scan defaults on and round-trips', () {
      expect(GateConfig.fromJson({}).secretsScan, isTrue);
      final off = GateConfig.fromJson({'secrets_scan': false});
      expect(off.secretsScan, isFalse);
      expect(off.toJson()['secrets_scan'], false);
      expect(const GateConfig().toJson()['secrets_scan'], true);
    });

    test(
      'RolesConfig no longer writes review_enforce or review_max_rounds',
      () {
        final j = RolesConfig.fromJson({
          'review_enforce': 'warn',
          'review_max_rounds': 2,
        }).toJson();
        expect(j.containsKey('review_enforce'), isFalse);
        expect(j.containsKey('review_max_rounds'), isFalse);
      },
    );

    test('UncheckedRow reads line and rule, both optional', () {
      final s = UncheckedRow.fromJson({
        'kind': 'secret_found',
        'file': 'a.env',
        'line': 4,
        'rule': 'generic-api-key',
        'detail': 'possible credential',
        'count': 0,
        'key': 'k',
      });
      expect(s.line, 4);
      expect(s.rule, 'generic-api-key');
      final t = UncheckedRow.fromJson({'kind': 'untested_lines', 'key': 'k'});
      expect(t.line, isNull);
      expect(t.rule, isNull);
    });

    test('AiReview tells the two shapes apart', () {
      final v = AiReview.fromJson({
        'ran_at': 1790000000.0,
        'model': 'opus',
        'verdict': 'fail',
        'summary': 's',
        'must_fix': [
          {
            'file': 'a.ts',
            'line': 3,
            'title': 't',
            'detail': 'd',
            'cited': '+x',
          },
        ],
        'notes': ['n'],
      });
      expect(v, isA<ReviewVerdict>());
      v as ReviewVerdict;
      expect(v.pass, isFalse);
      expect(v.items.single.line, 3);
      expect(v.notes, ['n']);

      final r = AiReview.fromJson({
        'ran_at': 1.0,
        'model': 'sonnet',
        'summary': 's',
        'findings': [
          {
            'file': 'b.ts',
            'line': null,
            'severity': 'nit',
            'category': 'style',
            'title': 't',
          },
        ],
      });
      expect(r, isA<ReviewResult>());
      expect(r.items.single.severity, 'nit');
      expect(r.items.single.line, isNull);

      final e = AiReview.fromJson({
        'ran_at': 1.0,
        'model': '',
        'error': 'no cli',
      });
      expect(e, isA<ReviewResult>());
      expect(e.error, 'no cli');
      expect(
        AiReview.fromJson({'ran_at': 1.0, 'nothing_to_review': true})
            .nothingToReview,
        isTrue,
      );
    });

    test('StackDetection with proposal and candidates', () {
      Map<String, dynamic> cand(String id, double c) => {
        'preset': {
          'id': id,
          'label': id,
          'blurb': '',
          'setup': null,
          'run': 'npm run dev',
          'gate': {'runner': 'vitest', 'gate_dir': 'src'},
          'toml': '[gate]',
        },
        'confidence': c,
      };
      final d = StackDetection.fromJson({
        'ambiguous': false,
        'proposal': cand('vitest', 0.9),
        'candidates': [cand('vitest', 0.9), cand('custom', 0.1)],
      });
      expect(d.proposal!.preset.gate['gate_dir'], 'src');
      expect(d.candidates, hasLength(2));
    });

    test('ScriptsConfig with named runs', () {
      final s = ScriptsConfig.fromJson({
        'setup': 'npm ci',
        'run': 'npm run dev',
        'runs': [
          {
            'id': 'web',
            'command': 'npm run dev',
            'default': true,
            'icon': null,
            'running': true,
            'url': 'http://localhost:4500',
          },
        ],
        'archive': null,
        'run_mode': 'concurrent',
        'login_shell': true,
      });
      expect(s.runs.single.isDefault, isTrue);
      expect(s.toJson().containsKey('runs'), isFalse);
    });

    test('a run script carries the static package.json finding', () {
      final s = ScriptsConfig.fromJson({
        'runs': [
          {
            'id': 'app',
            'command': 'npm run dev',
            'default': true,
            'problem': 'no `dev` script in package.json',
          },
          {'id': 'worker', 'command': 'npm run worker'},
        ],
      });
      expect(s.runs[0].problem, 'no `dev` script in package.json');
      expect(s.runs[1].problem, isNull);
    });

    test('BaselineState reads the default branch sha', () {
      final s = BaselineState.fromJson({
        'running': false,
        'result': {'status': 'passed', 'sha': 'abc'},
        'head_sha': 'def',
      });
      expect(s.result!.sha, 'abc');
      expect(s.headSha, 'def');
      expect(BaselineState.fromJson({'running': false}).headSha, isNull);
    });

    test('SetupState unknown status', () {
      expect(
        SetupState.fromJson({'status': 'ok', 'exit': 0}).status,
        SetupStatus.ok,
      );
      expect(
        SetupState.fromJson({'status': 'huh'}).status,
        SetupStatus.unknown,
      );
    });
  });

  group('Backlog and git', () {
    test('TodoFile blocks discriminate items from notes', () {
      final f = TodoFile.fromJson({
        'path': 'backlog/gate.md',
        'label': 'gate.md',
        'items': [
          {
            'kind': 'item',
            'heading': 'H',
            'text': 'do it',
            'body': 'do it\n```x```',
            'done': false,
            'seed_key': 'k',
            'seeded_workspace': null,
            'stage': 'ready',
          },
        ],
        'blocks': [
          {'kind': 'note', 'md': '# hello'},
          {
            'kind': 'item',
            'heading': null,
            'text': 'do it',
            'body': 'do it',
            'done': true,
          },
        ],
        'content': '# hello',
        'done': 1,
        'pending': 1,
      });
      expect(f.blocks[0], isA<TodoNote>());
      expect((f.blocks[1] as TodoItemBlock).item.done, isTrue);
      expect(f.items.single.stage, 'ready');
    });

    test('IssuesResponse degrade payload', () {
      final r = IssuesResponse.fromJson({
        'available': false,
        'reason': 'no-gh',
        'issues': [],
      });
      expect(r.available, isFalse);
      expect(r.reason, 'no-gh');
    });

    test('PrStatusResponse and MergeResult', () {
      final pr = PrStatusResponse.fromJson({
        'supported': true,
        'exists': true,
        'reason': null,
        'number': 232,
        'title': 't',
        'state': 'MERGED',
        'workspace_merged': true,
        'url': 'https://x/232',
        'draft': false,
        'mergeable': 'MERGEABLE',
        'review_decision': '',
        'comments': 0,
        'additions': 367,
        'deletions': 130,
        'checks': [
          {'name': 'ci', 'bucket': 'pass', 'url': 'u'},
        ],
        'checks_passed': 1,
        'checks_failed': 0,
        'checks_pending': 0,
      });
      expect(pr.workspaceMerged, isTrue);
      expect(pr.checks.single.bucket, 'pass');
      final m = MergeResult.fromJson({
        'merged': true,
        'method': 'gh',
        'pr_url': 'https://x/232',
        'detail': 'ok',
        'committed': null,
      });
      expect(m.prUrl, 'https://x/232');
    });

    test('GitStatusResponse worktree_missing', () {
      final g = GitStatusResponse.fromJson({
        'branch': 'b',
        'base_ref': 'origin/main',
        'ahead': 0,
        'behind': 0,
        'dirty': 0,
        'files': [],
        'merge_mode': 'pr',
        'worktree_missing': true,
      });
      expect(g.worktreeMissing, isTrue);
      expect(g.mergeMode, 'pr');
    });
  });

  group('System', () {
    test('UsageResponse available and unavailable', () {
      final ok = UsageResponse.fromJson({
        'available': true,
        'fetched_at': 1.0,
        'account': {
          'name': 'H',
          'email': 'h@x',
          'org': null,
          'plan': 'Claude Max 5x',
        },
        'limits': [
          {
            'kind': 'session',
            'group': 'session',
            'label': 'Session',
            'percent': 21.5,
            'severity': 'normal',
            'resets_at': '2026-09-29T12:00:00Z',
            'is_active': true,
          },
        ],
        'spend': {
          'percent': 70.0,
          'severity': 'warning',
          'used_label': '\$70.06',
          'limit_label': '\$100.00',
          'disclaimer': null,
        },
      });
      expect(ok.limits.single.percent, 21.5);
      expect(ok.spend!.usedLabel, '\$70.06');
      final bad = UsageResponse.fromJson({
        'available': false,
        'reason': 'token_expired',
      });
      expect(bad.reason, 'token_expired');
      expect(bad.limits, isEmpty);
    });

    test('ArchiveQueueRun outcome enum tolerant', () {
      final r = ArchiveQueueRun.fromJson({
        'id': 'aq_1',
        'project_id': 'p',
        'dry': true,
        'force': false,
        'state': 'planned',
        'stop_requested': false,
        'items': [
          {
            'workspace_id': 'w',
            'name': 'n',
            'outcome': 'skipped',
            'reason': 'dirty',
            'risks': ['uncommitted edits'],
          },
          {
            'workspace_id': 'w2',
            'name': 'n2',
            'outcome': 'teleported',
            'reason': null,
            'risks': [],
          },
        ],
        'created_at': 1.0,
        'finished_at': null,
      });
      expect(r.items[0].outcome, ArchiveOutcome.skipped);
      expect(r.items[1].outcome, ArchiveOutcome.unknown);
    });

    test('FileNode tree', () {
      final n = FileNode.fromJson({
        'name': 'lib',
        'path': 'lib',
        'dir': true,
        'children': [
          {'name': 'a.ts', 'path': 'lib/a.ts', 'dir': false},
        ],
      });
      expect(n.children.single.path, 'lib/a.ts');
    });
  });
}
