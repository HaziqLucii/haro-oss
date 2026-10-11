import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';
import 'package:haro_app/widgets/shell_icons.dart';

/// What can be pressed is the bright thing: a bone squircle with a dark icon; what cannot is a
/// dim ghost.
Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

Decoration decorationOf(WidgetTester tester) => tester
    .widget<AnimatedContainer>(find.byType(AnimatedContainer))
    .decoration!;

void main() {
  testWidgets('a filled icon button is a bone squircle with a dark icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        ShellIconButton(
          icon: ShellIcon.play,
          tooltip: 'Run',
          filled: true,
          onTap: () {},
        ),
      ),
    );
    final deco = decorationOf(tester) as ShapeDecoration;
    expect(deco.color, HaroTokens.ink);
    expect(deco.shape, isA<RoundedSuperellipseBorder>());
    final icon = tester.widget<ShellIconView>(find.byType(ShellIconView));
    expect(icon.color, HaroTokens.bg);
  });

  testWidgets('disabled, it is a dim ghost with no fill', (tester) async {
    await tester.pumpWidget(
      host(
        const ShellIconButton(
          icon: ShellIcon.openExternal,
          tooltip: 'Open in browser',
          filled: true,
          onTap: null,
        ),
      ),
    );
    final deco = decorationOf(tester) as BoxDecoration;
    expect(deco.color, HaroTokens.transparent);
    expect(
      tester.widget<ShellIconView>(find.byType(ShellIconView)).color,
      HaroTokens.ink42,
    );
  });

  testWidgets('an unfilled icon button keeps its quiet look', (tester) async {
    await tester.pumpWidget(
      host(
        ShellIconButton(icon: ShellIcon.menu, tooltip: 'Menu', onTap: () {}),
      ),
    );
    expect(decorationOf(tester), isA<BoxDecoration>());
    expect(
      tester.widget<ShellIconView>(find.byType(ShellIconView)).color,
      HaroTokens.ink66,
    );
  });

  testWidgets('a control button is bone-filled with dark text, like primary', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        HaroButton(
          label: 'Rename',
          variant: HaroButtonVariant.control,
          onPressed: () {},
        ),
      ),
    );
    final inButton = find.descendant(
      of: find.byType(HaroButton),
      matching: find.byType(AnimatedContainer),
    );
    final deco =
        tester.widget<AnimatedContainer>(inButton.first).decoration
            as BoxDecoration;
    expect(deco.color, HaroTokens.ink);
    final text = tester.widget<AnimatedDefaultTextStyle>(
      find
          .descendant(
            of: find.byType(HaroButton),
            matching: find.byType(AnimatedDefaultTextStyle),
          )
          .first,
    );
    expect(text.style.color, HaroTokens.bg);
  });
}
