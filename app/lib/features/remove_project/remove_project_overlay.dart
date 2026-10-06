import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/haro_api.dart';
import '../../data/workspace_store.dart';
import '../../overlays/overlay.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_text_field.dart';
import '../../widgets/status_square.dart';
import '../add_project/clone_runner.dart' show homeDirProvider;
import '../new_workspace/creation_widgets.dart';
import 'remove_project_model.dart';

Future<void> showRemoveProject(
  BuildContext context, {
  required String projectId,
}) => showHaroOverlay<void>(
  context,
  width: 520,
  child: RemoveProjectOverlay(projectId: projectId),
);

/// Confirm for `DELETE /projects/{id}`. The backend tears down every workspace of the project
/// (worktrees included) and untracks it; the repository on disk is untouched.
class RemoveProjectOverlay extends ConsumerStatefulWidget {
  const RemoveProjectOverlay({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<RemoveProjectOverlay> createState() =>
      _RemoveProjectOverlayState();
}

class _RemoveProjectOverlayState extends ConsumerState<RemoveProjectOverlay> {
  final _typed = TextEditingController();
  bool _busy = false;
  String? _error;

  /// Kept so the overlay still renders while the store drops the project after the delete.
  RemovalPlan? _last;

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _remove(RemovalPlan plan) async {
    if (_busy || (plan.requiresName && !plan.confirms(_typed.text))) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final store = ref.read(workspaceStoreProvider.notifier);
    final api = ref.read(haroApiProvider);
    final router = GoRouter.maybeOf(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.removeProject(plan.projectId);
    } catch (e) {
      // The teardown is per workspace, so a failure can leave some already gone.
      await store.reload();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is HaroApiException ? e.message : e.toString();
      });
      return;
    }
    await store.reload();
    if (router != null &&
        routeBelongsTo(router.routerDelegate.currentConfiguration.uri, plan)) {
      router.go('/');
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final plan =
        buildRemovalPlan(ref.watch(workspaceStoreProvider), widget.projectId) ??
        _last;
    if (plan == null) return const SizedBox.shrink();
    _last = plan;
    final home = ref.watch(homeDirProvider);
    final needsName = plan.requiresName;
    final canRemove = !_busy && (!needsName || plan.confirms(_typed.text));
    final maxList = (MediaQuery.sizeOf(context).height * .3).clamp(96.0, 280.0);

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
                    'Remove ${plan.name} from haro?',
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
                  const TextSpan(text: 'The repository at '),
                  TextSpan(
                    text: tildePath(plan.path, home),
                    style: HaroText.mono(
                      size: 12.5,
                      color: HaroTokens.ink,
                      tracking: 0,
                    ),
                  ),
                  const TextSpan(
                    text: ' stays on disk and can be added again.',
                  ),
                ],
              ),
              style: HaroText.ui(
                size: 14,
                color: HaroTokens.ink66,
                height: 1.45,
              ),
            ),
            if (plan.rows.isNotEmpty) ...[
              const SizedBox(height: 20),
              MonoCaption(
                plan.rows.length == 1
                    ? '1 workspace will be torn down'
                    : '${plan.rows.length} workspaces will be torn down',
              ),
              const SizedBox(height: 8),
              Flexible(
                child: Container(
                  decoration: const BoxDecoration(
                    border: Border.symmetric(
                      horizontal: BorderSide(color: HaroTokens.line12),
                    ),
                  ),
                  constraints: BoxConstraints(maxHeight: maxList),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [for (final r in plan.rows) _Row(row: r)],
                  ),
                ),
              ),
            ],
            if (needsName) ...[
              const SizedBox(height: 18),
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Type '),
                    TextSpan(
                      text: plan.name,
                      style: HaroText.mono(
                        size: 12.5,
                        color: HaroTokens.ink,
                        tracking: 0,
                      ),
                    ),
                    const TextSpan(text: ' to confirm.'),
                  ],
                ),
                style: HaroText.ui(size: 13, color: HaroTokens.ink66),
              ),
              const SizedBox(height: 8),
              HaroTextField(
                controller: _typed,
                mono: true,
                autofocus: true,
                enabled: !_busy,
                hintText: plan.name,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (canRemove) _remove(plan);
                },
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
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
                  opacity: canRemove || _busy ? 1 : .4,
                  child: HaroButton(
                    variant: HaroButtonVariant.destructive,
                    label: _busy ? 'Removing…' : 'Remove project',
                    onPressed: canRemove ? () => _remove(plan) : null,
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

class _Row extends StatelessWidget {
  const _Row({required this.row});

  final RemovalRow row;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line08)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            StatusSquare.forState(row.state),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                row.name,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(size: 13.5),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              row.state.word,
              maxLines: 1,
              softWrap: false,
              style: HaroText.mono(
                size: 10,
                color: row.state.color,
                tracking: 0,
              ),
            ),
          ],
        ),
        if (row.unmerged)
          Padding(
            padding: const EdgeInsets.only(left: 17, top: 3),
            child: Text(
              "has work that isn't merged: its worktree is deleted",
              style: HaroText.ui(
                size: 12,
                color: HaroTokens.fail,
                height: 1.35,
              ),
            ),
          ),
      ],
    ),
  );
}
