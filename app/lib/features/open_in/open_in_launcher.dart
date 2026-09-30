import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../widgets/haro_menu.dart';
import '../workspace/terminal/terminal_sessions.dart';
import '../workspace/workspace_ui.dart';
import 'editors_provider.dart';
import 'open_in_errors.dart';
import 'open_in_notice.dart';

/// Bottom-left of the widget behind [context], where a dropdown menu hangs.
Offset menuAnchor(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached) return const Offset(120, 120);
  return box.localToGlobal(Offset(0, box.size.height + 4));
}

/// Everything behind an "Open in..." control: pick the editor (the default, or a menu),
/// ask the backend, and for a terminal editor type the returned command into the Shell tab.
/// Failures land in [openInNoticeProvider] under the caller's `source`.
class OpenInLauncher {
  OpenInLauncher(this._ref);

  final Ref _ref;

  Future<void> launch(
    BuildContext context, {
    required String workspaceId,
    required String source,
    String? path,
    int? line,
    Offset? position,
    bool forceMenu = false,
  }) async {
    final editors = await _editors(source);
    if (editors == null) return;
    final available = availableEditors(editors);
    if (available.isEmpty) {
      _fail(source, 'No editors found on this machine');
      return;
    }
    final fallback = _ref.read(defaultEditorProvider);
    if (fallback != null && !forceMenu) {
      await open(
        workspaceId: workspaceId,
        editor: fallback,
        source: source,
        path: path,
        line: line,
      );
      return;
    }
    if (!context.mounted) return;
    await showHaroMenu(
      context,
      position: position ?? menuAnchor(context),
      items: openInMenuItems(
        available,
        (editor) => open(
          workspaceId: workspaceId,
          editor: editor,
          source: source,
          path: path,
          line: line,
        ),
      ),
    );
  }

  /// A small menu for a right-click or the header `···`: the default editor first (when
  /// there is one), then `[verb] in…` for the full list. [verb] is `Open` or `Open worktree`.
  Future<void> showActions(
    BuildContext context, {
    required Offset position,
    required String workspaceId,
    required String source,
    required String verb,
    String? path,
    int? line,
  }) async {
    final editors = await _editors(source);
    if (editors == null || !context.mounted) return;
    final fallback = _ref.read(defaultEditorProvider);
    await showHaroMenu(
      context,
      position: position,
      items: [
        if (fallback != null)
          HaroMenuItem(
            label: '$verb in ${fallback.label}',
            onSelected: () => open(
              workspaceId: workspaceId,
              editor: fallback,
              source: source,
              path: path,
              line: line,
            ),
          ),
        HaroMenuItem(
          label: '$verb in…',
          onSelected: () {
            if (!context.mounted) return;
            launch(
              context,
              workspaceId: workspaceId,
              source: source,
              path: path,
              line: line,
              position: position,
              forceMenu: true,
            );
          },
        ),
      ],
    );
  }

  Future<void> open({
    required String workspaceId,
    required EditorInfo editor,
    required String source,
    String? path,
    int? line,
  }) async {
    final notice = _ref.read(openInNoticeProvider.notifier);
    notice.clear();
    try {
      final res = await _ref
          .read(haroApiProvider)
          .openIn(workspaceId, editor.id, path: path, line: line);
      if (res.mode == OpenInMode.shell) {
        final error = _typeIntoShell(workspaceId, res.command);
        if (error != null) return _fail(source, error);
      }
      _ref.read(lastEditorProvider.notifier).set(editor.id);
    } catch (e) {
      _fail(source, openInError(e));
    }
  }

  String? _typeIntoShell(String workspaceId, String? command) {
    if (command == null || command.isEmpty) {
      return 'The backend sent no command for this editor';
    }
    final session = _ref.read(shellSessionsProvider)[workspaceId];
    if (session == null) return 'Open the workspace to use a terminal editor';
    _ref.read(workspaceUiProvider.notifier).showShell();
    session.sendCommand(command);
    return null;
  }

  Future<List<EditorInfo>?> _editors(String source) async {
    if (_ref.read(editorsProvider).hasError) _ref.invalidate(editorsProvider);
    try {
      return await _ref.read(editorsProvider.future);
    } catch (e) {
      _fail(source, editorsLoadError(e));
      return null;
    }
  }

  void _fail(String source, String message) =>
      _ref.read(openInNoticeProvider.notifier).show(source, message);
}

final openInLauncherProvider = Provider<OpenInLauncher>(OpenInLauncher.new);

/// GUI editors, terminal editors, file manager, each under a caption.
List<HaroMenuItem> openInMenuItems(
  List<EditorInfo> available,
  void Function(EditorInfo editor) onPick,
) {
  const groups = [
    (EditorKind.gui, 'GUI'),
    (EditorKind.terminal, 'Terminal'),
    (EditorKind.fileManager, 'File manager'),
  ];
  return [
    for (final (kind, title) in groups)
      if (available.any((e) => e.kind == kind)) ...[
        HaroMenuItem.heading(title),
        for (final e in available)
          if (e.kind == kind)
            HaroMenuItem(label: e.label, onSelected: () => onPick(e)),
      ],
  ];
}
