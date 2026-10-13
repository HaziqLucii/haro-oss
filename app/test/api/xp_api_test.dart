import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

http.Response _json(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> xpJson({
  int xp = 1240,
  int level = 7,
  String rank = 'Journeyman',
  int rankStart = 800,
  int? next = 2000,
  int days = 3,
  List<bool>? streak,
  bool today = true,
  Map<String, dynamic>? latest,
}) => {
  'xp': xp,
  'level': level,
  'rank': rank,
  'rank_start': rankStart,
  'next_rank_at': next,
  'streak_days': days,
  'streak': streak ?? [for (var i = 0; i < 14; i++) i >= 11],
  'today_done': today,
  'latest':
      latest ??
      {'kind': 'docs_read', 'amount': 10, 'label': 'read the docs', 'at': 1.0},
  'badges': [
    {'kind': 'first_by_hand', 'label': 'First by hand', 'at': 2.0},
  ],
};

Map<String, dynamic> rulesJson() => {
  'level_xp': 180,
  'ranks': [
    {'name': 'Novice', 'at': 0},
    {'name': 'Journeyman', 'at': 800},
    {'name': 'Craftsman', 'at': 2000},
    {'name': 'Master', 'at': 4000},
  ],
  'rules': [
    {
      'kind': 'docs_read',
      'group': 'daily',
      'label': 'read the docs',
      'text': 'Read a plan, pinned doc or man page in Docs',
      'manual': 10,
      'agent': 2,
      'cap': null,
    },
    {
      'kind': 'plan_made',
      'group': 'daily',
      'label': 'made a plan',
      'text': 'Made a plan with haro',
      'manual': 10,
      'agent': 2,
      'cap': null,
    },
    {
      'kind': 'merge_green',
      'group': 'merge',
      'label': 'merged on green',
      'text': 'Merged on green',
      'manual': 20,
      'agent': 10,
      'cap': null,
    },
    {
      'kind': 'eyes_resolved',
      'group': 'merge',
      'label': 'resolved items',
      'text': 'Each needs-your-eyes item ticked',
      'manual': 10,
      'agent': 5,
      'cap': 5,
    },
    {
      'kind': 'review_bonus',
      'group': 'merge',
      'label': 'reviewed every file',
      'text': 'Opened every changed file in Diff',
      'manual': null,
      'agent': 15,
      'cap': null,
    },
    {
      'kind': 'red_to_green',
      'group': 'manual',
      'label': 'red to green by hand',
      'text': 'Red to green with no agent run',
      'manual': 120,
      'agent': null,
      'cap': null,
    },
    {
      'kind': 'test_first',
      'group': 'manual',
      'label': 'started from a test',
      'text': 'Started from a test',
      'manual': 30,
      'agent': null,
      'cap': null,
    },
    {
      'kind': 'first_by_hand',
      'group': 'badge',
      'label': 'First by hand',
      'text': 'Your first merge made by hand',
      'manual': null,
      'agent': null,
      'cap': null,
    },
  ],
};

void main() {
  final base = Uri.parse('http://127.0.0.1:8000');

  HaroApi apiWith(
    Future<http.Response> Function(http.Request r) handler, {
    List<http.Request>? log,
  }) => HaroApi(
    base,
    client: MockClient((req) async {
      log?.add(req);
      return handler(req);
    }),
  );

  group('models', () {
    test('XpStatus parses every field', () {
      final s = XpStatus.fromJson(xpJson());
      expect(s.xp, 1240);
      expect(s.level, 7);
      expect(s.rank, 'Journeyman');
      expect(s.nextRankAt, 2000);
      expect(s.streakDays, 3);
      expect(s.streak, hasLength(14));
      expect(s.streak.last, isTrue);
      expect(s.todayDone, isTrue);
      expect(s.latest!.label, 'read the docs');
      expect(s.badges.single.label, 'First by hand');
    });

    test('progress runs inside the current rank and is full at the top', () {
      final s = XpStatus.fromJson(xpJson());
      expect(s.progress, closeTo((1240 - 800) / (2000 - 800), 1e-9));
      final top = XpStatus.fromJson(
        xpJson(xp: 4210, rank: 'Master', rankStart: 4000, next: null),
      );
      expect(top.nextRankAt, isNull);
      expect(top.progress, 1);
    });

    test('a bare object degrades to a level 1 Novice', () {
      final s = XpStatus.fromJson(<String, dynamic>{});
      expect((s.xp, s.level, s.rank), (0, 1, 'Novice'));
      expect(s.streak, isEmpty);
      expect(s.latest, isNull);
    });

    test('XpRules groups rules and finds one by kind', () {
      final r = XpRules.fromJson(rulesJson());
      expect(r.levelXp, 180);
      expect(r.ranks.map((k) => k.name), [
        'Novice',
        'Journeyman',
        'Craftsman',
        'Master',
      ]);
      expect(r.inGroup('merge').map((x) => x.kind), [
        'merge_green',
        'eyes_resolved',
        'review_bonus',
      ]);
      expect(r.rule('test_first')!.manual, 30);
      expect(r.rule('review_bonus')!.manual, isNull);
      expect(r.rule('eyes_resolved')!.cap, 5);
      expect(r.rule('nope'), isNull);
    });

    test('the xp ws event parses awards and lists badges', () {
      final e = parseWsEvent({
        'channel': 'xp',
        'workspace_id': 'ws_1',
        'amount': 140,
        'label': 'merged on green, red to green by hand',
        'badge': 'First by hand',
        'awards': [
          {
            'kind': 'merge_green',
            'amount': 20,
            'label': 'merged on green',
            'badge': false,
          },
          {
            'kind': 'first_by_hand',
            'amount': 0,
            'label': 'First by hand',
            'badge': true,
          },
        ],
      });
      expect(e, isA<XpWsEvent>());
      e as XpWsEvent;
      expect(e.amount, 140);
      expect(e.workspaceId, 'ws_1');
      expect(e.awards, hasLength(2));
      expect(e.badges, ['First by hand']);
    });

    test('the receipt carries the xp line', () {
      final r = Receipt.fromJson({
        'workspace_id': 'ws_1',
        'xp': 'XP: +20 (merged on green)',
      });
      expect(r.xp, 'XP: +20 (merged on green)');
      expect(Receipt.fromJson({'workspace_id': 'ws_1'}).xp, isNull);
    });
  });

  group('api', () {
    test('getXp and getXpRules hit their routes', () async {
      final log = <http.Request>[];
      final api = apiWith(
        (r) async => _json(r.url.path == '/xp' ? xpJson() : rulesJson()),
        log: log,
      );
      expect((await api.getXp()).xp, 1240);
      expect((await api.getXpRules()).rules, isNotEmpty);
      expect(log.map((r) => '${r.method} ${r.url.path}'), [
        'GET /xp',
        'GET /xp/rules',
      ]);
    });

    test('postXpActivity sends the kind, workspace and paths', () async {
      final log = <http.Request>[];
      final api = apiWith(
        (r) async => _json({
          'awards': [
            {
              'kind': 'diff_reviewed',
              'amount': 3,
              'label': 'reviewed the diff',
              'badge': false,
            },
          ],
        }),
        log: log,
      );
      final awards = await api.postXpActivity(
        'diff_reviewed',
        workspaceId: 'ws_1',
        paths: ['a.js', 'b.js'],
      );
      expect(awards.single.amount, 3);
      expect(log.single.method, 'POST');
      expect(log.single.url.path, '/xp/activity');
      expect(jsonDecode(log.single.body), {
        'kind': 'diff_reviewed',
        'workspace_id': 'ws_1',
        'paths': ['a.js', 'b.js'],
      });
    });

    test('postXpActivity omits an absent workspace and empty paths', () async {
      final log = <http.Request>[];
      final api = apiWith((r) async => _json({'awards': []}), log: log);
      expect(await api.postXpActivity('docs_read'), isEmpty);
      expect(jsonDecode(log.single.body), {'kind': 'docs_read'});
    });

    test('createWorkspace sends start_from_test only when asked', () async {
      final log = <http.Request>[];
      final api = apiWith((r) async => _json(workspaceJson()), log: log);
      await api.createWorkspace('p1', 'a', mode: WorkspaceMode.manual);
      await api.createWorkspace(
        'p1',
        'b',
        mode: WorkspaceMode.manual,
        startFromTest: true,
      );
      expect(jsonDecode(log[0].body), isNot(contains('start_from_test')));
      expect(jsonDecode(log[1].body)['start_from_test'], isTrue);
    });
  });
}
