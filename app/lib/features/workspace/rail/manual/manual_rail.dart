import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../state/manual_rail.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_pressable.dart';
import 'docs_tab.dart';
import 'manual_controller.dart';
import 'plan_tab.dart';
import 'search_tab.dart';

/// Height the manual rail takes when the rail is too short to fill and scrolls as a whole.
/// Tabs scroll on their own.
const manualRailHeight = 520.0;

/// Below this much rail body height the manual rail keeps [manualRailHeight] in a scrolling
/// rail; at or above it the manual rail fills what the gate and app sections leave.
const manualRailMinFill = 640.0;

/// The manual workspace's right-rail working area (Finalized UI): Plan, Search, Docs. The AI
/// behind it is read-only, and the footer says exactly what it did.
class ManualRail extends ConsumerStatefulWidget {
  const ManualRail({super.key, required this.workspaceId, this.fill = false});

  final String workspaceId;

  /// Take the parent's height (inside an Expanded) instead of [manualRailHeight].
  final bool fill;

  @override
  ConsumerState<ManualRail> createState() => _ManualRailState();
}

class _ManualRailState extends ConsumerState<ManualRail> {
  String get workspaceId => widget.workspaceId;

  @override
  void initState() {
    super.initState();
    _resync();
  }

  @override
  void didUpdateWidget(ManualRail old) {
    super.didUpdateWidget(old);
    if (old.workspaceId != widget.workspaceId) _resync();
  }

  /// A job started before a reload or a workspace switch is still running server-side:
  /// re-read it so the tab shows it instead of an empty form.
  void _resync() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    unawaited(ref.read(manualRailProvider(workspaceId).notifier).resync());
  });

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(manualRailProvider(workspaceId));
    final docs = docItems(
      plans: s.plans,
      pinned: s.pinned,
      manPages: s.manPages,
    );
    String badge(ManualTab t) => switch (t) {
      ManualTab.plan => planTabBadge(s.activePlan),
      ManualTab.search => '',
      ManualTab.docs => docs.isEmpty ? '' : '${docs.length}',
    };
    return SizedBox(
      key: const ValueKey('manual-rail'),
      height: widget.fill ? null : manualRailHeight,
      child: Column(
        children: [
          Container(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: HaroTokens.line12),
                bottom: BorderSide(color: HaroTokens.line12),
              ),
            ),
            child: Row(
              children: [
                for (final t in ManualTab.values)
                  Expanded(
                    child: _TabButton(
                      key: ValueKey('manual-tab-${t.name}'),
                      label: t.label,
                      badge: badge(t),
                      active: s.tab == t,
                      onTap: () => ref
                          .read(manualRailProvider(workspaceId).notifier)
                          .setTab(t),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: switch (s.tab) {
              ManualTab.plan => PlanTab(workspaceId: workspaceId),
              ManualTab.search => SearchTab(workspaceId: workspaceId),
              ManualTab.docs => DocsTab(workspaceId: workspaceId),
            },
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: HaroTokens.line12)),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                manualFooterFor(unverified: s.unverified),
                key: const ValueKey('manual-footer'),
                style: HaroText.mono(
                  size: 10,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.label,
    required this.badge,
    required this.active,
    required this.onTap,
  });

  final String label;
  final String badge;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: label,
    builder: (context, hovered) => Container(
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: active ? HaroTokens.ink : HaroTokens.transparent,
            width: 2,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: HaroText.ui(
              size: 13,
              color: active || hovered ? HaroTokens.ink : HaroTokens.ink66,
            ),
          ),
          if (badge.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              badge,
              style: HaroText.mono(
                size: 10,
                color: HaroTokens.ink42,
                tracking: 0,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
