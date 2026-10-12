import 'package:flutter/material.dart'
    show Brightness, ColorScheme, DynamicSchemeVariant;
import 'package:flutter/painting.dart';

/// One theme: every colour, corner and font the widgets read through `HaroTokens`. Only the
/// values that differ between themes live here; sizes and durations stay constants.
class HaroPalette {
  const HaroPalette({
    required this.id,
    required this.label,
    required this.light,
    required this.ink,
    required this.bg,
    required this.panel,
    required this.raised,
    required this.ink86,
    required this.ink66,
    required this.ink42,
    required this.ink02,
    required this.line08,
    required this.line12,
    required this.line14,
    required this.line20,
    required this.line30,
    required this.gate,
    required this.fail,
    required this.merged,
    required this.warn,
    required this.diffAddBg,
    required this.diffDelBg,
    required this.gateWash,
    required this.backdrop,
    required this.accent,
    required this.onAccent,
    required this.tertiary,
    required this.ansiYellow,
    required this.ansiBlue,
    required this.ansiCyan,
    required this.syntaxKeyword,
    required this.syntaxString,
    required this.syntaxNumber,
    required this.syntaxFunction,
    required this.syntaxType,
    required this.radius,
    required this.buttonRadius,
    required this.panelRadius,
    required this.dialogRadius,
    required this.checkRadius,
    required this.statusRound,
    required this.bigSwitch,
    required this.ripple,
    required this.fontUi,
    required this.fontMono,
    required this.fontWordmark,
    required this.wordmarkWeight,
    required this.wordmarkTracking,
    required this.mediumWeight,
    required this.trackingScale,
    required this.grain,
    required this.boot,
  });

  final String id;
  final String label;

  /// Dark ink on a light ground.
  final bool light;

  final Color ink;
  final Color bg;
  final Color panel;
  final Color raised;
  final Color ink86;
  final Color ink66;
  final Color ink42;
  final Color ink02;
  final Color line08;
  final Color line12;
  final Color line14;
  final Color line20;
  final Color line30;
  final Color gate;
  final Color fail;
  final Color merged;
  final Color warn;
  final Color diffAddBg;
  final Color diffDelBg;
  final Color gateWash;
  final Color backdrop;

  /// The fill of the thing you can press and of what is switched on, and the colour on it.
  /// The same as [ink] and [bg] in the warm-monochrome themes.
  final Color accent;
  final Color onAccent;

  /// A third colour beside the accent and the ink, used by the Expressive start and quit screens.
  final Color tertiary;

  final Color ansiYellow;
  final Color ansiBlue;
  final Color ansiCyan;
  final Color syntaxKeyword;
  final Color syntaxString;
  final Color syntaxNumber;
  final Color syntaxFunction;
  final Color syntaxType;

  /// Corners: small controls and inputs, buttons and chips, cards and menus, dialogs, checkboxes.
  final double radius;
  final double buttonRadius;
  final double panelRadius;
  final double dialogRadius;
  final double checkRadius;

  /// Status markers are circles, not squares.
  final bool statusRound;

  /// Switches are the 52 by 32 Material shape, not the small hairline box.
  final bool bigSwitch;

  /// Pressing a control starts an ink ripple from the pointer (Material 3).
  final bool ripple;

  final String fontUi;
  final String fontMono;
  final String fontWordmark;
  final FontWeight wordmarkWeight;

  /// Wordmark letter spacing as a share of its size.
  final double wordmarkTracking;

  /// What the UI font's "medium" weight is drawn as.
  final FontWeight mediumWeight;

  /// Scales the wide tracking of mono labels (1 is the Kuro look).
  final double trackingScale;

  /// The film grain overlay is part of the look.
  final bool grain;

  /// Which start and quit screens the theme wears.
  final BootStyle boot;

  /// The logo is four colours and rounded (Expressive): rose dots, accent cells, the gate's
  /// green cell and an ink bar, the colours the shapes take when they morph.
  bool get colourMark => boot == BootStyle.expressive;

