import 'package:flutter/widgets.dart';

import '../../workspace/steps/code/code_tokens.dart';
import '../../../theme/coding_font.dart';
import '../../../theme/tokens.dart';

/// A few lines of code in the chosen coding font and syntax colour mode, drawn with the same
/// style map as the diff and editor, so both can be judged before saving. `=>` and `!==`
/// show ligatures.
class CodeFontPreview extends StatelessWidget {
  const CodeFontPreview({
    super.key,
    required this.font,
    this.syntaxColour = true,
  });

  final String font;
  final bool syntaxColour;

  static const _lines = <List<(String, _Kind)>>[
    [('// free shipping kicks in at the threshold', _Kind.comment)],
    [
      ('export const ', _Kind.keyword),
      ('shippingFor', _Kind.function),
      (' = (total: ', _Kind.plain),
      ('number', _Kind.type),
      (') =>', _Kind.plain),
    ],
    [
      ('  total >= ', _Kind.plain),
      ('100', _Kind.number),
      (' ? ', _Kind.plain),
      ('0', _Kind.number),
      (' : rates[', _Kind.plain),
      ("'standard'", _Kind.string),
      (']', _Kind.plain),
    ],
    [
      ('if', _Kind.keyword),
      (' (label !== ', _Kind.plain),
      ("'free'", _Kind.string),
      (') { ', _Kind.plain),
      ('return', _Kind.keyword),
      (' {0O1lI|} }', _Kind.plain),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final base = codingTextStyle(
      font,
      fontSize: 13,
      height: 1.6,
      color: HaroTokens.ink86,
    );
    final styles = syntaxStyles(colour: syntaxColour);
    TextStyle styleOf(_Kind k) => switch (k) {
      _Kind.plain => base,
      final k => base.merge(styles[k.scope]),
    };
    return Container(
      key: const ValueKey('code-font-preview'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: HaroTokens.bg,
        border: Border.all(color: HaroTokens.line12),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text.rich(
          TextSpan(
            children: [
              for (var i = 0; i < _lines.length; i++) ...[
                if (i > 0) TextSpan(text: '\n', style: base),
                for (final (text, kind) in _lines[i])
                  TextSpan(text: text, style: styleOf(kind)),
              ],
            ],
          ),
          softWrap: false,
        ),
      ),
    );
  }
}

enum _Kind {
  plain(''),
  keyword('keyword'),
  string('string'),
  number('number'),
  function('title.function_'),
  type('type'),
  comment('comment');

  const _Kind(this.scope);

  final String scope;
}
