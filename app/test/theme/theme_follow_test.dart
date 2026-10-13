import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_tokens.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';

void main() {
  tearDown(() => HaroTokens.apply(HaroPalette.haro));

  for (final (name, palette) in [
    ('Classic', HaroPalette.haro),
    ('Expressive', HaroPalette.material3),
    ('Paper', HaroPalette.paper),
  ]) {
    test(
      '$name: "no fill" is the background at zero opacity, so a hover fade has no dip',
      () {
        HaroTokens.apply(palette);
        final none = HaroTokens.transparent;
        expect(none.a, 0);
        expect(none.r, closeTo(HaroTokens.bg.r, .005));
        expect(none.g, closeTo(HaroTokens.bg.g, .005));
        // Halfway to the hover surface, no channel is darker than both ends: no black flash.
        final mid = Color.lerp(none, HaroTokens.panel, .5)!;
        final lo = [
          HaroTokens.bg.r,
          HaroTokens.panel.r,
        ].reduce((a, b) => a < b ? a : b);
        expect(mid.r, greaterThanOrEqualTo(lo - .005));
      },
    );
  }

  test('agent text styles read the theme when asked, not once at start-up', () {
    HaroTokens.apply(HaroPalette.haro);
    final dark = AgentTokens.prose.color!;
    HaroTokens.apply(HaroPalette.paper);
    final paper = AgentTokens.prose.color!;
    expect(paper, isNot(dark));
    expect(paper, HaroTokens.ink86);
    expect(AgentTokens.footer.color, HaroTokens.ink42);
    expect(AgentTokens.hint.color, HaroTokens.ink42);
  });
}
