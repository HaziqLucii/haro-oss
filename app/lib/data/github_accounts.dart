import 'package:flutter/painting.dart' show ImageProvider, NetworkImage;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/models.dart';
import 'workspace_store.dart' show haroApiProvider;

/// How an avatar picture loads. Overridden in tests so nothing touches the network.
final githubAvatarImageProvider = Provider<ImageProvider Function(String url)>(
  (ref) => NetworkImage.new,
);

/// `GET /github/accounts`. A failed load leaves [data] null, which the avatar draws as the
/// person icon, so an older backend without the endpoint simply shows no account.
class GithubAccountsState {
  const GithubAccountsState({this.data, this.loaded = false});

  final GithubAccounts? data;
  final bool loaded;
}

class GithubAccountsNotifier extends Notifier<GithubAccountsState> {
  int _request = 0;

  @override
  GithubAccountsState build() {
    Future.microtask(refresh);
    return const GithubAccountsState();
  }

  Future<void> refresh() async {
    final request = ++_request;
    GithubAccounts? next;
    try {
      next = await ref.read(haroApiProvider).getGithubAccounts();
    } catch (_) {
      next = null;
    }
    if (!ref.mounted || request != _request) return;
    state = GithubAccountsState(data: next, loaded: true);
  }

  /// Switches the avatar at once, then confirms with the backend. A refused change reloads
  /// the real list so the mark never lies.
  Future<void> setDefault(String login) async {
    final current = state.data;
    if (current != null) {
      state = GithubAccountsState(
        data: current.withDefault(login),
        loaded: true,
      );
    }
    final api = ref.read(haroApiProvider);
    try {
      await api.setGithubDefault(login);
    } catch (_) {}
    if (!ref.mounted) return;
    await refresh();
  }
}

final githubAccountsProvider =
    NotifierProvider<GithubAccountsNotifier, GithubAccountsState>(
      GithubAccountsNotifier.new,
    );

/// The account a project's `gh` calls use. Null until loaded or when the call failed.
class ProjectGhAccountNotifier extends Notifier<ProjectGhAccount?> {
  ProjectGhAccountNotifier(this.projectId);

  final String projectId;
  int _request = 0;

  @override
  ProjectGhAccount? build() {
    Future.microtask(refresh);
    return null;
  }

  Future<void> refresh() async {
    final request = ++_request;
    ProjectGhAccount? next;
    try {
      next = await ref.read(haroApiProvider).getProjectGhAccount(projectId);
    } catch (_) {
      next = null;
    }
    if (!ref.mounted || request != _request) return;
    state = next;
  }

  /// [login] null picks Auto.
  Future<void> setOverride(String? login) async {
    final request = ++_request;
    final api = ref.read(haroApiProvider);
    try {
      final next = await api.setProjectGhAccount(projectId, login);
      if (!ref.mounted || request != _request) return;
      state = next;
    } catch (_) {
      if (ref.mounted) await refresh();
    }
  }
}

final projectGhAccountProvider =
    NotifierProvider.family<
      ProjectGhAccountNotifier,
      ProjectGhAccount?,
      String
    >(ProjectGhAccountNotifier.new);
