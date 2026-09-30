import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/models/models.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/status_square.dart';
import '../new_workspace/creation_widgets.dart';
import 'backlog_model.dart';
import 'inline_markdown.dart';

const _readWidth = 640.0;

/// Tooltip for the disabled editor link. The todo file lives in the project root, and the
/// open endpoint only reaches a workspace's worktree copy, which is not the file being shown.
const editInEditorHint =
    'Open in… reaches workspace worktrees, not the project root';

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

class TodoDetail extends StatelessWidget {
  const TodoDetail({
    super.key,
    required this.file,
    required this.pickedKey,
    required this.onPick,
    required this.onStart,
  });

  final TodoFile file;
  final String? pickedKey;
  final ValueChanged<String> onPick;
  final ValueChanged<TodoItem> onStart;

  TodoItem? get _target {
    for (final i in file.items) {
      if (i.seedKey == pickedKey && isStartable(i)) return i;
    }
    return nextStartable(file);
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    final summary = fileSummary(file);
    final rows = <Widget>[];
    String? heading;
    for (final item in file.items) {
      if (item.heading != null && item.heading != heading) {
        heading = item.heading;
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 2),
            child: MonoCaption(stripInlineMarkdown(heading!)),
          ),
        );
      }
      rows.add(
        _ChecklistRow(
          item: item,
          isTarget: identical(item, target),
          onTap: isStartable(item) ? () => onPick(item.seedKey!) : null,
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
          Tooltip(
            message: editInEditorHint,
            child: Text(
              'edit in your editor ↗',
              key: const Key('bl-edit-link'),
              style:
                  HaroText.mono(
                    size: 11,
                    tracking: 0,
                    color: HaroTokens.ink42,
                  ).copyWith(
                    decoration: TextDecoration.underline,
                    decorationColor: HaroTokens.line20,
                  ),
            ),
          ),
        ],
      ),
      title: fileTitle(file),
      action: HaroButton(
        key: const Key('bl-start'),
        label: 'Start as workspace',
        variant: HaroButtonVariant.primary,
        onPressed: target == null ? null : () => onStart(target),
      ),
      children: [
        if (summary.isNotEmpty) _prose(summary),
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

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({
    required this.item,
    required this.isTarget,
    required this.onTap,
  });

  final TodoItem item;
  final bool isTarget;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final seeded = !item.done && item.seededWorkspace != null;
    return HaroPressable(
      onTap: onTap,
      semanticLabel: stripInlineMarkdown(item.text),
      builder: (context, hovered) => AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isTarget || hovered
              ? HaroTokens.ink02
              : HaroTokens.transparent,
          border: const Border(bottom: BorderSide(color: HaroTokens.line08)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _Marker(item: item),
            ),
            const SizedBox(width: 12),
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
            ] else if (isTarget) ...[
              const SizedBox(width: 12),
              const MonoCaption('Starts here', color: HaroTokens.ink66),
            ],
          ],
        ),
      ),
    );
  }
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
