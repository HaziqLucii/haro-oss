import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_markdown.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/theme/ui_fonts.dart';

final _palettes = <String, HaroPalette>{
  'haro': HaroPalette.haro,
  'material3': HaroPalette.material3,
  'paper': HaroPalette.paper,
};

void main() {
  tearDown(() {
    HaroTokens.applyFonts();
    HaroTokens.apply(HaroPalette.haro);
  });

  test(
    'the picks map to families; theme default and an empty custom are null',
    () {
      expect(uiFontFamily(themeFontOption, ''), isNull);
      expect(uiFontFamily('Space Grotesk', ''), 'SpaceGrotesk');
      expect(uiFontFamily('Roboto Flex', ''), 'RobotoFlex');
      expect(uiFontFamily('Fraunces', ''), 'Fraunces');
      expect(uiFontFamily('System', ''), '.AppleSystemUIFont');
      expect(uiFontFamily(customFontOption, '  Inter '), 'Inter');
      expect(uiFontFamily(customFontOption, '  '), isNull);
      expect(uiFontFamily('something old', 'x'), isNull);
    },
  );

  test('prefs round-trip, and an older file reads as the theme default', () {
    const p = DisplayPrefs(
      interfaceFont: customFontOption,
      interfaceFontCustom: 'Inter',
      textFont: 'Newsreader',
    );
    final back = DisplayPrefs.fromJson(p.toJson());
    expect(back.interfaceFont, customFontOption);
    expect(back.interfaceFontCustom, 'Inter');
    expect(back.textFont, 'Newsreader');
    final old = DisplayPrefs.fromJson({'coding_font': 'Fira Code'});
    expect(old.interfaceFont, themeFontOption);
    expect(old.textFont, themeFontOption);
    expect(old.codingFont, 'JetBrains Mono');
  });

  for (final e in _palettes.entries) {
    group('in the ${e.key} theme', () {
      setUp(() => HaroTokens.apply(e.value));

      test('with no pick the theme font stays and reading text follows it', () {
        expect(HaroTokens.fontUi, e.value.fontUi);
        expect(HaroTokens.fontText, e.value.fontUi);
        expect(HaroTokens.fontUiFallback, isNull);
        expect(HaroText.ui().fontFamily, e.value.fontUi);
        expect(HaroText.text().fontFamily, e.value.fontUi);
      });

      test(
        'Interface font changes the UI text, and the reading text with it',
        () {
          HaroTokens.applyFonts(ui: 'Newsreader');
          expect(HaroText.ui().fontFamily, 'Newsreader');
          expect(HaroText.text().fontFamily, 'Newsreader');
          expect(HaroTokens.fontUiFallback!.first, e.value.fontUi);
          expect(
            HaroText.mono().fontFamily,
            e.value.fontMono,
            reason: 'labels keep the brand mono',
          );
        },
      );

      test('Text font changes reading text only', () {
        HaroTokens.applyFonts(text: 'Newsreader');
        expect(HaroText.text().fontFamily, 'Newsreader');
        expect(HaroText.ui().fontFamily, e.value.fontUi);
        expect(HaroTokens.fontTextFallback, contains(e.value.fontUi));
      });

      testWidgets('agent prose draws in the Text font', (tester) async {
        HaroTokens.applyFonts(text: 'Newsreader');
        await tester.pumpWidget(
          MaterialApp(
            theme: buildHaroTheme(),
            home: const Scaffold(body: AgentProse('Some **reply** text')),
          ),
        );
        final families = <String?>{};
        for (final t in tester.widgetList<RichText>(find.byType(RichText))) {
          t.text.visitChildren((span) {
            if (span is TextSpan) families.add(span.style?.fontFamily);
            return true;
          });
          families.add(t.text.style?.fontFamily);
        }
        expect(families, contains('Newsreader'));
      });
    });
  }
}
