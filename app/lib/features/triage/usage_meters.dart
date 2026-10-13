import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/models.dart';
import '../../data/workspace_store.dart' show haroApiProvider;
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../settings/settings_logic.dart' show resetLabel;

/// Your Claude plan limits, read on each visit to the dashboard. Null when the usage service
/// is unreachable or there is no login: the meters then simply do not appear.
final dashboardUsageProvider = FutureProvider.autoDispose<UsageResponse?>((
  ref,
) async {
  try {
    return await ref.read(haroApiProvider).usage();
  } catch (_) {
    return null;
  }
});

/// The windows worth a glance, in order, with their short names. Anything else the service
/// reports keeps its own label, upper-cased.
String usageShortName(UsageLimit l) => switch (l.kind) {
  'session' => 'SESSION',
  'weekly_all' => 'WEEK',
  _ => l.label.toUpperCase(),
};

/// Which limits the dashboard shows: the session and the weekly total always, other windows
/// only once they have been touched, and at most three rows.
List<UsageLimit> dashboardLimits(List<UsageLimit> all) {
  final shown = [
    for (final l in all)
      if (l.kind == 'session' ||
          l.kind == 'weekly_all' ||
          (l.percent ?? 0) >= 1)
        l,
  ];
  return shown.take(3).toList();
}

/// A few hairline bars: how much of each plan window is used and when it resets. The weekly
/// cap is the real ceiling on a team seat, so it earns a place where you look first. Hierarchy
/// comes from ink opacity only (the bar brightens as the window fills); red stays for failures.
class UsageMeters extends ConsumerWidget {
  const UsageMeters({super.key, this.width = 280});

  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dashboardUsageProvider).value;
    if (data == null || !data.available) return const SizedBox.shrink();
    final limits = dashboardLimits(data.limits);
    if (limits.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      key: const ValueKey('usage-meters'),
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < limits.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            _Row(limit: limits[i]),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.limit});

  final UsageLimit limit;

  @override
  Widget build(BuildContext context) {
    final pct = (limit.percent ?? 0).clamp(0, 100).toDouble();
    final fill = switch (limit.severity) {
      'normal' => HaroTokens.ink66,
      _ => HaroTokens.ink,
    };
    final reset = resetLabel(limit.resetsAt)?.toLowerCase();
    final small = HaroText.mono(
      size: 10,
      color: HaroTokens.ink42,
      tracking: .12,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(usageShortName(limit), style: small),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                reset ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: small.copyWith(letterSpacing: 0),
              ),
            ),
            Text(
              '${pct.round()}%',
              key: ValueKey('usage-pct-${limit.kind}-${limit.label}'),
              style: HaroText.mono(
                size: 12,
                color: HaroTokens.ink,
                tracking: 0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 3,
          alignment: Alignment.centerLeft,
          color: HaroTokens.line12,
          child: FractionallySizedBox(
            widthFactor: pct / 100,
            child: Container(height: 3, color: fill),
          ),
        ),
      ],
    );
  }
}
