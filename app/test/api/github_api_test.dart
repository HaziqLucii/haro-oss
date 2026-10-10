import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final base = Uri.parse('http://127.0.0.1:8000');

  http.Response jsonRes(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  HaroApi apiWith(
    http.Response Function(http.Request) h, [
    List<http.Request>? log,
  ]) => HaroApi(
    base,
    client: MockClient((r) async {
      log?.add(r);
      return h(r);
    }),
  );

  group('models', () {
    test(
      'accounts parse, and a missing avatar_url falls back to the login',
      () {
        final a = GithubAccounts.fromJson({
          'gh_available': true,
          'default': 'octo',
          'accounts': [
            {
              'login': 'octo',
              'avatar_url': 'https://github.com/octo.png?size=64',
              'is_default': true,
              'terminal_active': false,
            },
            {'login': 'work', 'terminal_active': true},
          ],
        });
        expect(a.ghAvailable, isTrue);
        expect(a.defaultLogin, 'octo');
        expect(a.accounts.map((x) => x.login), ['octo', 'work']);
        expect(a.accounts[0].isDefault, isTrue);
        expect(a.accounts[1].isDefault, isFalse);
        expect(a.accounts[1].terminalActive, isTrue);
        expect(a.accounts[1].avatarUrl, 'https://github.com/work.png?size=64');
      },
    );

    test('empty or odd payloads degrade to defaults', () {
      final a = GithubAccounts.fromJson({});
      expect(a.accounts, isEmpty);
      expect(a.defaultLogin, isNull);
      final b = GithubAccounts.fromJson({
        'gh_available': false,
        'accounts': 'nope',
      });
      expect(b.ghAvailable, isFalse);
      expect(b.accounts, isEmpty);
    });

    test('no token-like field is parsed or kept', () {
      final a = GithubAccounts.fromJson({
        'gh_available': true,
        'token': 'ghp_secret',
        'accounts': [
          {
            'login': 'octo',
            'token': 'ghp_secret',
            'oauth_token': 'gho_secret',
            'GH_TOKEN': 'ghp_secret',
            'is_default': true,
          },
        ],
      });
      final dump = [
        a.accounts.single.login,
        a.accounts.single.avatarUrl,
        a.defaultLogin,
        a.toString(),
        a.accounts.single.toString(),
      ].join(' ');
      expect(dump.contains('secret'), isFalse);
      final project = ProjectGhAccount.fromJson({
        'override': null,
        'resolved': 'octo',
        'source': 'auto',
        'token': 'ghp_secret',
      });
      expect(
        '${project.resolved}${project.source}'.contains('secret'),
        isFalse,
      );
    });

    test('login start and status', () {
      final s = GithubLoginStart.fromJson({
        'id': 'l1',
        'code': 'ABCD-1234',
        'url': 'https://github.com/login/device',
      });
      expect((s.id, s.code), ('l1', 'ABCD-1234'));
      expect(
        GithubLoginStatus.fromJson({'state': 'done', 'login': 'octo'}).state,
        GithubLoginState.done,
      );
      final failed = GithubLoginStatus.fromJson({
        'state': 'failed',
        'login': null,
        'error': 'expired',
      });
      expect(failed.state, GithubLoginState.failed);
      expect(failed.error, 'expired');
      expect(
        GithubLoginStatus.fromJson({'state': 'weird'}).state,
        GithubLoginState.unknown,
      );
    });

    test('project account', () {
      final p = ProjectGhAccount.fromJson({
        'override': 'work',
        'resolved': 'work',
        'source': 'override',
      });
      expect((p.override, p.resolved, p.source), ('work', 'work', 'override'));
      final none = ProjectGhAccount.fromJson({});
      expect(none.source, 'none');
      expect(none.resolved, isNull);
    });

    test('withDefault moves the mark', () {
      final a = GithubAccounts.fromJson({
        'default': 'a',
        'accounts': [
          {'login': 'a', 'is_default': true},
          {'login': 'b'},
        ],
      }).withDefault('b');
      expect(a.defaultLogin, 'b');
      expect(a.accounts.map((x) => x.isDefault), [false, true]);
    });
  });

  group('requests', () {
    test('accounts and default', () async {
      final log = <http.Request>[];
      final api = apiWith((r) {
        if (r.url.path == '/github/accounts') {
          return jsonRes({
            'gh_available': true,
            'default': null,
            'accounts': [],
          });
        }
        return jsonRes({'default': 'octo'});
      }, log);
      expect((await api.getGithubAccounts()).accounts, isEmpty);
      await api.setGithubDefault('octo');
      expect(log[0].method, 'GET');
      expect(log[1].method, 'POST');
      expect(log[1].url.path, '/github/default');
      expect(jsonDecode(log[1].body), {'login': 'octo'});
    });

    test('login start, poll and cancel', () async {
      final log = <http.Request>[];
      final api = apiWith((r) {
        if (r.url.path == '/github/login/start') {
          return jsonRes({'id': 'l1', 'code': 'AB-12', 'url': 'u'});
        }
        if (r.url.path == '/github/login/l1/cancel') {
          return jsonRes({'state': 'cancelled'});
        }
        return jsonRes({'state': 'pending', 'login': null, 'error': null});
      }, log);
      expect((await api.startGithubLogin()).code, 'AB-12');
      expect((await api.getGithubLogin('l1')).state, GithubLoginState.pending);
      expect(
        (await api.cancelGithubLogin('l1')).state,
        GithubLoginState.cancelled,
      );
      expect(log.map((r) => '${r.method} ${r.url.path}'), [
        'POST /github/login/start',
        'GET /github/login/l1',
        'POST /github/login/l1/cancel',
      ]);
    });

    test('a 409 keeps its reason in the exception body', () async {
      final api = apiWith((r) => jsonRes({'reason': 'login_in_progress'}, 409));
      await expectLater(
        api.startGithubLogin(),
        throwsA(
          isA<HaroApiException>()
              .having((e) => e.status, 'status', 409)
              .having((e) => e.body?['reason'], 'reason', 'login_in_progress'),
        ),
      );
    });

    test('project account GET and PUT, null clears the override', () async {
      final log = <http.Request>[];
      final api = apiWith(
        (r) =>
            jsonRes({'override': null, 'resolved': 'a', 'source': 'default'}),
        log,
      );
      expect((await api.getProjectGhAccount('p1')).resolved, 'a');
      await api.setProjectGhAccount('p1', null);
      await api.setProjectGhAccount('p1', 'work');
      expect(log[1].method, 'PUT');
      expect(log[1].url.path, '/projects/p1/gh-account');
      expect(jsonDecode(log[1].body), {'login': null});
      expect(jsonDecode(log[2].body), {'login': 'work'});
    });
  });
}
