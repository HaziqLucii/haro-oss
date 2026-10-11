import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../api/models/models.dart';
import '../../../../../data/workspace_detail.dart';
import '../../../../../shortcuts/platform_keys.dart';
import '../../../../../widgets/haro_menu.dart';
import '../../../../open_in/editors_provider.dart';
import '../../../../open_in/open_in_launcher.dart';
import '../code_buffers.dart';
import '../diff_model.dart' show dirnameOf;
import '../editor/editor_tabs.dart';
import 'workbench_dialogs.dart';
import 'workbench_ops.dart';

/// `⌥⌘C` on macOS, `Ctrl+Alt+C` elsewhere; same for the other menu hints.
String _hint(String mac, String other) =>
    primaryModifier == PrimaryModifier.meta ? mac : other;

String get hintOpen => _hint('↵', 'Enter');
String get hintOpenToSide => _hint('⌘↵', 'Ctrl+Enter');
String get hintRename => 'F2';
String get hintCopyPath => _hint('⌥⌘C', 'Ctrl+Alt+C');
String get hintCopyRelative => _hint('⇧⌥⌘C', 'Ctrl+Shift+Alt+C');
String get hintDelete => _hint('⌫', 'Del');

/// What the explorer does to a file or folder. One object serves the context menu, the
/// keyboard and the header buttons so they cannot drift apart. Every file open goes through
/// the editor tab model.
class ExplorerActions {
  ExplorerActions(this.ref, this.context, this.workspaceId);

  final WidgetRef ref;
  final BuildContext context;
  final String workspaceId;

  EditorTabsNotifier get _tabs =>
      ref.read(editorTabsProvider(workspaceId).notifier);
  WorkbenchOps get _ops => ref.read(workbenchOpsProvider(workspaceId));

  /// A pinned open: Enter, the menu and a double-click all mean "I want this one".
  void open(String path, {int? line}) =>
      _tabs.open(path, line: line, preview: false);

  void openToSide(String path) =>
      _tabs.open(path, preview: false, toSide: true);

  /// Opens the file on its diff whatever the editor's Diff | Edit choice is; only this tab.
  void showDiff(String path) =>
      _tabs.open(path, preview: false, mode: CodeMode.diff);

  Future<void> copyPath(String path) async {
    final root = ref
        .read(workspaceDetailProvider(workspaceId))
        .workspace
        ?.worktreePath;
    final abs = root == null || root.isEmpty ? path : '$root/$path';
    await Clipboard.setData(ClipboardData(text: abs));
  }

  Future<void> copyRelativePath(String path) =>
      Clipboard.setData(ClipboardData(text: path));

  CodeBufferStore get _store => ref.read(codeBuffersProvider(workspaceId));

  Future<void> rename(String path) async {
    var moved = path;
    final ok = await promptDialog(
      context,
      title: 'Rename',
      confirmLabel: 'Rename',
      initial: path,
      caption: 'A new path moves the file.',
      submit: (to) async {
        if (to == path) return null;
        try {
          await _ops.renameEntry(path, to);
          moved = to;
          return null;
        } catch (e) {
          return errorText(e);
        }
      },
    );
    if (!ok || moved == path) return;
    // Tabs first: the store's notification mirrors dirty marks onto tabs by path, so the
    // tabs must already carry the new one.
    _tabs.movePath(path, moved);
    _store.moveUnder(path, moved);
  }

  Future<void> delete(String path, {required bool isDir}) async {
    final name = path.split('/').last;
    final unsaved = _store.dirtyUnder(path).length;
    final base = isDir
        ? 'The folder and everything in it is removed from this worktree.'
        : 'The file is removed from this worktree.';
    final ok = await confirmDialog(
      context,
      title: 'Delete $name?',
      body: unsaved == 0
          ? base
          : '$base $unsaved unsaved ${unsaved == 1 ? 'file' : 'files'} will be discarded.',
      confirmLabel: 'Delete',
      destructive: true,
      submit: () async {
        try {
          await _ops.deleteEntry(path);
          return null;
        } catch (e) {
          return errorText(e);
        }
      },
    );
    if (!ok) return;
    _tabs.closeUnder(path);
    _store.dropUnder(path);
  }

  Future<void> newEntry(String dirPath, {required bool dir}) async {
    String? made;
    await promptDialog(
      context,
      title: dir ? 'New folder' : 'New file',
      confirmLabel: 'Create',
      initial: dirPath.isEmpty ? '' : '$dirPath/',
      hint: dir ? 'path/to/folder' : 'path/to/file.ts',
      submit: (path) async {
        try {
          await _ops.createEntry(path, dir: dir);
          made = path;
          return null;
        } catch (e) {
          return errorText(e);
        }
      },
    );
    final path = made;
    if (path != null && !dir) open(path);
  }

