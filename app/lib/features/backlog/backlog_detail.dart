import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../overlays/confirm_overlay.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/shell_icons.dart';
import '../../widgets/haro_menu.dart';
import '../../widgets/path_line.dart';
import '../../widgets/haro_text_field.dart';
import '../../widgets/issue_comment_card.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_tag.dart';
import '../../widgets/status_square.dart';
import '../new_workspace/creation_widgets.dart';
import '../open_in/open_in_launcher.dart';
import '../open_in/open_in_notice.dart';
import 'backlog_jump.dart';
import 'backlog_model.dart';
import '../workspace/steps/agent/agent_markdown.dart' show AgentProse;
import 'inline_markdown.dart';

const _readWidth = 640.0;

/// The "Edit in editor" button under a backlog file's title. The file sits in the project
/// root, so it goes through the project open route, not a workspace's.
class _EditInEditorLink extends ConsumerWidget {
  const _EditInEditorLink({required this.projectId, required this.path});

  final String projectId;
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) => HaroButton(
    key: const Key('bl-edit-link'),
    label: 'Edit in editor',
    trailing: ShellIcon.openExternal,
    height: 26,
    fontSize: 12,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    tooltip: 'Open $path in your preferred editor',
    onPressed: () => ref
        .read(openInLauncherProvider)
        .launch(
          context,
          projectId: projectId,
          source: 'project:$path',
          path: path,
        ),
  );
}

class _PaneFrame extends StatelessWidget {
  const _PaneFrame({
    required this.caption,
    required this.title,
    required this.action,
    required this.children,
    this.subtitle,
  });

  final Widget caption;

  /// A quiet single line under the title (a file's path).
  final Widget? subtitle;
  final String title;
  final Widget action;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SelectionArea(
    // Right-click belongs to the rows (their own menu), not to a Copy / Select all bubble.
    contextMenuBuilder: (context, state) => const SizedBox.shrink(),
    child: ListView(
      padding: const EdgeInsets.fromLTRB(32, 26, 32, 26),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  caption,
                  const SizedBox(height: 8),
                  Text(
                    title,
                    style: HaroText.ui(
                      size: 26,
                      weight: FontWeight.w500,
                    ).copyWith(letterSpacing: -.39, height: 1.2),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 6),
                    subtitle!,
                  ],
                ],
              ),
            ),
            const SizedBox(width: 20),
            action,
          ],
        ),
        ...children,
      ],
    ),
  );
}

/// A GitHub issue's description as markdown (headings, lists, code, links), not just inline marks.
Widget _markdown(String text) => ConstrainedBox(
  constraints: const BoxConstraints(maxWidth: _readWidth),
  child: Padding(
    padding: const EdgeInsets.only(top: 18),
    child: AgentProse(text.trim()),
  ),
);

Widget _prose(String text) => ConstrainedBox(
  constraints: const BoxConstraints(maxWidth: _readWidth),
  child: Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Text.rich(
      inlineMarkdown(
        text,
        HaroText.ui(size: 15, color: HaroTokens.ink86, height: 1.6),
      ),
    ),
  ),
);

/// What the Backlog page can do to an item. Each takes the item's position in the file and
/// its text, which the backend checks against the file before touching it.
class TodoActions {
  const TodoActions({
    required this.add,
    required this.toggle,
    required this.edit,
    required this.delete,
    required this.move,
    required this.moveTo,
    required this.rename,
    this.otherFiles = const [],
    this.pin,
    this.tags,
    this.depends,
    this.snooze,
    this.archive,
    this.copyLink,
    this.filterTag,
  });

  final Future<void> Function(String text) add;
  final Future<void> Function(int index, TodoItem item) toggle;
  final Future<void> Function(int index, TodoItem item, String body) edit;
  final Future<void> Function(int index, TodoItem item) delete;
  final Future<void> Function(int index, TodoItem item, int delta) move;
  final Future<void> Function(int index, TodoItem item, String toFile) moveTo;
  final VoidCallback rename;

  /// The other backlog files, as targets for "Move to".
  final List<String> otherFiles;

  /// What haro remembers about an item beside the project's files (`.haro/todos/meta.jsonl`).
  /// Each is optional: a row without the callback leaves that entry out of its menu.
  final Future<void> Function(int index, TodoItem item)? pin;
  final Future<void> Function(int index, TodoItem item)? tags;
  final Future<void> Function(int index, TodoItem item)? depends;

  /// [until] is `YYYY-MM-DD`, or empty to clear the snooze.
  final Future<void> Function(int index, TodoItem item, String until)? snooze;
  final Future<void> Function(int index, TodoItem item)? archive;
  final Future<void> Function(int index, TodoItem item)? copyLink;

