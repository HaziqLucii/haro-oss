import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api/models/models.dart';
import '../../../data/issue_provider.dart';
import '../../../data/workspace_detail.dart';
import '../../../overlays/overlay.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_button.dart';
import '../../../widgets/haro_pressable.dart';
import '../../../widgets/issue_comment_card.dart';
import '../../../widgets/shell_icons.dart';
import '../../backlog/backlog_page.dart' show issuesUnavailableMessage;
import '../steps/agent/agent_markdown.dart' show AgentProse;

TextStyle _label() =>
    HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .16);

/// A few plain lines of an issue body for the rail: fences, images, HTML and markdown marks
/// dropped, whitespace folded.
String issueExcerpt(String body, {int max = 240}) {
  final plain = body
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(
        RegExp(r'^\s*(#{1,6}|[-*+]|\d+[.)]|>)\s+', multiLine: true),
        '',
      )
      .replaceAll(RegExp(r'[*_`]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (plain.length <= max) return plain;
  final cut = plain.substring(0, max);
  final space = cut.lastIndexOf(' ');
  return '${(space > max ~/ 2 ? cut.substring(0, space) : cut).trimRight()}…';
}

/// The GitHub issue a workspace was started from, in the right rail: the title, state and labels
/// with the start of the description, and the whole thing (rendered body and comments) in a
/// fullscreen view. It uses haro's own `gh` login, so it also reads a private repo's issue. Shown
/// only for a workspace whose seed key is `issue:<n>`.
class IssueSection extends ConsumerWidget {
  const IssueSection({
    super.key,
    required this.workspaceId,
    this.compact = false,
  });

  final String workspaceId;

  /// Title only: a manual workspace's rail is mostly Plan / Search / Docs and needs the room.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seed = ref.watch(
      workspaceDetailProvider(workspaceId)
          .select((d) => (d.workspace?.projectId, d.workspace?.seedKey)),
    );
    final number = issueNumberOf(seed.$2);
    final projectId = seed.$1;
    if (number == null || projectId == null) return const SizedBox.shrink();
    final key = (projectId: projectId, number: number);
    final issue = ref.watch(workspaceIssueProvider(key));
    final d = issue.value;
    // The card is a button over the whole section, so its ripple fills the section's box.
    if (d != null && d.available) {
      return _Card(
        number: number,
        detail: d,
        compact: compact,
        onOpen: () => showIssueFullscreen(context, key),
      );
    }
    return Container(
      key: const ValueKey('rail-issue'),
      padding: _sectionPadding,
      decoration: _sectionBorder(),
      child: issue.when(
        loading: () => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('ISSUE #$number', style: _label()),
            const SizedBox(height: 8),
            Text(
              'Loading…',
              style: HaroText.mono(
                size: 11,
                tracking: 0,
                color: HaroTokens.ink42,
              ),
            ),
          ],
        ),
        error: (e, _) =>
            _note(ref, key, 'ISSUE #$number', 'Could not load the issue: $e'),
        data: (d) => _note(
          ref,
          key,
          'ISSUE #$number',
          issuesUnavailableMessage(d.reason),
        ),
      ),
    );
  }

  Widget _note(
    WidgetRef ref,
    ({String projectId, int number}) key,
    String head,
    String text,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(head, style: _label()),
      const SizedBox(height: 8),
      Text(
        text,
        key: const ValueKey('rail-issue-note'),
        style: HaroText.mono(
          size: 11,
          tracking: 0,
          color: HaroTokens.ink42,
          height: 1.5,
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: HaroPressable(
          onTap: () => ref.invalidate(workspaceIssueProvider(key)),
          semanticLabel: 'Try again',
          builder: (context, hovered) => Text(
            'TRY AGAIN',
            style: _label().copyWith(
              color: hovered ? HaroTokens.ink : HaroTokens.ink42,
            ),
          ),
        ),
      ),
    ],
  );
}

const _sectionPadding = EdgeInsets.fromLTRB(20, 18, 20, 14);

BoxDecoration _sectionBorder({Color? color}) => BoxDecoration(
  color: color,
  border: Border(bottom: BorderSide(color: HaroTokens.line12)),
);

class _Card extends StatelessWidget {
  const _Card({
    required this.number,
    required this.detail,
    required this.onOpen,
    this.compact = false,
  });

