import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api/models/models.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/shell_icons.dart';
import '../new_workspace/creation_widgets.dart';
import 'backlog_model.dart';
import 'backlog_query.dart';

/// The todos matching the query, across every file, one row each (a search result list). Pressing
/// a row opens that item in its file.
class TodoResults extends StatelessWidget {
  const TodoResults({
    super.key,
    required this.hits,
    required this.onOpen,
    required this.onTag,
  });

  final List<TodoHit> hits;
  final ValueChanged<TodoHit> onOpen;
  final ValueChanged<String> onTag;

  @override
  Widget build(BuildContext context) {
    if (hits.isEmpty) {
      return Center(
        child: Text(
          'Nothing matches.',
          key: const Key('bl-results-empty'),
          style: HaroText.ui(size: 14, color: HaroTokens.ink42),
        ),
      );
    }
    return ListView(
      key: const Key('bl-results'),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      children: [
        for (final h in hits)
          HaroPressable(
            key: Key('bl-hit-${h.file.path}#${h.index}'),
            onTap: () => onOpen(h),
            semanticLabel: h.item.text,
            builder: (context, hovered) => Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              decoration: BoxDecoration(
                color: hovered ? HaroTokens.ink02 : HaroTokens.transparent,
                border: Border(bottom: BorderSide(color: HaroTokens.line08)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          h.item.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: HaroText.ui(
                            size: 14,
                            color: h.item.done
                                ? HaroTokens.ink42
                                : HaroTokens.ink86,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Wrap(
                          spacing: 8,
                          children: [
                            MonoCaption(h.file.path),
                            for (final t in h.item.tags)
                              GestureDetector(
                                onTap: () => onTag(t),
                                child: MonoCaption('#$t'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  MonoCaption(_stageLabel(h.item)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _stageLabel(TodoItem item) {
  if (item.done) return 'done';
  if (item.blocked) return 'blocked';
  return item.stage ?? 'ready';
}

/// Todos by stage, from the stages haro already derives from each item's workspace: Ready, Blocked
/// (a dependency is not done), Queued, Running, Red, Green, Shipped. There is no dragging: a
/// card moves because its workspace does. A ready card has Start.
class TodoBoard extends StatelessWidget {
  const TodoBoard({
    super.key,
    required this.files,
    required this.query,
    required this.onOpen,
    required this.onStart,
    required this.onTag,
  });

  final List<TodoFile> files;
  final TodoQuery query;
  final ValueChanged<TodoHit> onOpen;
  final ValueChanged<TodoHit> onStart;
  final ValueChanged<String> onTag;

  @override
  Widget build(BuildContext context) {
    final hits = filterTodos(files, query);
    final byColumn = <String, List<TodoHit>>{
      for (final c in boardColumns) c.$1: [],
    };
    for (final h in hits) {
      final col = boardColumnOf(h.item, query);
      if (col != null) byColumn[col]?.add(h);
    }
    // The column titles stay put and the cards of every column scroll together, so a long
    // column and a short one line up; the whole board moves sideways when the window is narrow.
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        key: const Key('bl-board'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 16, 4, 0),
        child: SizedBox(
          height: math.max(0, box.maxHeight - 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (final (id, label) in boardColumns)
                    _ColumnHead(
                      id: id,
                      label: label,
                      count: byColumn[id]!.length,
                    ),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  key: const Key('bl-board-body'),
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (id, _) in boardColumns)
                        _Column(
                          id: id,
                          hits: byColumn[id]!,
                          onOpen: onOpen,
                          onStart: onStart,
                          onTag: onTag,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColumnHead extends StatelessWidget {
  const _ColumnHead({
    required this.id,
    required this.label,
    required this.count,
  });

  final String id;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) => Container(
    key: Key('bl-col-$id'),
    width: _columnWidth,
    margin: const EdgeInsets.only(right: 12),
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
    child: MonoCaption(label, count: count),
  );
}

const _columnWidth = 236.0;

class _Column extends StatelessWidget {
  const _Column({
    required this.id,
    required this.hits,
    required this.onOpen,
    required this.onStart,
    required this.onTag,
  });

  final String id;
  final List<TodoHit> hits;
  final ValueChanged<TodoHit> onOpen;
  final ValueChanged<TodoHit> onStart;
  final ValueChanged<String> onTag;

  @override
  Widget build(BuildContext context) => Container(
    key: Key('bl-col-list-$id'),
    width: _columnWidth,
    margin: const EdgeInsets.only(right: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final h in hits)
              Container(
                key: Key('bl-card-${h.file.path}#${h.index}'),
                margin: const EdgeInsets.only(bottom: 8),
                child: HaroPressable(
                  onTap: () => onOpen(h),
                  semanticLabel: h.item.text,
                  builder: (context, hovered) => Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: HaroTokens.panel,
                      border: Border.all(
                        color: hovered ? HaroTokens.line30 : HaroTokens.line12,
                      ),
                      borderRadius: BorderRadius.circular(HaroTokens.radius),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          h.item.text,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: HaroText.ui(
                            size: 13.5,
                            color: HaroTokens.ink86,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            MonoCaption(h.file.path.split('/').last),
                            for (final t in h.item.tags)
                              GestureDetector(
                                onTap: () => onTag(t),
                                child: MonoCaption('#$t'),
                              ),
                          ],
                        ),
                        if (id == 'ready' && isStartable(h.item)) ...[
                          const SizedBox(height: 8),
                          HaroButton(
                            key: Key('bl-card-start-${h.file.path}#${h.index}'),
                            label: 'Start as workspace',
                            leading: ShellIcon.play,
                            height: 26,
                            fontSize: 12,
                            padding: const EdgeInsets.symmetric(horizontal: 9),
                            onPressed: () => onStart(h),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}
