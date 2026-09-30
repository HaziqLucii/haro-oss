import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/workspace_actions.dart';
import '../../../data/workspace_detail_lazy.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_button.dart';
import '../../../widgets/haro_text_field.dart';
import '../../open_in/open_in_launcher.dart';
import '../../open_in/open_in_notice.dart';

String _shortBase(String baseRef) {
  final ref = baseRef.isEmpty ? 'origin/main' : baseRef;
  return ref.startsWith('origin/') ? ref.substring(7) : ref;
}

/// `project · branch → main · N behind` (spec 5).
String workspaceSubline({
  required String? project,
  required String branch,
  required String baseRef,
  int? behind,
}) => [
  if (project != null && project.isNotEmpty) project,
  '$branch → ${_shortBase(baseRef)}',
  if (behind != null && behind > 0) '$behind behind',
].join(' · ');

/// Name, sub-line and the Rename / Archive controls. Rename edits the name in place; Archive
/// asks twice on the same button (a workspace's worktree goes with it).
class WorkspaceHeader extends ConsumerStatefulWidget {
  const WorkspaceHeader({
    super.key,
    required this.workspaceId,
    required this.name,
    required this.branch,
    required this.baseRef,
    this.project,
    required this.onError,
  });

  final String workspaceId;
  final String name;
  final String branch;
  final String baseRef;
  final String? project;
  final ValueChanged<Object> onError;

  @override
  ConsumerState<WorkspaceHeader> createState() => _WorkspaceHeaderState();
}

class _WorkspaceHeaderState extends ConsumerState<WorkspaceHeader> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;
  bool _saving = false;
  bool _confirmArchive = false;
  bool _archiving = false;
  Timer? _confirmTimer;

  WorkspaceActions get _actions =>
      ref.read(workspaceActionsProvider(widget.workspaceId));

  @override
  void dispose() {
    _confirmTimer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startRename() {
    _controller.text = widget.name;
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.name.length,
    );
    setState(() {
      _editing = true;
      _confirmArchive = false;
    });
  }

  void _cancelRename() => setState(() => _editing = false);

  Future<void> _saveRename() async {
    final next = _controller.text.trim();
    if (_saving) return;
    if (next.isEmpty || next == widget.name) {
      _cancelRename();
      return;
    }
    setState(() => _saving = true);
    try {
      await _actions.renameWorkspace(name: next);
      if (mounted) setState(() => _editing = false);
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _archive() async {
    if (_archiving) return;
    if (!_confirmArchive) {
      setState(() => _confirmArchive = true);
      _confirmTimer?.cancel();
      _confirmTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _confirmArchive = false);
      });
      return;
    }
    _confirmTimer?.cancel();
    setState(() => _archiving = true);
    try {
      await _actions.archiveWorkspace();
      if (mounted) context.go('/');
    } catch (e) {
      widget.onError(e);
      if (mounted) {
        setState(() {
          _archiving = false;
          _confirmArchive = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final behind = ref.watch(
      workspaceGitStatusProvider(widget.workspaceId)
          .select((s) => s.value?.behind),
    );
    final sub = workspaceSubline(
      project: widget.project,
      branch: widget.branch,
      baseRef: widget.baseRef,
      behind: behind,
    );

    final title = _editing
        ? CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _cancelRename,
            },
            child: HaroTextField(
              key: const ValueKey('rename-field'),
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              enabled: !_saving,
              height: 34,
              fontSize: 18,
              onSubmitted: (_) => _saveRename(),
            ),
          )
        : Text(
            widget.name,
            key: const ValueKey('workspace-name'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HaroText.ui(
              size: 22,
              weight: FontWeight.w500,
            ).copyWith(letterSpacing: -.22),
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                title,
                const SizedBox(height: 5),
                Text(
                  sub,
                  key: const ValueKey('workspace-subline'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.mono(
                    size: 11,
                    color: HaroTokens.ink42,
                    tracking: 0,
                  ),
                ),
                const OpenInNoticeText(
                  source: 'header',
                  padding: EdgeInsets.only(top: 4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          if (_editing) ...[
            HaroButton(
              key: const ValueKey('rename-save'),
              label: 'Save',
              height: 28,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: _saving ? null : _saveRename,
            ),
            const SizedBox(width: 6),
            HaroButton(
              key: const ValueKey('rename-cancel'),
              label: 'Cancel',
              height: 28,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: _saving ? null : _cancelRename,
            ),
          ] else ...[
            Builder(
              builder: (context) => HaroButton(
                key: const ValueKey('open-worktree'),
                label: '···',
                variant: HaroButtonVariant.tertiary,
                height: 28,
                fontSize: 14,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tooltip: 'Open worktree in…',
                onPressed: () => ref
                    .read(openInLauncherProvider)
                    .showActions(
                      context,
                      position: menuAnchor(context),
                      workspaceId: widget.workspaceId,
                      source: 'header',
                      verb: 'Open worktree',
                    ),
              ),
            ),
            const SizedBox(width: 6),
            HaroButton(
              key: const ValueKey('rename'),
              label: 'Rename',
              height: 28,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: _startRename,
            ),
            const SizedBox(width: 6),
            HaroButton(
              key: const ValueKey('archive'),
              label: _confirmArchive ? 'Archive? Confirm' : 'Archive',
              height: 28,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              foreground: _confirmArchive ? HaroTokens.fail : null,
              onPressed: _archiving ? null : _archive,
            ),
          ],
        ],
      ),
    );
  }
}