  final int number;
  final IssueDetailResponse detail;
  final VoidCallback onOpen;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final excerpt = compact ? '' : issueExcerpt(detail.body ?? '');
    final state = (detail.state ?? '').toUpperCase();
    return HaroPressable(
      onTap: onOpen,
      semanticLabel: 'Open issue #$number fullscreen',
      builder: (context, hovered) => AnimatedContainer(
        key: const ValueKey('rail-issue'),
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        padding: _sectionPadding,
        decoration: _sectionBorder(
          color: hovered ? HaroTokens.panel : HaroTokens.transparent,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'ISSUE #$number${state.isEmpty ? '' : ', $state'}',
                    style: _label(),
                  ),
                ),
                ShellIconButton(
                  key: const ValueKey('rail-issue-fullscreen'),
                  icon: ShellIcon.expand,
                  tooltip: 'Read the issue fullscreen',
                  width: 24,
                  height: 24,
                  iconSize: 14,
                  onTap: onOpen,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              detail.title ?? '#$number',
              key: const ValueKey('rail-issue-title'),
              maxLines: compact ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(
                size: 14.5,
                weight: FontWeight.w500,
                color: hovered ? HaroTokens.ink : HaroTokens.ink86,
                height: 1.3,
              ),
            ),
            if (!compact && detail.labels.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                detail.labels.join(', '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: HaroText.mono(
                  size: 10.5,
                  tracking: 0,
                  color: HaroTokens.ink42,
                ),
              ),
            ],
            if (excerpt.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                excerpt,
                key: const ValueKey('rail-issue-excerpt'),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(
                  size: 12.5,
                  color: HaroTokens.ink66,
                  height: 1.45,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The issue in full over the window: description rendered as markdown, every comment, and a
/// link to open it on GitHub. Esc or the exit row closes it.
Future<void> showIssueFullscreen(
  BuildContext context,
  ({String projectId, int number}) key,
) => showHaroOverlay<void>(
  context,
  width: 0,
  fullscreen: true,
  child: Consumer(
    builder: (context, ref, _) {
      final d = ref.watch(workspaceIssueProvider(key)).value;
      return _IssueFull(
        number: key.number,
        detail: d,
        onClose: () => closeHaroOverlay(context),
      );
    },
  ),
);

class _IssueFull extends StatelessWidget {
  const _IssueFull({
    required this.number,
    required this.detail,
    required this.onClose,
  });

  final int number;
  final IssueDetailResponse? detail;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final url = d?.url ?? '';
    return Column(
      key: const ValueKey('issue-fullscreen'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 14, 40, 10),
          child: Row(
            children: [
              HaroPressable(
                onTap: onClose,
                semanticLabel: 'Exit fullscreen',
                builder: (context, hovered) => Text(
                  '‹  EXIT FULLSCREEN  ESC',
                  style: _label().copyWith(
                    color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                  ),
                ),
              ),
              const Spacer(),
              if (url.isNotEmpty)
                HaroButton(
                  key: const ValueKey('issue-open-github'),
                  label: 'Open on GitHub',
                  trailing: ShellIcon.openExternal,
                  variant: HaroButtonVariant.tertiary,
                  onPressed: () => launchUrl(
                    Uri.parse(url),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
            ],
          ),
        ),
        Container(height: 1, color: HaroTokens.line12),
        Expanded(
          child: d == null || !d.available
              ? Padding(
                  padding: const EdgeInsets.all(40),
                  child: Text(
                    d == null
                        ? 'Loading…'
                        : (d.reason ?? 'GitHub is not available.'),
                    style: HaroText.ui(size: 14, color: HaroTokens.ink42),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(40, 26, 40, 40),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '#$number, ${(d.state ?? '').toUpperCase()}'
                              '${d.labels.isEmpty ? '' : ', ${d.labels.join(', ')}'}',
                              style: HaroText.mono(
                                size: 11,
                                tracking: 0,
                                color: HaroTokens.ink42,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              d.title ?? '#$number',
                              key: const ValueKey('issue-full-title'),
                              style: HaroText.ui(
                                size: 26,
                                weight: FontWeight.w500,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 18),
                            if ((d.body ?? '').trim().isEmpty)
                              Text(
                                'No description.',
                                style: HaroText.ui(
                                  size: 15,
                                  color: HaroTokens.ink42,
                                ),
                              )
                            else
                              AgentProse(d.body!.trim()),
                            if (d.comments.isNotEmpty) ...[
                              const SizedBox(height: 28),
                              Text(
                                '${d.comments.length} COMMENT${d.comments.length == 1 ? '' : 'S'}',
                                style: _label(),
                              ),
                              for (final c in d.comments)
                                IssueCommentCard(
                                  author: c.author,
                                  createdAt: c.createdAt,
                                  body: c.body,
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
