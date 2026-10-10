import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/models/models.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_menu.dart';
import '../../widgets/haro_text_field.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/status_square.dart';
import '../new_workspace/creation_widgets.dart';
import '../open_in/open_in_launcher.dart';
import '../open_in/open_in_notice.dart';
import 'backlog_model.dart';
import 'inline_markdown.dart';

const _readWidth = 640.0;

/// The "edit in your editor" link under a backlog file's title. The file sits in the project
/// root, so it goes through the project open route, not a workspace's.
class _EditInEditorLink extends ConsumerWidget {
  const _EditInEditorLink({required this.projectId, required this.path});

  final String projectId;
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Tooltip(
    message: 'Open $path in your preferred editor',
    child: HaroPressable(
      onTap: () => ref
          .read(openInLauncherProvider)
          .launch(
            context,
            projectId: projectId,
            source: 'project:$path',
            path: path,
          ),
      semanticLabel: 'Edit $path in your editor',
      builder: (context, hovered) => Text(
        'edit in your editor ↗',
        key: const Key('bl-edit-link'),
        style:
            HaroText.mono(
              size: 11,
              tracking: 0,
              color: hovered ? HaroTokens.ink : HaroTokens.ink42,
            ).copyWith(
              decoration: TextDecoration.underline,
              decorationColor: HaroTokens.line20,
            ),
      ),
    ),
  );
}

class _PaneFrame extends StatelessWidget {
  const _PaneFrame({
    required this.caption,
    required this.title,
    required this.action,
    required this.children,
  });

  final Widget caption;
  final String title;
  final Widget action;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
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
              ],
            ),
          ),
          const SizedBox(width: 20),
          action,
        ],
      ),
      ...children,
    ],
  );
}

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
          Text(
            '${file.path} · ${itemsDone(file)} of ${file.items.length} done',
            style: HaroText.mono(
              size: 11,
              tracking: 0,
              color: HaroTokens.ink42,
            ),
          ),
          _EditInEditorLink(projectId: widget.projectId, path: file.path),
          HaroPressable(
            onTap: widget.actions.rename,
            semanticLabel: 'Rename ${file.path}',
            builder: (context, hovered) => Text(
              'rename',
              key: const Key('bl-rename'),
              style:
                  HaroText.mono(
                    size: 11,
                    tracking: 0,
                    color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                  ).copyWith(
                    decoration: TextDecoration.underline,
                    decorationColor: HaroTokens.line20,
                  ),
            ),
          ),
          OpenInNoticeText(source: 'project:${file.path}'),
        ],
      ),
      title: fileTitle(file),
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

  void _menu(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(box.size.width, box.size.height));
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
        const HaroMenuItem.separator(),
        HaroMenuItem(
          label: widget.item.children == 0
              ? 'Delete'
              : 'Delete with ${widget.item.children} sub-item${widget.item.children == 1 ? '' : 's'}',
          destructive: true,
          onSelected: () => a.delete(widget.index, widget.item),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (_editing) return _editor();
    final seeded = !item.done && item.seededWorkspace != null;
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
          border: const Border(bottom: BorderSide(color: HaroTokens.line08)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HaroPressable(
              key: Key('bl-toggle-${widget.index}'),
              onTap: () => widget.actions.toggle(widget.index, item),
              semanticLabel: item.done ? 'Mark not done' : 'Mark done',
              builder: (context, _) => Padding(
                padding: const EdgeInsets.fromLTRB(0, 2, 12, 2),
                child: _Marker(item: item),
              ),
            ),
            Expanded(
              child: Text.rich(
                inlineMarkdown(
                  item.text,
                  HaroText.ui(
                    color: item.done ? HaroTokens.ink42 : HaroTokens.ink86,
                    height: 1.4,
                  ),
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (seeded) ...[
              const SizedBox(width: 12),
              const MonoCaption('In progress'),
            ] else if (widget.isTarget) ...[
              const SizedBox(width: 12),
              const MonoCaption('Starts here', color: HaroTokens.ink66),
            ],
            const SizedBox(width: 8),
            Builder(
              builder: (rowContext) => HaroPressable(
                key: Key('bl-menu-${widget.index}'),
                onTap: () => _menu(rowContext),
                tooltip: 'Edit, move or delete',
                semanticLabel: 'Item actions',
                builder: (context, h) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '···',
                    style: HaroText.mono(
                      size: 12,
                      color: h
                          ? HaroTokens.ink
                          : (hovered ? HaroTokens.ink66 : HaroTokens.ink42),
                    ),
                  ),
                ),
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
          ? Text(
              '✓',
              style: HaroText.ui(size: 10, color: HaroTokens.bg, height: 1),
            )
          : null,
    );
  }
}

/// A seeded item's glyph mirrors its workspace's gate: green and red are gate meaning,
/// anything else is work in progress (hollow ink).
Widget stageSquare(String? stage) => switch (stage) {
  'green' => const StatusSquare(size: 9, color: HaroTokens.gate, filled: true),
  'red' => const StatusSquare(size: 9, color: HaroTokens.fail, filled: true),
  _ => const StatusSquare(size: 9, color: HaroTokens.ink, filled: false),
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
            '#${issue.number} · ${issue.state}',
            style: HaroText.mono(
              size: 11,
              tracking: 0,
              color: HaroTokens.ink42,
            ),
          ),
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
        _prose(body.isEmpty ? 'No description.' : body),
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
                  for (final c in comments) _Comment(c),
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
                label: 'Open on GitHub ↗',
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

class _Comment extends StatelessWidget {
  const _Comment(this.comment);

  final IssueComment comment;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.only(top: 12),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: HaroTokens.line08)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            comment.author.isEmpty ? 'someone' : comment.author,
            if (comment.createdAt.isNotEmpty) comment.createdAt,
          ].join(' · '),
          style: HaroText.mono(size: 11, tracking: 0, color: HaroTokens.ink42),
        ),
        const SizedBox(height: 6),
        Text(
          comment.body,
          style: HaroText.ui(size: 14, color: HaroTokens.ink86, height: 1.5),
        ),
      ],
    ),
  );
}
