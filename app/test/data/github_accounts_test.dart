import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart' show HaroApiException;
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/github_accounts.dart';
import 'package:haro_app/data/workspace_store.dart';

import 'github_harness.dart';

GithubAccounts _two() => GithubAccounts.fromJson({
  'default': 'a',
  'accounts': [
    {'login': 'a', 'is_default': true},
    {'login': 'b'},
  ],
});

ProviderContainer _container(FakeGithubApi api) {
  final c = ProviderContainer(
    overrides: [haroApiProvider.overrideWithValue(api)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('loads the accounts once built', () async {
    final api = FakeGithubApi()..accounts = _two();
    final c = _container(api);
    expect(c.read(githubAccountsProvider).loaded, isFalse);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final s = c.read(githubAccountsProvider);
    expect(s.loaded, isTrue);
    expect(s.data!.accounts, hasLength(2));
  });

  test('a failed load leaves no data instead of throwing', () async {
    final api = FakeGithubApi()
      ..accountsError = const HaroApiException(404, 'x');
    final c = _container(api);
    await c.read(githubAccountsProvider.notifier).refresh();
    await pumpEventQueue();
    final s = c.read(githubAccountsProvider);
    expect(s.loaded, isTrue);
    expect(s.data, isNull);
  });

  test('setDefault switches at once, posts, then refreshes', () async {
    final api = FakeGithubApi()..accounts = _two();
    final c = _container(api);
    final n = c.read(githubAccountsProvider.notifier);
    await n.refresh();
    await pumpEventQueue();
    final future = n.setDefault('b');
    expect(c.read(githubAccountsProvider).data!.defaultLogin, 'b');
    await future;
    await pumpEventQueue();
    expect(api.calls, containsAllInOrder(['default:b', 'accounts']));
    expect(c.read(githubAccountsProvider).data!.defaultLogin, 'b');
  });

  test('a refused default reloads the real list', () async {
    final api = FakeGithubApi()
      ..accounts = _two()
      ..defaultError = const HaroApiException(404, 'unknown login');
    final c = _container(api);
    final n = c.read(githubAccountsProvider.notifier);
    await n.refresh();
    await pumpEventQueue();
    await n.setDefault('b');
    await pumpEventQueue();
    expect(c.read(githubAccountsProvider).data!.defaultLogin, 'a');
  });

  test(
    'project account loads, sets an override, and Auto sends null',
    () async {
      final api = FakeGithubApi();
      final c = _container(api);
      final p = projectGhAccountProvider('p1');
      c.listen(p, (_, _) {});
      await c.read(p.notifier).refresh();
      await pumpEventQueue();
      expect(c.read(p)!.resolved, 'a');
      await c.read(p.notifier).setOverride('b');
      expect(c.read(p)!.override, 'b');
      await c.read(p.notifier).setOverride(null);
      expect(c.read(p)!.override, isNull);
      expect(
        api.calls,
        containsAllInOrder(['override:p1:b', 'override:p1:auto']),
      );
    },
  );

  test('a failed project lookup is null, not an error', () async {
    final api = FakeGithubApi()..projectError = Exception('down');
    final c = _container(api);
    final p = projectGhAccountProvider('p1');
    c.listen(p, (_, _) {});
    await c.read(p.notifier).refresh();
    await pumpEventQueue();
    expect(c.read(p), isNull);
  });
}
