import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/workspace_detail.dart';
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

/// The row a gutter click wants the Problems tab to reveal: the first row at [path]:[line].
/// [serial] makes a repeat click on the same line reveal it again.
@immutable
class ProblemsFocus {
  const ProblemsFocus(this.path, this.line, this.serial);

  final String path;
  final int line;
  final int serial;
}

class ProblemsFocusNotifier extends Notifier<ProblemsFocus?> {
  ProblemsFocusNotifier(this.workspaceId);

  final String workspaceId;
  int _handled = 0;

  @override
  ProblemsFocus? build() => null;

  /// True once per focus: the tab scrolls to the row the first time it sees it, not on every
  /// later rebuild of the tab.
  bool takeReveal(int serial) {
    if (serial <= _handled) return false;
    _handled = serial;
    return true;
  }

  void reveal(String path, int line) =>
      state = ProblemsFocus(path, line, (state?.serial ?? 0) + 1);
}

final problemsFocusProvider =
    NotifierProvider.family<ProblemsFocusNotifier, ProblemsFocus?, String>(
      ProblemsFocusNotifier.new,
    );

/// Whether the workspace's Dev log can be shown: one rule for the bottom panel's tab and the
/// rail's Dev log button, so they never disagree.
final workspaceDevLogAvailableProvider = Provider.autoDispose
    .family<bool, String>(
      (ref, id) => devLogAvailable(
        running: ref.watch(
          workspaceDetailProvider(id)
              .select((d) => d.runs.values.any((r) => r.running)),
        ),
        hasOutput: ref.watch(
          workspaceDevLogProvider(id).select((l) => l.lines.isNotEmpty),
        ),
      ),
    );
