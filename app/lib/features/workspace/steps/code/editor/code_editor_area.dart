import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../api/models/models.dart' show FileContent;
import '../../../../../data/workspace_actions.dart';
import '../../../../../data/workspace_detail.dart';
import '../../../../../data/xp_store.dart';
import '../../../../open_in/open_in_notice.dart';
import '../../../../../shortcuts/app_commands.dart';
import '../../../../../state/workspace_flow.dart' show StepKey;
import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../../../../../widgets/haro_button.dart';
import '../../../../settings/editor_prefs_provider.dart';
import '../../../workspace_ui.dart';
import '../../../../../api/haro_api.dart' show HaroApiException;
import '../code_buffers.dart';
import '../code_tokens.dart';
import '../run_on_save.dart';
import '../diff_model.dart';
import '../diff_view.dart';
import '../edit_buffer.dart' show BufferPhase;
import '../edit_pane.dart';
import '../proof.dart';
import '../../../../../widgets/haro_pressable.dart';
import 'breadcrumbs.dart';
import 'deferred_listenable.dart';
import 'editor_data.dart';
import 'editor_icons.dart';
import 'editor_marks.dart';
import 'editor_shell_buttons.dart';
import 'editor_tabs.dart';
import 'tab_strip.dart';

/// The editor region of the code step: one pane, or two side by side, each with its own tab
/// strip, breadcrumbs and a body that is the editor or the diff. Driven by [editorTabsProvider];
/// every open tab keeps its buffer, so unsaved edits survive switching tabs and leaving the step.
class CodeEditorArea extends ConsumerStatefulWidget {
  const CodeEditorArea(this.workspaceId, {super.key});

  final String workspaceId;

  @override
  ConsumerState<CodeEditorArea> createState() => _CodeEditorAreaState();
}

class _CodeEditorAreaState extends ConsumerState<CodeEditorArea> {
  CodeBufferStore? _store;
  late final AppCommandsNotifier _commands;
  late final VoidCallback _saveCommand = _saveAll;
  late final VoidCallback _splitCommand = _toggleSplit;

  String get _id => widget.workspaceId;
  EditorTabsNotifier get _tabs => ref.read(editorTabsProvider(_id).notifier);

