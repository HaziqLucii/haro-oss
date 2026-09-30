import 'package:flutter/widgets.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';

class Kbd extends StatelessWidget {
  const Kbd(
    this.label, {
    super.key,
    this.bordered = true,
    this.color = HaroTokens.ink42,
    this.size = 10.5,
  });

  final String label;
  final bool bordered;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      maxLines: 1,
      softWrap: false,
      style: HaroText.mono(size: size, color: color, tracking: 0),
    );
    if (!bordered) return text;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: HaroTokens.line14),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: text,
      ),
    );
  }
}
