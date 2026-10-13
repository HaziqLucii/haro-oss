import 'package:flutter/material.dart';

import '../../api/models/models.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_menu.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_segmented.dart';
import '../../widgets/haro_tag.dart';
import '../../widgets/haro_text_field.dart';
import '../../widgets/shell_icons.dart';

/// The strip above the todo files: a filter with operators (`tag:ui stage:red is:ready`), the saved
/// views, List or Board, and the two working pages: sorting the inbox and the weekly review.
class TodoToolbar extends StatelessWidget {
  const TodoToolbar({
    super.key,
    required this.query,
    required this.focus,
    required this.onChanged,
    required this.views,
    required this.layout,
    required this.onLayout,
    required this.onPickView,
    required this.onSaveView,
    required this.onDeleteView,
    required this.onSortInbox,
    required this.onReview,
    required this.onInsert,
    this.inbox = 0,
  });

  final TextEditingController query;
  final FocusNode focus;
  final ValueChanged<String> onChanged;
  final List<BacklogView> views;
  final String layout;
  final ValueChanged<String> onLayout;
  final ValueChanged<BacklogView> onPickView;
  final VoidCallback onSaveView;
  final ValueChanged<BacklogView> onDeleteView;
  final VoidCallback onSortInbox;
  final VoidCallback onReview;

  /// A filter word picked from the help menu (`tag:`, `is:ready`...), to add to the field.
  final ValueChanged<String> onInsert;

  /// Open items in the inbox file: the number on the Sort inbox button.
  final int inbox;

  void _viewsMenu(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    showHaroMenu(
      context,
      position: at,
      items: [
        if (views.isEmpty) const HaroMenuItem.heading('No saved views yet'),
        for (final v in views)
          HaroMenuItem(
            label: v.name,
            hint: v.layout == 'board' ? 'board' : null,
            onSelected: () => onPickView(v),
          ),
        const HaroMenuItem.separator(),
        HaroMenuItem(label: 'Save this view…', onSelected: onSaveView),
        if (views.isNotEmpty) ...[
          const HaroMenuItem.separator(),
          const HaroMenuItem.heading('Delete a view'),
          for (final v in views)
            HaroMenuItem(
              label: v.name,
              destructive: true,
              onSelected: () => onDeleteView(v),
            ),
        ],
      ],
    );
  }

  void _helpMenu(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(box.size.width, box.size.height));
    const words = [
      ('tag:', 'a tag'),
      ('stage:', 'running, red'),
      ('is:ready', 'startable'),
      ('is:blocked', 'waiting'),
      ('is:done', 'ticked'),
      ('in:notes', 'notes only'),
      ('path:', 'one file'),
      ('-done', 'leave out'),
    ];

    showHaroMenu(
      context,
      position: at,
      items: [
        const HaroMenuItem.heading('Filter words'),
        for (final (w, d) in words)
          HaroMenuItem(label: w, hint: d, onSelected: () => onInsert(w)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line12)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              HaroTextField(
                key: const Key('bl-find'),
                controller: query,
                focusNode: focus,
                height: 32,
                fontSize: 13,
                padding: const EdgeInsets.only(left: 34, right: 10),
                hintText: 'Filter todos',
                onChanged: onChanged,
              ),
              Positioned(
                left: 11,
                child: IgnorePointer(
                  child: ShellIconView(
                    ShellIcon.search,
                    size: 15,
                    color: HaroTokens.ink42,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        Builder(
          builder: (ctx) => ShellIconButton(
            key: const Key('bl-find-help'),
            icon: ShellIcon.help,
            tooltip: 'Filter words: tag:, stage:, is:ready',
            onTap: () => _helpMenu(ctx),
          ),
        ),
        const SizedBox(width: 8),
        Builder(
          builder: (context) => HaroPressable(
            key: const Key('bl-views'),
            onTap: () => _viewsMenu(context),
            tooltip: 'Saved views',
            semanticLabel: 'Saved views',
            builder: (context, hovered) => Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                border: Border.all(
                  color: hovered ? HaroTokens.line30 : HaroTokens.line14,
                ),
                borderRadius: BorderRadius.circular(HaroTokens.buttonRadius),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Views',
                    style: HaroText.ui(
                      size: 13,
                      color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                    ),
                  ),
                  if (views.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    HaroTag('${views.length}'),
                  ],
                  const SizedBox(width: 6),
                  ShellIconView(
                    ShellIcon.chevronDown,
                    size: 13,
                    color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        HaroSegmented<String>(
          keyPrefix: 'bl-layout',
          height: 32,
          selected: layout,
          onChanged: onLayout,
          segments: const [
            HaroSegment('list', 'List'),
            HaroSegment('board', 'Board'),
          ],
        ),
        const SizedBox(width: 8),
        HaroButton(
          key: const Key('bl-sort-inbox'),
          label: 'Sort inbox',
          count: inbox > 0 ? inbox : null,
          height: 32,
          fontSize: 13,
          tooltip: 'Go through the inbox one item at a time, from the keyboard',
          onPressed: onSortInbox,
        ),
        const SizedBox(width: 8),
        HaroButton(
          key: const Key('bl-review'),
          label: 'Review',
          height: 32,
          fontSize: 13,
          tooltip:
              'What is stale, unstarted or unlinked: computed from the repo',
          onPressed: onReview,
        ),
      ],
    ),
  );
}
