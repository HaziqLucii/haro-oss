import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart';
import '../../../../data/workspace_actions.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_store.dart' show haroApiProvider;

/// The "Run on save" gate setting (`[gate] run_on_save`, Settings, Gate) as the code step
/// sees it. Stored per project on the backend like every other `[gate]` key. In agent mode
/// the trigger is client side (this file); in manual mode the backend watcher fires it, so
/// a save from any editor gates.

/// Whether saving should start a gate run, as last loaded with the workspace. Watches, so
/// a build can label the step bar action "Save & run gate". Toggling the setting in
/// Settings shows here after the workspace reloads; [RunOnSave.run] rechecks the live
/// value, so a save never acts on a stale one.
final runOnSaveEnabledProvider = Provider.autoDispose.family<bool, String>(
  (ref, workspaceId) => ref.watch(
    workspaceDetailProvider(workspaceId)
        .select((d) => d.gateConfig?.runOnSave ?? false),
  ),
);

bool runOnSaveEnabled(WidgetRef ref, String workspaceId) =>
    ref.watch(runOnSaveEnabledProvider(workspaceId));

/// For code that has a [Ref] rather than a [WidgetRef] (a notifier): `ref.read(...)`.
final runOnSaveProvider = Provider.family<RunOnSave, String>(
  (ref, workspaceId) => RunOnSave(ref, workspaceId),
);

/// Starts a gate run after a save. Call from ⌘S once the file is written:
/// ```dart
/// await ref.read(runOnSaveProvider(id)).run();   // or runGateAfterSave(ref, id)
/// ```
class RunOnSave {
  RunOnSave(this._ref, this.workspaceId);

  final Ref _ref;
  final String workspaceId;

  /// Runs the gate when Run on save is on, in the scope the project's gate settings default
  /// to (impacted or all; the full-scope gate stays the merge verdict, and a ship still
  /// needs it). Returns null when it did nothing or the run started and finished; an error
  /// message when the request failed, for the caller to show.
  ///
  /// Skips (returns null, no request) while an agent run or a gate run is already going:
  /// a second run would only queue behind or fight the first. The future resolves when the
  /// run finishes, so do not await it on the save path; use `unawaited`.
  Future<String?> run() async {
    final detail = _ref.read(workspaceDetailProvider(workspaceId));
    final ws = detail.workspace;
    if (ws == null) return null;
    // Manual workspaces gate from the backend watcher once the worktree goes quiet, so a
    // save from this editor and a save from Zed behave the same and never gate twice.
    if (ws.manual) return null;
    switch (ws.status) {
      case WorkspaceStatus.agentRunning ||
          WorkspaceStatus.testsRunning ||
          WorkspaceStatus.settingUp ||
          WorkspaceStatus.merged ||
          WorkspaceStatus.archived ||
          WorkspaceStatus.broken:
        return null;
      default:
    }

    var config = detail.gateConfig;
    try {
      config = await _ref.read(haroApiProvider).getGate(ws.projectId);
    } on HaroApiException {
      // Keep the value the workspace loaded with.
    }
    if (config == null || !config.runOnSave) return null;

    try {
      await _ref
          .read(workspaceActionsProvider(workspaceId))
          .runGate(impacted: config.defaultScope == 'impacted');
      return null;
    } on HaroApiException catch (e) {
      return e.message;
    }
  }
}

/// [RunOnSave.run] for a widget.
Future<String?> runGateAfterSave(WidgetRef ref, String workspaceId) =>
    ref.read(runOnSaveProvider(workspaceId)).run();
