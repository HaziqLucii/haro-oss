import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:re_editor/re_editor.dart' show CodeEditor;
import 'package:xterm/xterm.dart' show TerminalView;

import '../api/haro_api.dart';
import '../api/models/models.dart' show WorkspaceMode;
import '../data/workspace_actions.dart';
import '../data/workspace_detail.dart';
import '../data/workspace_detail_lazy.dart';
import '../features/new_workspace/creation_commands.dart';
import '../features/open_in/open_in_commands.dart';
import '../features/remove_project/remove_project_commands.dart';
import '../features/settings/settings_register.dart';
import '../features/workspace/mode_switch.dart';
import '../features/workspace/workspace_ui.dart';
import '../overlays/command_palette.dart';
import '../overlays/overlay.dart';
import '../overlays/help_overlay.dart';
import '../shell/shell_layout.dart';
import '../shell/shell_providers.dart';
import '../state/workspace_flow.dart' show StepKey;
import 'app_commands.dart';
import 'key_bindings.dart';
import 'need_you.dart';
import 'platform_keys.dart';

/// `w/<id>/<step>` locations carry the open workspace.
String? workspaceIdOf(Uri location) {
  final s = location.pathSegments;
  return s.length >= 2 && s.first == 'w' ? s[1] : null;
}

/// Binds the global shortcuts and registers the built-in commands (palette, shortcuts
/// overlay, ⌘J, step jumps). Place it once, below the router's Navigator.
///
/// Keys go through [FocusManager.addEarlyKeyEventHandler] rather than a Shortcuts widget: a
/// widget only sees keys while focus sits beneath it, and clicking away from a text field
/// leaves focus on the route's scope, outside any widget we could wrap the app in.
class ShortcutsHost extends ConsumerStatefulWidget {
  const ShortcutsHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ShortcutsHost> createState() => _ShortcutsHostState();
}

