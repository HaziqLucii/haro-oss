/// The two prose fonts a user can change besides the code font (the Obsidian trio: interface,
/// text, monospace): Settings > Display > Interface font and Text font.
const themeFontOption = 'Theme default';
const customFontOption = 'Custom';

/// What the Interface and Text pickers offer: sans faces for the interface, serif ones for reading.
/// `Custom` takes a family name installed on this device. Theme default is the theme's own font
/// (Space Grotesk, Roboto Flex or Geist).
const uiFontOptions = [
  themeFontOption,
  'System',
  'Inter',
  'Instrument Sans',
  'Onest',
  'Atkinson Hyperlegible Next',
  'Geist',
  'Newsreader',
  'Literata',
  'Source Serif 4',
  customFontOption,
];

/// The family name for a pick, or null to leave the theme's own font alone. [custom] is the typed
/// name; an empty one is the same as the theme's font. The first three older picks are kept so a
/// saved one still works, though the pickers no longer list them.
String? uiFontFamily(String option, String custom) => switch (option) {
  'System' => '.AppleSystemUIFont',
  'Inter' => 'Inter',
  'Instrument Sans' => 'InstrumentSans',
  'Onest' => 'Onest',
  'Atkinson Hyperlegible Next' => 'AtkinsonHyperlegibleNext',
  'Geist' => 'Geist',
  'Newsreader' => 'Newsreader',
  'Literata' => 'Literata',
  'Source Serif 4' => 'SourceSerif4',
  'Space Grotesk' => 'SpaceGrotesk',
  'Roboto Flex' => 'RobotoFlex',
  'Fraunces' => 'Fraunces',
  customFontOption => custom.trim().isEmpty ? null : custom.trim(),
  _ => null,
};

/// Tried, in order, when a glyph (or the whole family, for a typed name that is not installed) is
/// missing from the picked font. The theme's own font comes first, added by the caller.
const uiFontFallback = [
  '.AppleSystemUIFont',
  'Segoe UI',
  'Cantarell',
  'Noto Sans',
  'DejaVu Sans',
  'sans-serif',
];
