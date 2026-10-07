import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/haro_api.dart';
import '../../data/workspace_actions.dart';
import '../../overlays/overlay.dart';
import '../../theme/haro_theme.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_text_field.dart';
import '../new_workspace/creation_widgets.dart';

Future<void> showRenameWorkspace(
  BuildContext context, {
  required String workspaceId,
  required String name,
}) => showHaroOverlay<void>(
  context,
  width: 440,
  child: RenameWorkspaceOverlay(workspaceId: workspaceId, name: name),
);

/// Display name only (`PATCH /workspaces/{id}`); the branch keeps its own rename in the header.
class RenameWorkspaceOverlay extends ConsumerStatefulWidget {
  const RenameWorkspaceOverlay({
    super.key,
    required this.workspaceId,
    required this.name,
  });

  final String workspaceId;
  final String name;

  @override
  ConsumerState<RenameWorkspaceOverlay> createState() =>
      _RenameWorkspaceOverlayState();
}

class _RenameWorkspaceOverlayState
    extends ConsumerState<RenameWorkspaceOverlay> {
  late final _controller = TextEditingController(
    text: widget.name,
  )..selection = TextSelection(baseOffset: 0, extentOffset: widget.name.length);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final next = _controller.text.trim();
    if (next.isEmpty || next == widget.name) {
      closeHaroOverlay(context);
      return;
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(workspaceActionsProvider(widget.workspaceId))
          .renameWorkspace(name: next);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is HaroApiException ? e.message : e.toString();
      });
      return;
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Rename workspace',
                  style: HaroText.ui(size: 20, weight: FontWeight.w500),
                ),
              ),
              OverlayCloseButton(
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).maybePop(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          HaroTextField(
            key: const ValueKey('rename-workspace-field'),
            controller: _controller,
            autofocus: true,
            enabled: !_saving,
            onSubmitted: (_) => _save(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            ErrorLine(_error!),
          ],
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              HaroButton(
                label: 'Cancel',
                onPressed: _saving ? null : () => closeHaroOverlay(context),
              ),
              const SizedBox(width: 8),
              HaroButton(
                variant: HaroButtonVariant.primary,
                label: _saving ? 'Saving…' : 'Rename',
                onPressed: _saving ? null : _save,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
