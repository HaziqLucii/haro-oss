import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/code/code_tokens.dart';
import 'package:haro_app/features/workspace/steps/code/syntax.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:re_highlight/re_highlight.dart';

/// The path re_editor takes: one registered language highlights directly, several
/// auto-detect among them (see `_code_highlight.dart` in re_editor).
TextSpan _render(Map<String, Mode> modes, String lang, String code) {
  final h = Highlight()..registerLanguages(modes);
  final r = TextSpanRenderer(null, syntaxStyles(colour: true));
  final result = modes.length == 1
      ? h.highlight(code: code, language: lang)
      : h.highlightAuto(code, modes.keys.toList());
  expect(result.language, lang, reason: 'auto-detection must not pick xml');
  result.render(r);
  return r.span!;
}

Map<String, Color?> _colours(TextSpan root) {
  final out = <String, Color?>{};
  void walk(InlineSpan s) {
    if (s is! TextSpan) return;
    final t = s.text;
    if (t != null && t.trim().isNotEmpty) out[t.trim()] = s.style?.color;
    s.children?.forEach(walk);
  }

  walk(root);
  return out;
}

void main() {
  const tsx = 'const a = <div className="page" id={x}>hi</div>;';

  test('the editor registers xml beside typescript and javascript for JSX', () {
    for (final lang in ['typescript', 'javascript']) {
      expect(
        modesForEditor(lang).keys,
        containsAll([lang, 'xml']),
        reason: lang,
      );
    }
    expect(modesForEditor('python').keys, ['python']);
    expect(modesForEditor('nope'), isEmpty);
  });

  test('JSX tags and attribute names are coloured, not plain bone', () {
    final c = _colours(
      _render(modesForEditor('typescript'), 'typescript', tsx),
    );
    expect(c['div'], SyntaxColors.keyword, reason: 'tag name');
    expect(c['className'], SyntaxColors.function, reason: 'attribute name');
    expect(c['"page"'], SyntaxColors.string, reason: 'attribute value');
  });

  test('a plain TypeScript file still highlights as typescript', () {
    final c = _colours(
      _render(
        modesForEditor('typescript'),
        'typescript',
        'export const n: number = 1; function f() { return "x"; }',
      ),
    );
    expect(c['export'], SyntaxColors.keyword);
    expect(c['"x"'], SyntaxColors.string);
  });

  test(
    'without xml registered JSX stays plain (what the editor did before)',
    () {
      final only = {'typescript': modesForEditor('typescript')['typescript']!};
      final c = _colours(_render(only, 'typescript', tsx));
      expect(c['className'], isNot(SyntaxColors.function));
    },
  );

  test(
    'monochrome keeps attribute names off the palette and leaves tag unstyled',
    () {
      final s = syntaxStyles(colour: false);
      expect(s['attr']?.color, HaroTokens.ink86);
      expect(s['tag'], isNull, reason: 'monochrome stays the original look');
    },
  );
}
