import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/xp_store.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:haro_app/shell/haro_shell.dart';
import 'package:haro_app/shell/shell_slots.dart';
import 'package:haro_app/theme/tokens.dart';

import '../api/xp_api_test.dart' show rulesJson, xpJson;
import '../features/workspace/harness.dart';

class FakeXpStore extends XpStore {
  FakeXpStore(this.initial);

  final XpState initial;

  @override
  XpState build() => initial;

  @override
  Future<void> load() async {}
}

XpState stateOf({Map<String, dynamic>? status, bool rules = true}) => XpState(
  status: XpStatus.fromJson(status ?? xpJson()),
  rules: rules ? XpRules.fromJson(rulesJson()) : null,
);

Future<Rig> pumpShell(
  WidgetTester tester, {
  XpState? xp,
  Json? prefs,
  bool strip = false,
}) async {
  final rig = Rig(Preview.green)
    ..prefs = MemoryDevicePrefsStore(prefs)
    ..extra.add(
      xpStoreProvider.overrideWith(() => FakeXpStore(xp ?? stateOf())),
    );
  await rig.pump(tester);
  if (strip) {
    await tester.tap(find.byKey(const ValueKey('sidebar-toggle')));
    await tester.pumpAndSettle();
  }
  return rig;
}

ProviderContainer containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(HaroShell)));

String textOf(WidgetTester t, String key) =>
    t.widget<Text>(find.byKey(ValueKey(key))).data!;

final footer = find.byKey(const ValueKey('xp-footer'));

