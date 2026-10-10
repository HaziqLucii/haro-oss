import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../../api/models/models.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/check_mark.dart';
import '../../../../widgets/haro_pressable.dart';
import '../code/code_file_list.dart';
import '../code/code_tokens.dart';
import '../code/diff_model.dart';
import '../code/diff_view.dart';
import '../code/proof.dart';
import '../../../open_in/open_in_notice.dart';
import 'ai_review_panel.dart';
import 'ai_review_state.dart';
import 'files_viewed.dart';
import 'review_dwell.dart';
import 'review_order.dart';

/// The longest an expanded file grows before its own diff scrolls.
const double _maxDiffHeight = 520;

/// "Files changed": one collapsible diff per changed file, each with a Viewed box. Collapsed
/// until opened; marking a file Viewed folds it. Proceeding to ship waits for every box.
class FilesChangedSection extends StatefulWidget {
  const FilesChangedSection({
    super.key,
    required this.files,
    required this.marks,
    required this.proof,
    required this.onToggleViewed,
    required this.dwell,
    required this.workspaceId,
    required this.baseShort,
    required this.onRunReview,
    required this.onOpenDiff,
    this.aiReview,
  });

  final List<DiffFile> files;
  final Map<String, String> marks;
  final ProofIndex? proof;

  /// Called with the seconds the file's diff has been open when its Viewed box is ticked.
  final void Function(DiffFile file, double seconds) onToggleViewed;
  final ReviewDwell dwell;
  final String workspaceId;
  final String baseShort;

  /// The Review with AI result. Null hides the button and the result (a merged branch has
  /// nothing left to review).
  final AiReviewState? aiReview;
  final VoidCallback onRunReview;
  final void Function(String file, int? line) onOpenDiff;

  @override
  State<FilesChangedSection> createState() => _FilesChangedSectionState();
}

