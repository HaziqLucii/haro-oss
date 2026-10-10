import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/data/xp_store.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/xp_prefs_provider.dart';
import 'package:haro_app/shell/shell_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../api/xp_api_test.dart' show rulesJson, xpJson;

http.Response _json(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class Rig {
  Rig({Map<String, dynamic>? status, this.statusCode = 200, Json? prefs})
    : statusBody = status ?? xpJson() {
    api = HaroApi(
      Uri.parse('http://test'),
      client: MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.url.path == '/xp') return _json(statusBody, statusCode);
        if (req.url.path == '/xp/rules') return _json(rulesJson());
        if (req.url.path == '/xp/activity') {
          activity.add(jsonDecode(req.body) as Map<String, dynamic>);
          if (failActivity) return _json({'detail': 'no'}, 500);
          return _json({'awards': []});
        }
        return _json({'detail': 'nope'}, 404);
      }),
    );
    container = ProviderContainer(
      overrides: [
        haroApiProvider.overrideWithValue(api),
        devicePrefsStoreProvider.overrideWithValue(
          MemoryDevicePrefsStore(prefs),
        ),
      ],
    );
  }

  final Map<String, dynamic> statusBody;
  final int statusCode;
  final calls = <String>[];
  final activity = <Map<String, dynamic>>[];
  bool failActivity = false;
  late final HaroApi api;
  late final ProviderContainer container;

  XpStore get store => container.read(xpStoreProvider.notifier);
  XpState get state => container.read(xpStoreProvider);
}

void main() {
  group('XpStore', () {
    test(
      'load fetches the status and the rules, the rules only once',
      () async {
        final r = Rig();
        addTearDown(r.container.dispose);
        await r.store.load();
        expect(r.state.status!.xp, 1240);
        expect(r.state.rules!.rule('test_first')!.manual, 30);
        await r.store.load();
        expect(r.calls.where((c) => c == 'GET /xp/rules'), hasLength(1));
        expect(r.calls.where((c) => c == 'GET /xp'), hasLength(2));
      },
    );

    test(
      'a backend without XP leaves the state empty and does not throw',
      () async {
        final r = Rig(statusCode: 404);
        addTearDown(r.container.dispose);
        await r.store.load();
        expect(r.state.status, isNull);
        expect(r.state.rules, isNull);
      },
    );

    test(
      'an award event queues a notice with a fresh sequence number',
      () async {
        final r = Rig();
        addTearDown(r.container.dispose);
        r.store.onEvent(
          const XpWsEvent(
            amount: 10,
            label: 'read the docs',
            awards: [
              XpAward(kind: 'docs_read', amount: 10, label: 'read the docs'),
            ],
          ),
        );
        final first = r.state.notice!;
        expect(first.message, '+10 XP · read the docs');
        r.store.onEvent(const XpWsEvent(amount: 10, label: 'read the docs'));
        expect(r.state.notice!.seq, greaterThan(first.seq));
        await Future<void>.delayed(Duration.zero);
      },
    );

    test('badge unlocks get their own line', () {
      final r = Rig();
      addTearDown(r.container.dispose);
      r.store.onEvent(
        const XpWsEvent(
          amount: 20,
          label: 'merged on green',
          awards: [
            XpAward(kind: 'merge_green', amount: 20, label: 'merged on green'),
            XpAward(
              kind: 'first_by_hand',
              amount: 0,
              label: 'First by hand',
              badge: true,
            ),
          ],
        ),
      );
      expect(
        r.state.notice!.message,
        '+20 XP · merged on green\nBadge unlocked: First by hand',
      );
    });

    test('a badge alone still toasts, an empty event does not', () {
      final r = Rig();
      addTearDown(r.container.dispose);
      r.store.onEvent(const XpWsEvent());
      expect(r.state.notice, isNull);
      r.store.onEvent(
        const XpWsEvent(
          awards: [
            XpAward(
              kind: 'mutant_hunter',
              amount: 0,
              label: 'Mutant hunter',
              badge: true,
            ),
          ],
        ),
      );
      expect(r.state.notice!.message, 'Badge unlocked: Mutant hunter');
    });

    test('an award event refreshes the numbers under the toast', () async {
      final r = Rig();
      addTearDown(r.container.dispose);
      r.store.onEvent(const XpWsEvent(amount: 5, label: 'ran the gate'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(r.state.status!.xp, 1240);
    });
  });

  group('footer data', () {
    test('formats the bar text with separators and drops the target at the top rank', () {
      final mid = XpFooterData.fromStatus(XpStatus.fromJson(xpJson()));
      expect(mid.xpText, '1,240 / 2,000 XP');
      expect(mid.tooltip, 'Level 7 · Journeyman · 1,240 / 2,000 XP');
      final top = XpFooterData.fromStatus(
        XpStatus.fromJson(
          xpJson(xp: 4210, rank: 'Master', rankStart: 4000, next: null),
        ),
      );
      expect(top.xpText, '4,210 XP');
    });

    test('the provider is null until loaded and when Show XP is off', () async {
      final r = Rig();
      addTearDown(r.container.dispose);
      expect(r.container.read(xpFooterProvider), isNull);
      await r.store.load();
      expect(r.container.read(xpFooterProvider)!.level, 7);
      r.container
          .read(xpPrefsProvider.notifier)
          .set(const XpPrefs(showXp: false));
      expect(r.container.read(xpFooterProvider), isNull);
    });
  });

  group('XpReporter', () {
    XpReporter reporter(Rig r, DateTime Function() clock) =>
        XpReporter(() => r.api, clock: clock);

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 10));

    test('a Docs read reports once per local day', () async {
      final r = Rig();
      addTearDown(r.container.dispose);
      var now = DateTime(2026, 9, 30, 10);
      final xp = reporter(r, () => now);
      xp.docsRead('ws_1');
      xp.docsRead('ws_2');
      await settle();
      expect(r.activity, [
        {'kind': 'docs_read', 'workspace_id': 'ws_1'},
      ]);
      now = DateTime(2026, 10, 1, 9);
      xp.docsRead('ws_1');
      await settle();
      expect(r.activity, hasLength(2));
    });

    test('a failed report is retried on the next occasion', () async {
      final r = Rig()..failActivity = true;
      addTearDown(r.container.dispose);
      final xp = reporter(r, () => DateTime(2026, 9, 30));
      xp.docsRead('ws_1');
      await settle();
      r.failActivity = false;
      xp.docsRead('ws_1');
      await settle();
      expect(r.activity, hasLength(2));
      xp.docsRead('ws_1');
      await settle();
      expect(r.activity, hasLength(2));
    });

    test(
      'a diff review reports once per distinct list of viewed files',
      () async {
        final r = Rig();
        addTearDown(r.container.dispose);
        final xp = reporter(r, DateTime.now);
        xp.diffReviewed('ws_1', ['b.js', 'a.js']);
        xp.diffReviewed('ws_1', ['a.js', 'b.js']);
        await settle();
        expect(r.activity, [
          {
            'kind': 'diff_reviewed',
            'workspace_id': 'ws_1',
            'paths': ['a.js', 'b.js'],
          },
        ]);
        xp.diffReviewed('ws_1', ['a.js', 'b.js', 'c.js']);
        await settle();
        expect(r.activity, hasLength(2));
        expect(r.activity.last['paths'], ['a.js', 'b.js', 'c.js']);
      },
    );

    test('an empty list never reports', () async {
      final r = Rig();
      addTearDown(r.container.dispose);
      final xp = reporter(r, DateTime.now);
      xp.diffReviewed('ws_1', const []);
      await settle();
      expect(r.activity, isEmpty);
    });
  });
}