  /// A tag chip was pressed: filter the Backlog by it.
  final ValueChanged<String>? filterTag;
}

class TodoDetail extends StatefulWidget {
  const TodoDetail({
    super.key,
    required this.file,
    required this.projectId,
    required this.pickedKey,
    required this.onPick,
    required this.onStart,
    required this.actions,
  });

  final TodoFile file;
  final String projectId;
  final String? pickedKey;
  final ValueChanged<String> onPick;
  final ValueChanged<TodoItem> onStart;
  final TodoActions actions;

  @override
  State<TodoDetail> createState() => _TodoDetailState();
}

class _TodoDetailState extends State<TodoDetail> {
  final _add = TextEditingController();
  final _addFocus = FocusNode();

  TodoFile get file => widget.file;

  @override
  void dispose() {
    _add.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  TodoItem? get _target {
    for (final i in file.items) {
      if (i.seedKey == widget.pickedKey && isStartable(i)) return i;
    }
    return nextStartable(file);
  }

  Future<void> _submitAdd(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return;
    _add.clear();
    _addFocus.requestFocus();
    await widget.actions.add(text);
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    final summary = fileSummary(file);
    final rows = <Widget>[];
    String? heading;
    for (var n = 0; n < file.items.length; n++) {
      final item = file.items[n];
      if (item.heading != null && item.heading != heading) {
        heading = item.heading;
        rows.add(
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 2),
              child: MonoCaption(stripInlineMarkdown(heading!)),
            ),
          ),
        );
      }
      rows.add(
        _ChecklistRow(
          key: ValueKey('${file.path}#$n#${item.body}'),
          item: item,
          index: n,
          last: n == file.items.length - 1,
          isTarget: identical(item, target),
          onTap: isStartable(item) ? () => widget.onPick(item.seedKey!) : null,
          actions: widget.actions,
        ),
      );
    }
    return _PaneFrame(
      caption: Wrap(
        spacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(
              file.path.substring(file.path.lastIndexOf('/') + 1),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 11,
                tracking: 0,
                color: HaroTokens.ink66,
              ),
            ),
          ),
          HaroTag('${itemsDone(file)} of ${file.items.length} done'),
          _EditInEditorLink(projectId: widget.projectId, path: file.path),
          HaroButton(
            key: const Key('bl-rename'),
            label: 'Rename',
            leading: ShellIcon.pencil,
            height: 26,
            fontSize: 12,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            tooltip: 'Rename ${file.path}',
            onPressed: widget.actions.rename,
          ),
          OpenInNoticeText(source: 'project:${file.path}'),
        ],
      ),
      title: fileTitle(file),
      subtitle: Align(
        alignment: Alignment.centerLeft,
        child: PathLine(file.path),
      ),
      action: HaroButton(
        key: const Key('bl-start'),
        label: 'Start as workspace',
        variant: HaroButtonVariant.primary,
        onPressed: target == null ? null : () => widget.onStart(target),
      ),
      children: [
        if (summary.isNotEmpty) _prose(summary),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _readWidth),
          child: Padding(
            padding: const EdgeInsets.only(top: 18),
            child: HaroTextField(
              key: const Key('bl-add'),
              controller: _add,
              focusNode: _addFocus,
              height: 34,
              fontSize: 14,
              hintText: 'Add a todo, press Enter',
              onSubmitted: _submitAdd,
            ),
          ),
        ),
        if (file.items.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _readWidth),
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Column(children: rows),
            ),
          ),
        if (target?.id != null && target!.id!.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _readWidth),
            child: _LinkedNotes(
              key: ValueKey('linked-${target.id}'),
              projectId: widget.projectId,
              id: target.id!,
              title: target.text,
            ),
          ),
      ],
    );
  }
}

class _ChecklistRow extends StatefulWidget {
  const _ChecklistRow({
    super.key,
    required this.item,
    required this.index,
    required this.last,
    required this.isTarget,
    required this.onTap,
    required this.actions,
  });

  final TodoItem item;
  final int index;
  final bool last;
  final bool isTarget;
  final VoidCallback? onTap;
  final TodoActions actions;

  @override
  State<_ChecklistRow> createState() => _ChecklistRowState();
}

class _ChecklistRowState extends State<_ChecklistRow> {
  bool _editing = false;
  final TextEditingController _ctl = TextEditingController();

  String get _current =>
      widget.item.body.isEmpty ? widget.item.text : widget.item.body;

