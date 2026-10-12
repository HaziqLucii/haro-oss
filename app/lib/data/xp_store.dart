import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/haro_api.dart';
import '../api/models/models.dart';
import '../backend/backend_health.dart';
import '../features/settings/xp_prefs_provider.dart';
import '../shell/shell_models.dart';
import 'workspace_store.dart';

/// The toast text for one award event: `+10 XP · read the docs`, then a line per badge.
@immutable
class XpNotice {
  const XpNotice({
    required this.seq,
    required this.amount,
    required this.label,
    this.badges = const [],
  });

  /// Distinguishes two identical awards, so listening for a change fires for both.
  final int seq;
  final int amount;
  final String label;
  final List<String> badges;

  String get message => [
    if (amount > 0) '+$amount XP${label.isEmpty ? '' : ' · $label'}',
    for (final b in badges) 'Badge unlocked: $b',
  ].join('\n');
}

@immutable
class XpState {
  const XpState({this.status, this.rules, this.notice});

  final XpStatus? status;
  final XpRules? rules;
  final XpNotice? notice;

  XpState copyWith({XpStatus? status, XpRules? rules, XpNotice? notice}) =>
      XpState(
        status: status ?? this.status,
        rules: rules ?? this.rules,
        notice: notice ?? this.notice,
      );
}

/// XP, rank and streak from `GET /xp`, plus the award table. Passive on its own: nothing here
/// touches the network until [load] or an award event, and [xpWiringProvider] is what starts
/// that in the real app.
class XpStore extends Notifier<XpState> {
  int _seq = 0;
  Future<void>? _loading;

  @override
  XpState build() => const XpState();

  HaroApi get _api => ref.read(haroApiProvider);

  /// Fetches the status, and the rules once. A backend that has not answered leaves the old
  /// state alone: the footer just does not show.
  Future<void> load() =>
      _loading ??= _load().whenComplete(() => _loading = null);

  Future<void> _load() async {
    try {
      final status = await _api.getXp();
      if (!ref.mounted) return;
      state = state.copyWith(status: status);
      if (state.rules == null) {
        final rules = await _api.getXpRules();
        if (!ref.mounted) return;
        state = state.copyWith(rules: rules);
      }
    } on HaroApiException {
      // No backend yet, or one that predates XP.
    }
  }

  /// An award landed: queue the toast and refresh the numbers under it.
  void onEvent(XpWsEvent e) {
    if (e.amount > 0 || e.badges.isNotEmpty) {
      state = state.copyWith(
        notice: XpNotice(
          seq: ++_seq,
          amount: e.amount,
          label: e.label,
          badges: e.badges,
        ),
      );
    }
    unawaited(load());
  }
}

final xpStoreProvider = NotifierProvider<XpStore, XpState>(XpStore.new);

/// Starts XP in the real app: loads once the backend is up and follows the global feed's
/// `xp` events. Watched by the real `shellDataProvider`, so widget tests that override that
/// provider never open a socket.
final xpWiringProvider = Provider<void>((ref) {
  final store = ref.read(xpStoreProvider.notifier);
  final sub = ref
      .read(workspaceStoreProvider.notifier)
      .xpEvents
      .listen(store.onEvent);
  ref.onDispose(sub.cancel);
  ref.listen(backendStatusProvider, (prev, next) {
    if (next.value == BackendStatus.up && prev?.value != BackendStatus.up) {
      unawaited(store.load());
    }
  }, fireImmediately: true);
});

/// The footer's data, or null when XP is off in Settings or nothing has loaded.
final xpFooterProvider = Provider<XpFooterData?>((ref) {
  final show = ref.watch(xpPrefsProvider.select((p) => p.showXp));
  final status = ref.watch(xpStoreProvider.select((s) => s.status));
  if (!show || status == null) return null;
  return XpFooterData.fromStatus(status);
});

/// Tells the backend about things only the client can see. The backend decides whether each
/// one pays, so this only avoids repeating itself: a Docs read once per local day, a diff
/// review whenever the set of shown files changes. Failures are swallowed and retried on the
/// next occasion; XP never gets in the way of the work.
class XpReporter {
  XpReporter(this._api, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final HaroApi Function() _api;
  final DateTime Function() _clock;
  final _sent = <String>{};

  String get _today {
    final d = _clock();
    return '${d.year}-${d.month}-${d.day}';
  }

  void docsRead(String workspaceId) {
    final key = 'docs|$_today';
    if (!_sent.add(key)) return;
    _post('docs_read', workspaceId: workspaceId, retryKey: key);
  }

  /// Every changed file is marked Viewed in the review step: [paths] is the list, reported
  /// once per distinct list (so again if the diff grows and is viewed again).
  void diffReviewed(String workspaceId, Iterable<String> paths) {
    final sorted = paths.toSet().toList()..sort();
    if (sorted.isEmpty) return;
    final key = 'diff|$workspaceId|${sorted.join('\n')}';
    if (!_sent.add(key)) return;
    _post(
      'diff_reviewed',
      workspaceId: workspaceId,
      paths: sorted,
      retryKey: key,
    );
  }

  void _post(
    String kind, {
    required String workspaceId,
    List<String> paths = const [],
    required String retryKey,
  }) {
    unawaited(
      _api()
          .postXpActivity(kind, workspaceId: workspaceId, paths: paths)
          .then<void>((_) {}, onError: (Object _) => _sent.remove(retryKey)),
    );
  }
}

final xpReporterProvider = Provider<XpReporter>(
  (ref) => XpReporter(() => ref.read(haroApiProvider)),
);
