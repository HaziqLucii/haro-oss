import 'package:flutter/widgets.dart';

import '../../../../api/models/models.dart';
import '../../../../state/manual_rail.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_menu.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../steps/code/workbench/workbench_icons.dart';

TextStyle manualLabelStyle() =>
    HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .16);

class ManualLabel extends StatelessWidget {
  const ManualLabel(this.text, {super.key, this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Flexible(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: manualLabelStyle(),
        ),
      ),
      if (trailing != null) Text(trailing!, style: manualLabelStyle()),
    ],
  );
}

/// What the run could not promise, in plain words, under a plan or an answer: the file guard
/// could not check the worktree (a gate or dev server was writing), and any tools it tried
/// that it does not have. Muted on purpose: neither is a failure.
class RunNotes extends StatelessWidget {
  const RunNotes({
    super.key,
    required this.guardNote,
    required this.blockedCalls,
    this.keyPrefix = 'run',
  });

  final String? guardNote;
  final List<String> blockedCalls;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final blocked = blockedCallsLine(blockedCalls);
    final guard = guardNote;
    if ((guard == null || guard.isEmpty) && blocked == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (guard != null && guard.isNotEmpty)
            Text(
              guard,
              key: ValueKey('$keyPrefix-guard-note'),
              style: HaroText.ui(
                size: 12,
                color: HaroTokens.ink66,
                height: 1.45,
              ),
            ),
          if (blocked != null)
            Padding(
              padding: EdgeInsets.only(top: guard == null ? 0 : 6),
              child: Text(
                blocked,
                key: ValueKey('$keyPrefix-blocked'),
                style: HaroText.mono(
                  size: 10,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A failure line. Red is for failures, so this is the one place the rail uses it.
class ManualError extends StatelessWidget {
  const ManualError(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      message,
      style: HaroText.ui(size: 12.5, color: HaroTokens.fail, height: 1.4),
    ),
  );
}

/// 14px bone-filled square with a dark tick when done. Bone, not green: green is the gate's.
class ManualCheck extends StatelessWidget {
  const ManualCheck({super.key, required this.done, this.onTap});

  final bool done;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: done ? 'Mark not done' : 'Mark done',
    builder: (context, hovered) => Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: done ? HaroTokens.ink : HaroTokens.transparent,
        border: Border.all(
          color: done || hovered ? HaroTokens.ink : HaroTokens.ink42,
        ),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: done
          ? const WorkbenchIconView(
              WorkbenchIcon.check,
              size: 11,
              color: HaroTokens.bg,
            )
          : null,
    ),
  );
}

/// One plan step: a box and the text. `onTap` null makes it a read-only line.
class PlanStepRow extends StatelessWidget {
  const PlanStepRow({super.key, required this.step, this.onTap});

  final PlanStep step;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line08)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1, right: 8),
          child: ManualCheck(done: step.done, onTap: onTap),
        ),
        Expanded(
          child: Text(
            step.text,
            style: HaroText.ui(
              size: 13,
              color: step.done ? HaroTokens.ink42 : HaroTokens.ink86,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );
}

/// A compact `label: value` chip that opens a small menu of choices at the tap.
class PickerChip extends StatelessWidget {
  const PickerChip({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onPick,
  });

  final String label;

  /// Null shows `default`.
  final String? value;

  /// The first entry is offered as `default` and sends null.
  final List<String> options;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) => HaroPressable(
    semanticLabel: '$label: ${value ?? 'default'}',
    onTap: () {
      final box = context.findRenderObject() as RenderBox;
      final origin = box.localToGlobal(Offset(0, box.size.height + 4));
      showHaroMenu(
        context,
        position: origin,
        width: 150,
        items: [
          HaroMenuItem(label: 'default', onSelected: () => onPick(null)),
          for (final o in options)
            HaroMenuItem(label: o, onSelected: () => onPick(o)),
        ],
      );
    },
    builder: (context, hovered) => Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(
          color: hovered ? HaroTokens.line30 : HaroTokens.line14,
        ),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Text(
        '$label ${value ?? 'default'}',
        maxLines: 1,
        style: HaroText.mono(
          size: 10.5,
          color: hovered ? HaroTokens.ink : HaroTokens.ink66,
          tracking: 0,
        ),
      ),
    ),
  );
}