class _ShortcutsHostState extends ConsumerState<ShortcutsHost> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
    FocusManager.instance.addLateKeyEventHandler(_onLateKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(appCommandsProvider.notifier)
          .register(
            (c) => c.copyWith(
              openPalette: () => showCommandPalette(context),
              openShortcuts: () =>
                  showHelpOverlay(context, tab: HelpTab.shortcuts),
              openGuide: () => showHelpOverlay(context),
              nextNeedYou: _nextNeedYou,
              toggleTerminal: _toggleTerminal,
              focusComposer: _focusComposer,
              runGate: _runGate,
              runDevServer: _toggleDevServer,
              setWorkspaceMode: _setMode,
              toggleFocus: _toggleFocus,
              toggleSidebar: () =>
                  ref.read(shellLayoutProvider.notifier).toggleSidebar(),
              toggleRail: () =>
                  ref.read(shellLayoutProvider.notifier).toggleRail(),
            ),
          );
      registerCreationCommands(ref, () => context);
      registerRemoveProjectCommands(ref, () => context);
      registerSettingsCommands(ref, () => context);
      registerOpenInCommands(ref, () => context);
    });
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    FocusManager.instance.removeLateKeyEventHandler(_onLateKey);
    super.dispose();
  }

  Uri get _location =>
      GoRouter.of(context).routerDelegate.currentConfiguration.uri;

  void _nextNeedYou() {
    final target = nextNeedYou(
      ref.read(needYouIdsProvider),
      workspaceIdOf(_location),
    );
    if (target == null) return;
    final step =
        ref.read(shellDataProvider).workspaceById(target)?.defaultStep ??
        StepKey.agent;
    GoRouter.of(context).go('/w/$target/${step.name}');
  }

  String? get _openWorkspace => workspaceIdOf(_location);

  /// Focus mode belongs to the code step of the open workspace.
  String? get _codeStepWorkspace {
    final segments = _location.pathSegments;
    final id = workspaceIdOf(_location);
    return id != null && segments.length >= 3 && segments[2] == 'code'
        ? id
        : null;
  }

  void _toggleFocus() {
    final id = _codeStepWorkspace;
    if (id == null) return;
    ref.read(shellLayoutProvider.notifier).toggleFocus(id);
  }

  /// Esc leaves focus mode only when nothing else wanted it: this runs as a late handler, so
  /// the editor (close find, cancel a selection, end IME composing) and the terminal (vim,
  /// less) have already had their chance. What is left is checked again here: an overlay, a
  /// menu or dialog on top of this page, or a text input or terminal holding focus.
  KeyEventResult _onLateKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        haroOverlayDepth.value > 0) {
      return KeyEventResult.ignored;
    }
    final id = _codeStepWorkspace;
    if (id == null || ref.read(shellLayoutProvider).focusWorkspaceId != id) {
      return KeyEventResult.ignored;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
      return KeyEventResult.ignored;
    }
    if (_textFieldFocused ||
        _focusedWithin<TerminalView>() ||
        _editorComposing) {
      return KeyEventResult.ignored;
    }
    ref.read(shellLayoutProvider.notifier).exitFocus();
    return KeyEventResult.handled;
  }

  /// re_editor turns its own Esc off while an IME is composing so the key reaches the IME;
  /// taking it here would exit focus mode and leave the candidate uncancelled.
  bool get _editorComposing =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<CodeEditor>()
          ?.controller
          ?.isComposing ==
      true;

  void _setMode(WorkspaceMode mode) {
    final id = _openWorkspace;
    if (id == null) return;
    requestWorkspaceModeSwitch(context, ref, workspaceId: id, target: mode);
  }

  void _toggleTerminal() {
    if (_openWorkspace == null) return;
    ref.read(workspaceUiProvider.notifier).toggleTerminal();
  }

  void _focusComposer() {
    final id = _openWorkspace;
    if (id == null) return;
    if (ref.read(shellDataProvider).workspaceById(id)?.mode ==
        WorkspaceMode.manual) {
      return;
    }
    GoRouter.of(context).go(workspaceStepPath(id, StepKey.agent));
    ref.read(workspaceUiProvider.notifier).requestComposerFocus();
  }

  // Failures surface in the verify step's own state (the gate stays red / not run);
  // a keyboard shortcut has no inline place to show an error.
  void _runGate() {
    final id = _openWorkspace;
    if (id == null) return;
    GoRouter.of(context).go(workspaceStepPath(id, StepKey.verify));
    ref
        .read(workspaceActionsProvider(id))
        .runGate()
        .then(
          (_) {},
          onError: (Object e) {
            if (e is! HaroApiException) throw e;
          },
        );
  }

  void _toggleDevServer() {
    final id = _openWorkspace;
    if (id == null) return;
    final actions = ref.read(workspaceActionsProvider(id));
    final running = ref.read(workspaceDetailProvider(id)).app.running;
    if (!running && ref.read(workspaceRunProblemProvider(id)).value != null) {
      return;
    }
    (running ? actions.stopDevServer() : actions.startDevServer()).then(
      (_) {},
      onError: (Object e) {
        if (e is! HaroApiException) throw e;
      },
    );
  }

  bool _focusedWithin<T extends Widget>() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<T>() !=
      null;

  bool get _textFieldFocused =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || haroOverlayDepth.value > 0) {
      return KeyEventResult.ignored;
    }
    final kb = HardwareKeyboard.instance;
    final action = resolveShortcut(
      key: event.logicalKey,
      character: event.character,
      meta: kb.isMetaPressed,
      control: kb.isControlPressed,
      shift: kb.isShiftPressed,
      alt: kb.isAltPressed,
      modifier: primaryModifier,
      // xterm's TerminalView takes text through its own TextInputClient, not EditableText.
      textFieldFocused:
          _textFieldFocused ||
          _focusedWithin<CodeEditor>() ||
          _focusedWithin<TerminalView>(),
      onWorkspace: workspaceIdOf(_location) != null,
    );
    if (action == null) return KeyEventResult.ignored;
    if (action == ShortcutAction.toggleFocus && _codeStepWorkspace == null) {
      return KeyEventResult.ignored;
    }
    // With Control as the primary modifier every chord is also a shell or editor key
    // (Ctrl+R history search, Ctrl+K kill line, Ctrl+G/I/N...), so those keep them.
    if (primaryModifier == PrimaryModifier.control &&
        (_focusedWithin<TerminalView>() || _focusedWithin<CodeEditor>()) &&
        action != ShortcutAction.toggleTerminal &&
        action != ShortcutAction.toggleFocus &&
        !(action == ShortcutAction.splitEditor &&
            !_focusedWithin<TerminalView>()) &&
        !(action == ShortcutAction.saveFile &&
            !_focusedWithin<TerminalView>())) {
      return KeyEventResult.ignored;
    }
    final c = ref.read(appCommandsProvider);
    switch (action) {
      case ShortcutAction.palette:
        c.openPalette();
      case ShortcutAction.needYou:
        c.nextNeedYou();
      case ShortcutAction.newWorkspace:
        c.openNewWorkspace(null);
      case ShortcutAction.shortcuts:
        c.openShortcuts();
      case ShortcutAction.runGate:
        c.runGate();
      case ShortcutAction.toggleTerminal:
        c.toggleTerminal();
      case ShortcutAction.focusComposer:
        c.focusComposer();
      case ShortcutAction.runDevServer:
        c.runDevServer();
      case ShortcutAction.openWorktree:
        c.openWorktree();
      case ShortcutAction.saveFile:
        c.saveFile();
      case ShortcutAction.splitEditor:
        c.splitEditor();
      case ShortcutAction.toggleFocus:
        c.toggleFocus();
      case ShortcutAction.captureTodo:
        c.captureTodo();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
