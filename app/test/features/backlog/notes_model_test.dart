import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/backlog/notes_model.dart';

void main() {
  group('lineOrSelection', () {
    const text = 'first line\n- [ ] second line\n\nlast';
    test('a collapsed cursor takes its line', () {
      expect(
        lineOrSelection(text, const TextSelection.collapsed(offset: 3)),
        'first line',
      );
      expect(
        lineOrSelection(text, const TextSelection.collapsed(offset: 15)),
        '- [ ] second line',
      );
      expect(
        lineOrSelection(
          text,
          const TextSelection.collapsed(offset: text.length),
        ),
        'last',
      );
    });

    test('a blank line gives nothing', () {
      expect(
        lineOrSelection(text, const TextSelection.collapsed(offset: 29)),
        '',
      );
    });

    test('a selection wins over the line', () {
      expect(
        lineOrSelection(
          text,
          const TextSelection(baseOffset: 6, extentOffset: 10),
        ),
        'line',
      );
    });

    test('an invalid selection gives nothing', () {
      expect(
        lineOrSelection(text, const TextSelection.collapsed(offset: -1)),
        '',
      );
    });
  });

  group('todoTextFrom', () {
    test('drops bullets, checkboxes, headings and numbers', () {
      expect(todoTextFrom('- [ ] cache the lookups'), 'cache the lookups');
      expect(todoTextFrom('* [x] done thing'), 'done thing');
      expect(todoTextFrom('## Caching'), 'Caching');
      expect(todoTextFrom('3. third idea'), 'third idea');
      expect(todoTextFrom('plain'), 'plain');
    });

    test('folds several lines onto one', () {
      expect(todoTextFrom('- one\n\n- two\n  three'), 'one two three');
    });
  });

  group('notePathFrom', () {
    test('adds .md and joins spaces', () {
      expect(notePathFrom('caching ideas'), 'caching-ideas.md');
      expect(notePathFrom('design/api'), 'design/api.md');
      expect(notePathFrom('Keep.MD'), 'Keep.MD');
    });

    test('refuses anything that is not a plain relative name', () {
      for (final bad in ['', '  ', '/etc/x', '../x', 'a/../b', 'folder/']) {
        expect(notePathFrom(bad), isNull, reason: bad);
      }
    });
  });

  test('noteTitleFor reads the file name', () {
    expect(noteTitleFor('caching-ideas.md'), 'Caching ideas');
    expect(noteTitleFor('design/api_sketch.md'), 'Api sketch');
    expect(noteTitleFor('.md'), 'Note');
  });

  test('relativeTime', () {
    final now = DateTime(2026, 10, 10, 12);
    double ago(Duration d) => now.subtract(d).millisecondsSinceEpoch / 1000;
    expect(relativeTime(ago(const Duration(seconds: 20)), now), 'just now');
    expect(relativeTime(ago(const Duration(minutes: 5)), now), '5 min ago');
    expect(relativeTime(ago(const Duration(hours: 3)), now), '3 h ago');
    expect(relativeTime(ago(const Duration(days: 2)), now), '2 d ago');
    expect(relativeTime(ago(const Duration(days: 60)), now), '2026-08-11');
  });

  group('wikiToMarkdown', () {
    test('a wikilink becomes a link with its alias or its target', () {
      expect(
        wikiToMarkdown(
          'see [[Cache ideas]] and [[design/api#auth|the auth part]]',
        ),
        'see [Cache ideas](haro-note:Cache%20ideas) and [the auth part](haro-note:design%2Fapi)',
      );
    });

    test('a tag becomes a link, a heading and a URL fragment do not', () {
      expect(
        wikiToMarkdown('# Title\n#perf and at https://x.dev/#frag'),
        '# Title\n[#perf](haro-tag:perf) and at https://x.dev/#frag',
      );
    });

    test('#123 is an issue link, a heading or a URL fragment is not', () {
      expect(
        wikiToMarkdown('# Title\nsee #123 and https://x.dev/#45'),
        '# Title\nsee [#123](haro-issue:123) and https://x.dev/#45',
      );
      expect(issueNumberFrom('haro-issue:123'), 123);
    });

    test('[[todo:id text]] is a todo link showing the text', () {
      expect(
        wikiToMarkdown('do [[todo:ab12cd Fix the cart]] soon'),
        'do [Fix the cart](haro-todo:ab12cd) soon',
      );
      expect(todoIdFrom('haro-todo:ab12cd'), 'ab12cd');
    });

    test('`path:line` is a code link, but not inside a fence', () {
      expect(
        wikiToMarkdown('see `src/price.js:12-20` here'),
        'see [`src/price.js:12-20`](haro-code:src%2Fprice.js%3A12) here',
      );
      expect(
        wikiToMarkdown('```\n`src/a.js:1`\n```'),
        '```\n`src/a.js:1`\n```',
      );
      expect(codeRefFrom('haro-code:src%2Fprice.js%3A12'), (
        'src/price.js',
        12,
      ));
    });

    test('code is left alone', () {
      const text = '```\n[[no]] #no\n```\nand `[[no]] #no` but [[yes]]';
      expect(
        wikiToMarkdown(text),
        '```\n[[no]] #no\n```\nand `[[no]] #no` but [yes](haro-note:yes)',
      );
    });

    test('noteLinkFrom reads both schemes and nothing else', () {
      expect(noteLinkFrom('haro-note:Cache%20ideas'), (
        tag: false,
        value: 'Cache ideas',
      ));
      expect(noteLinkFrom('haro-tag:perf%2Fdb'), (tag: true, value: 'perf/db'));
      expect(noteLinkFrom('https://x.dev'), isNull);
    });
  });

  group('wikiToMarkdown, the same rules as the backend', () {
    test('masking is linear on a long run of backticks', () {
      final sw = Stopwatch()..start();
      maskCode('x${'`' * 20000}\n${'a `b` [[c]]\n' * 5000}');
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });

    test('fences match their own marker; an inline triple or four spaces is not one', () {
      expect(
        wikiToMarkdown(
          '```x``` [[a]]\n```\n[[b]]\n```\n[[c]]\n~~~\n```\n[[d]]\n~~~\n[[e]]',
        ),
        '```x``` [a](haro-note:a)\n```\n[[b]]\n```\n[c](haro-note:c)\n~~~\n```\n[[d]]\n~~~\n[e](haro-note:e)',
      );
      expect(wikiToMarkdown('    ```\n[[a]]'), '    ```\n[a](haro-note:a)');
    });

    test('unicode tags, and a parenthesis in a target is encoded', () {
      expect(
        wikiToMarkdown('#naïve é#no'),
        '[#naïve](haro-tag:na%C3%AFve) é#no',
      );
      expect(wikiToMarkdown('[[a (b)]]'), '[a (b)](haro-note:a%20%28b%29)');
      expect(noteLinkFrom('haro-note:a%20%28b%29'), (
        tag: false,
        value: 'a (b)',
      ));
    });
  });

  group('files, embeds and properties', () {
    test('an embedded image is an image, a note embed is a plain link', () {
      expect(
        wikiToMarkdown(
          '![[banners/hero.png]] and ![[hero.gif|300]] and ![[Other note]]',
        ),
        '![banners/hero.png](banners%2Fhero.png) and ![hero.gif](hero.gif) and '
        '[Other note](haro-note:Other%20note)',
      );
    });

    test('a link to a file is a file link, never a note to create', () {
      expect(
        wikiToMarkdown(
          'see [[source-materials/report.pdf]] and ![[plan.xlsx|the plan]]',
        ),
        'see [report.pdf](haro-file:source-materials%2Freport.pdf) and '
        '[plan.xlsx](haro-file:plan.xlsx)',
      );
      expect(
        fileLinkFrom('haro-file:source-materials%2Freport.pdf'),
        'source-materials/report.pdf',
      );
      expect(fileLinkFrom('haro-note:x'), isNull);
    });

    test(
      'an Excalidraw drawing embeds as its exported picture when there is one',
      () {
        expect(
          wikiToMarkdown(
            '![[sketch.excalidraw]]',
            knownFiles: {'sketch.excalidraw.png'},
          ),
          '![sketch.excalidraw](sketch.excalidraw.png)',
        );
        expect(
          wikiToMarkdown('![[sketch.excalidraw]]'),
          '[sketch.excalidraw](haro-file:sketch.excalidraw)',
        );
      },
    );

    test('code is left alone, so an example [[x.pdf]] stays text', () {
      expect(wikiToMarkdown('`[[x.pdf]]`'), '`[[x.pdf]]`');
    });

    test('a leading --- block becomes properties and leaves the body', () {
      final (props, body) = splitFrontMatter(
        '---\ntitle: Plan\nbanner: "![[banners/x.gif]]"\ntags:\n  - sap\n  - vpn\n---\n\n# Body\n',
      );
      expect(props, [
        ('title', 'Plan'),
        ('banner', '![[banners/x.gif]]'),
        ('tags', 'sap, vpn'),
      ]);
      expect(body, '# Body\n');
    });

    test('text without a closed block, or with a line that is not a property, is left as written', () {
      expect(splitFrontMatter('# Title\n---\nx: 1\n---\n').$1, isEmpty);
      expect(splitFrontMatter('---\nnot a property\n---\nbody').$1, isEmpty);
      expect(splitFrontMatter('---\nx: 1\nno end').$1, isEmpty);
    });
  });
}