class _FilesChangedSectionState extends State<FilesChangedSection>
    with WidgetsBindingObserver {
  final Set<String> _open = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  // A diff left open while the window is in the background is not time spent on it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      widget.dwell.update(
        state == AppLifecycleState.resumed ? _open : const {},
        DateTime.now(),
      );

  void _changeOpen(void Function() change) {
    setState(change);
    widget.dwell.update(_open, DateTime.now());
  }

  void _toggleOpen(String path) => _changeOpen(() {
    if (!_open.remove(path)) _open.add(path);
  });

  void _toggleViewed(DiffFile f, bool wasViewed) {
    final now = DateTime.now();
    widget.onToggleViewed(f, widget.dwell.seconds(f.path, now));
    if (wasViewed) {
      widget.dwell.reset(f.path, now);
    } else {
      _changeOpen(() => _open.remove(f.path));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.dwell.update(const {}, DateTime.now());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final files = reviewOrder(widget.files, widget.proof);
    if (files.isEmpty) return const SizedBox.shrink();
    final viewed = viewedPaths(files, widget.marks);
    final allOpen = files.every((f) => _open.contains(f.path));
    final ai = widget.aiReview;
    final placed = placeFindings(ai?.review, {for (final f in files) f.path});
    final mustFix = ai?.review is ReviewVerdict;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.only(bottom: 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: HaroTokens.line20)),
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 14,
            runSpacing: 8,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 14,
                runSpacing: 4,
                children: [
                  Text(
                    'FILES CHANGED',
                    style: HaroText.mono(
                      size: 11,
                      color: HaroTokens.ink,
                      tracking: .16,
                    ),
                  ),
                  Text(
                    '${viewed.length} / ${files.length} viewed',
                    key: const ValueKey('files-progress'),
                    style: HaroText.mono(
                      size: 11,
                      color: HaroTokens.ink42,
                      tracking: 0,
                    ),
                  ),
                ],
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 20,
                runSpacing: 8,
                children: [
                  HaroPressable(
                    key: const ValueKey('files-expand-all'),
                    onTap: () => _changeOpen(() {
                      if (allOpen) {
                        _open.clear();
                      } else {
                        _open.addAll(files.map((f) => f.path));
                      }
                    }),
                    builder: (context, hovered) => Text(
                      allOpen ? 'COLLAPSE ALL' : 'EXPAND ALL',
                      style: HaroText.mono(
                        size: 11,
                        color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                        tracking: .16,
                      ),
                    ),
                  ),
                  if (ai != null)
                    AiReviewButton(state: ai, onRun: widget.onRunReview),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (ai != null) ...[
          const OpenInNoticeText(
            source: 'verify-review',
            padding: EdgeInsets.only(bottom: 12),
          ),
          AiReviewSummary(
            workspaceId: widget.workspaceId,
            state: ai,
            baseShort: widget.baseShort,
            other: placed.other,
            onRun: widget.onRunReview,
            onOpenDiff: widget.onOpenDiff,
          ),
        ],
        for (final f in files)
          _FileCard(
            key: ValueKey('file-card-${f.path}'),
            file: f,
            proof: widget.proof,
            open: _open.contains(f.path),
            viewed: viewed.contains(f.path),
            findings: placed.byFile[f.path] ?? const [],
            mustFix: mustFix,
            workspaceId: widget.workspaceId,
            onOpenDiff: widget.onOpenDiff,
            onToggleOpen: () => _toggleOpen(f.path),
            onToggleViewed: () => _toggleViewed(f, viewed.contains(f.path)),
          ),
      ],
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    super.key,
    required this.file,
    required this.proof,
    required this.open,
    required this.viewed,
    required this.findings,
    required this.mustFix,
    required this.workspaceId,
    required this.onOpenDiff,
    required this.onToggleOpen,
    required this.onToggleViewed,
  });

  final DiffFile file;
  final ProofIndex? proof;
  final bool open;
  final bool viewed;
  final List<IndexedFinding> findings;
  final bool mustFix;
  final String workspaceId;
  final void Function(String file, int? line) onOpenDiff;
  final VoidCallback onToggleOpen;
  final VoidCallback onToggleViewed;

  String get _tag => switch (file.tag) {
    DiffFileTag.added => 'ADDED',
    DiffFileTag.deleted => 'DELETED',
    DiffFileTag.renamed => 'RENAMED',
    DiffFileTag.none => '',
  };

  @override
  Widget build(BuildContext context) {
    final path = file.path;
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? '' : path.substring(0, slash + 1);
    final name = slash < 0 ? path : path.substring(slash + 1);
    final vf = proof?[path];
    final square = proofSquareFor(file, proof);
    final dim = viewed ? HaroTokens.ink42 : HaroTokens.ink;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: HaroTokens.line14),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: HaroPressable(
                  key: ValueKey('file-head-$path'),
                  onTap: onToggleOpen,
                  builder: (context, hovered) => Container(
                    color: hovered ? HaroTokens.ink02 : HaroTokens.transparent,
                    padding: const EdgeInsets.fromLTRB(14, 13, 8, 13),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 14,
                          child: Text(
                            open ? '▾' : '▸',
                            style: HaroText.mono(
                              size: 11,
                              color: HaroTokens.ink42,
                              tracking: 0,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: dir,
                                  style: TextStyle(color: HaroTokens.ink42),
                                ),
                                TextSpan(
                                  text: name,
                                  style: TextStyle(color: dim),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HaroText.mono(size: 12.5, tracking: 0),
                          ),
                        ),
                        for (final label in [
                          if (_tag.isNotEmpty) _tag,
                          ?roleBadge(file),
                        ]) ...[
                          const SizedBox(width: 10),
                          Text(
                            label,
                            key: ValueKey('file-badge-$path-$label'),
                            style: HaroText.mono(
                              size: 10,
                              color: HaroTokens.ink42,
                              tracking: .14,
                            ),
                          ),
                        ],
                        const SizedBox(width: 12),
                        Counts(added: file.additions, removed: file.deletions),
                        if (vf != null) ...[
                          const SizedBox(width: 10),
                          ProofDot(square),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              _ViewedBox(
                key: ValueKey('viewed-$path'),
                viewed: viewed,
                onTap: onToggleViewed,
              ),
            ],
          ),
          for (final (i, item) in findings)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: AiFindingTile(
                key: ValueKey('ai-review-item-$i'),
                index: i,
                workspaceId: workspaceId,
                item: item,
                mustFix: mustFix,
                onOpenDiff: onOpenDiff,
              ),
            ),
          if (open)
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: HaroTokens.line12)),
              ),
              child: _FileDiff(file: file, vf: vf),
            ),
        ],
      ),
    );
  }
}

class _FileDiff extends StatelessWidget {
  const _FileDiff({required this.file, required this.vf});

  final DiffFile file;
  final VerifiedFile? vf;

  @override
  Widget build(BuildContext context) {
    final rows = file.isBinary ? 1 : buildDiffRows(file, vf).length;
    final height = math.min(
      _maxDiffHeight,
      math.max(rows, 1) * CodeTokens.diffRowHeight + 16,
    );
    return SizedBox(
      height: height,
      child: DiffView(file: file, proof: vf),
    );
  }
}

class _ViewedBox extends StatelessWidget {
  const _ViewedBox({super.key, required this.viewed, required this.onTap});

  final bool viewed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: viewed ? 'Viewed' : 'Mark as viewed',
    builder: (context, hovered) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 13, 14, 13),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: viewed ? HaroTokens.ink : HaroTokens.transparent,
              border: Border.all(
                color: viewed || hovered ? HaroTokens.ink : HaroTokens.ink42,
              ),
              borderRadius: BorderRadius.circular(HaroTokens.radius),
            ),
            child: viewed
                ? const CheckMark(color: HaroTokens.bg, size: 12)
                : null,
          ),
          const SizedBox(width: 8),
          Text(
            'VIEWED',
            style: HaroText.mono(
              size: 10.5,
              color: viewed || hovered ? HaroTokens.ink : HaroTokens.ink66,
              tracking: .14,
            ),
          ),
        ],
      ),
    ),
  );
}