void main() {
  setUp(() => haroOverlayDepth.value = 0);

  group('sidebar footer', () {
    testWidgets(
      'draws level, rank, XP text, bar, streak and the latest reward',
      (tester) async {
        await pumpShell(tester);
        expect(footer, findsOneWidget);
        expect(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byKey(const ValueKey('xp-level')),
                  matching: find.byType(Text),
                ),
              )
              .data,
          '7',
        );
        expect(textOf(tester, 'xp-rank'), 'Journeyman');
        expect(textOf(tester, 'xp-text'), '1,240 / 2,000 XP');
        expect(textOf(tester, 'xp-streak-days'), '3d');
        final latest = tester.widget<Text>(
          find.byKey(const ValueKey('xp-latest')),
        );
        expect(latest.textSpan!.toPlainText(), '+10 XP read the docs');
        expect(find.byKey(const ValueKey('xp-help')), findsOneWidget);
      },
    );

    testWidgets(
      'the bar is bone ink at the share of the way to the next rank',
      (tester) async {
        await pumpShell(tester);
        final fill = tester.widget<Container>(
          find.byKey(const ValueKey('xp-bar-fill')),
        );
        expect(fill.color, HaroTokens.ink);
        final wrap = tester.widget<FractionallySizedBox>(
          find.ancestor(
            of: find.byKey(const ValueKey('xp-bar-fill')),
            matching: find.byType(FractionallySizedBox),
          ),
        );
        expect(wrap.widthFactor, closeTo((1240 - 800) / (2000 - 800), 1e-9));
      },
    );

    testWidgets('no green anywhere in the footer', (tester) async {
      await pumpShell(tester);
      final boxes = tester.widgetList<Widget>(
        find.descendant(of: footer, matching: find.byType(Container)),
      );
      for (final w in boxes) {
        final c = w as Container;
        expect(c.color, isNot(HaroTokens.gate));
        final d = c.decoration;
        if (d is BoxDecoration) expect(d.color, isNot(HaroTokens.gate));
      }
      final texts = tester.widgetList<Text>(
        find.descendant(of: footer, matching: find.byType(Text)),
      );
      for (final t in texts) {
        expect(t.style?.color, isNot(HaroTokens.gate));
      }
    });

    testWidgets('fourteen ticks, today hollow until it has a by-hand merge', (
      tester,
    ) async {
      await pumpShell(
        tester,
        xp: stateOf(
          status: xpJson(
            today: false,
            streak: [for (var i = 0; i < 14; i++) i == 11 || i == 12],
          ),
        ),
      );
      final ticks = [
        for (var i = 0; i < 14; i++)
          tester.widget<Container>(find.byKey(ValueKey('xp-tick-$i'))),
      ];
      expect(ticks, hasLength(14));
      BoxDecoration deco(int i) => ticks[i].decoration! as BoxDecoration;
      expect(deco(12).color, HaroTokens.ink66);
      expect(deco(0).color, HaroTokens.line12);
      expect(deco(13).color, HaroTokens.transparent);
      expect(deco(13).border, isNotNull);
    });

    testWidgets('a merge today fills the last tick with ink', (tester) async {
      await pumpShell(
        tester,
        xp: stateOf(
          status: xpJson(streak: [for (var i = 0; i < 14; i++) i >= 12]),
        ),
      );
      final last = tester.widget<Container>(
        find.byKey(const ValueKey('xp-tick-13')),
      );
      expect((last.decoration! as BoxDecoration).color, HaroTokens.ink);
    });

    testWidgets('the top rank shows the total alone and a full bar', (
      tester,
    ) async {
      await pumpShell(
        tester,
        xp: stateOf(
          status: xpJson(
            xp: 4210,
            level: 24,
            rank: 'Master',
            rankStart: 4000,
            next: null,
          ),
        ),
      );
      expect(textOf(tester, 'xp-text'), '4,210 XP');
      final wrap = tester.widget<FractionallySizedBox>(
        find.ancestor(
          of: find.byKey(const ValueKey('xp-bar-fill')),
          matching: find.byType(FractionallySizedBox),
        ),
      );
      expect(wrap.widthFactor, 1);
    });

    testWidgets('a fresh ledger reads as nothing earned yet', (tester) async {
      await pumpShell(
        tester,
        xp: XpState(
          status: XpStatus.fromJson({
            'xp': 0,
            'level': 1,
            'rank': 'Novice',
            'next_rank_at': 800,
            'streak': [for (var i = 0; i < 14; i++) false],
          }),
          rules: XpRules.fromJson(rulesJson()),
        ),
      );
      expect(textOf(tester, 'xp-text'), '0 / 800 XP');
      final latest = tester.widget<Text>(
        find.byKey(const ValueKey('xp-latest')),
      );
      expect(latest.data, 'Nothing earned yet');
    });

    testWidgets('nothing before the backend answers', (tester) async {
      await pumpShell(tester, xp: const XpState());
      expect(footer, findsNothing);
    });

    testWidgets('fits the smallest window without overflow', (tester) async {
      final rig = Rig(Preview.green)
        ..extra.add(xpStoreProvider.overrideWith(() => FakeXpStore(stateOf())));
      await rig.pump(tester, size: const Size(960, 640));
      expect(footer, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('xp-help')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Show XP off hides the footer', (tester) async {
      await pumpShell(
        tester,
        prefs: {
          'xp': {'show_xp': false},
        },
      );
      expect(footer, findsNothing);
    });
  });

  group('collapsed strip', () {
    testWidgets('shows the level badge instead of the footer', (tester) async {
      await pumpShell(tester, strip: true);
      expect(footer, findsNothing);
      final badge = find.byKey(const ValueKey('xp-strip-badge'));
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('7')),
        findsOneWidget,
      );
    });

    testWidgets('Show XP off hides the badge', (tester) async {
      await pumpShell(
        tester,
        strip: true,
        prefs: {
          'xp': {'show_xp': false},
        },
      );
      expect(find.byKey(const ValueKey('xp-strip-badge')), findsNothing);
    });

    testWidgets('tapping the badge opens How XP works', (tester) async {
      await pumpShell(tester, strip: true);
      await tester.tap(find.byKey(const ValueKey('xp-strip-badge')));
      await tester.pumpAndSettle();
      expect(find.text('How XP works'), findsOneWidget);
    });
  });

  group('How XP works', () {
    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('xp-help')));
      await tester.pumpAndSettle();
    }

    testWidgets('renders the served table in its four groups', (tester) async {
      await pumpShell(tester);
      await open(tester);
      final pop = find.byKey(const ValueKey('xp-popover'));
      expect(pop, findsOneWidget);
      for (final h in ['EVERY DAY', 'ON MERGE', 'MANUAL BONUSES', 'BADGES']) {
        expect(
          find.descendant(of: pop, matching: find.text(h)),
          findsOneWidget,
          reason: h,
        );
      }
      expect(find.byKey(const ValueKey('xp-rule-docs_read')), findsOneWidget);
      expect(find.text('+10 by hand · +2 agent'), findsNWidgets(2));
      expect(find.text('+20 by hand · +10 agent'), findsOneWidget);
      expect(find.text('+15 agent'), findsOneWidget);
      expect(find.text('+120 by hand'), findsOneWidget);
      expect(find.text('+30 by hand'), findsOneWidget);
      expect(find.textContaining('(up to 5)'), findsOneWidget);
    });

    testWidgets('a number changed on the backend shows here', (tester) async {
      final rules = rulesJson();
      (rules['rules'] as List)[0]['manual'] = 99;
      await pumpShell(
        tester,
        xp: XpState(
          status: XpStatus.fromJson(xpJson()),
          rules: XpRules.fromJson(rules),
        ),
      );
      await open(tester);
      expect(find.text('+99 by hand · +2 agent'), findsOneWidget);
    });

    testWidgets('says how far the next rank is, and lists the ranks', (
      tester,
    ) async {
      await pumpShell(tester);
      await open(tester);
      expect(textOf(tester, 'xp-to-next'), '760 XP to Craftsman');
      expect(textOf(tester, 'xp-ranks'), contains('Journeyman 800'));
    });

    testWidgets('has no kanji or em-dash', (tester) async {
      await pumpShell(tester);
      await open(tester);
      final all = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('xp-popover')),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
          .join(' ');
      expect(all.runes.every((r) => r < 0x3000), isTrue);
      expect(all.contains(String.fromCharCode(0x2014)), isFalse);
    });

    testWidgets('Esc closes it', (tester) async {
      await pumpShell(tester);
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('xp-popover')), findsNothing);
    });
  });

  group('toasts', () {
    XpStore storeOf(WidgetTester t) =>
        containerOf(t).read(xpStoreProvider.notifier);

    testWidgets('an award event toasts the amount and the reason', (
      tester,
    ) async {
      await pumpShell(tester);
      storeOf(tester).onEvent(
        const XpWsEvent(
          amount: 10,
          label: 'read the docs',
          awards: [
            XpAward(kind: 'docs_read', amount: 10, label: 'read the docs'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('+10 XP · read the docs'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('a badge unlock gets its own line', (tester) async {
      await pumpShell(tester);
      storeOf(tester).onEvent(
        const XpWsEvent(
          amount: 20,
          label: 'merged on green',
          awards: [
            XpAward(kind: 'merge_green', amount: 20, label: 'merged on green'),
            XpAward(
              kind: 'first_by_hand',
              amount: 0,
              label: 'First by hand',
              badge: true,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('+20 XP · merged on green\nBadge unlocked: First by hand'),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('Show XP off swallows the toast', (tester) async {
      await pumpShell(
        tester,
        prefs: {
          'xp': {'show_xp': false},
        },
      );
      storeOf(tester)
          .onEvent(const XpWsEvent(amount: 10, label: 'read the docs'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('toast')), findsNothing);
    });
  });

  testWidgets('the footer slots draw nothing without data', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: [SidebarFooterSlot(), StripBadgeSlot()]),
      ),
    );
    expect(find.byType(Text), findsNothing);
  });
}
