import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/issue_provider.dart';
import 'package:haro_app/features/workspace/rail/issue_section.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_markdown.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_pressable.dart';

import 'agent_events.dart';
import 'agent_harness.dart';

Map<String, dynamic> issueJson({
  bool available = true,
  String? reason,
  String body =
      '## Goal\nValidate the **item price** sync against the SAP price list.\n\n'
      '- check `OSPP` rows\n- compare with Shopify\n\n```\nnot shown in the rail\n```',
}) => {
  'available': available,
  'reason': reason,
  'number': 116,
  'title': 'Item 3: SAP item price validation',
  'body': body,
  'state': 'open',
  'url': 'https://github.com/acme/demo/issues/116',
  'labels': ['sap', 'validation'],
  'comments': [
    {
      'author': 'ana',
      'body': 'Reproduced on the dev stack.',
      'created_at': '2026-10-09',
    },
  ],
};

AgentRig rig({String? seedKey = 'issue:116', Map<String, dynamic>? issue}) {
  final r = AgentRig(
    Preview.idle,
    status: WorkspaceStatus.idle,
    seedKey: seedKey,
    events: [userEv('go'), metaEv()],
  );
  r.api.routes['GET /projects/p1/issues/116'] = (_) =>
      jsonRes(issue ?? issueJson());
  return r;
}