  @override
  void initState() {
    super.initState();
    _commands = ref.read(appCommandsProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _commands.register(
        (c) => c.copyWith(saveFile: _saveCommand, splitEditor: _splitCommand),
      );
    });
  }

  @override
  void dispose() {
    final commands = _commands;
    final save = _saveCommand;
    final split = _splitCommand;
    _store
      ?..removeListener(_onStore)
      ..releaseClean();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Only take our own callbacks back: the next workspace's editor may already own them.
      if (!commands.alive) return;
      commands.register(
        (c) => c.copyWith(
          saveFile: c.saveFile == save ? const AppCommands().saveFile : null,
          splitEditor: c.splitEditor == split
              ? const AppCommands().splitEditor
              : null,
        ),
      );
    });
    super.dispose();
  }

  @override
  void didUpdateWidget(CodeEditorArea old) {
    super.didUpdateWidget(old);
    if (old.workspaceId != widget.workspaceId) {
      _store?.removeListener(_onStore);
      _store = null;
    }
  }

  void _bindStore(CodeBufferStore store) {
    if (identical(store, _store)) return;
    _store?.removeListener(_onStore);
    _store = store..addListener(_onStore);
  }

  /// The tab strip mirrors the buffers' unsaved state (buffers are the truth).
  void _onStore() {
    if (!mounted) return;
    final store = _store;
    if (store == null) return;
    final dirty = store.dirtyPaths;
    final state = ref.read(editorTabsProvider(_id));
    for (final p in state.openPaths) {
      final d = dirty.contains(p);
      final tab = _tabFor(state, p);
      if (tab != null && tab.dirty != d) _tabs.setDirty(p, d);
    }
    setState(() {});
  }

  EditorTab? _tabFor(EditorTabsState s, String path) {
    for (final pane in s.panes) {
      for (final t in pane.tabs) {
        if (t.path == path) return t;
      }
    }
    return null;
  }

  Future<FileContent> _read(String path) =>
      ref.read(workspaceActionsProvider(_id)).readFile(path);

  Future<bool> _save(String path) async {
    final b = _store?.bufferFor(path);
    if (b == null || b.phase != BufferPhase.ready || !b.dirty) return false;
    if (await b.changedOnDisk(() => _read(path))) {
      b.markDiskConflict(true);
      return false;
    }
    final actions = ref.read(workspaceActionsProvider(_id));
    final ok = await b.save((content) => actions.saveFile(path, content));
    if (ok && mounted) unawaited(runGateAfterSave(ref, _id));
    return ok;
  }

  /// ⌘S: every file with unsaved edits, not only the one in view, so it always agrees with the
  /// step bar action. The gate runs after only when Run on save is on ([runGateAfterSave]
  /// checks the live setting).
  Future<void> _saveAll() async {
    final store = _store;
    if (store == null || store.dirtyPaths.isEmpty) return;
    try {
      await saveDirtyBuffers(store, ref.read(workspaceActionsProvider(_id)));
    } on HaroApiException {
      return;
    }
    if (mounted) unawaited(runGateAfterSave(ref, _id));
  }

  Future<void> _overwrite(String path) async {
    final b = _store?.bufferFor(path);
    if (b == null) return;
    b.markDiskConflict(false);
    final actions = ref.read(workspaceActionsProvider(_id));
    final ok = await b.save((content) => actions.saveFile(path, content));
    if (ok && mounted) unawaited(runGateAfterSave(ref, _id));
  }

  Future<void> _reload(String path) =>
      _store?.bufferFor(path)?.reloadFromDisk(() => _read(path)) ??
      Future.value();

  /// The agent or a gate run may have rewritten files: clean buffers follow the disk. A buffer
  /// with unsaved edits is left alone and only asks at save time.
  void _refreshClean() {
    final store = _store;
    if (store == null) return;
    for (final path in ref.read(editorTabsProvider(_id)).openPaths) {
      store.bufferFor(path)?.refreshIfClean(() => _read(path));
    }
  }

  void _toggleSplit() => _tabs.toggleSplit();

  /// Whether some other pane still shows [path] once [pane] lets go of it.
  bool _heldElsewhere(String path, int pane) {
    final s = ref.read(editorTabsProvider(_id));
    for (var i = 0; i < s.panes.length; i++) {
      if (i != pane && s.panes[i].has(path)) return true;
    }
    return false;
  }

  void _closeNow(String path, int pane, {bool discard = false}) {
    final held = _heldElsewhere(path, pane);
    _tabs.close(path, pane: pane);
    if (!held) {
      final store = _store;
      if (discard) {
        store?.drop(path);
      } else {
        store?.retainOnly(ref.read(editorTabsProvider(_id)).openPaths);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _bindStore(ref.watch(codeBuffersProvider(_id)));
    ref.listen(
      workspaceDetailProvider(_id).select((d) => d.diff),
      (_, _) => _refreshClean(),
    );
    final state = ref.watch(editorTabsProvider(_id));
    final parsed = ref.watch(parsedDiffProvider(_id));
    final prefs = ref.watch(editorPrefsProvider);
    final ranProof = ref.watch(editorProofProvider(_id));
    final diffProof = ref.watch(diffProofProvider(_id));
    final store = _store!;

    final shownDiffs = <String>[];
    for (final pane in state.panes) {
      final tab = pane.active;
      if (tab == null) continue;
      final changed = parsed.byPath.containsKey(tab.path);
      final mode = tab.resolveMode(changed: changed, viewMode: state.viewMode);
      if (mode == CodeMode.edit) {
        store.ensure(tab.path, () => _read(tab.path));
      } else if (changed) {
        shownDiffs.add(tab.path);
      }
    }
    if (shownDiffs.isNotEmpty) {
      final changedPaths = parsed.byPath.keys.toList();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final xp = ref.read(xpReporterProvider);
        for (final p in shownDiffs) {
          xp.diffShown(_id, p, changedPaths);
        }
      });
    }

    final children = <Widget>[];
    for (var i = 0; i < state.panes.length; i++) {
      if (i > 0) {
        children.add(Container(width: 1, color: HaroTokens.line12));
      }
      children.add(
        Expanded(
          child: _PaneView(
            key: ValueKey('pane-$i'),
            workspaceId: _id,
            index: i,
            pane: state.panes[i],
            focused: state.focusedPane == i,
            split: state.split,
            parsed: parsed,
            ranProof: ranProof,
            diffProof: diffProof,
            store: store,
            fontSize: prefs.fontSize,
            minimap: prefs.minimap,
            jump: state.jump,
            onJumped: _tabs.consumeJump,
            onSave: _save,
            onSaveAll: _saveAll,
            onOverwrite: _overwrite,
            onReload: _reload,
            onClose: (path, {discard = false}) =>
                _closeNow(path, i, discard: discard),
            onRefresh: (path) =>
                store.bufferFor(path)?.refreshIfClean(() => _read(path)),
            onEnsure: (path) => store.ensure(path, () => _read(path)),
          ),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

typedef _CloseTab = void Function(String path, {bool discard});

class _PaneView extends ConsumerStatefulWidget {
  const _PaneView({
    super.key,
    required this.workspaceId,
    required this.index,
    required this.pane,
    required this.focused,
    required this.split,
    required this.parsed,
    required this.ranProof,
    required this.diffProof,
    required this.store,
    required this.fontSize,
    required this.minimap,
    required this.jump,
    required this.onJumped,
    required this.onSave,
    required this.onSaveAll,
    required this.onOverwrite,
    required this.onReload,
    required this.onClose,
    required this.onRefresh,
    required this.onEnsure,
  });

  final String workspaceId;
  final int index;
  final EditorPane pane;
  final bool focused;
  final bool split;
  final ParsedDiff parsed;
  final ProofIndex? ranProof;
  final ProofIndex? diffProof;
  final CodeBufferStore store;
  final int fontSize;
  final bool minimap;
  final EditorJump? jump;
  final ValueChanged<int> onJumped;
  final Future<bool> Function(String path) onSave;
  final Future<void> Function() onSaveAll;
  final Future<void> Function(String path) onOverwrite;
  final Future<void> Function(String path) onReload;
  final _CloseTab onClose;
  final void Function(String path) onRefresh;

  /// Starts loading the buffer for [path] now, ahead of the rebuild that would.
  final void Function(String path) onEnsure;

  @override
  ConsumerState<_PaneView> createState() => _PaneViewState();
}

class _PaneViewState extends ConsumerState<_PaneView> {
  /// The tab whose close is waiting on an answer about its unsaved edits.
  String? _confirm;

  String get _id => widget.workspaceId;
  EditorTabsNotifier get _tabs => ref.read(editorTabsProvider(_id).notifier);

  @override
  void didUpdateWidget(_PaneView old) {
    super.didUpdateWidget(old);
    final active = widget.pane.activePath;
    if (active != null && active != old.pane.activePath) {
      // Coming back to a tab picks up what the agent wrote meanwhile, if there are no edits.
      widget.onRefresh(active);
    }
    if (_confirm != null && !widget.pane.has(_confirm!)) _confirm = null;
  }

  void _requestClose(String path) {
    final dirty = widget.store.bufferFor(path)?.dirty ?? false;
    final elsewhere = _heldElsewhere(path);
    if (dirty && !elsewhere) {
      setState(() => _confirm = path);
      _tabs.activate(path, pane: widget.index);
      return;
    }
    widget.onClose(path);
  }

  bool _heldElsewhere(String path) {
    final s = ref.read(editorTabsProvider(_id));
    for (var i = 0; i < s.panes.length; i++) {
      if (i != widget.index && s.panes[i].has(path)) return true;
    }
    return false;
  }

  Future<void> _saveAndClose(String path) async {
    if (await widget.onSave(path) && mounted) {
      setState(() => _confirm = null);
      widget.onClose(path);
    }
  }

  void _discardAndClose(String path) {
    setState(() => _confirm = null);
    widget.onClose(path, discard: true);
  }

  @override
  Widget build(BuildContext context) {
    final pane = widget.pane;
    final tab = pane.active;
    final parsed = widget.parsed;
    final file = tab == null ? null : parsed.byPath[tab.path];
    final mode = tab?.resolveMode(
      changed: file != null,
      viewMode: ref.watch(editorTabsProvider(_id).select((s) => s.viewMode)),
    );
    return Listener(
      onPointerDown: (_) {
        if (!widget.focused) _tabs.focusPane(widget.index);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabStrip(
            pane: pane,
            changed: parsed.byPath,
            mode: mode,
            split: widget.split,
            onActivate: (p) => _tabs.activate(p, pane: widget.index),
            onPin: _tabs.pin,
            onClose: _requestClose,
            onMode: (m) {
              if (tab == null) return;
              if (m == CodeMode.edit) widget.onEnsure(tab.path);
              _tabs.setMode(m);
            },
            onSplit: _tabs.toggleSplit,
            trailing: !widget.split || widget.index > 0
                ? EditorShellButtons(workspaceId: _id)
                : null,
          ),
          if (tab != null) _crumbs(tab, file, mode!),
          if (tab == null && widget.index > 0)
            _SideBar(onClose: _tabs.closeSplit),
          if (tab != null && widget.index == 0)
            const OpenInNoticeText(
              source: 'code',
              padding: EdgeInsets.fromLTRB(14, 6, 14, 6),
            ),
          if (_confirm != null)
            UnsavedBar(
              name: basenameOf(_confirm!),
              onSave: () => _saveAndClose(_confirm!),
              onDiscard: () => _discardAndClose(_confirm!),
              onKeep: () => setState(() => _confirm = null),
              error: widget.store.bufferFor(_confirm!)?.saveError,
            ),
          if (tab != null &&
              widget.store.bufferFor(tab.path)?.diskConflict == true)
            DiskConflictBar(
              onOverwrite: () => widget.onOverwrite(tab.path),
              onReload: () => widget.onReload(tab.path),
              onCancel: () =>
                  widget.store.bufferFor(tab.path)?.markDiskConflict(false),
            ),
          Expanded(child: tab == null ? _empty() : _body(tab, file, mode!)),
        ],
      ),
    );
  }

  Widget _crumbs(EditorTab tab, DiffFile? file, CodeMode mode) {
    final buffer = widget.store.bufferFor(tab.path);
    final controller = mode == CodeMode.edit ? buffer?.controller : null;
    final legend = mode == CodeMode.diff && widget.diffProof != null;
    int? openLine() => mode == CodeMode.diff
        ? file?.firstChangedLine
        : controller == null
        ? null
        : controller.selection.extentIndex + 1;
    Widget build(List<String> symbols) => Breadcrumbs(
      workspaceId: _id,
      path: tab.path,
      symbols: symbols,
      file: file,
      showLegend: legend,
      openLine: openLine,
      onClosePane: widget.index > 0 ? _tabs.closeSplit : null,
    );
    if (controller == null) return build(const []);
    return DeferredListenableBuilder(
      listenable: controller,
      builder: (context) => build(symbolsAtCursor(tab.path, controller)),
    );
  }

  Widget _body(EditorTab tab, DiffFile? file, CodeMode mode) {
    final path = tab.path;
    if (mode == CodeMode.diff) {
      if (file == null) {
        return const _Note(
          'No changes in this file. Switch to Edit to open it.',
        );
      }
      return DiffView(
        key: ValueKey('diff:$path'),
        file: file,
        proof: widget.diffProof?[path],
      );
    }
    final b = widget.store.bufferFor(path);
    if (b == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) {
        final clean = !b.dirty;
        final j = widget.jump;
        return EditPane(
          key: ValueKey('edit:$path:${widget.index}'),
          buffer: b,
          onSave: widget.onSaveAll,
          fontSize: widget.fontSize,
          minimap: widget.minimap,
          marks: clean ? changeMarks(file) : const {},
          ran: clean ? ranLines(file, widget.ranProof?[path]) : const {},
          jump: j != null && j.path == path ? j : null,
          onJumped: widget.onJumped,
        );
      },
    );
  }

  Widget _empty() {
    if (widget.index > 0) {
      return const _Note('Open a file here to read it beside the other one.');
    }
    if (widget.parsed.files.isNotEmpty) {
      return const _Note(
        'Open a file from the explorer, or press the shortcut for Go to file.',
      );
    }
    final manual = ref.watch(
      workspaceDetailProvider(_id).select((d) => d.workspace?.manual ?? false),
    );
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'No changes yet.',
            key: const ValueKey('code-empty'),
            style: HaroText.mono(
              size: 12,
              color: HaroTokens.ink42,
              tracking: 0,
            ),
          ),
          if (!manual) const SizedBox(height: 8),
          if (!manual)
            IntrinsicWidth(
              child: HaroButton(
                key: const ValueKey('code-empty-agent'),
                label: 'Go to the agent →',
                variant: HaroButtonVariant.tertiary,
                height: 26,
                fontSize: 13,
                onPressed: () =>
                    context.go(workspaceStepPath(_id, StepKey.agent)),
              ),
            ),
        ],
      ),
    );
  }
}

