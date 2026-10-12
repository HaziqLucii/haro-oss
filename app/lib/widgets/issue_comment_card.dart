import 'package:flutter/material.dart';

import '../features/workspace/steps/agent/agent_markdown.dart' show AgentProse;
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';

/// One GitHub issue comment in its own bordered block: author and time on a ruled header, the
/// markdown body below. Fill, border and corners come from the theme's tokens.
class IssueCommentCard extends StatelessWidget {
  const IssueCommentCard({
    super.key,
    required this.author,
    required this.createdAt,
    required this.body,
  });

  final String author;
  final String createdAt;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 14),
    decoration: BoxDecoration(
      color: HaroTokens.panel,
      border: Border.all(color: HaroTokens.line14),
      borderRadius: BorderRadius.circular(HaroTokens.panelRadius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: HaroTokens.line08)),
          ),
          child: Text(
            [
              author.isEmpty ? 'someone' : author,
              if (createdAt.isNotEmpty) createdAt,
            ].join(' · '),
            style: HaroText.mono(
              size: 11,
              tracking: 0,
              color: HaroTokens.ink42,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: AgentProse(body.trim()),
        ),
      ],
    ),
  );
}
