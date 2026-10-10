import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

void main() {
  final base = Uri.parse('http://127.0.0.1:8000');

  http.Response jsonRes(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  HaroApi apiWith(
    Future<http.Response> Function(http.Request) handler,
    List<http.Request> log,
  ) => HaroApi(
    base,
    client: MockClient((r) async {
      log.add(r);
      return handler(r);
    }),
  );

  const planJson = {
    'id': 'plan_1',
    'title': 'Wire it',
    'prompt': 'p',
    'steps': [
      {'text': 'a', 'done': true},
      {'text': 'b', 'done': false},
    ],
    'why': 'read first',
    'model': 'sonnet',
    'cost_usd': 0.05,
    'saved': false,
  };

  test('models parse and tolerate missing keys', () {
    final p = ManualPlan.fromJson(planJson);
    expect(p.steps.map((s) => s.done), [true, false]);
    expect(p.doneCount, 1);
    expect(p.why, 'read first');
    expect(p.saved, isFalse);
    expect(ManualPlan.fromJson(const {'id': 'x'}).steps, isEmpty);
    final r = ResearchResponse.fromJson({
      'scope': 'repo',
      'query': 'q',
      'rows': [
        {
          'source': 'repo',
          'title': 'a.ts:1',
          'target': 'a.ts:1',
          'why': 'w',
          'action': 'jump',
        },
      ],
      'note': 'n',
    });
    expect(r.rows.single.action, 'jump');
    expect(r.jobId, isNull);
    expect(ResearchRow.fromJson(const {}).action, 'open');
  });

  test('guard notes, blocked calls and unverified flags parse', () {
    final p = ManualPlan.fromJson({
      ...planJson,
      'guard_note': 'could not check',
      'blocked_calls': ['Write', 'Bash'],
    });
    expect(p.guardNote, 'could not check');
    expect(p.blockedCalls, ['Write', 'Bash']);
    expect(ManualPlan.fromJson(planJson).guardNote, isNull);
    expect(p.copyWith(saved: true).guardNote, 'could not check');

    final r = Receipt.fromJson({
      'workspace_id': 'w',
      'plan': {'plans': 1, 'steps': 2, 'unverified': true},
      'research': {'lookups': 2, 'unverified': true},
    });
    expect(r.plan!.unverified, isTrue);
    expect(r.researchUnverified, isTrue);
    expect(Receipt.fromJson({'workspace_id': 'w'}).researchUnverified, isFalse);

    final e = parseWsEvent({
      'channel': 'assist',
      'job': 'research',
      'kind': 'done',
      'guard_note': 'g',
      'blocked_calls': ['Write'],
    }) as AssistEvent;
    expect(e.guardNote, 'g');
    expect(e.blockedCalls, ['Write']);
  });

  test('workspace carries plans and the lookup count', () {
    final ws = Workspace.fromJson(
      workspaceJson(
        overrides: {
          'plans': [planJson],
          'research_log': {'count': 7, 'entries': []},
        },
      ),
    );
    expect(ws.plans.single.title, 'Wire it');
    expect(ws.researchLookups, 7);
    final old = Workspace.fromJson(workspaceJson());
    expect(old.plans, isEmpty);
    expect(old.researchLookups, 0);
  });

  test('receipt parses plan and research, and their absence', () {
    final r = Receipt.fromJson({
      'workspace_id': 'w',
      'plan': {'plans': 1, 'steps': 6, 'done': 2, 'ai_edits': 0},
      'research': {'lookups': 3},
    });
    expect(r.plan!.steps, 6);
    expect(r.researchLookups, 3);
    final none = Receipt.fromJson({'workspace_id': 'w'});
    expect(none.plan, isNull);
    expect(none.researchLookups, isNull);
  });

  test('assist channel events parse', () {
    final e = parseWsEvent({
      'channel': 'assist',
      'job': 'plan',
      'job_id': 'job_1',
      'kind': 'done',
      'plan': planJson,
      'cost_usd': 0.05,
    }) as AssistEvent;
    expect(e.job, 'plan');
    expect(e.kind, 'done');
    expect(e.plan!.id, 'plan_1');
    expect(e.costUsd, 0.05);
    final ask = parseWsEvent({
      'channel': 'assist',
      'job': 'research',
      'kind': 'done',
      'answer': 'a',
      'rows': [
        {'source': 'web', 'title': 't', 'target': 'https://x'},
      ],
    }) as AssistEvent;
    expect(ask.answer, 'a');
    expect(ask.rows.single.source, 'web');
    final tok = parseWsEvent({
      'channel': 'assist',
      'job': 'plan',
      'kind': 'token',
      'text': 'hi',
    }) as AssistEvent;
    expect(tok.text, 'hi');
  });

  test('assistPlan and assistResearch send the documented bodies', () async {
    final log = <http.Request>[];
    final api = apiWith((r) async {
      if (r.url.path.endsWith('/assist/plan')) {
        return jsonRes({
          'id': 'job_1',
          'kind': 'plan',
          'status': 'running',
          'workspace_id': 'ws_1',
        });
      }
      return jsonRes({'scope': 'ask', 'query': 'q', 'job_id': 'job_2'});
    }, log);
    final job = await api.assistPlan('ws_1', 'build it', model: 'opus');
    expect(job.id, 'job_1');
    expect(log.last.method, 'POST');
    expect(log.last.url.path, '/workspaces/ws_1/assist/plan');
    expect(jsonDecode(log.last.body), {'prompt': 'build it', 'model': 'opus'});

    final res = await api.assistResearch('ws_1', 'q', effort: 'low');
    expect(res.jobId, 'job_2');
    expect(log.last.url.path, '/workspaces/ws_1/assist/research');
    expect(jsonDecode(log.last.body), {'query': 'q', 'effort': 'low'});
  });

  test(
    'patchPlan sends only what changed; pinned docs and man pages',
    () async {
      final log = <http.Request>[];
      final api = apiWith((r) async {
        if (r.url.path.startsWith('/man/')) {
          return jsonRes({'page': 'ls(1)', 'text': 'LS', 'truncated': false});
        }
        if (r.url.path.contains('pinned-docs')) {
          return jsonRes([
            {'title': 'S', 'url': 'https://s.io'},
          ]);
        }
        return jsonRes(planJson);
      }, log);

      await api.patchPlan(
        'ws_1',
        'plan_1',
        steps: const [PlanStep(text: 'a', done: true)],
      );
      expect(log.last.method, 'PATCH');
      expect(log.last.url.path, '/workspaces/ws_1/plans/plan_1');
      expect(jsonDecode(log.last.body), {
        'steps': [
          {'text': 'a', 'done': true},
        ],
      });
      await api.patchPlan('ws_1', 'plan_1', saved: true);
      expect(jsonDecode(log.last.body), {'saved': true});

      final docs = await api.setPinnedDocs('p1', const [
        PinnedDoc(title: 'S', url: 'https://s.io'),
      ]);
      expect(log.last.method, 'PUT');
      expect(log.last.url.path, '/projects/p1/pinned-docs');
      expect(docs.single.url, 'https://s.io');

      final man = await api.getManPage('ls(1)');
      expect(man.text, 'LS');
      expect(Uri.decodeComponent(log.last.url.pathSegments.last), 'ls(1)');
    },
  );
}
