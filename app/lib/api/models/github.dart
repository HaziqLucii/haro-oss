import 'json_util.dart';

/// One `gh` account haro knows about. Only the fields the UI draws are read: a token never
/// travels to the client, and nothing here would pick one up if a backend ever sent it.
class GithubAccount {
  const GithubAccount({
    required this.login,
    required this.avatarUrl,
    this.isDefault = false,
    this.terminalActive = false,
  });

  factory GithubAccount.fromJson(Json j) {
    final login = jStr(j, 'login');
    return GithubAccount(
      login: login,
      avatarUrl: jStr(j, 'avatar_url', 'https://github.com/$login.png?size=64'),
      isDefault: jBool(j, 'is_default'),
      terminalActive: jBool(j, 'terminal_active'),
    );
  }

  final String login;
  final String avatarUrl;

  /// haro's own default for `gh` calls.
  final bool isDefault;

  /// The account the user's terminal currently has active.
  final bool terminalActive;

  GithubAccount copyWith({bool? isDefault}) => GithubAccount(
    login: login,
    avatarUrl: avatarUrl,
    isDefault: isDefault ?? this.isDefault,
    terminalActive: terminalActive,
  );
}

/// `GET /github/accounts`.
class GithubAccounts {
  const GithubAccounts({
    this.ghAvailable = true,
    this.defaultLogin,
    this.accounts = const [],
  });

  factory GithubAccounts.fromJson(Json j) => GithubAccounts(
    ghAvailable: jBool(j, 'gh_available', true),
    defaultLogin: jStrN(j, 'default'),
    accounts: jList(j, 'accounts', GithubAccount.fromJson),
  );

  static const none = GithubAccounts();

  final bool ghAvailable;
  final String? defaultLogin;
  final List<GithubAccount> accounts;

  /// This list with [login] as the default, for showing a switch before the refresh lands.
  GithubAccounts withDefault(String login) => GithubAccounts(
    ghAvailable: ghAvailable,
    defaultLogin: login,
    accounts: [
      for (final a in accounts) a.copyWith(isDefault: a.login == login),
    ],
  );
}

/// `POST /github/login/start`: the one-time code to type at [url].
class GithubLoginStart {
  const GithubLoginStart({
    required this.id,
    required this.code,
    required this.url,
  });

  factory GithubLoginStart.fromJson(Json j) => GithubLoginStart(
    id: jStr(j, 'id'),
    code: jStr(j, 'code'),
    url: jStr(j, 'url', 'https://github.com/login/device'),
  );

  final String id;
  final String code;
  final String url;
}

enum GithubLoginState {
  pending('pending'),
  done('done'),
  failed('failed'),
  cancelled('cancelled'),
  unknown('');

  const GithubLoginState(this.wire);

  final String wire;

  static GithubLoginState parse(Object? raw) =>
      enumFromWire(values, (s) => s.wire, raw, unknown);
}

/// `GET /github/login/{id}` and the cancel reply.
class GithubLoginStatus {
  const GithubLoginStatus({required this.state, this.login, this.error});

  factory GithubLoginStatus.fromJson(Json j) => GithubLoginStatus(
    state: GithubLoginState.parse(j['state']),
    login: jStrN(j, 'login'),
    error: jStrN(j, 'error'),
  );

  final GithubLoginState state;
  final String? login;
  final String? error;
}

/// `GET` / `PUT /projects/{id}/gh-account`. [source] is `override`, `auto`, `default`,
/// `terminal` or `none`.
class ProjectGhAccount {
  const ProjectGhAccount({this.override, this.resolved, this.source = 'none'});

  factory ProjectGhAccount.fromJson(Json j) => ProjectGhAccount(
    override: jStrN(j, 'override'),
    resolved: jStrN(j, 'resolved'),
    source: jStr(j, 'source', 'none'),
  );

  final String? override;
  final String? resolved;
  final String source;
}
