import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/models/models.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_detail_lazy.dart'
    show workspaceGitStatusProvider;
import 'code_providers.dart';
import 'workbench/workbench_state.dart';

/// What one `changed` fs event asks of the editor and the file tree.
class FsEffects {
  const FsEffects({
    this.structural = false,
    this.refreshAll = false,
    this.modified = const {},
    this.deleted = const {},
    this.added = const {},
  });

  /// Files appeared or vanished (or the event was cut short): the tree and git status are stale.
  final bool structural;

  /// The event named no usable paths (truncated, or an older backend): every open buffer may have
  /// changed, and a 404 on re-read means the file is gone.
  final bool refreshAll;
  final Set<String> modified;
  final Set<String> deleted;
  final Set<String> added;
}

/// Reduces [e] to what the open tabs and the tree need. A plain `modified` event never touches
/// the tree: the listing only changes when a file is added or deleted. An `added` path in
/// [known] (the files the loaded tree already lists) is a rewrite, not a new file: an atomic
/// save (write a temp file, rename over the target) reaches the watcher as `added`, and treating
/// it as structural would refetch the tree on every save.
FsEffects planFsEffects(FsEvent e, {Set<String> known = const {}}) {
  final modified = <String>{};
  final deleted = <String>{};
  final added = <String>{};
  for (final p in e.paths) {
    switch (p.change) {
      case FsChange.modified:
        modified.add(p.path);
      case FsChange.deleted:
        added.remove(p.path);
        deleted.add(p.path);
      case FsChange.added:
        deleted.remove(p.path);
        if (known.contains(p.path)) {
          modified.add(p.path);
        } else {
          added.add(p.path);
        }
    }
  }
  return FsEffects(
    structural: e.truncated || deleted.isNotEmpty || added.isNotEmpty,
    refreshAll: e.truncated,
    modified: modified,
    deleted: deleted,
    added: added,
  );
}

/// Every directory path in [nodes].
Set<String> directoryPaths(List<FileNode> nodes) {
  final out = <String>{};
  void walk(List<FileNode> level) {
    for (final n in level) {
      if (n.dir) {
        out.add(n.path);
        walk(n.children);
      }
    }
  }

  walk(nodes);
  return out;
}

const fsTreeDebounce = Duration(milliseconds: 750);

/// Keeps the explorer tree and git status current with the worktree: a structural `fs` event
/// (a file added or deleted, or an event that lost its path list) refetches the tree once the
/// burst settles. Riverpod keeps the old rows while the refetch runs, so the tree does not flash,
/// and the expanded folders live in [workbenchProvider], not in the tree. Watch it from the code
/// step so it lives exactly as long as the step does.
final codeFsSyncProvider = Provider.autoDispose.family<void, String>((ref, id) {
  Timer? timer;
  Timer? statusTimer;
  var alive = true;
  ref.onDispose(() {
    alive = false;
    timer?.cancel();
    statusTimer?.cancel();
  });

  // A plain edit to a tracked file is not structural, so the git status behind the Changes
  // panel and its badge would otherwise keep whatever it held before the edit.
  void refreshStatus() {
    final status = workspaceGitStatusProvider(id);
    if (alive && ref.exists(status)) ref.invalidate(status);
  }

  // Edits made while another step was open never reached this provider. A status still loading
  // is already current, and invalidating it would only restart the fetch.
  Future.microtask(() {
    if (alive && !ref.read(workspaceGitStatusProvider(id)).isLoading) {
      refreshStatus();
    }
  });

  Future<void> sync() async {
    ref.read(workspaceDetailProvider(id).notifier).bumpGit();
    final tree = codeFileTreeProvider(id);
    // A tree nobody has opened pays nothing: it fetches on first watch anyway.
    if (!ref.exists(tree)) return;
    ref.invalidate(tree);
    try {
      final nodes = await ref.read(tree.future);
      if (alive) {
        ref
            .read(workbenchProvider(id).notifier)
            .pruneExpanded(directoryPaths(nodes));
      }
    } on Object {
      return;
    }
  }

  Set<String> knownFiles(FsEvent e) {
    if (!e.paths.any((p) => p.change == FsChange.added)) return const {};
    final tree = codeFileTreeProvider(id);
    if (!ref.exists(tree)) return const {};
    return flattenFilePaths(ref.read(tree).value ?? const []).toSet();
  }

  ref.listen(workspaceDetailProvider(id).select((d) => d.lastFs), (_, e) {
    if (e == null) return;
    if (!planFsEffects(e, known: knownFiles(e)).structural) {
      statusTimer?.cancel();
      statusTimer = Timer(fsTreeDebounce, refreshStatus);
      return;
    }
    // sync() bumps the git revision, which refetches the status itself.
    statusTimer?.cancel();
    timer?.cancel();
    timer = Timer(fsTreeDebounce, () => unawaited(sync()));
  });
});