  static const haro = HaroPalette(
    id: 'haro',
    label: 'Classic',
    light: false,
    ink: Color(0xFFD8D0C5),
    bg: Color(0xFF0B0A09),
    panel: Color(0xFF131210),
    raised: Color(0xFF1B1915),
    ink86: Color.fromRGBO(216, 208, 197, .86),
    ink66: Color.fromRGBO(216, 208, 197, .66),
    ink42: Color.fromRGBO(216, 208, 197, .42),
    ink02: Color.fromRGBO(216, 208, 197, .02),
    line08: Color.fromRGBO(216, 208, 197, .08),
    line12: Color.fromRGBO(216, 208, 197, .12),
    line14: Color.fromRGBO(216, 208, 197, .14),
    line20: Color.fromRGBO(216, 208, 197, .2),
    line30: Color.fromRGBO(216, 208, 197, .3),
    gate: Color(0xFF41D183),
    fail: Color(0xFFE0685E),
    merged: Color(0xFFB3A0D6),
    warn: Color(0xFFD6A15E),
    diffAddBg: Color.fromRGBO(65, 209, 131, .06),
    diffDelBg: Color.fromRGBO(224, 104, 94, .07),
    gateWash: Color.fromRGBO(65, 209, 131, .06),
    backdrop: Color.fromRGBO(8, 7, 6, .8),
    accent: Color(0xFFD8D0C5),
    onAccent: Color(0xFF0B0A09),
    tertiary: Color(0xFFB3A0D6),
    ansiYellow: Color(0xFFC9A96A),
    ansiBlue: Color(0xFF7F9BB8),
    ansiCyan: Color(0xFF7FB3AE),
    syntaxKeyword: Color(0xFFD6A15E),
    syntaxString: Color(0xFF8FAFC8),
    syntaxNumber: Color(0xFFCFC08A),
    syntaxFunction: Color(0xFFB8C7D9),
    syntaxType: Color(0xFFD9B98C),
    radius: 2,
    buttonRadius: 2,
    panelRadius: 2,
    dialogRadius: 2,
    checkRadius: 1,
    statusRound: false,
    bigSwitch: false,
    ripple: false,
    fontUi: 'SpaceGrotesk',
    fontMono: 'SpaceMono',
    fontWordmark: 'Fraunces',
    wordmarkWeight: FontWeight.w500,
    wordmarkTracking: -.01,
    mediumWeight: FontWeight.w500,
    trackingScale: 1,
    grain: true,
    boot: BootStyle.kuro,
  );

  /// The Material 3 colour options: a seed each, from which the tonal palette (primary, the
  /// surfaces, the ink) is generated. No green, red or yellow seed: those hues belong to the
  /// gate, failures and the review-limit note.
  static const material3Colours = [
    M3Colour(
      'purple',
      'Purple',
      Color(0xFF6750A4),
      DynamicSchemeVariant.tonalSpot,
      _baselinePurple,
    ),
    M3Colour('magenta', 'Magenta', Color(0xFF9C27B0)),
    M3Colour('rose', 'Rose', Color(0xFFC2185B)),
    M3Colour('blue', 'Blue', Color(0xFF1A73E8)),
    M3Colour('cyan', 'Cyan', Color(0xFF0097A7)),
    M3Colour(
      'graphite',
      'Graphite',
      Color(0xFF5F6368),
      DynamicSchemeVariant.monochrome,
    ),
  ];

  static final _m3Cache = <String, HaroPalette>{};

  /// Material 3 in one of [material3Colours] (purple when the id is unknown).
  static HaroPalette material3With(String colourId) {
    final c = material3Colours.firstWhere(
      (c) => c.id == colourId,
      orElse: () => material3Colours.first,
    );
    return _m3Cache.putIfAbsent(c.id, () {
      var s = ColorScheme.fromSeed(
        seedColor: c.seed,
        brightness: Brightness.dark,
        dynamicSchemeVariant: c.variant,
      );
      s = c.tune?.call(s) ?? s;
      final ink = s.onSurface;
      return HaroPalette(
        id: 'material3:${c.id}',
        label: 'Expressive',
        light: false,
        ink: ink,
        bg: s.surface,
        panel: s.surfaceContainer,
        raised: s.surfaceContainerHighest,
        ink86: ink.withValues(alpha: .86),
        ink66: ink.withValues(alpha: .66),
        ink42: ink.withValues(alpha: .42),
        ink02: ink.withValues(alpha: .02),
        line08: ink.withValues(alpha: .08),
        line12: ink.withValues(alpha: .12),
        line14: ink.withValues(alpha: .14),
        line20: ink.withValues(alpha: .2),
        line30: ink.withValues(alpha: .3),
        gate: const Color(0xFF41D183),
        fail: const Color(0xFFE0685E),
        merged: s.secondary,
        warn: const Color(0xFFD6A15E),
        diffAddBg: const Color.fromRGBO(65, 209, 131, .06),
        diffDelBg: const Color.fromRGBO(224, 104, 94, .07),
        gateWash: const Color.fromRGBO(65, 209, 131, .06),
        backdrop: const Color.fromRGBO(0, 0, 0, .5),
        accent: s.primary,
        onAccent: s.onPrimary,
        tertiary: s.tertiary,
        ansiYellow: const Color(0xFFC9A96A),
        ansiBlue: const Color(0xFF7F9BB8),
        ansiCyan: const Color(0xFF7FB3AE),
        syntaxKeyword: const Color(0xFFD6A15E),
        syntaxString: const Color(0xFF8FAFC8),
        syntaxNumber: const Color(0xFFCFC08A),
        syntaxFunction: const Color(0xFFB8C7D9),
        syntaxType: const Color(0xFFD9B98C),
        radius: 12,
        buttonRadius: 999,
        panelRadius: 16,
        dialogRadius: 28,
        checkRadius: 4,
        statusRound: true,
        bigSwitch: true,
        ripple: true,
        fontUi: 'RobotoFlex',
        fontMono: 'RobotoMono',
        fontWordmark: 'RobotoFlex',
        wordmarkWeight: FontWeight.w800,
        wordmarkTracking: -.04,
        mediumWeight: FontWeight.w600,
        trackingScale: .43,
        grain: false,
        boot: BootStyle.expressive,
      );
    });
  }

