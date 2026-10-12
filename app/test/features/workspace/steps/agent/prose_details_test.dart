import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_markdown.dart';
import 'package:haro_app/features/workspace/steps/agent/prose_details.dart';
import 'package:haro_app/widgets/issue_comment_card.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('splitDetails', () {
    test('a text with no details block is one markdown segment', () {
      final s = splitDetails('plain **text**');
      expect(s, hasLength(1));
      expect((s.single as MarkdownSegment).text, 'plain **text**');
    });

    test('splits text, summary and body', () {
      final s = splitDetails(
        'before\n<details>\n<summary>As <b>delivered</b>,\n 2026</summary>\n\n- a\n- b\n</details>\nafter',
      );
      expect(s, hasLength(3));
      expect((s[0] as MarkdownSegment).text, 'before\n');
      final d = s[1] as DetailsSegment;
      expect(d.summary, 'As delivered, 2026');
      expect(d.body, '- a\n- b');
      expect(d.open, isFalse);
      expect((s[2] as MarkdownSegment).text, '\nafter');
    });

    test('the open attribute and a missing summary', () {
      final d =
          splitDetails('<details open>\nbody\n</details>').single
              as DetailsSegment;
      expect(d.open, isTrue);
      expect(d.summary, 'Details');
      expect(d.body, 'body');
    });

    test('a nested block stays inside its parent', () {
      final d =
          splitDetails(
                '<details><summary>a</summary>x<details><summary>b</summary>y</details>z</details>',
              ).single
              as DetailsSegment;
      expect(d.summary, 'a');
      expect(d.body, contains('<details><summary>b</summary>y</details>'));
    });

    test('a sentence that mentions the tags in inline code is left alone', () {
      final s = splitDetails(
        'GitHub wraps it in `<details>` and `</details>` tags',
      );
      expect(s, hasLength(1));
      expect(s.single, isA<MarkdownSegment>());
    });

    test('an unclosed block and a fenced one are left alone', () {
      expect(splitDetails('<details><summary>x</summary>never closed'), [
        isA<MarkdownSegment>(),
      ]);
      final fenced = splitDetails(
        '```html\n<details><summary>x</summary>y</details>\n```',
      );
      expect(fenced, hasLength(1));
      expect(fenced.single, isA<MarkdownSegment>());
    });
  });

  group('rendering', () {
    testWidgets('a details block is collapsed until its summary is tapped', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const AgentProse(
            '<details><summary>Baseline</summary>\n\nSecret body\n</details>',
          ),
        ),
      );
      expect(find.text('Baseline'), findsOneWidget);
      expect(find.text('<details>'), findsNothing);
      expect(
        find.textContaining('Secret body', findRichText: true),
        findsNothing,
      );
      await tester.tap(find.text('Baseline'));
      await tester.pump();
      expect(
        find.textContaining('Secret body', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.text('Baseline'));
      await tester.pump();
      expect(
        find.textContaining('Secret body', findRichText: true),
        findsNothing,
      );
    });

    testWidgets('a comment is a bordered card with author and time', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const IssueCommentCard(
            author: 'haziqmeekco',
            createdAt: '2026-10-06T00:09:07Z',
            body: 'Complete the work.',
          ),
        ),
      );
      expect(find.text('haziqmeekco · 2026-10-06T00:09:07Z'), findsOneWidget);
      final box = tester.widget<Container>(find.byType(Container).first);
      final deco = box.decoration! as BoxDecoration;
      expect(deco.border, isNotNull);
      expect(deco.borderRadius, isNotNull);
    });
  });
}
