import 'package:flutter/painting.dart';

import '../../../../theme/coding_font.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';

/// Sizes for the code step. Colours come straight from [HaroTokens]; nothing here is a hex.
abstract final class CodeTokens {
  static const double listWidthMax = 260;
  static const double listWidthMin = 170;
  static const double listWidthFraction = .24;
  static const double listPadX = 16;
  static const double proofSquare = 6;

  static const double headerMinHeight = 44;
  static const double headerPadX = 20;

  static const double diffFont = 12.5;
  static const double diffRowHeight = 22;
  static const double diffMarkerCol = 22;
  static const double diffNumberCol = 44;
  static const double diffSignCol = 16;
  static const double diffTextPad = 6;

  /// Lines longer than this are shown plain and clipped: highlighting or laying out a
  /// minified bundle line would stall the frame.
  static const int diffMaxHighlightChars = 1000;
  static const int diffMaxRenderChars = 4000;

  static const double editorFont = 13;
  static const double editorLineHeight = 1.7;
  static const double editorFooterHeight = 30;

  static const double quickOpenWidth = 560;
  static const int quickOpenMaxRows = 60;
  static const double quickOpenRowHeight = 32;

  static TextStyle diffText(
    String codingFont, {
    Color color = HaroTokens.ink,
  }) =>
      codingTextStyle(codingFont, fontSize: diffFont, color: color, height: 1);

  static TextStyle label({
    Color color = HaroTokens.ink42,
    double size = 10.5,
  }) => HaroText.mono(size: size, color: color, tracking: .14);
}

final _styleCache = <(bool, bool), Map<String, TextStyle>>{};

/// The one scope-to-style mapping for highlighted code (diff, editor, agent code blocks and
/// the Display preview). Monochrome is the original look: hierarchy from ink opacity, weight
/// and italics only. Colour swaps in [SyntaxColors] for keywords, strings, numbers, function
/// names and types; comments, attributes and variables keep their ink styles. [dim] fades a
/// deleted diff line.
Map<String, TextStyle> syntaxStyles({required bool colour, bool dim = false}) =>
    _styleCache.putIfAbsent((colour, dim), () => _buildStyles(colour, dim));

Map<String, TextStyle> _buildStyles(bool colour, bool dim) {
  Color c(Color base) => dim ? base.withValues(alpha: base.a * .72) : base;
  TextStyle s(Color color, {FontWeight? weight, FontStyle? style}) =>
      TextStyle(color: c(color), fontWeight: weight, fontStyle: style);

  final plain = s(HaroTokens.ink);
  final strong = s(HaroTokens.ink86);
  final punct = s(HaroTokens.ink66);
  final comment = s(HaroTokens.ink42, style: FontStyle.italic);
  final meta = s(HaroTokens.ink42);

  final keyword = colour
      ? s(SyntaxColors.keyword, weight: FontWeight.w700)
      : s(HaroTokens.ink, weight: FontWeight.w700);
  final builtIn = colour ? s(SyntaxColors.keyword) : strong;
  final type = colour ? s(SyntaxColors.type) : strong;
  final string = colour ? s(SyntaxColors.string) : punct;
  final number = colour ? s(SyntaxColors.number) : strong;
  final function = colour ? s(SyntaxColors.function) : plain;
  final className = colour
      ? s(SyntaxColors.type)
      : s(HaroTokens.ink, weight: FontWeight.w700);
  final selector = colour ? s(SyntaxColors.type) : strong;

  return {
    if (colour) ...{
      // re_highlight emits dotted scopes without the trailing underscore of the
      // highlight.js theme names below. Monochrome leaves them unstyled, as it always was.
      'title.function': function,
      'title.class': className,
      'title.class.inherited': type,
    },
    'root': plain,
    'keyword': keyword,
    'meta-keyword': keyword,
    'selector-tag': keyword,
    'template-tag': keyword,
    'section': keyword,
    'name': keyword,
    'built_in': builtIn,
    'type': type,
    'title': function,
    'title.class_': className,
    'title.class_.inherited__': type,
    'title.function_': function,
    'attr': strong,
    'attribute': strong,
    'variable': plain,
    'variable.language_': keyword,
    'template-variable': strong,
    'literal': number,
    'number': number,
    'symbol': number,
    'bullet': number,
    'operator': colour ? punct : plain,
    'punctuation': punct,
    'property': plain,
    'params': plain,
    'string': string,
    'meta-string': string,
    'regexp': string,
    'subst': plain,
    'selector-class': selector,
    'selector-id': selector,
    'selector-attr': strong,
    'selector-pseudo': strong,
    'meta': meta,
    'comment': comment,
    'doctag': comment,
    'quote': comment,
    'code': comment,
    'formula': comment,
    'emphasis': s(HaroTokens.ink, style: FontStyle.italic),
    'strong': s(HaroTokens.ink, weight: FontWeight.w700),
  };
}
