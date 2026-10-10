import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../data/workspace_actions.dart';
import '../../../../../data/workspace_detail.dart';
import '../../../../../data/workspace_detail_lazy.dart';
import '../../../../../shortcuts/platform_keys.dart';
import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../../../../../widgets/haro_button.dart';
import '../../../../../widgets/haro_pressable.dart';
import '../diff_model.dart';
import '../editor/editor_tabs.dart';
import 'changes_model.dart';
import 'explorer_model.dart' show ChangeLetter;
import 'workbench_dialogs.dart' show errorText;
import 'workbench_icons.dart';
import 'workbench_ops.dart';
import 'workbench_widgets.dart';

/// What git sees as changed since the last commit, with a checkbox per file for the index and
/// a message box that commits exactly the staged files. In manual mode this is where your own
/// work gets committed.
class ChangesPanel extends ConsumerStatefulWidget {
  const ChangesPanel({
    super.key,
    required this.workspaceId,
    required this.diff,
  });

  final String workspaceId;

  /// The branch diff, for the +N beside each file.
  final List<DiffFile> diff;

  @override
  ConsumerState<ChangesPanel> createState() => _ChangesPanelState();
}

class _ChangesPanelState extends ConsumerState<ChangesPanel> {
  final _message = TextEditingController();
  final _pending = <String, bool>{};
  bool _committing = false;
  String? _error;

  String get _id => widget.workspaceId;

