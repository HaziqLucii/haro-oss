import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/display_state.dart';
import '../../state/format.dart';
import '../../state/workspace_flow.dart';
import '../../theme/display_scope.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/status_square.dart';
import 'triage_model.dart';
import 'triage_providers.dart';
import 'dithered_orb.dart';
import 'usage_meters.dart';

const _contentMax = 1048.0;
const _gutter = 56.0;
const _wrapBelow = 484.0;

typedef TriageRowAction = void Function(TriageRow row);

void _openRow(BuildContext context, TriageRow row) =>
    context.go('/w/${row.id}/${row.flow.defaultStep.name}');

class TriagePage extends ConsumerStatefulWidget {
  const TriagePage({super.key, this.onRowAction, this.clock = DateTime.now});

  /// The row's next-action button. Until the workspace actions land it opens the default
  /// step, same as clicking the row; wire the real action here.
  final TriageRowAction? onRowAction;

  /// Injected so the relative-time column is testable.
  final DateTime Function() clock;

  @override
  ConsumerState<TriagePage> createState() => _TriagePageState();
}

class _TriagePageState extends ConsumerState<TriagePage> {
  Timer? _tick;
  bool _mergedOpen = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(triageViewProvider);
    final filter = ref.watch(triageFilterProvider);

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (view.workspaceCount == 0)
            Center(child: _EmptyLine(_emptyText(view)))
          else
            _content(view, filter),
        ],
      ),
    );
  }

  String _emptyText(TriageView v) {
    if (!v.loaded) {
      return v.error != null ? 'Backend not reachable' : 'Loading workspaces';
    }
    return 'No workspaces yet';
  }

  Widget _content(TriageView view, TriageFilter filter) {
    final now = widget.clock();
    final groups = [
      for (final g in triageGroupOrder)
        if (filter.group == null || filter.group == g)
          if (view.inGroup(g).isNotEmpty) (g, view.inGroup(g)),
    ];

    return LayoutBuilder(
      builder: (context, box) {
        final inset = math.max(_gutter, (box.maxWidth - _contentMax) / 2);
        final h = EdgeInsets.symmetric(horizontal: inset);
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: h.copyWith(top: 44),
              sliver: SliverToBoxAdapter(child: _Header(view: view)),
            ),
            SliverPadding(
              padding: h.copyWith(top: 32),
              sliver: SliverToBoxAdapter(
                child: _Filters(
                  view: view,
                  selected: filter,
                  onPick: ref.read(triageFilterProvider.notifier).pick,
                ),
              ),
            ),
            if (groups.isEmpty)
              SliverPadding(
                padding: h.copyWith(top: 40),
                sliver: SliverToBoxAdapter(
                  child: _EmptyLine('Nothing in ${filter.label}'),
                ),
              ),
            for (final (group, rows) in groups) ...[
              SliverPadding(
                padding: h.copyWith(top: 40),
                sliver: SliverToBoxAdapter(
                  child: _GroupHeader(
                    group: group,
                    count: rows.length,
                    collapsible: group == TriageGroup.merged,
                    open: _isOpen(group, filter),
                    onToggle: () => setState(() => _mergedOpen = !_mergedOpen),
                  ),
                ),
              ),
              if (_isOpen(group, filter))
                SliverPadding(
                  padding: h,
                  sliver: DecoratedSliver(
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: HaroTokens.line20)),
                    ),
                    sliver: SliverList.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) => _RowView(
                        row: rows[i],
                        primary: group == TriageGroup.needsYou,
                        now: now,
                        onAction:
                            widget.onRowAction ?? (r) => _openRow(context, r),
                      ),
                    ),
                  ),
                ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        );
      },
    );
  }

  bool _isOpen(TriageGroup g, TriageFilter f) =>
      g != TriageGroup.merged || f == TriageFilter.merged || _mergedOpen;
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: HaroText.mono(color: HaroTokens.ink42),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.view});

  final TriageView view;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          triageHeadline(view.needYouCount),
          style: HaroText.ui(
            size: 38,
            weight: FontWeight.w500,
            height: 1.1,
          ).copyWith(letterSpacing: -.02 * 38),
        ),
      ],
    );
    // Meters when there is room beside the headline, the orb when there is a lot of it; the
    // narrow layouts keep just the headline.
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < 760) return text;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: text),
            const SizedBox(width: 40),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: UsageMeters(),
            ),
            if (box.maxWidth >= 980) ...[
              const SizedBox(width: 36),
              const DitheredOrb(),
            ],
          ],
        );
      },
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.view,
    required this.selected,
    required this.onPick,
  });

  final TriageView view;
  final TriageFilter selected;
  final ValueChanged<TriageFilter> onPick;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final f in TriageFilter.values)
        _Chip(
          filter: f,
          count: view.countOf(f),
          on: f == selected,
          onTap: () => onPick(f),
        ),
    ],
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.filter,
    required this.count,
    required this.on,
    required this.onTap,
  });

  final TriageFilter filter;
  final int count;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: filter.label,
    builder: (context, hovered) {
      final fg = on
          ? HaroTokens.bg
          : (hovered ? HaroTokens.ink : HaroTokens.ink66);
      return AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: on ? HaroTokens.ink : HaroTokens.transparent,
          borderRadius: BorderRadius.circular(HaroTokens.radius),
          border: Border.all(color: on ? HaroTokens.ink : HaroTokens.line12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(filter.label, style: HaroText.ui(size: 13, color: fg)),
            const SizedBox(width: 8),
            Text(
              '$count',
              style: HaroText.mono(
                size: 10.5,
                color: fg.withValues(alpha: .7),
                tracking: 0,
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.count,
    required this.collapsible,
    required this.open,
    required this.onToggle,
  });

  final TriageGroup group;
  final int count;
  final bool collapsible;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final header = Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            triageGroupTitle(group).toUpperCase(),
            style: HaroText.mono(color: HaroTokens.ink, tracking: .16),
          ),
          const SizedBox(width: 14),
          Text(
            '$count',
            style: HaroText.mono(color: HaroTokens.ink42, tracking: 0),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              triageGroupHint(group),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(size: 13, color: HaroTokens.ink42),
            ),
          ),
          if (collapsible) ...[
            const SizedBox(width: 14),
            Text(
              open ? 'HIDE' : 'SHOW',
              style: HaroText.mono(size: 10.5, color: HaroTokens.ink42),
            ),
          ],
        ],
      ),
    );
    if (!collapsible) return header;
    return HaroPressable(
      onTap: onToggle,
      semanticLabel: open ? 'Hide merged' : 'Show merged',
      builder: (context, hovered) => header,
    );
  }
}