  /// Seeded from the item every time editing starts, so a cancelled draft does not come back.
  void _startEditing() {
    _ctl.text = _current;
    setState(() => _editing = true);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final body = _ctl.text.trim();
    setState(() => _editing = false);
    if (body.isEmpty) return;
    if (body == _current.trim()) return;
    await widget.actions.edit(widget.index, widget.item, body);
  }

  /// Asks in a modal first: deleting a todo (and its sub-items) cannot be undone from the page.
  Future<void> _confirmDelete(BuildContext context) async {
    final text = stripInlineMarkdown(widget.item.text);
    final shown = text.length > 140 ? '${text.substring(0, 140)}...' : text;
    final n = widget.item.children;
    final ok = await showConfirm(
      context,
      title: n == 0
          ? 'Delete this todo?'
          : 'Delete this todo and its sub-items?',
      body: n == 0
          ? shown
          : '$shown\n\n$n sub-item${n == 1 ? '' : 's'} go${n == 1 ? 'es' : ''} with it.',
    );
    if (ok && mounted) await widget.actions.delete(widget.index, widget.item);
  }

  /// The row's menu: under the button that opened it, or where a right-click landed ([at]).
  void _menu(BuildContext context, {Offset? at}) {
    final box = context.findRenderObject() as RenderBox;
    at ??= box.localToGlobal(Offset(box.size.width, box.size.height));
    final a = widget.actions;
    showHaroMenu(
      context,
      position: at,
      items: [
        HaroMenuItem(label: 'Edit', onSelected: _startEditing),
        if (widget.index > 0)
          HaroMenuItem(
            label: 'Move up',
            onSelected: () => a.move(widget.index, widget.item, -1),
          ),
        if (!widget.last)
          HaroMenuItem(
            label: 'Move down',
            onSelected: () => a.move(widget.index, widget.item, 1),
          ),
        if (a.otherFiles.isNotEmpty) ...[
          const HaroMenuItem.separator(),
          const HaroMenuItem.heading('Move to'),
          for (final f in a.otherFiles)
            HaroMenuItem(
              label: f,
              onSelected: () => a.moveTo(widget.index, widget.item, f),
            ),
        ],
        if (a.pin != null ||
            a.tags != null ||
            a.depends != null ||
            a.snooze != null ||
            a.archive != null ||
            a.copyLink != null)
          const HaroMenuItem.separator(),
        if (a.pin != null)
          HaroMenuItem(
            label: widget.item.pinned ? 'Unpin' : 'Pin to the top',
            onSelected: () => a.pin!(widget.index, widget.item),
          ),
        if (a.tags != null)
          HaroMenuItem(
            label: 'Tags\u2026',
            onSelected: () => a.tags!(widget.index, widget.item),
          ),
        if (a.depends != null)
          HaroMenuItem(
            label: 'Depends on\u2026',
            onSelected: () => a.depends!(widget.index, widget.item),
          ),
        if (a.snooze != null) ...[
          if (widget.item.snooze.isNotEmpty)
            HaroMenuItem(
              label: 'Clear snooze',
              onSelected: () => a.snooze!(widget.index, widget.item, ''),
            ),
          HaroMenuItem(
            label: 'Snooze until tomorrow',
            onSelected: () => a.snooze!(widget.index, widget.item, _isoIn(1)),
          ),
          HaroMenuItem(
            label: 'Snooze for a week',
            onSelected: () => a.snooze!(widget.index, widget.item, _isoIn(7)),
          ),
        ],
        if (a.archive != null)
          HaroMenuItem(
            label: widget.item.archived ? 'Unarchive' : 'Archive',
            onSelected: () => a.archive!(widget.index, widget.item),
          ),
        if (a.copyLink != null)
          HaroMenuItem(
            label: 'Copy link for a note',
            onSelected: () => a.copyLink!(widget.index, widget.item),
          ),
        const HaroMenuItem.separator(),
        HaroMenuItem(
          label: widget.item.children == 0
              ? 'Delete'
              : 'Delete with ${widget.item.children} sub-item${widget.item.children == 1 ? '' : 's'}',
          destructive: true,
          onSelected: () => unawaited(_confirmDelete(context)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (_editing) return _editor();
    final seeded = !item.done && item.seededWorkspace != null;
    // A right-click anywhere on the row opens the same menu as the menu button.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) => _menu(context, at: d.globalPosition),
      child: _row(item, seeded),
    );
  }

  Widget _row(TodoItem item, bool seeded) {
    return HaroPressable(
      onTap: widget.onTap,
      semanticLabel: stripInlineMarkdown(item.text),
      builder: (context, hovered) => AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        padding: EdgeInsets.fromLTRB(item.depth.clamp(0, 4) * 22.0, 10, 0, 10),
        decoration: BoxDecoration(
          color: widget.isTarget || hovered
              ? HaroTokens.ink02
              : HaroTokens.transparent,
          border: Border(bottom: BorderSide(color: HaroTokens.line08)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: HaroPressable(
                key: Key('bl-toggle-${widget.index}'),
                onTap: () => widget.actions.toggle(widget.index, item),
                semanticLabel: item.done ? 'Mark not done' : 'Mark done',
                // The ripple is clipped to this circle, so it grows from the box, not from a
                // padded rectangle that is wider than the box and off its centre.
                builder: (context, hovered) => AnimatedContainer(
                  duration: HaroTokens.fadeFast,
                  curve: HaroTokens.curve,
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hovered ? HaroTokens.raised : HaroTokens.transparent,
                  ),
                  child: _Marker(item: item),
                ),
              ),
            ),
            if (item.pinned) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 3, 6, 0),
                child: ShellIconView(
                  ShellIcon.pin,
                  size: 13,
                  color: HaroTokens.ink66,
                ),
              ),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    inlineMarkdown(
                      item.text,
                      HaroText.ui(
                        color: item.done || item.archived
                            ? HaroTokens.ink42
                            : HaroTokens.ink86,
                        height: 1.4,
                      ),
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.tags.isNotEmpty ||
                      item.blocked ||
                      item.snoozed ||
                      item.archived)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (final t in item.tags)
                            _TagChip(
                              key: Key('bl-tag-${widget.index}-$t'),
                              tag: t,
                              onTap: widget.actions.filterTag == null
                                  ? null
                                  : () => widget.actions.filterTag!(t),
                            ),
                          if (item.blocked)
                            MonoCaption(
                              'Blocked by ${item.blockedBy.length}',
                              color: HaroTokens.warn,
                            ),
                          if (item.snoozed)
                            MonoCaption('Snoozed until ${item.snooze}'),
                          if (item.archived) MonoCaption('Archived'),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (seeded) ...[
              const SizedBox(width: 12),
              MonoCaption('In progress'),
            ] else if (widget.isTarget) ...[
              const SizedBox(width: 12),
              MonoCaption('Starts here', color: HaroTokens.ink66),
            ],
            const SizedBox(width: 8),
            Builder(
              builder: (rowContext) => ShellIconButton(
                key: Key('bl-menu-${widget.index}'),
                icon: ShellIcon.ellipsis,
                tooltip: 'Edit, move or delete',
                onTap: () => _menu(rowContext),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _editor() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
          },
          child: Actions(
            actions: {
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  setState(() => _editing = false);
                  return null;
                },
              ),
            },
            child: HaroTextField(
              key: const Key('bl-edit-field'),
              controller: _ctl,
              autofocus: true,
              minLines: 2,
              maxLines: 8,
              fontSize: 14,
              padding: const EdgeInsets.all(10),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            HaroButton(
              key: const Key('bl-edit-save'),
              label: 'Save',
              variant: HaroButtonVariant.primary,
              onPressed: _save,
            ),
            const SizedBox(width: 8),
            HaroButton(
              key: const Key('bl-edit-cancel'),
              label: 'Cancel',
              onPressed: () => setState(() => _editing = false),
            ),
          ],
        ),
      ],
    ),
  );
}

