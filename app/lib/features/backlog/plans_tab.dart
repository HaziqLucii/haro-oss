import 'package:flutter/material.dart';

import '../../api/models/models.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_tag.dart';
import '../../widgets/shell_icons.dart';
import '../new_workspace/creation_widgets.dart';
import 'list_loading.dart';
import 'notes_model.dart' show relativeTime;

/// The Backlog's Plans tab: the plans haro made in this project's workspaces (the manual rail's Plan
/// tab), read from haro's database. The list on the left, one plan on the right. It only shows:
/// ticking steps and saving stay in the workspace's rail, where the work is.
class PlansTab extends StatefulWidget {
  const PlansTab({
    super.key,
    required this.plans,
    required this.error,
    required this.listWidth,
    required this.onOpenWorkspace,
  });

  /// Null while loading.
  final List<ProjectPlan>? plans;
  final String? error;
  final double listWidth;
  final ValueChanged<String> onOpenWorkspace;

  @override
  State<PlansTab> createState() => _PlansTabState();
}

class _PlansTabState extends State<PlansTab> {
  String? _selected;

  ProjectPlan? get _current {
    final plans = widget.plans;
    if (plans == null || plans.isEmpty) return null;
    return plans.where((p) => p.plan.id == _selected).firstOrNull ??
        plans.first;
  }

  @override
  Widget build(BuildContext context) {
    final plans = widget.plans;
    if (widget.error != null) {
      return _Note(widget.error!, error: true);
    }
    if (plans == null) return const ListLoading('Loading plans');
    if (plans.isEmpty) {
      return const _Note(
        'No plans yet. A plan made in a workspace\'s Plan tab (manual mode) shows up here.',
        key: Key('plans-empty'),
      );
    }
    final current = _current!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: widget.listWidth,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: HaroTokens.line12)),
          ),
          child: ListView(
            key: const Key('plans-list'),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            children: [
              for (final p in plans)
                _PlanRow(
                  key: Key('plan-${p.plan.id}'),
                  item: p,
                  selected: p.plan.id == current.plan.id,
                  onTap: () => setState(() => _selected = p.plan.id),
                ),
            ],
          ),
        ),
        Expanded(
          child: _PlanDetail(
            key: ValueKey(current.plan.id),
            item: current,
            onOpenWorkspace: widget.onOpenWorkspace,
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: HaroText.ui(
          size: 14,
          color: error ? HaroTokens.fail : HaroTokens.ink42,
          height: 1.6,
        ),
      ),
    ),
  );
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final ProjectPlan item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = item.plan;
    return HaroPressable(
      onTap: onTap,
      semanticLabel: p.title,
      builder: (context, hovered) => Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: selected || hovered
              ? HaroTokens.raised
              : HaroTokens.transparent,
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.title.isEmpty ? 'Untitled plan' : p.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(
                size: 13.5,
                color: selected ? HaroTokens.ink : HaroTokens.ink86,
              ),
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Flexible(child: MonoCaption(item.workspaceName)),
                const SizedBox(width: 8),
                HaroTag('${p.doneCount} of ${p.steps.length}', height: 16),
                if (p.saved) ...[
                  const SizedBox(width: 6),
                  const HaroTag('saved', height: 16),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanDetail extends StatelessWidget {
  const _PlanDetail({
    super.key,
    required this.item,
    required this.onOpenWorkspace,
  });

  final ProjectPlan item;
  final ValueChanged<String> onOpenWorkspace;

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [MonoCaption(title), const SizedBox(height: 8), child],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = item.plan;
    final created = p.createdAt == null
        ? null
        : relativeTime(p.createdAt!, DateTime.now());
    return SelectionArea(
      child: ListView(
        key: const Key('plan-detail'),
        padding: const EdgeInsets.fromLTRB(32, 26, 32, 26),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          item.workspaceName,
                          style: HaroText.mono(
                            size: 11,
                            tracking: 0,
                            color: HaroTokens.ink42,
                          ),
                        ),
                        if (created != null)
                          Text(
                            created,
                            style: HaroText.mono(
                              size: 11,
                              tracking: 0,
                              color: HaroTokens.ink42,
                            ),
                          ),
                        HaroTag('${p.doneCount} of ${p.steps.length} done'),
                        if (p.saved) const HaroTag('saved'),
                        if (p.model != null)
                          HaroTag(
                            p.effort == null || p.effort!.isEmpty
                                ? p.model!
                                : '${p.model}, ${p.effort}',
                          ),
                        if (p.costUsd != null)
                          HaroTag('\$${p.costUsd!.toStringAsFixed(2)}'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      p.title.isEmpty ? 'Untitled plan' : p.title,
                      style: HaroText.ui(
                        size: 26,
                        weight: FontWeight.w500,
                      ).copyWith(letterSpacing: -.39, height: 1.2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              HaroButton(
                key: const Key('plan-open-workspace'),
                label: 'Open workspace',
                trailing: ShellIcon.arrowRight,
                onPressed: () => onOpenWorkspace(item.workspaceId),
              ),
            ],
          ),
          if (p.prompt.trim().isNotEmpty)
            _section(
              'WHAT YOU ASKED',
              Text(
                p.prompt.trim(),
                style: HaroText.ui(
                  size: 14,
                  color: HaroTokens.ink66,
                  height: 1.6,
                ),
              ),
            ),
          _section(
            'STEPS',
            Column(
              key: const Key('plan-steps'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in p.steps)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2, right: 10),
                          child: _Tick(done: s.done),
                        ),
                        Expanded(
                          child: Text(
                            s.text,
                            style: HaroText.ui(
                              size: 14,
                              color: s.done
                                  ? HaroTokens.ink42
                                  : HaroTokens.ink86,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (p.why.trim().isNotEmpty)
            _section(
              'WHY THIS ORDER',
              Text(
                p.why.trim(),
                style: HaroText.ui(
                  size: 14,
                  color: HaroTokens.ink66,
                  height: 1.6,
                ),
              ),
            ),
          if (p.guardNote != null && p.guardNote!.trim().isNotEmpty)
            _section(
              'AI EDITS',
              Text(
                p.guardNote!.trim(),
                key: const Key('plan-guard-note'),
                style: HaroText.ui(
                  size: 13.5,
                  color: HaroTokens.warn,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The state of one step, read-only: a ticked box or an empty one.
class _Tick extends StatelessWidget {
  const _Tick({required this.done});

  final bool done;

  @override
  Widget build(BuildContext context) => Container(
    width: 15,
    height: 15,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: done ? HaroTokens.ink : HaroTokens.transparent,
      border: Border.all(color: HaroTokens.ink42),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: done
        ? ShellIconView(ShellIcon.check, size: 11, color: HaroTokens.bg)
        : null,
  );
}