Color _tickColor(StepStatus s) => switch (s) {
  StepStatus.pending => HaroTokens.line12,
  StepStatus.current => HaroTokens.ink,
  StepStatus.done => HaroTokens.ink42,
  StepStatus.red => HaroTokens.fail,
  StepStatus.green => HaroTokens.gate,
  StepStatus.merged => HaroTokens.merged,
};

class _RowView extends StatelessWidget {
  const _RowView({
    required this.row,
    required this.primary,
    required this.now,
    required this.onAction,
  });

  final TriageRow row;
  final bool primary;
  final DateTime now;
  final TriageRowAction onAction;

  @override
  Widget build(BuildContext context) {
    final flow = row.flow;
    final state = flow.displayState;
    final at = row.at;
    final density = DisplayScope.densityOf(context);
    return HaroPressable(
      onTap: () => _openRow(context, row),
      semanticLabel: row.workspace.name,
      builder: (context, hovered) => AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        constraints: BoxConstraints(minHeight: density.triageRowMin),
        padding: EdgeInsets.symmetric(vertical: density.triageRowPadY),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: hovered ? HaroTokens.panel : HaroTokens.transparent,
          border: const Border(bottom: BorderSide(color: HaroTokens.line08)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 82,
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Row(
                  children: [
                    StatusSquare.forState(
                      state,
                      size: HaroTokens.markTriageRow,
                    ),
                    const SizedBox(width: HaroTokens.markTriageGap),
                    Expanded(
                      child: Text(
                        flow.stateWord.toUpperCase(),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: HaroText.mono(
                          size: 10.5,
                          color: state.color,
                          tracking: .12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(child: _Middle(row: row)),
            const SizedBox(width: 16),
            SizedBox(
              width: 54,
              height: 3,
              child: Tooltip(
                message: [for (final s in flow.steps) s.label].join(' › '),
                child: OverflowBox(
                  // 4 x 12 + 3 x 3 = 57: the prototype's ticks spill 3px into the gap.
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: 57,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < flow.steps.length; i++) ...[
                        if (i > 0) const SizedBox(width: 3),
                        SizedBox(
                          width: 12,
                          height: 3,
                          child: ColoredBox(
                            color: _tickColor(flow.steps[i].tick),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: 32,
              child: Text(
                at == null ? '' : relativeAgo(at, now),
                textAlign: TextAlign.right,
                maxLines: 1,
                softWrap: false,
                style: HaroText.mono(color: HaroTokens.ink42, tracking: 0),
              ),
            ),
            const SizedBox(width: 16),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: HaroButton(
                label: flow.rowAction,
                height: 28,
                variant: primary
                    ? HaroButtonVariant.primary
                    : HaroButtonVariant.secondary,
                foreground: HaroTokens.ink86,
                onPressed: () => onAction(row),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Middle extends StatelessWidget {
  const _Middle({required this.row});

  final TriageRow row;

  @override
  Widget build(BuildContext context) {
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          row.workspace.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: HaroText.ui(size: 15, weight: FontWeight.w500),
        ),
        const SizedBox(height: 3),
        Text(
          '${row.projectName} · ${row.workspace.mode.wire} · ${row.workspace.branch}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: HaroText.mono(color: HaroTokens.ink42, tracking: 0),
        ),
      ],
    );
    final detail = Text(
      row.flow.rowDetail,
      style: HaroText.ui(size: 13.5, color: HaroTokens.ink66, height: 1.4),
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= _wrapBelow) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: name),
              const SizedBox(width: 24),
              Expanded(child: detail),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [name, const SizedBox(height: 3), detail],
        );
      },
    );
  }
}