class _Marker extends StatelessWidget {
  const _Marker({required this.item});

  final TodoItem item;

  @override
  Widget build(BuildContext context) {
    if (!item.done && item.seededWorkspace != null) {
      return SizedBox.square(
        dimension: 14,
        child: Center(child: stageSquare(item.stage)),
      );
    }
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: item.done ? HaroTokens.ink : HaroTokens.transparent,
        border: Border.all(color: HaroTokens.ink42),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: item.done
          ? ShellIconView(ShellIcon.check, size: 11, color: HaroTokens.bg)
          : null,
    );
  }
}

/// A seeded item's glyph mirrors its workspace's gate: green and red are gate meaning,
/// anything else is work in progress (hollow ink).
Widget stageSquare(String? stage) => switch (stage) {
  'green' => StatusSquare(size: 9, color: HaroTokens.gate, filled: true),
  'red' => StatusSquare(size: 9, color: HaroTokens.fail, filled: true),
  _ => StatusSquare(size: 9, color: HaroTokens.ink, filled: false),
};

class IssueDetailPane extends StatelessWidget {
  const IssueDetailPane({
    super.key,
    required this.issue,
    required this.detail,
    required this.onStart,
  });

  final IssueItem issue;

  /// Fetched separately for the discussion; null until it arrives or if it failed.
  final IssueDetailResponse? detail;
  final ValueChanged<IssueItem> onStart;

