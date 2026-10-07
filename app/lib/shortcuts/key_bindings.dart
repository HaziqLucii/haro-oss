import 'package:flutter/services.dart';

import 'platform_keys.dart';

enum ShortcutAction {
  palette,
  needYou,
  newWorkspace,
  shortcuts,
  step1,
  step2,
  step3,
  step4,
  runGate,
  toggleTerminal,
  focusComposer,
  runDevServer,
  openWorktree,
  saveFile,
  splitEditor,
  toggleFocus,
}

/// Pure key-to-action mapping so the platform and focus rules can be tested without a
/// widget tree. Returns null when the key is not ours, which lets it reach the focused widget.
ShortcutAction? resolveShortcut({
  required LogicalKeyboardKey key,
  String? character,
  required bool meta,
  required bool control,
  required bool shift,
  required bool alt,
  required PrimaryModifier modifier,
  required bool textFieldFocused,
  required bool onWorkspace,
}) {
  if (alt) return null;

  if (character == '?' && !meta && !control) {
    return textFieldFocused ? null : ShortcutAction.shortcuts;
  }

  if (control && !meta && !shift && key == LogicalKeyboardKey.backquote) {
    return ShortcutAction.toggleTerminal;
  }

  final primary = modifier == PrimaryModifier.meta
      ? meta && !control
      : control && !meta;
  if (primary && shift && !alt && key == LogicalKeyboardKey.keyO) {
    return onWorkspace ? ShortcutAction.openWorktree : null;
  }
  if (primary &&
      shift &&
      (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter)) {
    return onWorkspace ? ShortcutAction.toggleFocus : null;
  }
  if (!primary || shift) return null;

  if (key == LogicalKeyboardKey.keyK) return ShortcutAction.palette;
  if (key == LogicalKeyboardKey.keyJ) return ShortcutAction.needYou;
  if (key == LogicalKeyboardKey.keyN) return ShortcutAction.newWorkspace;
  if (key == LogicalKeyboardKey.keyG) return ShortcutAction.runGate;
  if (key == LogicalKeyboardKey.keyI) return ShortcutAction.focusComposer;
  if (key == LogicalKeyboardKey.keyR) return ShortcutAction.runDevServer;
  if (onWorkspace && key == LogicalKeyboardKey.keyS) {
    return ShortcutAction.saveFile;
  }
  if (onWorkspace && key == LogicalKeyboardKey.backslash) {
    return ShortcutAction.splitEditor;
  }
  if (onWorkspace) {
    if (key == LogicalKeyboardKey.digit1) return ShortcutAction.step1;
    if (key == LogicalKeyboardKey.digit2) return ShortcutAction.step2;
    if (key == LogicalKeyboardKey.digit3) return ShortcutAction.step3;
    if (key == LogicalKeyboardKey.digit4) return ShortcutAction.step4;
  }
  return null;
}
