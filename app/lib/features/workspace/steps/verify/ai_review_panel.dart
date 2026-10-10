import 'package:flutter/widgets.dart';

import '../../../../api/models/models.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../open_in/open_in_button.dart';
import 'ai_review_state.dart';

const aiReviewHint = 'Advisory. Never blocks the merge.';

/// One located remark and its position in the review's item list (the keys use it).
typedef IndexedFinding = (int, AiReviewItem);

/// Splits the review's items into those that sit under a changed file and the rest (no file,
/// or a file this diff does not contain). Nothing here can be green: the review is a reader's
/// opinion, not a gate signal.
({Map<String, List<IndexedFinding>> byFile, List<IndexedFinding> other})
placeFindings(AiReview? review, Set<String> changedPaths) {
  final byFile = <String, List<IndexedFinding>>{};
  final other = <IndexedFinding>[];
  if (review == null || review.error != null || review.nothingToReview) {
    return (byFile: byFile, other: other);
  }
  for (final (i, item) in review.items.indexed) {
    final path = item.file.startsWith('./')
        ? item.file.substring(2)
        : item.file;
    if (changedPaths.contains(path)) {
      (byFile[path] ??= []).add((i, item));
    } else {
      other.add((i, item));
    }
  }
  return (byFile: byFile, other: other);
}

/// `Review with AI`: a small bone control button (the review is never the screen's primary). The result is [AiReviewSummary] plus the findings
/// under their files.
class AiReviewButton extends StatelessWidget {
  const AiReviewButton({super.key, required this.state, required this.onRun});

  final AiReviewState state;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) => IntrinsicWidth(
    child: HaroButton(
      key: const ValueKey('ai-review-run'),
      label: state.busy ? 'Reviewing…' : 'Review with AI',
      tooltip: aiReviewHint,
      variant: HaroButtonVariant.control,
      height: 28,
      fontSize: 12.5,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      onPressed: state.busy ? null : onRun,
    ),
  );
}

/// What the review said as a whole: the failure, the empty state, or the verdict line, the
/// summary, the findings that sit under no changed file, and the notes. Nothing when no
/// review has run.
class AiReviewSummary extends StatelessWidget {
  const AiReviewSummary({
    super.key,
    required this.workspaceId,
    required this.state,
    required this.baseShort,
    required this.other,
    required this.onRun,
    required this.onOpenDiff,
  });

  final String workspaceId;
  final AiReviewState state;
  final String baseShort;
  final List<IndexedFinding> other;
  final VoidCallback onRun;
  final void Function(String file, int? line) onOpenDiff;

