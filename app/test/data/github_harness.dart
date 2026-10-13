import 'dart:async';

import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';

class FakeGithubApi extends HaroApi {
  FakeGithubApi() : super(Uri.parse('http://127.0.0.1:1'));

  final calls = <String>[];
  GithubAccounts accounts = const GithubAccounts();
  Object? accountsError;
  Object? defaultError;

  /// Holds `setGithubDefault` until completed, to model a slow backend.
  Completer<void>? defaultGate;

  /// Returned by the next accounts read only, then cleared: a read that raced a restore.
  GithubAccounts? staleOnce;
  ProjectGhAccount project = const ProjectGhAccount(
    resolved: 'a',
    source: 'default',
  );
  Object? projectError;

  GithubLoginStart startReply = const GithubLoginStart(
    id: 'l1',
    code: 'ABCD-1234',
    url: 'https://github.com/login/device',
  );
  Object? startError;

  /// Answers handed out by successive polls; the last one repeats.
  List<GithubLoginStatus> pollReplies = const [
    GithubLoginStatus(state: GithubLoginState.pending),
  ];
  int _polls = 0;

  @override
  Future<GithubAccounts> getGithubAccounts() async {
    calls.add('accounts');
    final stale = staleOnce;
    if (stale != null) {
      staleOnce = null;
      return stale;
    }
    if (accountsError != null) throw accountsError!;
    return accounts;
  }

  @override
  Future<void> setGithubDefault(String login) async {
    calls.add('default:$login');
    await defaultGate?.future;
    if (defaultError != null) throw defaultError!;
    accounts = accounts.withDefault(login);
  }

  @override
  Future<ProjectGhAccount> getProjectGhAccount(String projectId) async {
    calls.add('project:$projectId');
    if (projectError != null) throw projectError!;
    return project;
  }

  @override
  Future<ProjectGhAccount> setProjectGhAccount(
    String projectId,
    String? login,
  ) async {
    calls.add('override:$projectId:${login ?? 'auto'}');
    project = ProjectGhAccount(
      override: login,
      resolved: login ?? 'a',
      source: login == null ? 'auto' : 'override',
    );
    return project;
  }

  @override
  Future<GithubLoginStart> startGithubLogin() async {
    calls.add('login-start');
    if (startError != null) throw startError!;
    return startReply;
  }

  @override
  Future<GithubLoginStatus> getGithubLogin(String id) async {
    calls.add('login-poll');
    final i = _polls < pollReplies.length ? _polls : pollReplies.length - 1;
    _polls++;
    return pollReplies[i];
  }

  @override
  Future<GithubLoginStatus> cancelGithubLogin(String id) async {
    calls.add('login-cancel:$id');
    return const GithubLoginStatus(state: GithubLoginState.cancelled);
  }
}
