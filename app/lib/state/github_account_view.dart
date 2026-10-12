import '../api/models/models.dart';

/// The account the avatar shows: haro's default, else the one the terminal has active, else
/// the first. Null when `gh` is missing or nobody is signed in (the person icon).
GithubAccount? avatarAccount(GithubAccounts? accounts) {
  if (accounts == null || !accounts.ghAvailable) return null;
  final list = accounts.accounts;
  if (list.isEmpty) return null;
  for (final a in list) {
    if (a.isDefault) return a;
  }
  final named = accounts.defaultLogin;
  if (named != null) {
    for (final a in list) {
      if (a.login == named) return a;
    }
  }
  for (final a in list) {
    if (a.terminalActive) return a;
  }
  return list.first;
}

/// The letter inside the ring while the picture is not there.
String loginInitial(String login) =>
    login.isEmpty ? '?' : login.substring(0, 1).toUpperCase();

/// Where the project's resolved account came from, in a few words.
String ghSourceLabel(String source) => switch (source) {
  'override' => 'chosen for this project',
  'auto' => 'matches the repo owner',
  'default' => 'haro default',
  'terminal' => 'terminal account',
  _ => 'no account',
};

/// The Auto row's trailing detail: who it resolves to and why.
String autoRowDetail(ProjectGhAccount? p) {
  final login = p?.resolved;
  if (p == null || login == null) return 'no account';
  return '$login · ${ghSourceLabel(p.source)}';
}

/// Whether a failed GitHub load looks like the wrong account (a repo the signed-in account
/// cannot see answers as "not found").
bool needsAccountHint(String? error) {
  if (error == null || error.isEmpty) return false;
  return error.toLowerCase().contains('could not resolve to a repository') ||
      RegExp(r'\b404\b').hasMatch(error);
}

String accountHintLine(String? resolvedLogin) =>
    resolvedLogin == null || resolvedLogin.isEmpty
    ? 'Switch account from the avatar menu.'
    : 'Signed in as $resolvedLogin. Switch account from the avatar menu.';

/// What the login dialog says when `POST /github/login/start` is refused.
String loginStartFailure(
  int status,
  Map<String, dynamic>? body,
  String message,
) {
  final reason = _reasonOf(body);
  if (status == 409 && reason == 'login_in_progress') {
    return 'A GitHub sign-in is already in progress. Finish or cancel it first.';
  }
  if (reason == 'gh_missing') return 'The GitHub CLI (gh) is not installed.';
  return message;
}

String? _reasonOf(Map<String, dynamic>? body) {
  final direct = body?['reason'];
  if (direct is String) return direct;
  final detail = body?['detail'];
  if (detail is Map && detail['reason'] is String) {
    return detail['reason'] as String;
  }
  return null;
}

/// The id of the sign-in a 409 `login_in_progress` is blocked by, when the backend sends it.
String? loginInProgressId(Map<String, dynamic>? body) {
  if (_reasonOf(body) != 'login_in_progress') return null;
  final direct = body?['id'];
  if (direct is String && direct.isNotEmpty) return direct;
  final detail = body?['detail'];
  if (detail is Map &&
      detail['id'] is String &&
      (detail['id'] as String).isNotEmpty) {
    return detail['id'] as String;
  }
  return null;
}