  @override
  Widget build(BuildContext context) {
    final seeded = issue.seededWorkspace != null;
    final body = (detail?.available ?? false)
        ? (detail!.body ?? issue.body)
        : issue.body;
    final comments = detail?.available ?? false
        ? detail!.comments
        : const <IssueComment>[];
    final url = issue.url;
    return _PaneFrame(
      caption: Wrap(
        spacing: 10,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '#${issue.number}',
            style: HaroText.mono(
              size: 11,
              tracking: 0,
              color: HaroTokens.ink42,
            ),
          ),
          HaroTag(issue.state),
          for (final l in issue.labels) _LabelChip(l),
        ],
      ),
      title: issue.title,
      action: HaroButton(
        key: const Key('bl-start'),
        label: seeded ? 'In progress' : 'Start as workspace',
        variant: HaroButtonVariant.primary,
        onPressed: seeded ? null : () => onStart(issue),
      ),
      children: [
        body.trim().isEmpty ? _prose('No description.') : _markdown(body),
        if (comments.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _readWidth),
            child: Padding(
              padding: const EdgeInsets.only(top: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MonoCaption(
                    '${comments.length} comment${comments.length == 1 ? '' : 's'}',
                  ),
                  for (final c in comments)
                    IssueCommentCard(
                      author: c.author,
                      createdAt: c.createdAt,
                      body: c.body,
                    ),
                ],
              ),
            ),
          ),
        if (url.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 18),
              child: HaroButton(
                label: 'Open on GitHub',
                trailing: ShellIcon.openExternal,
                variant: HaroButtonVariant.tertiary,
                padding: EdgeInsets.zero,
                onPressed: () => launchUrl(
                  Uri.parse(url),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _LabelChip extends StatelessWidget {
  const _LabelChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: HaroTokens.line14),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Text(
      label,
      style: HaroText.mono(size: 10.5, tracking: 0, color: HaroTokens.ink66),
    ),
  );
}

/// `2026-10-13` for [days] from today: what a snooze menu entry sends.
String _isoIn(int days) {
  final d = DateTime.now().add(Duration(days: days));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// A tag on an item: `#ui`, a hairline chip; pressing it filters the Backlog by that tag.
class _TagChip extends StatelessWidget {
  const _TagChip({super.key, required this.tag, this.onTap});

  final String tag;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: 'Filter by #$tag',
    semanticLabel: 'Tag $tag',
    builder: (context, hovered) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(
          color: hovered ? HaroTokens.line30 : HaroTokens.line14,
        ),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Text(
        '#$tag',
        style: HaroText.mono(
          size: 10.5,
          tracking: 0,
          color: hovered ? HaroTokens.ink : HaroTokens.ink66,
        ),
      ),
    ),
  );
}

/// The notes that link to the selected todo with `[[todo:id text]]`: the other half of a todo's
/// provenance. Quiet when there are none or the lookup fails.
class _LinkedNotes extends ConsumerStatefulWidget {
  const _LinkedNotes({
    super.key,
    required this.projectId,
    required this.id,
    required this.title,
  });

  final String projectId;
  final String id;
  final String title;

  @override
  ConsumerState<_LinkedNotes> createState() => _LinkedNotesState();
}

class _LinkedNotesState extends ConsumerState<_LinkedNotes> {
  List<NoteRef> _notes = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final n = await ref
          .read(haroApiProvider)
          .todoLinks(widget.projectId, widget.id);
      if (mounted) setState(() => _notes = n);
    } on HaroApiException {
      // Provenance is extra: the todo works without it.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_notes.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const Key('bl-linked-notes'),
      margin: const EdgeInsets.only(top: 22),
      padding: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MonoCaption('LINKED FROM NOTES', count: _notes.length),
          const SizedBox(height: 6),
          for (final n in _notes)
            HaroPressable(
              onTap: () => ref
                  .read(backlogJumpProvider.notifier)
                  .jump(
                    BacklogJump(
                      projectId: widget.projectId,
                      kind: 'note',
                      path: n.path,
                    ),
                  ),
              semanticLabel: 'Open ${n.title}',
              builder: (context, hovered) => Padding(
                key: Key('bl-linked-${n.path}'),
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Text(
                  n.title,
                  style: HaroText.ui(
                    size: 13.5,
                    color: hovered ? HaroTokens.ink : HaroTokens.ink86,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
