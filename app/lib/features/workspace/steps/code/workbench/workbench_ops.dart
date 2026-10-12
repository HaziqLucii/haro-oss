import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../api/haro_api.dart';
import '../../../../../data/workspace_detail.dart';
import '../../../../../data/workspace_store.dart';
import '../code_providers.dart';

/// The explorer's and the Changes panel's writes: file system entries and the git index. Each one
/// ends by refreshing what it made stale (the tree, the git status, the diff) so a panel never
/// shows a state the disk has left. A failing request surfaces as a [HaroApiException].
class WorkbenchOps {
  WorkbenchOps(this._ref, this.workspaceId);

  final Ref _ref;
  final String workspaceId;

  HaroApi get _api => _ref.read(haroApiProvider);
  WorkspaceDetailNotifier get _detail =>
      _ref.read(workspaceDetailProvider(workspaceId).notifier);

  void _fsChanged() {
    _ref.invalidate(codeFileTreeProvider(workspaceId));
    _detail
      ..bumpGit()
      ..scheduleDiffRefresh();
  }

  Future<void> createEntry(String path, {required bool dir}) async {
    await _api.createEntry(workspaceId, path, dir: dir);
    _fsChanged();
  }

  Future<void> renameEntry(String path, String to) async {
    await _api.renameEntry(workspaceId, path, to);
    _fsChanged();
  }

  Future<void> deleteEntry(String path) async {
    await _api.deleteEntry(workspaceId, path);
    _fsChanged();
  }

  Future<void> stage(List<String> paths) async {
    if (paths.isEmpty) return;
    await _api.gitStage(workspaceId, paths);
    _detail.bumpGit();
  }

  Future<void> unstage(List<String> paths) async {
    if (paths.isEmpty) return;
    await _api.gitUnstage(workspaceId, paths);
    _detail.bumpGit();
  }
}

final workbenchOpsProvider = Provider.family<WorkbenchOps, String>(
  (ref, id) => WorkbenchOps(ref, id),
);