  /// The folder a "New file" from the header lands in: the cursor's folder, or the root.
  String folderFor(String? cursor, {required bool cursorIsDir}) {
    if (cursor == null || cursor.startsWith('#')) return '';
    return cursorIsDir ? cursor : dirnameOf(cursor);
  }

  EditorInfo? get _preferred => ref.read(defaultEditorProvider);

  /// Opens [path] in the preferred editor straight away; with none set, asks which.
  Future<void> openInPreferred(String path, {int? line, Offset? at}) => ref
      .read(openInLauncherProvider)
      .launch(
        context,
        workspaceId: workspaceId,
        source: 'code',
        path: path,
        line: line,
        position: at,
      );

  /// The full list of detected editors, even when one is preferred.
  Future<void> openInChoose(String path, {int? line, Offset? at}) => ref
      .read(openInLauncherProvider)
      .launch(
        context,
        workspaceId: workspaceId,
        source: 'code',
        path: path,
        line: line,
        position: at,
        forceMenu: true,
      );

  /// The file manager entry of the detected editors, for "Reveal in file manager".
  Future<void> revealInFileManager(String dir) async {
    final launcher = ref.read(openInLauncherProvider);
    List<EditorInfo> editors;
    try {
      editors = await ref.read(editorsProvider.future);
    } catch (_) {
      return;
    }
    final fm = editors
        .where((e) => e.kind == EditorKind.fileManager && e.available)
        .firstOrNull;
    if (fm == null) return;
    await launcher.open(
      workspaceId: workspaceId,
      editor: fm,
      source: 'code',
      path: dir,
    );
  }

  /// The right-click menu: files and folders each get their own list.
  Future<void> showMenu(
    Offset at, {
    required String path,
    required bool isDir,
    required bool changed,
    int? line,
  }) => showHaroMenu(
    context,
    position: at,
    width: 250,
    items: isDir
        ? [
            HaroMenuItem(
              label: 'New file here',
              onSelected: () => newEntry(path, dir: false),
            ),
            HaroMenuItem(
              label: 'New folder',
              onSelected: () => newEntry(path, dir: true),
            ),
            const HaroMenuItem.separator(),
            HaroMenuItem(
              label: 'Rename',
              hint: hintRename,
              onSelected: () => rename(path),
            ),
            HaroMenuItem(
              label: 'Copy path',
              hint: hintCopyPath,
              onSelected: () => copyPath(path),
            ),
            HaroMenuItem(
              label: 'Reveal in file manager',
              onSelected: () => revealInFileManager(path),
            ),
            const HaroMenuItem.separator(),
            if (_preferred != null)
              HaroMenuItem(
                label: 'Open folder in ${_preferred!.label}',
                onSelected: () => openInPreferred(path, at: at),
              ),
            HaroMenuItem(
              label: 'Open folder in…',
              onSelected: () => openInChoose(path, at: at),
            ),
          ]
        : [
            HaroMenuItem(
              label: 'Open',
              hint: hintOpen,
              onSelected: () => open(path),
            ),
            HaroMenuItem(
              label: 'Open to the side',
              hint: hintOpenToSide,
              onSelected: () => openToSide(path),
            ),
            const HaroMenuItem.separator(),
            HaroMenuItem(
              label: 'Rename',
              hint: hintRename,
              onSelected: () => rename(path),
            ),
            HaroMenuItem(
              label: 'Copy path',
              hint: hintCopyPath,
              onSelected: () => copyPath(path),
            ),
            HaroMenuItem(
              label: 'Copy relative path',
              hint: hintCopyRelative,
              onSelected: () => copyRelativePath(path),
            ),
            const HaroMenuItem.separator(),
            if (changed)
              HaroMenuItem(
                label: 'Show diff',
                onSelected: () => showDiff(path),
              ),
            if (_preferred != null)
              HaroMenuItem(
                label: 'Also open in ${_preferred!.label}',
                onSelected: () => openInPreferred(path, line: line, at: at),
              ),
            HaroMenuItem(
              label: 'Also open in…',
              onSelected: () => openInChoose(path, line: line, at: at),
            ),
            const HaroMenuItem.separator(),
            HaroMenuItem(
              label: 'Delete',
              hint: hintDelete,
              destructive: true,
              onSelected: () => delete(path, isDir: false),
            ),
          ],
  );
}
