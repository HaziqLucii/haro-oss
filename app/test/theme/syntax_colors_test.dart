import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/workspace/steps/code/code_tokens.dart';
import 'package:haro_app/theme/tokens.dart';

double _lin(double c) =>
    c <= .03928 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    .2126 * _lin(c.r) + .7152 * _lin(c.g) + .0722 * _lin(c.b);

double contrast(Color a, Color b) {
  final hi = math.max(_luminance(a), _luminance(b));
  final lo = math.min(_luminance(a), _luminance(b));
  return (hi + .05) / (lo + .05);
}

/// [fg] painted at its own alpha over [bg].
Color over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

double hueOf(Color c) => HSLColor.fromColor(c).hue;

double hueGap(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

const _names = {
  'keyword': SyntaxColors.keyword,
  'string': SyntaxColors.string,
  'number': SyntaxColors.number,
  'function': SyntaxColors.function,
  'type': SyntaxColors.type,
};

void main() {
  group('SyntaxColors contrast', () {
    for (final e in _names.entries) {
      test('${e.key} is at least 4.5:1 on the canvas', () {
        expect(contrast(e.value, HaroTokens.bg), greaterThanOrEqualTo(4.5));
      });
      test('${e.key} holds 4.5:1 on panel and the diff tints', () {
        final backdrops = [
          HaroTokens.panel,
          over(HaroTokens.diffAddBg, HaroTokens.bg),
          over(HaroTokens.diffDelBg, HaroTokens.bg),
        ];
        for (final bg in backdrops) {
          expect(contrast(e.value, bg), greaterThanOrEqualTo(4.5));
        }
      });
      test('${e.key} holds 4.5:1 when dimmed on a deleted line', () {
        final dimmed = over(e.value.withValues(alpha: .72), HaroTokens.bg);
        final bg = over(HaroTokens.diffDelBg, HaroTokens.bg);
        expect(contrast(dimmed, bg), greaterThanOrEqualTo(4.5));
      });
    }

    test('every palette colour in the styles clears 4.5:1, dimmed too', () {
      final used = <Color>{};
      for (final dim in [false, true]) {
        for (final e in syntaxStyles(colour: true, dim: dim).entries) {
          final c = e.value.color!;
          final isPalette = SyntaxColors.all.any(
            (p) => p.r == c.r && p.g == c.g && p.b == c.b,
          );
          if (!isPalette) continue;
          used.add(c);
          final bg = over(HaroTokens.diffDelBg, HaroTokens.bg);
          expect(
            contrast(over(c, bg), bg),
            greaterThanOrEqualTo(4.5),
            reason: '${e.key} dim=$dim',
          );
        }
      }
      expect(used.length, greaterThanOrEqualTo(SyntaxColors.all.length));
    });
  });

  group('SyntaxColors never look like a reserved hue', () {
    for (final e in _names.entries) {
      test('${e.key} avoids green, red/pink and purple', () {
        final h = hueOf(e.value);
        final green = h >= 80 && h <= 170;
        final redPink = h >= 330 || h <= 15;
        final purple = h >= 250 && h <= 320;
        expect(green, isFalse, reason: 'hue $h');
        expect(redPink, isFalse, reason: 'hue $h');
        expect(purple, isFalse, reason: 'hue $h');
      });
      test('${e.key} keeps 25 degrees from gate, fail and merged', () {
        for (final reserved in [
          HaroTokens.gate,
          HaroTokens.fail,
          HaroTokens.merged,
        ]) {
          expect(
            hueGap(hueOf(e.value), hueOf(reserved)),
            greaterThanOrEqualTo(25),
          );
        }
      });
    }

    test('no colour style, in either mode, uses a reserved hue', () {
      for (final colour in [false, true]) {
        for (final e in syntaxStyles(colour: colour).entries) {
          final c = e.value.color!;
          final rgb = (c.r, c.g, c.b);
          for (final r in [
            HaroTokens.gate,
            HaroTokens.fail,
            HaroTokens.merged,
          ]) {
            expect(rgb, isNot((r.r, r.g, r.b)), reason: e.key);
          }
        }
      }
    });
  });

  group('syntaxStyles', () {
    test('colour maps each scope to its palette entry', () {
      final t = syntaxStyles(colour: true);
      for (final k in ['keyword', 'meta-keyword', 'built_in']) {
        expect(t[k]!.color, SyntaxColors.keyword, reason: k);
      }
      expect(t['keyword']!.fontWeight, FontWeight.w700);
      for (final k in ['string', 'regexp', 'meta-string']) {
        expect(t[k]!.color, SyntaxColors.string, reason: k);
      }
      for (final k in ['number', 'literal', 'symbol']) {
        expect(t[k]!.color, SyntaxColors.number, reason: k);
      }
      for (final k in ['title', 'title.function_', 'title.function']) {
        expect(t[k]!.color, SyntaxColors.function, reason: k);
      }
      for (final k in [
        'type',
        'title.class_',
        'title.class',
        'title.class.inherited',
      ]) {
        expect(t[k]!.color, SyntaxColors.type, reason: k);
      }
      for (final k in ['attr', 'attribute']) {
        expect(t[k]!.color, HaroTokens.ink86, reason: k);
      }
      expect(t['variable']!.color, HaroTokens.ink);
      expect(t['comment']!.color, HaroTokens.ink42);
      expect(t['comment']!.fontStyle, FontStyle.italic);
      expect(t['punctuation']!.color, HaroTokens.ink66);
      expect(t['operator']!.color, HaroTokens.ink66);
    });

    test('diff add and delete token classes are not styled', () {
      for (final colour in [false, true]) {
        final t = syntaxStyles(colour: colour);
        expect(t.containsKey('addition'), isFalse);
        expect(t.containsKey('deletion'), isFalse);
      }
    });

    test('monochrome is the original look, exactly', () {
      final t = syntaxStyles(colour: false);
      TextStyle s(Color c, {FontWeight? w, FontStyle? i}) =>
          TextStyle(color: c, fontWeight: w, fontStyle: i);
      final bold = s(HaroTokens.ink, w: FontWeight.w700);
      final strong = s(HaroTokens.ink86);
      final plain = s(HaroTokens.ink);
      final string = s(HaroTokens.ink66);
      final comment = s(HaroTokens.ink42, i: FontStyle.italic);
      final expected = <String, TextStyle>{
        'root': plain,
        'keyword': bold,
        'meta-keyword': bold,
        'selector-tag': bold,
        'template-tag': bold,
        'section': bold,
        'name': bold,
        'built_in': strong,
        'type': strong,
        'title': plain,
        'title.class_': bold,
        'title.class_.inherited__': strong,
        'title.function_': plain,
        'attr': strong,
        'attribute': strong,
        'variable': plain,
        'variable.language_': bold,
        'template-variable': strong,
        'literal': strong,
        'number': strong,
        'symbol': strong,
        'bullet': strong,
        'operator': plain,
        'punctuation': string,
        'property': plain,
        'params': plain,
        'string': string,
        'meta-string': string,
        'regexp': string,
        'subst': plain,
        'selector-class': strong,
        'selector-id': strong,
        'selector-attr': strong,
        'selector-pseudo': strong,
        'meta': s(HaroTokens.ink42),
        'comment': comment,
        'doctag': comment,
        'quote': comment,
        'code': comment,
        'formula': comment,
        'emphasis': s(HaroTokens.ink, i: FontStyle.italic),
        'strong': bold,
      };
      expect(t.keys.toSet(), expected.keys.toSet());
      for (final e in expected.entries) {
        expect(t[e.key], e.value, reason: e.key);
      }
      for (final s in t.values) {
        expect(SyntaxColors.all, isNot(contains(s.color)));
      }
    });

    test('dim fades every style', () {
      final a = syntaxStyles(colour: true)['string']!.color!;
      final b = syntaxStyles(colour: true, dim: true)['string']!.color!;
      expect(b.a, lessThan(a.a));
    });
  });

  group('DisplayPrefs.syntaxColour', () {
    test('defaults to colour', () {
      expect(const DisplayPrefs().syntaxColour, isTrue);
    });

    test('missing or unreadable values read as colour', () {
      expect(DisplayPrefs.fromJson({}).syntaxColour, isTrue);
      expect(
        DisplayPrefs.fromJson({'syntax_colour': 'nope'}).syntaxColour,
        isTrue,
      );
      expect(
        DisplayPrefs.fromJson({'syntax_colour': null}).syntaxColour,
        isTrue,
      );
    });

    test('off survives a round trip', () {
      final off = const DisplayPrefs().copyWith(syntaxColour: false);
      expect(off.toJson()['syntax_colour'], false);
      expect(DisplayPrefs.fromJson(off.toJson()).syntaxColour, isFalse);
    });
  });
}