/// The strip over an empty side pane: only the way to close it.
class _SideBar extends StatelessWidget {
  const _SideBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
    height: CrumbTokens.height,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line08)),
    ),
    child: Row(
      children: [
        const Spacer(),
        HaroPressable(
          onTap: onClose,
          semanticLabel: 'Close split',
          builder: (context, hovered) => Padding(
            key: const ValueKey('close-split'),
            padding: const EdgeInsets.all(4),
            child: EditorIcon(
              EditorIconKind.close,
              size: 12,
              color: hovered ? HaroTokens.ink : HaroTokens.ink42,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Align(
      alignment: Alignment.topLeft,
      child: Text(
        text,
        style: HaroText.mono(size: 12, color: HaroTokens.ink42, tracking: 0),
      ),
    ),
  );
}

/// Shown when a save would overwrite a change made on disk since the file was opened.
class DiskConflictBar extends StatelessWidget {
  const DiskConflictBar({
    super.key,
    required this.onOverwrite,
    required this.onReload,
    required this.onCancel,
  });

  final VoidCallback onOverwrite;
  final VoidCallback onReload;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('disk-conflict-bar'),
    padding: const EdgeInsets.symmetric(
      horizontal: CodeTokens.headerPadX,
      vertical: 8,
    ),
    decoration: const BoxDecoration(
      color: HaroTokens.panel,
      border: Border(bottom: BorderSide(color: HaroTokens.line08)),
    ),
    child: Wrap(
      spacing: 14,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'This file changed on disk since you opened it.',
          style: HaroText.mono(
            size: 11.5,
            color: HaroTokens.ink86,
            tracking: 0,
          ),
        ),
        IntrinsicWidth(
          child: HaroButton(
            key: const ValueKey('conflict-overwrite'),
            label: 'Overwrite',
            height: 24,
            fontSize: 12,
            onPressed: onOverwrite,
          ),
        ),
        IntrinsicWidth(
          child: HaroButton(
            key: const ValueKey('conflict-reload'),
            label: 'Reload',
            height: 24,
            fontSize: 12,
            onPressed: onReload,
          ),
        ),
        IntrinsicWidth(
          child: HaroButton(
            key: const ValueKey('conflict-cancel'),
            label: 'Cancel',
            variant: HaroButtonVariant.tertiary,
            height: 24,
            fontSize: 12,
            padding: EdgeInsets.zero,
            onPressed: onCancel,
          ),
        ),
      ],
    ),
  );
}

