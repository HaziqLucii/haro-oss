import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/haro_api.dart' show HaroApiException;
import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import 'first_run_model.dart';

/// Read-only GETs only. Each source resolves on its own so rows can appear as they land;
/// autoDispose so coming back to the page re-detects instead of showing a stale answer.

/// Straight from `/projects` rather than the store: the store may not have seen a project
/// that was added a moment ago. `null` means the id is not registered.
final firstRunProjectProvider = FutureProvider.autoDispose
    .family<Project?, String>((ref, id) async {
      final projects = await ref.watch(haroApiProvider).listProjects();
      return projects.where((p) => p.id == id).firstOrNull;
    });

final firstRunScriptsProvider = FutureProvider.autoDispose
    .family<ScriptsConfig?, String>((ref, id) async {
      try {
        return await ref.watch(haroApiProvider).getProjectScripts(id);
      } catch (_) {
        return null;
      }
    });

final firstRunRunnerProvider = FutureProvider.autoDispose
    .family<RunnerInputs, String>((ref, id) async {
      final api = ref.watch(haroApiProvider);
      final gate = api.getGate(id);
      final stack = api
          .detectStack(id)
          .then<StackDetection?>((s) => s)
          .catchError((Object _) => null);
      final scripts = ref.watch(firstRunScriptsProvider(id).future);
      return RunnerInputs(
        gate: await gate,
        stack: await stack,
        scripts: await scripts,
      );
    });

final firstRunEnvCountProvider = FutureProvider.autoDispose.family<int, String>(
  (ref, id) async =>
      envVariableCount((await ref.watch(haroApiProvider).getEnv(id)).content),
);

/// The baseline as the backend last recorded it (`GET /projects/{id}/baseline`): `null`
/// when it has never run, or the backend predates the endpoint. Live progress and a run
/// started from this page arrive through [firstRunBaselineLiveProvider], which wins.
final firstRunBaselineProvider = FutureProvider.autoDispose
    .family<BaselineResult?, String>((ref, id) async {
      try {
        final state = await ref.watch(haroApiProvider).getBaseline(id);
        if (state.running) return const BaselineResult.running();
        final run = state.result;
        return run == null ? null : BaselineResult.fromRun(run);
      } on HaroApiException {
        return null;
      }
    });

/// The baseline run in flight or just finished, from the global feed's `baseline` channel.
/// `null` until this page has seen an event or started a run.
class BaselineLive extends Notifier<BaselineResult?> {
  BaselineLive(this.projectId);

  final String projectId;

  @override
  BaselineResult? build() {
    final sub = ref
        .read(workspaceStoreProvider.notifier)
        .baselineEvents
        .listen(apply);
    ref.onDispose(sub.cancel);
    // The backend's own answer outranks a "running" we inferred from the feed: a missed
    // done event must not leave the row spinning once a fresh read says nothing runs.
    ref.listen(firstRunBaselineProvider(projectId), (_, next) {
      final fetched = next.value;
      if (next.hasValue &&
          !(fetched?.running ?? false) &&
          state?.running == true) {
        state = null;
      }
    });
    return null;
  }

  void _resync() {
    state = null;
    ref.invalidate(firstRunBaselineProvider(projectId));
  }

  void apply(BaselineWsEvent e) {
    if (e.kind == 'resync') return _resync();
    if (e.projectId != projectId) return;
    switch (e.kind) {
      case 'started':
        state = const BaselineResult.running();
      case 'cell':
        state = BaselineResult.running(
          passed: e.passed,
          failed: e.failed,
          skipped: e.skipped,
        );
      case 'done' || 'error':
        final run = e.result;
        if (run != null) {
          state = BaselineResult.fromRun(run);
        } else {
          // "baseline stopped": the run was cancelled and nothing was recorded.
          _resync();
        }
    }
  }

  void markRunning() => state = const BaselineResult.running();
}

final firstRunBaselineLiveProvider = NotifierProvider.autoDispose
    .family<BaselineLive, BaselineResult?, String>(BaselineLive.new);
