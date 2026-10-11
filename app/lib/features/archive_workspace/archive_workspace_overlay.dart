import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_actions.dart';
import '../../data/workspace_store.dart';
import '../../overlays/overlay.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../add_project/clone_runner.dart' show homeDirProvider;
import '../new_workspace/creation_widgets.dart';
import '../remove_project/remove_project_model.dart' show tildePath;
import 'archive_workspace_model.dart';

Future<void> showArchiveWorkspace(
  BuildContext context, {
  required String workspaceId,
}) => showHaroOverlay<void>(
  context,
  width: 520,
  child: ArchiveWorkspaceOverlay(workspaceId: workspaceId),
);

Workspace? _find(WorkspaceSnapshot snapshot, String id) {
  for (final list in snapshot.workspaces.values) {
    for (final w in list) {
      if (w.id == id) return w;
    }
  }
  return null;
}

/// Confirm for `DELETE /workspaces/{id}`. The archive button waits for one git status read so
/// the warnings say what is really at stake before it can be clicked.
class ArchiveWorkspaceOverlay extends ConsumerStatefulWidget {
  const ArchiveWorkspaceOverlay({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<ArchiveWorkspaceOverlay> createState() =>
      _ArchiveWorkspaceOverlayState();
}

class _ArchiveWorkspaceOverlayState
    extends ConsumerState<ArchiveWorkspaceOverlay> {
  GitStatusResponse? _git;
  bool _gitDone = false;
  bool _busy = false;
  String? _error;

  /// Kept so the overlay still renders while the store drops the workspace after the delete.
  Workspace? _last;

  @override
  void initState() {
    super.initState();
    _loadGit();
  }

  Future<void> _loadGit() async {
    GitStatusResponse? git;
    try {
      git = await ref.read(haroApiProvider).gitStatus(widget.workspaceId);
    } catch (_) {
      git = null;
    }
    if (!mounted) return;
    setState(() {
      _git = git;
      _gitDone = true;
    });
  }

  Future<void> _archive() async {
    if (_busy) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final router = GoRouter.maybeOf(context);
    final actions = ref.read(workspaceActionsProvider(widget.workspaceId));
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await actions.archiveWorkspace();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is HaroApiException ? e.message : e.toString();
      });
      return;
    }
    if (router != null &&
        routeIsWorkspace(
          router.routerDelegate.currentConfiguration.uri,
          widget.workspaceId,
        )) {
      router.go('/');
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final ws =
        _find(ref.watch(workspaceStoreProvider), widget.workspaceId) ?? _last;
    if (ws == null) return const SizedBox.shrink();
    _last = ws;
    final home = ref.watch(homeDirProvider);
    final lines = archiveConsequences(ws, _git);
    final canArchive = _gitDone && !_busy;

    return PopScope(
      canPop: !_busy,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    'Delete ${ws.name}?',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.ui(
                      size: 20,
                      weight: FontWeight.w500,
                      height: 1.25,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OverlayCloseButton(
                  onPressed: () =>
                      Navigator.of(context, rootNavigator: true).maybePop(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Deletes the worktree at '),
                  TextSpan(
                    text: tildePath(ws.worktreePath, home),
                    style: HaroText.mono(
                      size: 12.5,
                      color: HaroTokens.ink,
                      tracking: 0,
                    ),
                  ),
                  const TextSpan(text: ' and the branch '),
                  TextSpan(
                    text: ws.branch,
                    style: HaroText.mono(
                      size: 12.5,
                      color: HaroTokens.ink,
                      tracking: 0,
                    ),
                  ),
                  const TextSpan(text: '. The repository itself is untouched.'),
                ],
              ),
              style: HaroText.ui(
                size: 14,
                color: HaroTokens.ink66,
                height: 1.45,
              ),
            ),
            if (lines.isNotEmpty) ...[
              const SizedBox(height: 14),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    line.text,
                    style: HaroText.ui(
                      size: 13.5,
                      color: line.warn ? HaroTokens.fail : HaroTokens.ink66,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              ErrorLine(_error!),
            ],
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Opacity(
                  opacity: _busy ? .4 : 1,
                  child: HaroButton(
                    label: 'Cancel',
                    onPressed: _busy ? null : () => closeHaroOverlay(context),
                  ),
                ),
                const SizedBox(width: 8),
                Opacity(
                  opacity: canArchive || _busy ? 1 : .4,
                  child: HaroButton(
                    variant: HaroButtonVariant.destructive,
                    label: _busy ? 'Deleting…' : 'Delete workspace',
                    onPressed: canArchive ? _archive : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
