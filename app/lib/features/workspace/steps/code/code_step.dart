import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/models/models.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_detail_lazy.dart';
import '../../../../shell/shell_layout.dart';
import '../../../../shortcuts/platform_keys.dart';
import '../../terminal/bottom_panel_provider.dart';
import 'code_providers.dart';
import 'diff_model.dart';
import 'editor/code_editor_area.dart';
import 'editor/editor_sticky_provider.dart';
import 'editor/editor_tabs.dart';
import 'proof.dart';
import 'quick_open.dart';
import 'workbench/activity_bar.dart';
import 'workbench/changes_model.dart';
import 'workbench/side_panel.dart';
import 'workbench/workbench_state.dart';
import 'workbench/workbench_widgets.dart' show WorkbenchTokens;

/// Step 02, the code step: `[activity bar][side panel][editor region]`. The bottom panel is
/// mounted by the workspace page under the whole step. This widget owns the layout and the
/// step-wide shortcuts; the panels, the tab model and the editor own the rest.
class CodeStep extends ConsumerStatefulWidget {
  const CodeStep(this.workspaceId, {super.key});

  final String workspaceId;

  @override
  ConsumerState<CodeStep> createState() => _CodeStepState();
}

class _CodeStepState extends ConsumerState<CodeStep> {
  final _focus = FocusNode(debugLabel: 'code-step');

  /// The step opens the first changed file once, and never again after the user closed it.
  bool _autoOpened = false;

  /// The saved tabs are looked for once per step, before the first changed file is opened.
  bool _stickyStarted = false;
  bool _stickyTried = false;

  DiffResponse? _parsedFrom;
  List<DiffFile> _files = const [];
  VerifiedHunksResponse? _proofFrom;
  ProofIndex? _proof;

  String get _id => widget.workspaceId;

  @override
  void initState() {
    super.initState();
    // Step-local shortcuts only fire while focus is inside the step, so take it on entry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(CodeStep old) {
    super.didUpdateWidget(old);
    if (old.workspaceId != widget.workspaceId) {
      _autoOpened = false;
      _stickyStarted = false;
      _stickyTried = false;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _parse(DiffResponse? diff) {
    if (identical(diff, _parsedFrom)) return;
    _parsedFrom = diff;
    _files = diff == null ? const [] : parseUnifiedDiff(diff.diff);
  }

  ProofIndex? _proofFor(VerifiedHunksResponse? v) {
    if (!identical(v, _proofFrom)) {
      _proofFrom = v;
      _proof = indexProof(v);
    }
    return _proof;
  }

  /// Puts back the tabs, active file and side panel this workspace had last time, keeping only
  /// files that still exist (the tree, or the diff for a deleted-but-changed one). When none do,
  /// or there was nothing saved, the step opens the first changed file as before.
  Future<void> _restoreSticky() async {
    final id = _id;
    var restored = false;
    try {
      final sticky = await ref.read(editorStickyProvider(id).future);
      if (!mounted || id != _id) return;
      final nothingOpen = ref.read(editorTabsProvider(id)).openPaths.isEmpty;
      if (sticky != null && sticky.hasTabs && nothingOpen) {
        final sub = ref.listenManual(codeFileTreeProvider(id), (_, _) {});
        var exists = <String>{};
        try {
          exists = flattenFilePaths(
            await ref.read(codeFileTreeProvider(id).future),
          ).toSet();
        } catch (_) {
        } finally {
          sub.close();
        }
        if (!mounted || id != _id) return;
        exists.addAll([for (final f in _files) f.path]);
        final keep = sticky.keeping(exists);
        if (keep != null &&
            ref.read(editorTabsProvider(id).notifier).restore(keep)) {
          restored = true;
          final wb = ref.read(workbenchProvider(id).notifier);
          wb.restore(
            view: keep.side.view,
            sideOpen: keep.side.open,
            sideWidth: keep.side.width,
            scope: keep.side.scope,
          );
          for (final p in keep.panes) {
            if (p.active != null) wb.expandTo(p.active!);
          }
        }
      }
    } catch (_) {}
    if (!mounted || id != _id) return;
    _stickyTried = true;
    if (restored) {
      _autoOpened = true;
    } else {
      _openFirstChanged();
    }
  }

  void _openFirstChanged() {
    if (_autoOpened || _files.isEmpty) return;
    _autoOpened = true;
    final tabs = ref.read(editorTabsProvider(_id));
    if (tabs.panes.any((p) => p.tabs.isNotEmpty)) return;
    final first = _files.first.path;
    ref.read(editorTabsProvider(_id).notifier).open(first);
    ref.read(workbenchProvider(_id).notifier).expandTo(first);
  }

  Future<void> _quickOpen() async {
    final sub = ref.listenManual(codeFileTreeProvider(_id), (_, _) {});
    try {
      final picked = await showQuickOpen(
        context,
        changed: [for (final f in _files) f.path],
        loadAll: () async =>
            flattenFilePaths(await ref.read(codeFileTreeProvider(_id).future)),
      );
      if (picked == null || !mounted) return;
      ref.read(editorTabsProvider(_id).notifier).open(picked, preview: false);
      ref.read(workbenchProvider(_id).notifier).reveal(picked);
    } finally {
      sub.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final diff = ref.watch(workspaceDetailProvider(_id).select((d) => d.diff));
    final verified = ref.watch(workspaceVerifiedHunksProvider(_id)).value;
    _parse(diff);
    final proof = _proofFor(verified);
    ref.watch(editorStickyProvider(_id));
    if (!_stickyStarted) {
      _stickyStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreSticky();
      });
    } else if (_stickyTried && !_autoOpened && _files.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openFirstChanged();
      });
    }

