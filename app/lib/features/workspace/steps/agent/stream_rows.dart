import 'package:flutter/widgets.dart';

import '../../../../state/format.dart' show relativeAgo;
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../../../widgets/status_square.dart';
import 'agent_markdown.dart';
import 'agent_tokens.dart';
import 'agent_transcript.dart';

/// `14m ago`, or `just now` inside the first minute.
String agoLabel(double epochSeconds, DateTime now) {
  final r = relativeAgo(epochSeconds, now);
  return r == 'now' ? 'just now' : '$r ago';
}

class StreamRowView extends StatelessWidget {
  const StreamRowView({
    super.key,
    required this.row,
    required this.now,
    required this.onReviewCode,
    this.plan,
  });

  final StreamRow row;
  final DateTime now;
  final VoidCallback onReviewCode;

  /// Set on the footer that closes the newest, still unapproved plan.
  final PlanApproval? plan;

  @override
  Widget build(BuildContext context) => switch (row) {
    UserRow r => UserBlock(row: r, now: now),
    AgentLabelRow r => Text(
      r.text.toUpperCase(),
      key: const ValueKey('agent-label'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AgentTokens.label(),
    ),
    ProseRow r => AgentProse(r.text),
    ToolRow r => ToolLine(row: r),
    ErrorRow r => ErrorBlock(message: r.message),
    QuestionRow r => QuestionBlock(row: r),
    FooterRow r => TurnFooter(row: r, onReviewCode: onReviewCode, plan: plan),
  };
}

class UserBlock extends StatelessWidget {
  const UserBlock({super.key, required this.row, required this.now});

  final UserRow row;
  final DateTime now;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${row.label} · ${agoLabel(row.ts, now)}'.toUpperCase(),
        key: const ValueKey('user-label'),
        style: AgentTokens.label(),
      ),
      const SizedBox(height: 8),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: HaroTokens.panel,
          border: Border.all(color: HaroTokens.line08),
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: Text(
          row.text,
          key: const ValueKey('user-text'),
          style: row.kind == 'user'
              ? AgentTokens.userText
              : AgentTokens.userText.copyWith(color: HaroTokens.ink66),
        ),
      ),
    ],
  );
}

/// `■ Edit  path  +a −d`. The square is filled once the call is done and hollow while it
/// runs; it is never green, since it says nothing about the gate.
class ToolLine extends StatelessWidget {
  const ToolLine({super.key, required this.row});

  final ToolRow row;

  @override
  Widget build(BuildContext context) {
    final dim = row.delegate;
    final style = AgentTokens.tool(
      color: dim ? HaroTokens.ink42 : HaroTokens.ink66,
    );
    return Padding(
      padding: EdgeInsets.only(left: dim ? 15 : 0),
      child: Row(
        children: [
          StatusSquare(
            size: AgentTokens.toolSquare,
            color: row.running ? HaroTokens.ink : HaroTokens.ink42,
            filled: !row.running,
          ),
          const SizedBox(width: 10),
          if (!row.delegate)
            ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: AgentTokens.verbWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text(
                  row.tool,
                  maxLines: 1,
                  softWrap: false,
                  style: AgentTokens.tool(color: HaroTokens.ink),
                ),
              ),
            ),
          Flexible(
            child: Text(
              row.target,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if ((row.added ?? 0) > 0) ...[
            const SizedBox(width: 10),
            Text(
              '+${row.added}',
              style: AgentTokens.tool(color: HaroTokens.gate),
            ),
          ],
          if ((row.removed ?? 0) > 0) ...[
            const SizedBox(width: 10),
            Text(
              '−${row.removed}',
              style: AgentTokens.tool(color: HaroTokens.fail),
            ),
          ],
        ],
      ),
    );
  }
}

class ErrorBlock extends StatelessWidget {
  const ErrorBlock({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.only(top: 5),
        child: StatusSquare(size: 7, color: HaroTokens.fail, filled: true),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          message,
          key: const ValueKey('agent-error'),
          style: AgentTokens.tool(color: HaroTokens.fail),
        ),
      ),
    ],
  );
}

class QuestionBlock extends StatelessWidget {
  const QuestionBlock({super.key, required this.row});