void main() {
  setUpAll(loadBrandFonts);

  group('issueNumberOf', () {
    test('reads the number from an issue seed key only', () {
      expect(issueNumberOf('issue:116'), 116);
      expect(issueNumberOf('backlog/a.md::do it'), isNull);
      expect(issueNumberOf('issue:abc'), isNull);
      expect(issueNumberOf(null), isNull);
    });
  });

  group('issueExcerpt', () {
    test('drops code, marks and links and keeps the prose', () {
      expect(
        issueExcerpt(
          '## Goal\nSee [the doc](http://x) for **bold** `code`.\n```\nhidden\n```',
        ),
        'Goal See the doc for bold code.',
      );
    });

    test('cuts at a word with an ellipsis', () {
      final text = List.filled(80, 'word').join(' ');
      final e = issueExcerpt(text, max: 50);
      expect(e.endsWith('…'), isTrue);
      expect(e.length, lessThanOrEqualTo(51));
    });
  });

  testWidgets('a backend reason code reads as a sentence, not a code', (
    tester,
  ) async {
    await rig(issue: issueJson(available: false, reason: 'no-gh'))
        .pump(tester, step: 'agent');
    await tester.pumpAndSettle();
    expect(
      find.text('Install the GitHub CLI (gh) to pull issues.'),
      findsOneWidget,
    );
    expect(find.text('no-gh'), findsNothing);
  });

  group('untrusted markdown (an issue anyone can write on)', () {
    test('a link opens only web pages and mail', () {
      for (final ok in [
        'https://github.com/o/r/issues/1',
        'http://example.com',
        'HTTPS://EXAMPLE.COM',
        'mailto:ana@example.com',
      ]) {
        expect(safeLinkUri(ok), isNotNull, reason: ok);
      }
      for (final bad in [
        'file:///System/Applications/Utilities/Terminal.app',
        'file:///Users/x/run.command',
        'smb://attacker/share',
        'vscode://vscode.git/clone?url=x',
        'x-apple.systempreferences:com.apple.preference.security',
        'javascript:alert(1)',
        'tel:+123',
        '/relative/path',
        '',
      ]) {
        expect(safeLinkUri(bad), isNull, reason: bad);
      }
    });

    testWidgets('an image is never fetched; its alt text stands in', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Material(
            child: AgentProse(
              'before ![screenshot of the cart](https://evil.example/pixel.png) after',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(Image),
        findsNothing,
        reason: 'no network image widget is built',
      );
      expect(find.textContaining('screenshot of the cart'), findsOneWidget);
    });
  });

  testWidgets(
    'a workspace that was not started from an issue has no ISSUE section',
    (tester) async {
      await rig(seedKey: null).pump(tester, step: 'agent');
      expect(find.byKey(const ValueKey('rail-issue')), findsNothing);
      await rig(seedKey: 'backlog/a.md::do it').pump(tester, step: 'agent');
      expect(find.byKey(const ValueKey('rail-issue')), findsNothing);
    },
  );

  testWidgets(
    'the rail shows the issue: title, labels and the start of the text',
    (tester) async {
      await rig().pump(tester, step: 'agent');
      await tester.pumpAndSettle();
      expect(find.text('ISSUE #116, OPEN'), findsOneWidget);
      expect(find.text('Item 3: SAP item price validation'), findsOneWidget);
      expect(find.text('sap, validation'), findsOneWidget);
      final excerpt = tester
          .widget<Text>(find.byKey(const ValueKey('rail-issue-excerpt')))
          .data!;
      expect(excerpt, startsWith('Goal Validate the item price sync'));
      expect(excerpt, isNot(contains('not shown in the rail')));
    },
  );

  testWidgets(
    'the ripple of the ISSUE card fills the whole section, edge to edge',
    (tester) async {
      // Ripples are an Expressive (Material 3) trait; the app starts on the stored theme.
      addTearDown(() => HaroTokens.apply(HaroPalette.haro));
      final r = rig();
      r.prefs = MemoryDevicePrefsStore({
        'display': {'theme': 'material3'},
      });
      await r.pump(tester, step: 'agent');
      await tester.pumpAndSettle();
      final section = tester.getRect(find.byKey(const ValueKey('rail-issue')));
      final press = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('rail-issue-title'))),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      final clip = rippleClipBounds(
        tester
            .widget<CustomPaint>(find.byKey(const ValueKey('ripple')))
            .painter,
      )!.single;
      expect(
        clip,
        rectMoreOrLessEquals(
          Rect.fromLTWH(0, 0, section.width, section.height),
          epsilon: .01,
        ),
      );
      await press.cancel();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'the expand button opens the whole issue fullscreen, and Esc row closes it',
    (tester) async {
      await rig().pump(tester, step: 'agent');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rail-issue-fullscreen')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('issue-fullscreen')), findsOneWidget);
      expect(find.byKey(const ValueKey('issue-full-title')), findsOneWidget);
      expect(find.textContaining('Validate the'), findsWidgets);
      expect(find.text('Reproduced on the dev stack.'), findsOneWidget);
      expect(find.text('1 COMMENT'), findsOneWidget);
      expect(find.byKey(const ValueKey('issue-open-github')), findsOneWidget);
      await tester.tap(find.text('‹  EXIT FULLSCREEN  ESC'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('issue-fullscreen')), findsNothing);
    },
  );

  testWidgets('tapping the card itself opens it too', (tester) async {
    await rig().pump(tester, step: 'agent');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rail-issue-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('issue-fullscreen')), findsOneWidget);
  });

  testWidgets('when GitHub cannot be read it says why instead of a blank', (
    tester,
  ) async {
    await rig(
      issue: issueJson(
        available: false,
        reason: 'gh is not logged in for this repo',
      ),
    ).pump(tester, step: 'agent');
    await tester.pumpAndSettle();
    expect(
      find.text("Couldn't load issues: gh is not logged in for this repo."),
      findsOneWidget,
    );
    expect(find.text('TRY AGAIN'), findsOneWidget);
  });

  testWidgets('a failed read says so and Try again reads it again', (
    tester,
  ) async {
    final r = rig();
    var calls = 0;
    r.api.routes['GET /projects/p1/issues/116'] = (_) {
      calls++;
      return calls == 1 ? errorRes('boom', 500) : jsonRes(issueJson());
    };
    await r.pump(tester, step: 'agent');
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not load the issue'), findsOneWidget);
    await tester.tap(find.text('TRY AGAIN'));
    await tester.pumpAndSettle();
    expect(find.text('Item 3: SAP item price validation'), findsOneWidget);
    expect(calls, 2);
  });
}