/// Asks what to do with unsaved edits before their tab closes.
class UnsavedBar extends StatelessWidget {
  const UnsavedBar({
    super.key,
    required this.name,
    required this.onSave,
    required this.onDiscard,
    required this.onKeep,
    this.error,
  });

  final String name;
  final VoidCallback onSave;
  final VoidCallback onDiscard;
  final VoidCallback onKeep;
  final String? error;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('unsaved-bar'),
    padding: const EdgeInsets.symmetric(
      horizontal: CodeTokens.headerPadX,
      vertical: 8,
    ),
    decoration: const BoxDecoration(
      color: HaroTokens.panel,
      border: Border(bottom: BorderSide(color: HaroTokens.line08)),
    ),
    child: Wrap(
      spacing: 14,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          error == null ? 'Unsaved changes in $name.' : 'Save failed: $error',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: HaroText.mono(
            size: 11.5,
            color: error == null ? HaroTokens.ink86 : HaroTokens.fail,
            tracking: 0,
          ),
        ),
        IntrinsicWidth(
          child: HaroButton(
            key: const ValueKey('unsaved-save'),
            label: 'Save and close',
            height: 24,
            fontSize: 12,
            onPressed: onSave,
          ),
        ),
        IntrinsicWidth(
          child: HaroButton(
            key: const ValueKey('unsaved-discard'),
            label: 'Discard',
            height: 24,
            fontSize: 12,
            onPressed: onDiscard,
          ),
        ),
        IntrinsicWidth(
          child: HaroButton(
            key: const ValueKey('unsaved-keep'),
            label: 'Keep editing',
            variant: HaroButtonVariant.tertiary,
            height: 24,
            fontSize: 12,
            padding: EdgeInsets.zero,
            onPressed: onKeep,
          ),
        ),
      ],
    ),
  );
}
