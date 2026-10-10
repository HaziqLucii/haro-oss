import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/code/code_providers.dart';
import 'package:haro_app/features/workspace/steps/code/code_tokens.dart';
import 'package:haro_app/features/workspace/steps/code/quick_open.dart';
import 'package:haro_app/features/workspace/steps/code/syntax.dart';
import 'package:haro_app/theme/tokens.dart';

import 'code_harness.dart';

void main() {
  group('file tree helpers', () {
    final tree = [
      file('zed.txt'),
      dir('lib', [
        file('lib/b.ts'),
        dir('lib/deep', [file('lib/deep/x.ts')]),
      ]),
      file('Alpha.md'),
    ];

    test('flattenFilePaths lists files only, depth first', () {
      expect(flattenFilePaths(tree), [
        'zed.txt',
        'lib/b.ts',
        'lib/deep/x.ts',
        'Alpha.md',
      ]);
    });

    test('visibleTreeRows: directories first, children only when expanded', () {
      final collapsed = visibleTreeRows(tree, {});
      expect(collapsed.map((r) => r.node.name), ['lib', 'Alpha.md', 'zed.txt']);

      final open = visibleTreeRows(tree, {'lib'});
      expect(open.map((r) => (r.node.name, r.depth)), [
        ('lib', 0),
        ('deep', 1),
        ('b.ts', 1),
        ('Alpha.md', 0),
        ('zed.txt', 0),
      ]);
      expect(open.first.expanded, isTrue);
    });
  });

  test('virtualenvs and tool caches are dropped from the tree, nested too', () {
    final cleaned = withoutNoise([
      dir('.venv', [file('.venv/x.py')]),
      dir('backend', [
        dir('backend/.venv', [file('backend/.venv/y.py')]),
        dir('backend/__pycache__', [file('backend/__pycache__/z.pyc')]),
        file('backend/app.py'),
      ]),
      file('.venv'),
    ]);
    expect(flattenFilePaths(cleaned), ['backend/app.py', '.venv']);
  });

  test('quick open ranks changed files first and lists each path once', () {
    expect(quickOpenCandidates(['b.ts', 'a.ts'], ['a.ts', 'c.ts', 'b.ts']), [
      'b.ts',
      'a.ts',
      'c.ts',
    ]);
  });

  group('syntax', () {
    test('languageForPath', () {
      expect(languageForPath('lib/rates.ts'), 'typescript');
      expect(languageForPath('a/b/App.TSX'), 'typescript');
      expect(languageForPath('main.py'), 'python');
      expect(languageForPath('Dockerfile'), 'dockerfile');
      expect(languageForPath('README'), isNull);
      expect(languageForPath('notes.txt'), isNull);
      expect(languageForPath('trailing.'), isNull);
    });

    test('the palette never uses the gate or failure colours', () {
      for (final dim in [false, true]) {
        for (final e in syntaxStyles(colour: false, dim: dim).entries) {
          final c = e.value.color!;
          final rgb = (c.r, c.g, c.b);
          expect(
            rgb,
            isNot((HaroTokens.gate.r, HaroTokens.gate.g, HaroTokens.gate.b)),
          );
          expect(
            rgb,
            isNot((HaroTokens.fail.r, HaroTokens.fail.g, HaroTokens.fail.b)),
          );
          expect(
            rgb,
            isNot((
              HaroTokens.merged.r,
              HaroTokens.merged.g,
              HaroTokens.merged.b,
            )),
          );
        }
      }
    });

    test('keywords are bolder, comments italic and dim, strings ink 66', () {
      final t = syntaxStyles(colour: false);
      expect(t['keyword']!.fontWeight, FontWeight.w700);
      expect(t['comment']!.fontStyle, FontStyle.italic);
      expect(t['comment']!.color, HaroTokens.ink42);
      expect(t['string']!.color, HaroTokens.ink66);
    });

    test('LineHighlighter highlights known languages and skips the rest', () {
      final h = LineHighlighter();
      final span = h.highlight('const a = "x"; // hi', 'typescript');
      expect(span, isNotNull);
      final styles = <String, TextStyle?>{};
      span!.visitChildren((s) {
        if (s is TextSpan && s.text != null) styles[s.text!] = s.style;
        return true;
      });
      expect(styles['const']?.fontWeight, FontWeight.w700);
      expect(h.highlight('plain', null), isNull);
      expect(h.highlight('', 'typescript'), isNull);
      expect(h.highlight('x' * 5000, 'typescript'), isNull);
    });

    test('dim spans are fainter than normal ones', () {
      final a = syntaxStyles(colour: false)['string']!.color!;
      final b = syntaxStyles(colour: false, dim: true)['string']!.color!;
      expect(b.a, lessThan(a.a));
    });
  });

  test('tokens: list width bounds match the spec', () {
    expect(CodeTokens.listWidthMax, 260);
    expect(CodeTokens.listWidthMin, lessThan(CodeTokens.listWidthMax));
  });
}
