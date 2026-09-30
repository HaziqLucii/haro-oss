import 'package:flutter/widgets.dart';

import '../../../../api/models/models.dart';
import '../../../../state/test_first.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/status_square.dart';
import 'agent_tokens.dart';

/// Test-first review, at the foot of the agent step: the drafted test, the red proof (each
/// case and how it failed on base) and one primary action. "Ask for changes" is the composer:
/// what the dev types there is sent as feedback and the agent redrafts.
///
/// [primary] is true where the step bar hides its own copy of the action (it lands on this
/// step), so approving is the one primary on screen. A rejected draft has no proof to approve;
/// its only way forward is the redraft.
class AcceptancePanel extends StatelessWidget {
  const AcceptancePanel({
    super.key,
    required this.state,
    required this.diffLines,
    required this.onApprove,
    required this.onAskChanges,
    this.onLeave,
    this.leaveArmed = false,
    this.onKeep,
    this.busy = false,
    this.primary = true,
    this.error,
  });

  final TestFirstState state;

  /// Added lines per drafted file path, from the workspace diff.
  final Map<String, List<String>> diffLines;
  final VoidCallback onApprove;
  final VoidCallback onAskChanges;

  /// "Leave test-first": the first tap arms it ([leaveArmed]), the second confirms.
  final VoidCallback? onLeave;
  final bool leaveArmed;
  final VoidCallback? onKeep;
  final bool busy;
  final bool primary;
  final String? error;

  static const _maxLines = 40;

  bool get _rejected => state.phase == TestFirstPhase.rejected;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('acceptance-panel'),
      padding: const EdgeInsets.only(top: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _rejected
                ? 'ACCEPTANCE TEST · REJECTED'
                : 'ACCEPTANCE TEST · PROVEN RED',
            style: AgentTokens.label(),
          ),
          const SizedBox(height: 10),
          Text(
            _rejected
                ? shortRejectReason(state.rejectReason)
                : redProofHeadline(state),
            key: const ValueKey('acceptance-headline'),
            style: HaroText.ui(size: 17, weight: FontWeight.w500, height: 1.35),
          ),
          const SizedBox(height: 6),
          Text(
            _rejected
                ? (state.rejectReason ?? '')
                : 'Haro ran it against the tree as it is, before any source change. '
                      'Approve it and the agent builds until it passes. The test file is '
                      'locked in: the gate blocks the merge if it changes.',
            key: const ValueKey('acceptance-sub'),
            style: HaroText.ui(
              size: 13.5,
              color: HaroTokens.ink66,
              height: 1.5,
            ),
          ),
          if (!_rejected) ...[
            const SizedBox(height: 14),
            for (final (i, c) in state.cases.indexed)
              _CaseRow(key: ValueKey('acceptance-case-$i'), c: c),
            for (final f in state.files) ...[
              const SizedBox(height: 12),
              _FileBlock(
                key: ValueKey('acceptance-file-${f.path}'),
                path: f.path,
                lines: diffLines[f.path] ?? const [],
              ),
            ],
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              if (!_rejected)
                HaroButton(
                  key: const ValueKey('approve-test'),
                  label: busy ? 'Approving…' : 'Approve test',
                  variant: primary
                      ? HaroButtonVariant.primary
                      : HaroButtonVariant.secondary,
                  onPressed: busy ? null : onApprove,
                ),
              if (!_rejected) const SizedBox(width: 8),
              HaroButton(
                key: const ValueKey('ask-changes'),
                label: _rejected ? 'Redraft test' : 'Ask for changes',
                variant: _rejected && primary
                    ? HaroButtonVariant.primary
                    : HaroButtonVariant.tertiary,
                foreground: HaroTokens.ink66,
                onPressed: onAskChanges,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _rejected
                      ? 'Say what to change in the composer below.'
                      : 'Feedback goes in the composer below.',
                  style: AgentTokens.hint,
                ),
              ),
            ],
          ),
          if (onLeave != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                HaroButton(
                  key: const ValueKey('leave-test-first'),
                  label: leaveArmed
                      ? 'Confirm: leave test-first'
                      : 'Leave test-first',
                  variant: HaroButtonVariant.tertiary,
                  foreground: HaroTokens.ink42,
                  onPressed: onLeave,
                ),
                if (leaveArmed && onKeep != null)
                  HaroButton(
                    key: const ValueKey('keep-test-first'),
                    label: 'Keep',
                    variant: HaroButtonVariant.tertiary,
                    foreground: HaroTokens.ink66,
                    onPressed: onKeep,
                  ),
              ],
            ),
            if (leaveArmed)
              Text(
                'The draft is dropped and this workspace runs like any other. No acceptance test is enforced.',
                style: AgentTokens.hint,
              ),
          ],
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(
              error!,
              key: const ValueKey('acceptance-error'),
              style: AgentTokens.tool(color: HaroTokens.fail),
            ),
          ],
        ],
      ),
    );
  }
}

class _CaseRow extends StatelessWidget {
  const _CaseRow({super.key, required this.c});

  final AcceptanceCase c;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 5),
          child: StatusSquare(
            size: AgentTokens.toolSquare,
            color: HaroTokens.fail,
            filled: true,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.name, style: AgentTokens.tool(color: HaroTokens.ink86)),
              if ((c.message ?? '').isNotEmpty)
                Text(
                  c.message!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AgentTokens.tool(color: HaroTokens.ink42),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FileBlock extends StatelessWidget {
  const _FileBlock({super.key, required this.path, required this.lines});

  final String path;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final shown = lines.take(AcceptancePanel._maxLines).toList();
    final more = lines.length - shown.length;
    return Container(
      decoration: BoxDecoration(
        color: HaroTokens.panel,
        border: Border.all(color: HaroTokens.line12),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(path, style: AgentTokens.label(color: HaroTokens.ink66)),
          const SizedBox(height: 8),
          if (lines.isEmpty)
            Text('Diff not loaded yet.', style: AgentTokens.hint)
          else
            for (final l in shown)
              Text(
                '+ $l',
                softWrap: false,
                overflow: TextOverflow.clip,
                style: AgentTokens.tool(color: HaroTokens.ink86),
              ),
          if (more > 0) Text('… $more more lines', style: AgentTokens.hint),
        ],
      ),
    );
  }
}