  final QuestionRow row;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('agent-question'),
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
    decoration: BoxDecoration(
      border: Border.all(
        color: row.waiting ? HaroTokens.line30 : HaroTokens.line12,
      ),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StatusSquare(
              size: 7,
              color: row.waiting ? HaroTokens.ink : HaroTokens.ink42,
              filled: !row.waiting,
            ),
            const SizedBox(width: 8),
            Text(
              row.waiting ? 'WAITING FOR YOUR ANSWER' : 'AGENT ASKED',
              style: AgentTokens.label(
                color: row.waiting ? HaroTokens.ink66 : HaroTokens.ink42,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(row.question, style: AgentTokens.userText),
        for (final o in row.options) ...[
          const SizedBox(height: 6),
          Text('· $o', style: AgentTokens.tool()),
        ],
        if (row.waiting) ...[
          const SizedBox(height: 12),
          Text(
            'Stop the run, then reply in the box below to continue the session.',
            style: HaroText.ui(size: 13, color: HaroTokens.ink66),
          ),
        ],
      ],
    ),
  );
}

/// What the plan footer needs to approve.
class PlanApproval {
  const PlanApproval({
    required this.onApprove,
    required this.busy,
    this.primary = true,
    this.error,
  });

  /// The step bar hides its "Review plan" on this step, so approving is the one primary.
  final bool primary;
  final VoidCallback onApprove;
  final bool busy;
  final String? error;
}

class TurnFooter extends StatelessWidget {
  const TurnFooter({
    super.key,
    required this.row,
    required this.onReviewCode,
    this.plan,
  });

  final FooterRow row;
  final VoidCallback onReviewCode;
  final PlanApproval? plan;

  @override
  Widget build(BuildContext context) {
    final plan = this.plan;
    return Container(
      padding: const EdgeInsets.only(top: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.text,
                  key: const ValueKey('turn-footer'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AgentTokens.footer,
                ),
              ),
              const SizedBox(width: 12),
              if (plan != null)
                HaroButton(
                  key: const ValueKey('approve-plan'),
                  label: plan.busy ? 'Approving…' : 'Approve plan',
                  variant: plan.primary
                      ? HaroButtonVariant.primary
                      : HaroButtonVariant.secondary,
                  onPressed: plan.busy ? null : plan.onApprove,
                )
              else if (!row.planReady && row.files > 0)
                HaroPressable(
                  onTap: onReviewCode,
                  semanticLabel: 'Review changes in code',
                  builder: (context, hovered) => Text(
                    'Review changes in code →',
                    key: const ValueKey('review-in-code'),
                    style: HaroText.ui(
                      size: 13,
                      color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                    ),
                  ),
                ),
            ],
          ),
          if (plan != null) ...[
            const SizedBox(height: 10),
            Text(
              'Approve to build it, or reply below to revise the plan.',
              style: HaroText.ui(size: 13, color: HaroTokens.ink66),
            ),
            if (plan.error != null) ...[
              const SizedBox(height: 6),
              Text(
                plan.error!,
                key: const ValueKey('approve-error'),
                style: AgentTokens.tool(color: HaroTokens.fail),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// The in-flight beat while the agent works and no tool line is pulsing already.
class WorkingLine extends StatelessWidget {
  const WorkingLine({super.key, this.elapsed});

  final String? elapsed;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const StatusSquare(
        size: AgentTokens.toolSquare,
        color: HaroTokens.ink,
        filled: false,
      ),
      const SizedBox(width: 10),
      Text(
        elapsed == null ? 'working' : 'working · $elapsed',
        key: const ValueKey('working-line'),
        style: AgentTokens.tool(color: HaroTokens.ink42),
      ),
    ],
  );
}

/// The step bar's action when it lands on this step (send failures, restore a test): the bar
/// hides it here, so the step renders it as the one primary.
class StepAction extends StatelessWidget {
  const StepAction({
    super.key,
    required this.label,
    required this.hint,
    required this.busy,
    required this.onPressed,
    this.error,
  });

  final String label;
  final String hint;
  final bool busy;
  final VoidCallback onPressed;
  final String? error;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.only(top: 14),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: HaroTokens.line08)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                hint,
                style: HaroText.ui(size: 13, color: HaroTokens.ink66),
              ),
            ),
            const SizedBox(width: 12),
            HaroButton(
              key: const ValueKey('step-action'),
              label: busy ? 'Sending…' : label,
              variant: HaroButtonVariant.primary,
              onPressed: busy ? null : onPressed,
            ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 6),
          Text(
            error!,
            key: const ValueKey('step-action-error'),
            style: AgentTokens.tool(color: HaroTokens.fail),
          ),
        ],
      ],
    ),
  );
}
