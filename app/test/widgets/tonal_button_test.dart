import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';

void main() {
  tearDown(() => HaroTokens.apply(HaroPalette.haro));

  for (final (name, palette) in [
    ('Classic', HaroPalette.haro),
    ('Expressive', HaroPalette.material3),
    ('Paper', HaroPalette.paper),
  ]) {
    testWidgets(
      '$name: a tonal button is the theme accent as a tint with accent text',
      (tester) async {
        HaroTokens.apply(palette);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildHaroTheme(),
            home: Material(
              child: Center(
                child: HaroButton(
                  label: 'Queue',
                  variant: HaroButtonVariant.tonal,
                  onPressed: () {},
                ),
              ),
            ),
          ),
        );
        final box = tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.byType(HaroButton),
            matching: find.byType(AnimatedContainer),
          ),
        );
        final fill = (box.decoration! as BoxDecoration).color!;
        expect(fill.r, closeTo(HaroTokens.accent.r, .01));
        expect(fill.g, closeTo(HaroTokens.accent.g, .01));
        expect(fill.a, closeTo(.14, .01));
        final style = tester
            .widget<AnimatedDefaultTextStyle>(
              find.descendant(
                of: find.byType(HaroButton),
                matching: find.byType(AnimatedDefaultTextStyle),
              ),
            )
            .style;
        expect(style.color, HaroTokens.accent);
      },
    );
  }
}
