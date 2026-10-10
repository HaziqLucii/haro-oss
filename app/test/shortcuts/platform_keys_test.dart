import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/shortcuts/key_bindings.dart';
import 'package:haro_app/shortcuts/platform_keys.dart';

ShortcutAction? _resolve(
  LogicalKeyboardKey key, {
  String? character,
  bool meta = false,
  bool control = false,
  bool shift = false,
  bool alt = false,
  PrimaryModifier modifier = PrimaryModifier.meta,
  bool textFieldFocused = false,
  bool onWorkspace = true,
}) => resolveShortcut(
  key: key,
  character: character,
  meta: meta,
  control: control,
  shift: shift,
  alt: alt,
  modifier: modifier,
  textFieldFocused: textFieldFocused,
  onWorkspace: onWorkspace,
);

void main() {
  group('primaryModifierFor', () {
    test('Control on Linux and Windows, Command elsewhere', () {
      expect(primaryModifierFor(TargetPlatform.macOS), PrimaryModifier.meta);
      expect(primaryModifierFor(TargetPlatform.linux), PrimaryModifier.control);
      expect(
        primaryModifierFor(TargetPlatform.windows),
        PrimaryModifier.control,
      );
    });

    test('labels follow the platform', () {
      expect(primaryLabel('K', modifier: PrimaryModifier.meta), '⌘K');
      expect(primaryLabel('K', modifier: PrimaryModifier.control), 'Ctrl+K');
      expect(
        primaryLabel('O', shift: true, modifier: PrimaryModifier.meta),
        '⌘⇧O',
      );
      expect(
        primaryLabel('O', shift: true, modifier: PrimaryModifier.control),
        'Ctrl+Shift+O',
      );
      expect(controlLabel('`', modifier: PrimaryModifier.meta), '⌃`');
      expect(controlLabel('`', modifier: PrimaryModifier.control), 'Ctrl+`');
    });
  });

  group('resolveShortcut', () {
    test(
      'primary+Shift+T captures a todo from anywhere, even a text field',
      () {
        expect(
          _resolve(LogicalKeyboardKey.keyT, meta: true, shift: true),
          ShortcutAction.captureTodo,
        );
        expect(
          _resolve(
            LogicalKeyboardKey.keyT,
            meta: true,
            shift: true,
            textFieldFocused: true,
            onWorkspace: false,
          ),
          ShortcutAction.captureTodo,
        );
        expect(_resolve(LogicalKeyboardKey.keyT, meta: true), isNull);
        expect(
          _resolve(
            LogicalKeyboardKey.keyT,
            control: true,
            shift: true,
            modifier: PrimaryModifier.control,
          ),
          ShortcutAction.captureTodo,
        );
      },
    );

    test('primary+Shift+O opens the worktree, only on a workspace', () {
      expect(
        _resolve(LogicalKeyboardKey.keyO, meta: true, shift: true),
        ShortcutAction.openWorktree,
      );
      expect(
        _resolve(
          LogicalKeyboardKey.keyO,
          control: true,
          shift: true,
          modifier: PrimaryModifier.control,
        ),
        ShortcutAction.openWorktree,
      );
      expect(
        _resolve(
          LogicalKeyboardKey.keyO,
          meta: true,
          shift: true,
          onWorkspace: false,
        ),
        isNull,
      );
      expect(_resolve(LogicalKeyboardKey.keyO, meta: true), isNull);
      expect(
        _resolve(LogicalKeyboardKey.keyO, control: true, shift: true),
        isNull,
        reason: 'Control is not primary on macOS',
      );
    });

    test('macOS resolves Command, ignores a bare Control', () {
      expect(
        _resolve(LogicalKeyboardKey.keyK, meta: true),
        ShortcutAction.palette,
      );
      expect(_resolve(LogicalKeyboardKey.keyK, control: true), isNull);
    });

    test('Linux resolves Control, ignores Super', () {
      const c = PrimaryModifier.control;
      expect(
        _resolve(LogicalKeyboardKey.keyK, control: true, modifier: c),
        ShortcutAction.palette,
      );
      expect(
        _resolve(LogicalKeyboardKey.keyK, meta: true, modifier: c),
        isNull,
      );
    });

    test('each primary binding', () {
      final expected = {
        LogicalKeyboardKey.keyK: ShortcutAction.palette,
        LogicalKeyboardKey.keyJ: ShortcutAction.needYou,
        LogicalKeyboardKey.keyN: ShortcutAction.newWorkspace,
        LogicalKeyboardKey.keyG: ShortcutAction.runGate,
        LogicalKeyboardKey.keyI: ShortcutAction.focusComposer,
        LogicalKeyboardKey.keyR: ShortcutAction.runDevServer,
      };
      expected.forEach((key, action) {
        expect(_resolve(key, meta: true), action, reason: '$key');
      });
    });

    test('shift or alt turn a binding off', () {
      expect(
        _resolve(LogicalKeyboardKey.keyK, meta: true, shift: true),
        isNull,
      );
      expect(_resolve(LogicalKeyboardKey.keyK, meta: true, alt: true), isNull);
    });

    test('step jumps need an open workspace', () {
      expect(
        _resolve(LogicalKeyboardKey.digit2, meta: true, onWorkspace: false),
        isNull,
      );
    });

    test('Control+backtick toggles the terminal on both platforms', () {
      expect(
        _resolve(LogicalKeyboardKey.backquote, control: true),
        ShortcutAction.toggleTerminal,
      );
      expect(
        _resolve(
          LogicalKeyboardKey.backquote,
          control: true,
          modifier: PrimaryModifier.control,
        ),
        ShortcutAction.toggleTerminal,
      );
      expect(_resolve(LogicalKeyboardKey.backquote, meta: true), isNull);
    });

    test('? opens the overlay only outside text fields', () {
      expect(
        _resolve(LogicalKeyboardKey.slash, character: '?', shift: true),
        ShortcutAction.shortcuts,
      );
      expect(
        _resolve(
          LogicalKeyboardKey.slash,
          character: '?',
          shift: true,
          textFieldFocused: true,
        ),
        isNull,
      );
    });

    test('command shortcuts stay global inside text fields', () {
      expect(
        _resolve(LogicalKeyboardKey.keyK, meta: true, textFieldFocused: true),
        ShortcutAction.palette,
      );
    });
  });
}
