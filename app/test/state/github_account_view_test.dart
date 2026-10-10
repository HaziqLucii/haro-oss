import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/github_account_view.dart';

GithubAccount _a(String login, {bool def = false, bool terminal = false}) =>
    GithubAccount(
      login: login,
      avatarUrl: 'u',
      isDefault: def,
      terminalActive: terminal,
    );

void main() {
  group('avatarAccount', () {
    test('null without data, without gh, or without accounts', () {
      expect(avatarAccount(null), isNull);
      expect(avatarAccount(const GithubAccounts(ghAvailable: false)), isNull);
      expect(avatarAccount(const GithubAccounts()), isNull);
      expect(
        avatarAccount(
          GithubAccounts(ghAvailable: false, accounts: [_a('x', def: true)]),
        ),
        isNull,
      );
    });

    test('default, then terminal, then first', () {
      expect(
        avatarAccount(GithubAccounts(accounts: [_a('a'), _a('b', def: true)]))!
            .login,
        'b',
      );
      expect(
        avatarAccount(
          GithubAccounts(defaultLogin: 'b', accounts: [_a('a'), _a('b')]),
        )!.login,
        'b',
      );
      expect(
        avatarAccount(
          GithubAccounts(accounts: [_a('a'), _a('b', terminal: true)]),
        )!.login,
        'b',
      );
      expect(
        avatarAccount(GithubAccounts(accounts: [_a('a'), _a('b')]))!.login,
        'a',
      );
    });
  });

  test('loginInitial', () {
    expect(loginInitial('octo'), 'O');
    expect(loginInitial(''), '?');
  });

  test('autoRowDetail names who and why', () {
    expect(autoRowDetail(null), 'no account');
    expect(
      autoRowDetail(const ProjectGhAccount(resolved: 'work', source: 'auto')),
      'work · matches the repo owner',
    );
    expect(
      autoRowDetail(const ProjectGhAccount(resolved: 'me', source: 'terminal')),
      'me · terminal account',
    );
  });

  test('needsAccountHint', () {
    expect(
      needsAccountHint(
        "GraphQL: Could not resolve to a Repository with the name 'A/b'.",
      ),
      isTrue,
    );
    expect(needsAccountHint('HTTP 404: Not Found'), isTrue);
    expect(needsAccountHint('rate limited'), isFalse);
    expect(needsAccountHint('port 14040 busy'), isFalse);
    expect(needsAccountHint(null), isFalse);
    expect(needsAccountHint(''), isFalse);
  });

  test('accountHintLine tolerates a missing login', () {
    expect(
      accountHintLine('octo'),
      'Signed in as octo. Switch account from the avatar menu.',
    );
    expect(accountHintLine(null), 'Switch account from the avatar menu.');
  });

  test('loginStartFailure reads the 409 reason, flat or under detail', () {
    expect(
      loginStartFailure(409, {'reason': 'login_in_progress'}, 'x'),
      contains('already in progress'),
    );
    expect(
      loginStartFailure(409, {
        'detail': {'reason': 'login_in_progress'},
      }, 'x'),
      contains('already in progress'),
    );
    expect(
      loginStartFailure(409, {'reason': 'gh_missing'}, 'x'),
      contains('not installed'),
    );
    expect(loginStartFailure(500, null, 'boom'), 'boom');
  });

  test('loginInProgressId reads the id of the blocking sign-in', () {
    expect(
      loginInProgressId({'reason': 'login_in_progress', 'id': 'abc'}),
      'abc',
    );
    expect(
      loginInProgressId({
        'detail': {'reason': 'login_in_progress', 'id': 'abc'},
      }),
      'abc',
    );
    expect(loginInProgressId({'reason': 'login_in_progress'}), isNull);
    expect(loginInProgressId({'reason': 'gh_missing', 'id': 'abc'}), isNull);
    expect(loginInProgressId(null), isNull);
  });
}