  @override
  void initState() {
    super.initState();
    _message.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  List<ChangeEntry> _entries() {
    final status = ref.read(workspaceGitStatusProvider(_id)).value;
    return _withPending(changeEntries(status, widget.diff));
  }

  List<ChangeEntry> _withPending(List<ChangeEntry> list) => [
    for (final e in list)
      _pending.containsKey(e.path)
          ? ChangeEntry(
              path: e.path,
              staged: _pending[e.path]!,
              conflict: e.conflict,
              letter: e.letter,
              additions: e.additions,
              deletions: e.deletions,
            )
          : e,
  ];

  Future<void> _setStaged(List<String> paths, bool staged) async {
    if (paths.isEmpty) return;
    setState(() {
      _error = null;
      for (final p in paths) {
        _pending[p] = staged;
      }
    });
    final ops = ref.read(workbenchOpsProvider(_id));
    try {
      await (staged ? ops.stage(paths) : ops.unstage(paths));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(e);
          _pending.clear();
        });
      }
    }
  }

  Future<void> _commit() async {
    final entries = _entries();
    if (_committing || !canCommit(entries, _message.text)) return;
    setState(() {
      _committing = true;
      _error = null;
    });
    try {
      final res = await ref
          .read(workspaceActionsProvider(_id))
          .commitStaged(_message.text);
      if (!mounted) return;
      setState(() {
        _committing = false;
        if (res.nothingToCommit) {
          _error = 'Nothing staged to commit.';
        } else {
          _message.clear();
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _committing = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(workspaceDetailProvider(_id).select((d) => d.diff), (_, _) {
      ref.invalidate(workspaceGitStatusProvider(_id));
    });
    // Until the refetch after a click lands, the boxes show the click itself.
    ref.listen(workspaceGitStatusProvider(_id), (_, next) {
      if (!next.isLoading && _pending.isNotEmpty) {
        setState(_pending.clear);
      }
    });
    final status = ref.watch(workspaceGitStatusProvider(_id));
    final entries = _withPending(changeEntries(status.value, widget.diff));
    final staged = stagedCount(entries);
    final allStaged = allFullyStaged(entries);
    final control = primaryModifier == PrimaryModifier.control;
    final ready = canCommit(entries, _message.text) && !_committing;

    return PanelColumn(
      children: [
        PanelHeader(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PanelTitle(
                'CHANGES · ${entries.length}',
                actions: [
                  IconAction(
                    key: const ValueKey('changes-stage-all'),
                    icon: WorkbenchIcon.check,
                    tooltip: allStaged ? 'Unstage all' : 'Stage all',
                    onTap: entries.isEmpty
                        ? null
                        : () => _setStaged([
                            for (final e in entries)
                              if (!e.conflict) e.path,
                          ], !allStaged),
                  ),
                ],
              ),
              Container(
                decoration: BoxDecoration(
                  color: HaroTokens.panel,
                  border: Border.all(color: HaroTokens.line20),
                  borderRadius: BorderRadius.circular(HaroTokens.radius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CallbackShortcuts(
                      bindings: {
                        SingleActivator(
                          LogicalKeyboardKey.enter,
                          control: control,
                          meta: !control,
                        ): _commit,
                      },
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 9, 10, 6),
                        child: Material(
                          type: MaterialType.transparency,
                          child: TextField(
                            key: const ValueKey('commit-message'),
                            controller: _message,
                            minLines: 3,
                            maxLines: 6,
                            style: HaroText.mono(
                              size: 11.5,
                              color: HaroTokens.ink,
                              tracking: 0,
                            ),
                            cursorColor: HaroTokens.ink,
                            cursorWidth: 1,
                            decoration: InputDecoration.collapsed(
                              hintText: 'Commit message',
                              hintStyle: HaroText.mono(
                                size: 11.5,
                                color: HaroTokens.ink42,
                                tracking: 0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: HaroTokens.line08),
                        ),
                      ),
                      child: LayoutBuilder(
                        builder: (context, box) => Row(
                          children: [
                            Expanded(
                              child: Text(
                                '$staged staged',
                                key: const ValueKey('staged-count'),
                                style: HaroText.mono(
                                  size: 10,
                                  color: HaroTokens.ink42,
                                  tracking: 0,
                                ),
                              ),
                            ),
                            HaroButton(
                              key: const ValueKey('commit-button'),
                              label: 'Commit',
                              kbd: box.maxWidth >= 190
                                  ? primaryLabel('↵')
                                  : null,
                              variant: HaroButtonVariant.primary,
                              height: 24,
                              fontSize: 12,
                              onPressed: ready ? _commit : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const ValueKey('changes-error'),
                  style: HaroText.mono(
                    size: 10.5,
                    color: HaroTokens.fail,
                    tracking: 0,
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? PanelNote(status.hasValue ? 'No changes.' : 'Loading…')
              : ListView.builder(
                  key: const ValueKey('changes-list'),
                  itemExtent: 28,
                  padding: const EdgeInsets.only(bottom: 10),
                  itemCount: entries.length,
                  itemBuilder: (context, i) => _ChangeRow(
                    entry: entries[i],
                    onToggle: () => _setStaged([
                      entries[i].path,
                    ], !entries[i].staged || entries[i].partial),
                    onOpen: entries[i].isDirectory
                        ? null
                        : () => ref
                              .read(editorTabsProvider(_id).notifier)
                              .open(entries[i].path, preview: false),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    required this.entry,
    required this.onToggle,
    required this.onOpen,
  });

  final ChangeEntry entry;
  final VoidCallback onToggle;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onOpen,
    semanticLabel: entry.path,
    builder: (context, hovered) => Container(
      key: ValueKey('change-row:${entry.path}'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: hovered ? HaroTokens.panel : HaroTokens.transparent,
      child: Row(
        children: [
          if (entry.conflict)
            Tooltip(
              message: 'Merge conflict: resolve it in the editor first',
              child: Text(
                'U',
                key: ValueKey('conflict:${entry.path}'),
                style: HaroText.mono(size: 11, color: HaroTokens.fail),
              ),
            )
          else
            _Checkbox(
              key: ValueKey('stage:${entry.path}'),
              on: entry.staged,
              partial: entry.partial,
              onTap: onToggle,
            ),
          const SizedBox(width: 8),
          Text(entry.name, style: HaroText.ui(size: 13)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.dir,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 10,
                color: HaroTokens.ink42,
                tracking: 0,
              ),
            ),
          ),
          if (entry.additions > 0) ...[
            const SizedBox(width: 8),
            Text(
              '+${entry.additions}',
              style: HaroText.mono(
                size: 10,
                color: HaroTokens.gate,
                tracking: 0,
              ),
            ),
          ],
          const SizedBox(width: 8),
          Text(
            entry.letter.text,
            style: HaroText.mono(
              size: 10,
              color: switch (entry.letter) {
                ChangeLetter.added => HaroTokens.gate,
                ChangeLetter.deleted => HaroTokens.fail,
                _ => HaroTokens.ink,
              },
              tracking: 0,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 13px square, bone-filled with a dark tick when the file is in the index, and a bone dash in
/// an empty box when only part of it is (the rest is still unstaged). Bone, not green: staging
/// is not a gate signal.
class _Checkbox extends StatelessWidget {
  const _Checkbox({
    super.key,
    required this.on,
    required this.onTap,
    this.partial = false,
  });

  final bool on;
  final bool partial;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final filled = on && !partial;
    return HaroPressable(
      onTap: onTap,
      semanticLabel: partial ? 'Stage the rest' : (on ? 'Unstage' : 'Stage'),
      builder: (context, hovered) => Container(
        width: 13,
        height: 13,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? HaroTokens.ink : HaroTokens.transparent,
          border: Border.all(
            color: on || hovered ? HaroTokens.ink : HaroTokens.ink42,
          ),
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: filled
            ? const WorkbenchIconView(
                WorkbenchIcon.check,
                size: 11,
                color: HaroTokens.bg,
              )
            : partial
            ? const SizedBox(
                key: ValueKey('partial-mark'),
                width: 7,
                height: 1.5,
                child: ColoredBox(color: HaroTokens.ink),
              )
            : null,
      ),
    );
  }
}
