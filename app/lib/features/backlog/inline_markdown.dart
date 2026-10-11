import 'package:flutter/painting.dart';

import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';

final _inline = RegExp(r'`([^`]+)`|\*\*([^*]+)\*\*|\*([^*]+)\*');

/// `code`, **bold** and *italic* only. Backlog prose is read-only and never needs blocks or
/// links, so a full markdown renderer would be dead weight here.
TextSpan inlineMarkdown(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    final code = m.group(1);
    final bold = m.group(2);
    final italic = m.group(3);
    if (code != null) {
      spans.add(
        TextSpan(
          text: code,
          style: HaroText.mono(
            size: (base.fontSize ?? 14) * .9,
            tracking: 0,
            color: HaroTokens.ink,
          ),
        ),
      );
    } else if (bold != null) {
      spans.add(
        inlineMarkdown(bold, base.copyWith(fontWeight: FontWeight.w600)),
      );
    } else if (italic != null) {
      spans.add(
        inlineMarkdown(italic, base.copyWith(fontStyle: FontStyle.italic)),
      );
    }
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return TextSpan(style: base, children: spans);
}

/// Markdown marks removed, for places that only show plain text (titles, ellipsized rows).
String stripInlineMarkdown(String text) => text.replaceAllMapped(
  _inline,
  (m) => m.group(1) ?? m.group(2) ?? m.group(3) ?? '',
);
