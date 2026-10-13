import 'package:flutter/widgets.dart';

import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../theme/ui_fonts.dart';

/// A line in the interface font and a paragraph in the text font, drawn from the draft picks (not
/// the applied ones), so both can be judged before saving. A null family is the theme's own font.
class UiFontPreview extends StatelessWidget {
  const UiFontPreview({
    super.key,
    required this.interfaceFamily,
    required this.textFamily,
  });

  final String? interfaceFamily;
  final String? textFamily;

  @override
  Widget build(BuildContext context) {
    final theme = HaroTokens.palette.fontUi;
    final ui = interfaceFamily ?? theme;
    final text = textFamily ?? ui;
    TextStyle style(String family, double size, Color color, double? height) =>
        TextStyle(
          fontFamily: family,
          fontFamilyFallback: [theme, ...uiFontFallback],
          fontSize: size,
          color: color,
          height: height,
        );
    return Container(
      key: const Key('ui-font-preview'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: HaroTokens.panel,
        border: Border.all(color: HaroTokens.line12),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'INTERFACE',
            style: HaroText.mono(size: 10, color: HaroTokens.ink42),
          ),
          const SizedBox(height: 4),
          Text(
            'Dashboard, review, ship: 0123456789',
            key: const Key('ui-font-preview-interface'),
            style: style(ui, 14, HaroTokens.ink, null),
          ),
          const SizedBox(height: 12),
          Text('TEXT', style: HaroText.mono(size: 10, color: HaroTokens.ink42)),
          const SizedBox(height: 4),
          Text(
            'The agent read the diff and found the rounding bug in the shipping rate. '
            'Each fix keeps a test beside it.',
            key: const Key('ui-font-preview-text'),
            style: style(text, 15, HaroTokens.ink86, 1.6),
          ),
        ],
      ),
    );
  }
}
