import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/xp_store.dart';
import '../../state/format.dart' show plural;
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_icons.dart';
import '../settings/xp_prefs_provider.dart';

/// `yyyy-mm-dd` of the local day, the key a dismissal is stored under.
String xpDayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// One plain line in triage while today has no merge written by hand. Hidden when XP or the
/// reminder is off in Settings, once today has its merge, and for the rest of the day after a
/// dismissal.
class XpNudge extends ConsumerWidget {
  const XpNudge({super.key, required this.today});

  /// [xpDayKey] of now.
  final String today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(xpPrefsProvider);
    final status = ref.watch(xpStoreProvider.select((s) => s.status));
    final dismissed = ref.watch(xpNudgeDismissedProvider);
    if (!prefs.showXp ||
        !prefs.streakReminder ||
        status == null ||
        status.todayDone ||
        dismissed == today) {
      return const SizedBox.shrink();
    }
    final n = status.streakDays;
    final text = n > 0
        ? 'Your streak is $n ${plural(n, 'day')}. Finish one by hand today.'
        : 'No streak yet. Finish one by hand today.';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Row(
        key: const ValueKey('xp-nudge'),
        children: [
          Expanded(
            child: Text(
              text,
              key: const ValueKey('xp-nudge-text'),
              style: HaroText.ui(
                size: 14,
                color: HaroTokens.ink66,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ShellIconButton(
            key: const ValueKey('xp-nudge-dismiss'),
            icon: ShellIcon.close,
            tooltip: 'Dismiss for today',
            width: 26,
            onTap: () =>
                ref.read(xpNudgeDismissedProvider.notifier).dismiss(today),
          ),
        ],
      ),
    );
  }
}
