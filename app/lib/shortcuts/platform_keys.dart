import 'package:flutter/foundation.dart';

/// The modifier the app treats as "primary": Control on desktop Linux (and Windows), Command
/// everywhere else. Linux has no reliable Super key in a Flutter window, so Ctrl stands in for
/// the spec's ⌘. Only desktop platforms ship, so the fallback to Command mainly means test
/// runs (which report android) render the same labels as macOS.
enum PrimaryModifier { meta, control }

PrimaryModifier primaryModifierFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.linux || TargetPlatform.windows => PrimaryModifier.control,
      _ => PrimaryModifier.meta,
    };

PrimaryModifier get primaryModifier =>
    primaryModifierFor(defaultTargetPlatform);

/// Label for a primary-modifier shortcut: `⌘K` on macOS, `Ctrl+K` elsewhere.
String primaryLabel(
  String key, {
  bool shift = false,
  PrimaryModifier? modifier,
}) => switch (modifier ?? primaryModifier) {
  PrimaryModifier.meta => '⌘${shift ? '⇧' : ''}$key',
  PrimaryModifier.control => 'Ctrl+${shift ? 'Shift+' : ''}$key',
};

/// Label for a shortcut that is Control on every platform (the terminal toggle).
String controlLabel(String key, {PrimaryModifier? modifier}) =>
    switch (modifier ?? primaryModifier) {
      PrimaryModifier.meta => '⌃$key',
      PrimaryModifier.control => 'Ctrl+$key',
    };
