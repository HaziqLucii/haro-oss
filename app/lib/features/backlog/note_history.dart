import 'package:flutter/material.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../overlays/overlay.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../new_workspace/creation_widgets.dart';
import 'notes_model.dart';

/// A note's git history: the commits that touched it, the diff of the one you pick, and Restore,
/// which hands that version's text back to the note (the editor saves it like any edit, so the
/// restore is itself one more step in the history).
Future<String?> showNoteHistory(
  BuildContext context, {
  required HaroApi api,
  required String projectId,
  required String path,
}) => showHaroOverlay<String>(
  context,
  width: 880,
  height: 600,
  child: NoteHistory(api: api, projectId: projectId, path: path),
);

class NoteHistory extends StatefulWidget {
  const NoteHistory({
    super.key,
    required this.api,
    required this.projectId,
    required this.path,
  });

  final HaroApi api;
  final String projectId;
  final String path;

  @override
  State<NoteHistory> createState() => _NoteHistoryState();
}

class _NoteHistoryState extends State<NoteHistory> {
  List<NoteCommit>? _commits;
  NoteRevision? _rev;
  String? _sha;
  String? _error;
  String? _revError;
  bool _confirm = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await widget.api.noteHistory(widget.projectId, widget.path);
      if (!mounted) return;
      setState(() => _commits = c);
      if (c.isNotEmpty) await _pick(c.first.sha);
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _pick(String sha) async {
    setState(() {
      _sha = sha;
      _rev = null;
      _revError = null;
      _confirm = false;
    });
    try {
      final r = await widget.api.noteRevision(
        widget.projectId,
        widget.path,
        sha,
      );
      if (mounted && _sha == sha) setState(() => _rev = r);
    } on HaroApiException catch (e) {
      if (mounted && _sha == sha) setState(() => _revError = e.message);
    }
  }

  Color _lineColor(String l) {
    if (l.startsWith('+') && !l.startsWith('+++')) return HaroTokens.gate;
    if (l.startsWith('-') && !l.startsWith('---')) return HaroTokens.fail;
    return HaroTokens.ink66;
  }

  @override
  Widget build(BuildContext context) {
    final commits = _commits;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'History',
                style: HaroText.ui(size: 22, weight: FontWeight.w500),
              ),
              const SizedBox(width: 12),
              Expanded(child: MonoCaption('.haro/notes/${widget.path}')),
              HaroButton(
                key: const Key('history-restore'),
                label: _confirm ? 'Replace the note' : 'Restore this version',
                onPressed: _rev == null
                    ? null
                    : _confirm
                    ? () => closeHaroOverlay<String>(context, _rev!.content)
                    : () => setState(() => _confirm = true),
              ),
            ],
          ),
          if (_confirm)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Replaces the note as it is now. Edits that were never committed are gone.',
                key: const Key('history-confirm'),
                style: HaroText.ui(size: 12.5, color: HaroTokens.warn),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: _error != null
                ? Text(
                    _error!,
                    style: HaroText.ui(size: 13, color: HaroTokens.fail),
                  )
                : commits == null
                ? const SizedBox.shrink()
                : commits.isEmpty
                ? Text(
                    'Nothing committed for this note yet. History starts at its first commit.',
                    key: const Key('history-empty'),
                    style: HaroText.ui(size: 14, color: HaroTokens.ink42),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 260,
                        child: ListView(
                          children: [
                            for (final c in commits)
                              HaroPressable(
                                key: Key('history-${c.sha}'),
                                onTap: () => _pick(c.sha),
                                semanticLabel: c.subject,
                                builder: (context, hovered) => Container(
                                  padding: const EdgeInsets.all(8),
                                  color: c.sha == _sha || hovered
                                      ? HaroTokens.raised
                                      : HaroTokens.transparent,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        c.subject,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: HaroText.ui(
                                          size: 13,
                                          color: HaroTokens.ink86,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Wrap(
                                        spacing: 10,
                                        children: [
                                          MonoCaption(c.author),
                                          MonoCaption(
                                            relativeTime(
                                              c.date.toDouble(),
                                              DateTime.now(),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: HaroTokens.line12),
                            borderRadius: BorderRadius.circular(
                              HaroTokens.radius,
                            ),
                          ),
                          child: _revError != null
                              ? Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    _revError!,
                                    key: const Key('history-rev-error'),
                                    style: HaroText.ui(
                                      size: 13,
                                      color: HaroTokens.fail,
                                    ),
                                  ),
                                )
                              : _rev == null
                              ? const SizedBox.shrink()
                              : SingleChildScrollView(
                                  padding: const EdgeInsets.all(12),
                                  child: SelectableText.rich(
                                    key: const Key('history-diff'),
                                    TextSpan(
                                      children: [
                                        for (final l in _rev!.diff.split('\n'))
                                          TextSpan(
                                            text: '$l\n',
                                            style: HaroText.mono(
                                              size: 12,
                                              tracking: 0,
                                              color: _lineColor(l),
                                              height: 1.5,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
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
