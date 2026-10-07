import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/haro_api.dart';
import '../api/models/models.dart';
import '../theme/tokens.dart';
import 'workspace_detail.dart';
import 'workspace_store.dart';

// What the verify and ship steps need but the rail and step bar do not. Each is created on
// first watch, so a workspace nobody opened on those steps never pays for the calls. All of
// them refetch off a revision counter on `WorkspaceDetail` (the same moments the React
// client's socket handler refreshes them) and keep the previous value while reloading.

int _gate(Ref ref, String id) =>
    ref.watch(workspaceDetailProvider(id).select((d) => d.gateRevision));

int _git(Ref ref, String id) =>
    ref.watch(workspaceDetailProvider(id).select((d) => d.gitRevision));

/// Per-line proof for the code and ship diffs. Reads the map the last green gate cached and
/// never runs a suite. `null` when it cannot load: an annotation that fails must leave a
/// plain, working diff.
final workspaceVerifiedHunksProvider = FutureProvider.autoDispose
    .family<VerifiedHunksResponse?, String>((ref, id) async {
      _gate(ref, id);
      final api = ref.read(haroApiProvider);
      try {
        return await api.getVerifiedHunks(id);
      } on HaroApiException {
        return null;
      }
    });

/// The gate receipt card. `null` when it cannot load.
final workspaceReceiptProvider = FutureProvider.autoDispose
    .family<ReceiptResponse?, String>((ref, id) async {
      _gate(ref, id);
      final api = ref.read(haroApiProvider);
      try {
        return await api.getReceipt(id);
      } on HaroApiException {
        return null;
      }
    });

/// Why the workspace's default run script cannot start, read statically off `package.json`
/// (`RunScriptInfo.problem`). `null` when nothing is missing or the read fails: the Run
/// button is only ever disabled on a positive finding.
final workspaceRunProblemProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, id) async {
      _git(ref, id);
      try {
        final scripts = await ref.read(haroApiProvider).getScripts(id);
        final run = scripts.runs.where((r) => r.isDefault).firstOrNull;
        return run?.problem;
      } catch (_) {
        return null;
      }
    });

final workspaceHistoryProvider = FutureProvider.autoDispose
    .family<List<TestRun>, String>((ref, id) {
      _gate(ref, id);
      return ref.read(haroApiProvider).getHistory(id);
    });

final workspaceImpactProvider = FutureProvider.autoDispose
    .family<ImpactResponse, String>((ref, id) {
      _gate(ref, id);
      return ref.read(haroApiProvider).getImpact(id);
    });

/// Failure to blame; only meaningful on a red gate, so it is `null` (and never fetched)
/// in any other status.
final workspaceBlameProvider = FutureProvider.autoDispose
    .family<BlameResponse?, String>((ref, id) async {
      _gate(ref, id);
      final red = ref.watch(
        workspaceDetailProvider(id)
            .select((d) => d.workspace?.status == WorkspaceStatus.gateRed),
      );
      if (!red) return null;
      try {
        return await ref.read(haroApiProvider).getBlame(id);
      } on HaroApiException {
        return null;
      }
    });

/// The autonomy-ladder checklist on the ship step.
final workspaceTrustProvider = FutureProvider.autoDispose
    .family<TrustReport, String>((ref, id) {
      _gate(ref, id);
      return ref.read(haroApiProvider).getTrust(id);
    });

final workspaceGitStatusProvider = FutureProvider.autoDispose
    .family<GitStatusResponse, String>((ref, id) {
      _git(ref, id);
      return ref.read(haroApiProvider).gitStatus(id);
    });

final workspaceGitLogProvider = FutureProvider.autoDispose
    .family<List<GitCommit>, String>((ref, id) {
      _git(ref, id);
      return ref.read(haroApiProvider).gitLog(id);
    });

/// How often an open PR is re-read. A provider so tests can shrink it.
final prPollIntervalProvider = Provider<Duration>(
  (ref) => HaroTokens.prPollInterval,
);

/// Whether the app window is in the foreground. A poll tick is skipped while it is not, so a
/// backgrounded haro does not keep calling `gh`. Unknown (no binding state yet) counts as
/// foreground.
final appInForegroundProvider = Provider<bool Function()>(
  (ref) => () {
    final s = WidgetsBinding.instance.lifecycleState;
    return s != AppLifecycleState.paused &&
        s != AppLifecycleState.hidden &&
        s != AppLifecycleState.inactive;
  },
);

bool _prStillOpen(PrStatusResponse pr) {
  final state = (pr.state ?? '').toUpperCase();
  return pr.exists &&
      !pr.workspaceMerged &&
      state != 'MERGED' &&
      state != 'CLOSED';
}

/// PR and CI state. The endpoint reconciles the merged verdict against GitHub, so read
/// `workspaceMerged` from it rather than `state`. While the PR is open it re-reads itself on
/// a timer, because merging on github.com changes nothing locally that could trigger a
/// refetch; a failed load or a settled PR schedules nothing.
final workspacePrProvider = FutureProvider.autoDispose
    .family<PrStatusResponse, String>((ref, id) async {
      _git(ref, id);
      final pr = await ref.read(haroApiProvider).gitPr(id);
      if (ref.mounted && _prStillOpen(pr)) _schedulePrPoll(ref);
      return pr;
    });

void _schedulePrPoll(Ref ref) {
  final interval = ref.read(prPollIntervalProvider);
  final foreground = ref.read(appInForegroundProvider);
  Timer? timer;
  void arm() {
    timer = Timer(interval, () {
      if (!ref.mounted) return;
      if (foreground()) {
        ref.invalidateSelf();
      } else {
        arm();
      }
    });
  }

  arm();
  ref.onDispose(() => timer?.cancel());
}