  @override
  Widget build(BuildContext context) {
    final review = state.review;
    if (state.failure != null) {
      return _Failure(
        message: state.failure!,
        onRetry: state.busy ? null : onRun,
      );
    }
    if (review == null) return const SizedBox.shrink();
    if (review.error != null) {
      return _Failure(
        message: review.error!,
        onRetry: state.busy ? null : onRun,
      );
    }
    if (review.nothingToReview) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Text(
          'Nothing to review: this branch matches $baseShort.',
          key: const ValueKey('ai-review-empty'),
          style: HaroText.ui(size: 14, color: HaroTokens.ink66),
        ),
      );
    }
    final r = review;
    final mono = HaroText.mono(
      size: 11,
      color: HaroTokens.ink42,
      tracking: .08,
    );
    final items = r.items;
    final failed = r is ReviewVerdict && !r.pass;
    return Container(
      key: const ValueKey('ai-review-result'),
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      decoration: BoxDecoration(
        border: Border.all(color: HaroTokens.line12),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 14,
            runSpacing: 4,
            children: [
              if (r is ReviewVerdict) ...[
                Text(
                  r.pass ? 'PASS' : 'FAIL',
                  key: const ValueKey('ai-review-word'),
                  style: HaroText.mono(size: 13, color: HaroTokens.ink),
                ),
                if (failed)
                  Text(
                    '${r.mustFix.length} MUST FIX',
                    key: const ValueKey('ai-review-mustfix-count'),
                    style: HaroText.mono(size: 11, color: HaroTokens.fail),
                  ),
              ] else
                Text(
                  '${items.length} ${items.length == 1 ? 'FINDING' : 'FINDINGS'}',
                  key: const ValueKey('ai-review-count'),
                  style: HaroText.mono(size: 11, color: HaroTokens.ink66),
                ),
              Text(_meta(r).toUpperCase(), style: mono),
            ],
          ),
          if (r.summary.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              r.summary,
              key: const ValueKey('ai-review-summary'),
              style: HaroText.ui(
                size: 14,
                color: HaroTokens.ink86,
                height: 1.45,
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                r is ReviewVerdict ? 'Nothing to fix.' : 'No findings.',
                key: const ValueKey('ai-review-none'),
                style: HaroText.ui(size: 13.5, color: HaroTokens.ink42),
              ),
            ),
          for (final (i, item) in other)
            AiFindingTile(
              key: ValueKey('ai-review-item-$i'),
              index: i,
              workspaceId: workspaceId,
              item: item,
              mustFix: r is ReviewVerdict,
              onOpenDiff: onOpenDiff,
            ),
          if (r is ReviewVerdict && r.notes.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('NOTES', style: mono),
            ),
            for (final n in r.notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  n,
                  style: HaroText.ui(size: 13.5, color: HaroTokens.ink66),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _meta(AiReview r) {
    final t = DateTime.fromMillisecondsSinceEpoch((r.ranAt * 1000).round())
        .toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final at = '${two(t.hour)}:${two(t.minute)}';
    return r.model.isEmpty ? at : '${r.model} · $at';
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Wrap(
      key: const ValueKey('ai-review-error'),
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 4,
      children: [
        Text(
          'The review did not run: $message',
          style: HaroText.mono(
            size: 11.5,
            color: HaroTokens.fail,
            tracking: 0,
            height: 1.45,
          ),
        ),
        HaroButton(
          key: const ValueKey('ai-review-retry'),
          label: 'Retry',
          variant: HaroButtonVariant.tertiary,
          height: 26,
          fontSize: 13,
          padding: EdgeInsets.zero,
          onPressed: onRetry,
        ),
      ],
    ),
  );
}

/// One finding: severity, title, detail, where it is, and the ways to open it.
class AiFindingTile extends StatelessWidget {
  const AiFindingTile({
    super.key,
    required this.index,
    required this.workspaceId,
    required this.item,
    required this.mustFix,
    required this.onOpenDiff,
  });

  final int index;
  final String workspaceId;
  final AiReviewItem item;
  final bool mustFix;
  final void Function(String file, int? line) onOpenDiff;

  @override
  Widget build(BuildContext context) {
    final label = mustFix ? 'MUST FIX' : (item.severity ?? '').toUpperCase();
    final where = item.file.isEmpty
        ? ''
        : (item.line == null ? item.file : '${item.file}:${item.line}');
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line08)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (label.isNotEmpty)
              Text(
                item.category == null || item.category!.isEmpty
                    ? label
                    : '$label · ${item.category!.toUpperCase()}',
                key: ValueKey('ai-review-sev-$index'),
                style: HaroText.mono(size: 10.5, color: HaroTokens.ink66),
              ),
            if (label.isNotEmpty) const SizedBox(height: 5),
            Text(
              item.title,
              style: HaroText.ui(
                size: 14,
                weight: FontWeight.w500,
                height: 1.35,
              ),
            ),
            if (item.detail.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                item.detail,
                style: HaroText.ui(
                  size: 13.5,
                  color: HaroTokens.ink66,
                  height: 1.45,
                ),
              ),
            ],
            if (where.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    where,
                    key: ValueKey('ai-review-where-$index'),
                    style: HaroText.mono(
                      size: 11.5,
                      color: HaroTokens.ink66,
                      tracking: 0,
                    ),
                  ),
                  IntrinsicWidth(
                    child: HaroButton(
                      key: ValueKey('ai-review-diff-$index'),
                      label: 'Open diff',
                      height: 26,
                      fontSize: 12.5,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      foreground: HaroTokens.ink86,
                      onPressed: () => onOpenDiff(item.file, item.line),
                    ),
                  ),
                  OpenInLink(
                    key: ValueKey('ai-review-editor-$index'),
                    workspaceId: workspaceId,
                    source: 'verify-review',
                    path: item.file,
                    line: item.line,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