    final wb = ref.watch(workbenchProvider(_id));
    final wbNotifier = ref.read(workbenchProvider(_id).notifier);
    final changeCount = changeEntries(
      ref.watch(workspaceGitStatusProvider(_id)).value,
      _files,
    ).length;
    final control = primaryModifier == PrimaryModifier.control;
    final focus = ref.watch(
      shellLayoutProvider.select(
        (l) => l.focusOn(workspaceId: _id, codeStep: true),
      ),
    );

    return CallbackShortcuts(
      bindings: {
        SingleActivator(
          LogicalKeyboardKey.keyP,
          control: control,
          meta: !control,
        ): _quickOpen,
        SingleActivator(
          LogicalKeyboardKey.keyB,
          control: control,
          meta: !control,
        ): wbNotifier.toggleSide,
        SingleActivator(
          LogicalKeyboardKey.keyF,
          control: control,
          meta: !control,
          shift: true,
        ): wbNotifier.showSearch,
      },
      child: Focus(
        focusNode: _focus,
        child: Listener(
          // A click on the diff or list focuses nothing, so pull focus back into the step
          // or the shortcuts above would stop firing.
          onPointerDown: (_) {
            if (!_focus.hasFocus) _focus.requestFocus();
          },
          child: LayoutBuilder(
            builder: (context, box) {
              final sideWidth = fitSideWidth(
                wb.sideWidth,
                box.maxWidth - WorkbenchTokens.activityBarWidth,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ActivityBar(
                    view: wb.view,
                    sideOpen: wb.sideOpen,
                    changeCount: changeCount,
                    searchHint: primaryLabel('F', shift: true),
                    focus: focus,
                    focusHint: primaryLabel('↵', shift: true),
                    onFocus: () =>
                        ref.read(shellLayoutProvider.notifier).toggleFocus(_id),
                    onPick: wbNotifier.pick,
                    gateOpen: ref.watch(
                      bottomPanelProvider(_id)
                          .select((s) => s.showing(BottomTab.gate)),
                    ),
                    onGate: () => ref
                        .read(bottomPanelProvider(_id).notifier)
                        .toggleTab(BottomTab.gate),
                  ),
                  if (wb.sideOpen)
                    SidePanel(
                      workspaceId: _id,
                      changed: _files,
                      proof: proof,
                      width: sideWidth,
                    ),
                  Expanded(child: CodeEditorArea(_id)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
