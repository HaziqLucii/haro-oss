import 'package:flutter/material.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../overlays/overlay.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_pressable.dart';
import '../new_workspace/creation_widgets.dart';

/// The weekly review: what to look at, all computed from the repo and the notes (nothing is
/// scored or guessed). Pressing a row opens the todo or the note it names.
Future<void> showReview(
  BuildContext context, {
  required HaroApi api,
  required String projectId,
  required void Function(String file, int index) onTodo,
  required ValueChanged<String> onNote,
}) => showHaroOverlay<void>(
  context,
  width: 720,
  height: 640,
  child: ReviewOverlay(
    api: api,
    projectId: projectId,
    onTodo: onTodo,
    onNote: onNote,
  ),
);

class ReviewOverlay extends StatefulWidget {
  const ReviewOverlay({
    super.key,
    required this.api,
    required this.projectId,
    required this.onTodo,
    required this.onNote,
  });

  final HaroApi api;
  final String projectId;
  final void Function(String file, int index) onTodo;
  final ValueChanged<String> onNote;

  @override
  State<ReviewOverlay> createState() => _ReviewOverlayState();
}

class _ReviewOverlayState extends State<ReviewOverlay> {
  ReviewData? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.getReview(widget.projectId);
      if (mounted) setState(() => _data = r);
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _todo(ReviewTodo t) {
    closeHaroOverlay<void>(context);
    widget.onTodo(t.file, t.index);
  }

  void _note(String path) {
    closeHaroOverlay<void>(context);
    widget.onNote(path);
  }

  Widget _section(
    String key,
    String title,
    int? count,
    String? hint,
    List<Widget> rows,
  ) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      key: Key(key),
      margin: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MonoCaption(title, count: count),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                hint,
                style: HaroText.ui(size: 12.5, color: HaroTokens.ink42),
              ),
            ),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }

  Widget _row(String key, String text, String meta, VoidCallback onTap) =>
      HaroPressable(
        key: Key(key),
        onTap: onTap,
        semanticLabel: text,
        builder: (context, hovered) => Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          color: hovered ? HaroTokens.ink02 : HaroTokens.transparent,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.ui(size: 14, color: HaroTokens.ink86),
                ),
              ),
              const SizedBox(width: 12),
              MonoCaption(meta),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Review', style: HaroText.ui(size: 24, weight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(
            'From the repo and your notes, not from a guess.',
            style: HaroText.ui(size: 13, color: HaroTokens.ink42),
          ),
          Expanded(
            child: _error != null
                ? Text(_error!, style: HaroText.ui(color: HaroTokens.fail))
                : d == null
                ? Center(
                    child: Text(
                      'Reading…',
                      style: HaroText.ui(size: 14, color: HaroTokens.ink42),
                    ),
                  )
                : ListView(
                    children: [
                      _section(
                        'review-stale',
                        'STALE',
                        d.stale.length,
                        'Open, in files nobody has touched for ${d.staleDays} days.',
                        [
                          for (final t in d.stale)
                            _row(
                              'review-stale-${t.file}#${t.index}',
                              t.text,
                              '${t.days} days',
                              () => _todo(t),
                            ),
                        ],
                      ),
                      _section(
                        'review-unstarted',
                        'READY, NOT STARTED',
                        d.notStarted.length,
                        'Open and nothing blocks them, and no workspace was started from them.',
                        [
                          for (final t in d.notStarted)
                            _row(
                              'review-unstarted-${t.file}#${t.index}',
                              t.text,
                              t.file.split('/').last,
                              () => _todo(t),
                            ),
                        ],
                      ),
                      _section(
                        'review-unlinked',
                        'NOTES THAT LINK NOWHERE',
                        d.unlinkedNotes.length,
                        'No note links to them and they link to none.',
                        [
                          for (final n in d.unlinkedNotes)
                            _row(
                              'review-unlinked-${n.path}',
                              n.title,
                              n.path,
                              () => _note(n.path),
                            ),
                        ],
                      ),
                      if (d.orphaned > 0)
                        _section(
                          'review-orphaned',
                          'WORKSPACES WITHOUT THEIR TODO',
                          d.orphaned,
                          'Started from a todo that was removed or reworded outside haro.',
                          [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text(
                                '${d.orphaned} workspace${d.orphaned == 1 ? '' : 's'}',
                                key: const Key('review-orphaned-count'),
                                style: HaroText.ui(
                                  size: 13.5,
                                  color: HaroTokens.ink66,
                                ),
                              ),
                            ),
                          ],
                        ),
                      if (d.resurface != null)
                        _section(
                          'review-resurface',
                          'AN OLD NOTE',
                          null,
                          'Untouched for ${d.resurface!.days} days.',
                          [
                            _row(
                              'review-resurface-note',
                              d.resurface!.title,
                              d.resurface!.path,
                              () => _note(d.resurface!.path),
                            ),
                          ],
                        ),
                      if (d.noteTasks > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 22),
                          child: Text(
                            '${d.noteTasks} open task${d.noteTasks == 1 ? '' : 's'} sit in your notes (Notes > Tasks).',
                            key: const Key('review-tasks'),
                            style: HaroText.ui(
                              size: 13,
                              color: HaroTokens.ink66,
                            ),
                          ),
                        ),
                      if (d.stale.isEmpty &&
                          d.notStarted.isEmpty &&
                          d.unlinkedNotes.isEmpty &&
                          d.orphaned == 0 &&
                          d.resurface == null)
                        Padding(
                          padding: const EdgeInsets.only(top: 22),
                          child: Text(
                            'Nothing to look at.',
                            key: const Key('review-empty'),
                            style: HaroText.ui(
                              size: 14,
                              color: HaroTokens.ink42,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
