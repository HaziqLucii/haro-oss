import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workspace_ui.dart';

export '../workspace_ui.dart' show BottomTab;

@immutable
class BottomPanelState {
  const BottomPanelState({required this.open, required this.tab});

  final bool open;

  /// The tab last chosen. The panel may show another one when this tab is unavailable
  /// (Dev log before a dev server has run); see [effectiveBottomTab].
  final BottomTab tab;

  /// True while the panel is open on [t]. The activity bar's Gate icon uses this for its
  /// active marker.
  bool showing(BottomTab t) => open && tab == t;

  @override
  bool operator ==(Object other) =>
      other is BottomPanelState && other.open == open && other.tab == tab;

  @override
  int get hashCode => Object.hash(open, tab);
}

/// Opens and closes the workspace page's bottom panel, and says which tab it is on.
///
/// The open flag is the one the rail's Terminal row and ⌃` already drive
/// (`workspaceUiProvider.terminalOpen`), so this is a view over shared state, not a second
/// source: ⌃`, the rail toggle, "hide" and these methods can never disagree.
///
/// From the activity bar's Gate icon:
/// ```dart
/// onTap: () => ref.read(bottomPanelProvider(id).notifier).toggleTab(BottomTab.gate),
/// active: ref.watch(bottomPanelProvider(id).select((s) => s.showing(BottomTab.gate))),
/// ```
/// `show(BottomTab.gate)` always opens on that tab; `toggleTab` also hides the panel when it
/// is already open on that tab.
class BottomPanelNotifier extends Notifier<BottomPanelState> {
  BottomPanelNotifier(this.workspaceId);

  final String workspaceId;

  WorkspaceUiNotifier get _ui => ref.read(workspaceUiProvider.notifier);

  @override
  BottomPanelState build() {
    final ui = ref.watch(workspaceUiProvider);
    return BottomPanelState(open: ui.terminalOpen, tab: ui.bottomTab);
  }

  /// Opens the panel on [tab].
  void show(BottomTab tab) {
    _ui
      ..selectBottomTab(tab)
      ..setTerminalOpen(true);
  }

  /// Opens on [tab], or hides the panel when it is already open on it.
  void toggleTab(BottomTab tab) {
    if (state.showing(tab)) {
      hide();
    } else {
      show(tab);
    }
  }

  void hide() => _ui.setTerminalOpen(false);

  /// ⌃`: hides an open panel, opens a hidden one on the last tab.
  void toggle() => _ui.toggleTerminal();
}

final bottomPanelProvider =
    NotifierProvider.family<BottomPanelNotifier, BottomPanelState, String>(
      BottomPanelNotifier.new,
    );

/// The Dev log tab exists only while a dev server runs or has left output.
bool devLogAvailable({required bool running, required bool hasOutput}) =>
    running || hasOutput;

/// [tab] when the panel can show it, else the Terminal.
BottomTab effectiveBottomTab(BottomTab tab, {required bool devLog}) =>
    tab == BottomTab.devLog && !devLog ? BottomTab.terminal : tab;
