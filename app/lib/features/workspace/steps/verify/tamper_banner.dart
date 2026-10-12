import 'package:flutter/widgets.dart';

import '../../../../state/verdict.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import 'verify_model.dart';
import 'verify_widgets.dart';

/// Zone 2 (spec 5.6): a test was removed or weakened on the way here. The 1px red border is
/// the whole treatment; nothing else on the page is outlined in a state colour.
class TamperBanner extends StatelessWidget {
  const TamperBanner({
    super.key,
    required this.alarm,
    required this.busy,
    required this.onSee,
    this.onRestore,
  });

  final TamperAlarm alarm;
  final bool busy;
  final VoidCallback onSee;

  /// Null on a merged tree, where there is nothing left to send back.
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: HaroTokens.fail),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: LayoutBuilder(
        builder: (context, c) {
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                alarm.blocked
                    ? 'TAMPER ALARM · BLOCKS THE MERGE'
                    : 'TAMPER ALARM',
                style: HaroText.mono(
                  size: 11,
                  weight: FontWeight.w700,
                  color: HaroTokens.fail,
                  tracking: .2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                alarm.headline,
                key: const ValueKey('tamper-headline'),
                style: HaroText.ui(size: 17, weight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                tamperDetail(alarm),
                key: const ValueKey('tamper-detail'),
                style: HaroText.ui(
                  size: 13.5,
                  color: HaroTokens.ink66,
                  height: 1.45,
                ),
              ),
            ],
          );
          final buttons = Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Fit(
                child: HaroButton(
                  key: const ValueKey('tamper-see'),
                  label: 'See deletion',
                  foreground: HaroTokens.ink86,
                  onPressed: onSee,
                ),
              ),
              if (onRestore != null)
                Fit(
                  child: HaroButton(
                    key: const ValueKey('tamper-restore'),
                    label: alarm.count > 1 ? 'Restore tests' : 'Restore test',
                    foreground: busy ? HaroTokens.ink42 : HaroTokens.ink86,
                    onPressed: busy ? null : onRestore,
                  ),
                ),
            ],
          );
          if (c.maxWidth < narrowWidth) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, const SizedBox(height: 14), buttons],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: text),
              const SizedBox(width: 18),
              buttons,
            ],
          );
        },
      ),
    ),
  );
}
