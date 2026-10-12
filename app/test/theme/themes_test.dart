import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/display_prefs_provider.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';
import 'package:haro_app/widgets/haro_pressable.dart';
import 'package:haro_app/widgets/status_square.dart';

import '../features/workspace/harness.dart';
import 'syntax_colors_test.dart' show contrast, hueGap, hueOf, over;

void main() {
  tearDown(() => HaroTokens.apply(HaroPalette.haro));

  group('palettes', () {
    test('an unknown id falls back to haro', () {
      expect(HaroPalette.resolve('nope'), HaroPalette.haro);
      expect(HaroPalette.resolve('material3'), HaroPalette.material3);
      expect(
        DisplayPrefs.fromJson(const {'m3_colour': 'zzz'}).m3Colour,
        'purple',
      );
      for (final (id, _) in HaroPalette.themeOptions) {
        expect(
          identical(HaroPalette.resolve(id), HaroPalette.haro),
          id == 'haro',
          reason: id,
        );
      }
    });

    test('tokens follow the applied palette', () {
      expect(HaroTokens.accent, HaroPalette.haro.ink);
      expect(HaroTokens.radius, 2);
      HaroTokens.apply(HaroPalette.material3);
      expect(HaroTokens.accent, const Color(0xFFD0BCFF));
      expect(HaroTokens.onAccent, const Color(0xFF381E72));
      expect(HaroTokens.buttonRadius, 999);
      expect(HaroTokens.fontUi, 'RobotoFlex');
      expect(HaroText.ui(weight: FontWeight.w500).fontWeight, FontWeight.w600);
      expect(buildHaroTheme().colorScheme.primary, const Color(0xFFD0BCFF));
    });

    test('purple is the baseline Claude Design drew, to the digit', () {
      final p = HaroPalette.material3With('purple');
      expect(p.accent, const Color(0xFFD0BCFF));
      expect(p.onAccent, const Color(0xFF381E72));
      expect(p.bg, const Color(0xFF141218));
      expect(p.panel, const Color(0xFF211F26));
      expect(p.raised, const Color(0xFF36343B));
      expect(p.ink, const Color(0xFFE6E0E9));
      expect(p.merged, const Color(0xFFCCC2DC));
    });

    test('every Material 3 colour is dark, legible, and clear of the gate and failure hues', () {
      final ids = {for (final c in HaroPalette.material3Colours) c.id};
      expect(ids.length, HaroPalette.material3Colours.length);
      final accents = <Color>{};
      for (final c in HaroPalette.material3Colours) {
        final p = HaroPalette.material3With(c.id);
        accents.add(p.accent);
        expect(p.id, 'material3:${c.id}');
        expect(p.light, isFalse);
        expect(
          contrast(p.accent, p.onAccent),
          greaterThanOrEqualTo(4.5),
          reason: c.id,
        );
        expect(contrast(p.ink, p.bg), greaterThanOrEqualTo(7), reason: c.id);
        expect(contrast(p.raised, p.bg), greaterThan(1.15), reason: c.id);
        expect(contrast(p.panel, p.bg), greaterThan(1.05), reason: c.id);
        if (HSLColor.fromColor(p.accent).saturation > .2) {
          for (final reserved in [p.gate, p.fail]) {
            expect(
              hueGap(hueOf(p.accent), hueOf(reserved)),
              greaterThanOrEqualTo(15),
              reason: '${c.id} vs $reserved',
            );
          }
        }
      }
      expect(accents.length, HaroPalette.material3Colours.length);
      expect(
        HaroPalette.material3With('nope'),
        HaroPalette.material3With('purple'),
      );
    });

    test('Paper is light, with dark ink and readable code colours', () {
      final p = HaroPalette.paper;
      HaroTokens.apply(p);
      expect(p.light, isTrue);
      expect(buildHaroTheme().brightness, Brightness.light);
      expect(HaroTokens.accent, HaroTokens.ink);
      expect(HaroTokens.fontUi, 'Geist');
      final bgs = [
        p.bg,
        p.panel,
        over(p.diffAddBg, p.bg),
        over(p.diffDelBg, p.bg),
      ];
      for (final c in [
        p.syntaxKeyword,
        p.syntaxString,
        p.syntaxNumber,
        p.syntaxFunction,
        p.syntaxType,
      ]) {
        for (final bg in bgs) {
          expect(contrast(c, bg), greaterThanOrEqualTo(4.5), reason: '$c');
        }
        for (final reserved in [p.gate, p.fail, p.merged]) {
          expect(
            hueGap(hueOf(c), hueOf(reserved)),
            greaterThanOrEqualTo(25),
            reason: '$c vs $reserved',
          );
        }
      }
      for (final text in [p.ink66, p.ink42]) {
        expect(contrast(over(text, p.bg), p.bg), greaterThanOrEqualTo(4.5));
      }
      expect(contrast(p.gate, p.bg), greaterThanOrEqualTo(4.5));
      for (final c in [
        p.syntaxKeyword,
        p.syntaxString,
        p.syntaxNumber,
        p.syntaxFunction,
        p.syntaxType,
      ]) {
        expect(
          contrast(
            over(c.withValues(alpha: .72), p.bg),
            over(p.diffDelBg, p.bg),
          ),
          greaterThanOrEqualTo(3),
          reason: 'dimmed $c on a deleted line',
        );
      }
      expect(contrast(p.fail, p.bg), greaterThanOrEqualTo(4.5));
    });

    test('the theme is saved with the Display prefs', () {
      final prefs = const DisplayPrefs().copyWith(theme: 'material3');
      expect(DisplayPrefs.fromJson(prefs.toJson()).theme, 'material3');
      expect(DisplayPrefs.fromJson(const {}).theme, 'haro');
    });
  });

  group('switching at runtime', () {
    testWidgets('Material 3 ripples from the press, haro does not', (
      tester,
    ) async {
      final rig = Rig(Preview.idle);
      rig.prefs = MemoryDevicePrefsStore({
        'display': {'theme': 'material3'},
      });
      await rig.pump(tester, step: 'agent');
      final rename = find.widgetWithText(HaroButton, 'Rename');
      final press = await tester.startGesture(tester.getCenter(rename));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey('ripple')), findsOneWidget);
      await press.cancel();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ripple')), findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(HaroApp)),
      );
      container
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(theme: 'haro'));
      await tester.pumpAndSettle();
      final again = await tester.startGesture(tester.getCenter(rename));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey('ripple')), findsNothing);
      await again.cancel();
      await tester.pumpAndSettle();
    });

    testWidgets('a Material 3 colour change repaints in place', (tester) async {
      final rig = Rig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HaroApp)),
      );
      Color? fill() =>
          ((tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: find.widgetWithText(HaroButton, 'Rename'),
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration)
                  as BoxDecoration)
              .color;
      await tester.enterText(find.byType(EditableText).first, 'keep me');
      container
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(theme: 'material3'));
      await tester.pumpAndSettle();
      expect(fill(), HaroPalette.material3With('purple').accent);
      container
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(theme: 'material3', m3Colour: 'blue'));
      await tester.pumpAndSettle();
      expect(fill(), HaroPalette.material3With('blue').accent);
      expect(find.text('keep me'), findsOneWidget);
    });

    testWidgets('the ripple follows the control: square rows stay square', (
      tester,
    ) async {
      HaroTokens.apply(HaroPalette.material3);
      addTearDown(() => HaroTokens.apply(HaroPalette.haro));
      Future<Path> clipOf(Widget child) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildHaroTheme(),
            home: Material(child: Center(child: child)),
          ),
        );
        final press = await tester.startGesture(
          tester.getCenter(find.byType(HaroPressable)),
        );
        await tester.pump(const Duration(milliseconds: 16));
        final painter =
            tester
                    .widget<CustomPaint>(find.byKey(const ValueKey('ripple')))
                    .painter
                as dynamic;
        final path = painter.ripples.first.clip as Path;
        await press.cancel();
        await tester.pumpAndSettle();
        return path;
      }

      final row = await clipOf(
        HaroPressable(
          onTap: () {},
          builder: (_, hovered) => Container(
            width: 300,
            height: 40,
            decoration: BoxDecoration(color: HaroTokens.panel),
          ),
        ),
      );
      expect(row.getBounds().size, const Size(300, 40));
      expect(
        row.contains(const Offset(1, 1)),
        isTrue,
        reason: 'no rounded corner',
      );

      final text = await clipOf(
        HaroPressable(
          onTap: () {},
          builder: (_, hovered) =>
              const SizedBox(width: 100, height: 20, child: Text('tab')),
        ),
      );
      expect(
        text.getBounds().size,
        const Size(116, 28),
        reason: 'room around the text',
      );

      final wide = await clipOf(
        HaroPressable(
          onTap: () {},
          builder: (_, hovered) => const SizedBox(
            width: 220,
            height: 30,
            child: Text('HIDE MERGED'),
          ),
        ),
      );
      expect(
        wide.getBounds().size,
        const Size(220, 30),
        reason: 'a row-wide target stays inside its line',
      );
    });

    testWidgets('every widget takes the new theme and keeps its state', (
      tester,
    ) async {
      final rig = Rig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HaroApp)),
      );

      Color? fill(Finder f) =>
          ((tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: f,
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration)
                  as BoxDecoration)
              .color;

      expect(find.byType(HaroButton), findsWidgets);
      final before = fill(find.widgetWithText(HaroButton, 'Rename'));
      expect(before, HaroPalette.haro.ink);

      await tester.enterText(
        find.byType(EditableText).first,
        'keep this draft',
      );
      await tester.pump();

      container
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(theme: 'material3'));
      await tester.pumpAndSettle();

      expect(HaroTokens.palette.id, 'material3:purple');
      expect(
        fill(find.widgetWithText(HaroButton, 'Rename')),
        HaroPalette.material3.accent,
      );
      expect(find.text('keep this draft'), findsOneWidget);

      final square = tester.widget<StatusSquare>(
        find.byType(StatusSquare).first,
      );
      final deco =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: find.byWidget(square),
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      expect(deco.shape, BoxShape.circle);

      container
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(theme: 'haro'));
      await tester.pumpAndSettle();
      expect(
        fill(find.widgetWithText(HaroButton, 'Rename')),
        HaroPalette.haro.ink,
      );
    });
  });
}