  /// The default Material 3 (the baseline purple).
  static HaroPalette get material3 => material3With('purple');

  static const paper = HaroPalette(
    id: 'paper',
    label: 'Paper',
    light: true,
    ink: Color(0xFF18181B),
    bg: Color(0xFFFFFFFF),
    panel: Color(0xFFF6F6F5),
    raised: Color(0xFFEEEEEC),
    ink86: Color.fromRGBO(24, 24, 27, .92),
    ink66: Color.fromRGBO(24, 24, 27, .82),
    ink42: Color.fromRGBO(24, 24, 27, .68),
    ink02: Color.fromRGBO(24, 24, 27, .02),
    line08: Color.fromRGBO(24, 24, 27, .056),
    line12: Color.fromRGBO(24, 24, 27, .084),
    line14: Color.fromRGBO(24, 24, 27, .098),
    line20: Color.fromRGBO(24, 24, 27, .2),
    line30: Color.fromRGBO(24, 24, 27, .3),
    gate: Color(0xFF15803D),
    fail: Color(0xFFDC2626),
    merged: Color(0xFF7C3AED),
    warn: Color(0xFFB45309),
    diffAddBg: Color.fromRGBO(22, 163, 74, .08),
    diffDelBg: Color.fromRGBO(220, 38, 38, .07),
    gateWash: Color.fromRGBO(22, 163, 74, .06),
    backdrop: Color.fromRGBO(250, 250, 249, .72),
    accent: Color(0xFF18181B),
    onAccent: Color(0xFFFFFFFF),
    tertiary: Color(0xFF7C3AED),
    ansiYellow: Color(0xFFA16207),
    ansiBlue: Color(0xFF2563EB),
    ansiCyan: Color(0xFF0E7490),
    syntaxKeyword: Color(0xFF7F3F06),
    syntaxString: Color(0xFF1C5380),
    syntaxNumber: Color(0xFF6A5000),
    syntaxFunction: Color(0xFF2F4A73),
    syntaxType: Color(0xFF744610),
    radius: 6,
    buttonRadius: 6,
    panelRadius: 6,
    dialogRadius: 8,
    checkRadius: 4,
    statusRound: true,
    bigSwitch: false,
    ripple: false,
    fontUi: 'Geist',
    fontMono: 'GeistMono',
    fontWordmark: 'Geist',
    wordmarkWeight: FontWeight.w600,
    wordmarkTracking: -.04,
    mediumWeight: FontWeight.w500,
    trackingScale: .29,
    grain: false,
    boot: BootStyle.paper,
  );

  /// The themes Settings offers, as (saved id, label). The saved ids are the old names (haro,
  /// material3); Expressive's colour is a second choice.
  static const themeOptions = [
    ('haro', 'Classic'),
    ('material3', 'Expressive'),
    ('paper', 'Paper'),
  ];

  /// The palette for a saved theme id and Material 3 colour id.
  static HaroPalette resolve(String theme, [String m3Colour = 'purple']) =>
      switch (theme) {
        'material3' => material3With(m3Colour),
        'paper' => paper,
        _ => haro,
      };
}

/// One Material 3 colour option.
class M3Colour {
  const M3Colour(
    this.id,
    this.label,
    this.seed, [
    this.variant = DynamicSchemeVariant.tonalSpot,
    this.tune,
  ]);

  final String id;
  final String label;
  final Color seed;
  final DynamicSchemeVariant variant;

  /// Pins slots of the generated scheme to hand-picked values.
  final ColorScheme Function(ColorScheme generated)? tune;
}

/// The baseline Claude Design drew, to the digit (the generator lands a shade off).
ColorScheme _baselinePurple(ColorScheme s) => s.copyWith(
  primary: const Color(0xFFD0BCFF),
  onPrimary: const Color(0xFF381E72),
  secondary: const Color(0xFFCCC2DC),
  tertiary: const Color(0xFFEFB8C8),
  onSurface: const Color(0xFFE6E0E9),
  surfaceContainer: const Color(0xFF211F26),
  surfaceContainerHighest: const Color(0xFF36343B),
);

/// The start and quit screens: the mark assembling like a gate run (haro), a shape that morphs
/// into the mark (Material 3), ink drawn and stamped on ruled paper with a printed receipt on the
/// way out (Paper).
enum BootStyle { kuro, expressive, paper }
