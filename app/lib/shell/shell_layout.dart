import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/json_util.dart' show asJson, jBool;
import '../features/settings/device_prefs.dart';

/// Which side chrome is showing. The two collapse flags persist per device (`shell` in the
/// device prefs file); focus mode never does, it is a session-only state tied to one
/// workspace's code step.
class ShellLayout {
  const ShellLayout({
    this.sidebarOpen = true,
    this.railOpen = true,
    this.minimal = false,
    this.peekSidebar = false,
    this.peekRail = false,
    this.focusWorkspaceId,
  });

  /// Left sidebar: 220px when open, the 52px strip when not.
  final bool sidebarOpen;

  /// Right rail: 290px when open, the 44px strip when not.
  final bool railOpen;

  /// Minimal view: the sidebar and rail are tucked away (the two flags above stay as they were
  /// and come back when it ends). Persists per device.
  final bool minimal;

  /// Minimal view only: the pointer is on that window edge, so the panel slides in. Session state.
  final bool peekSidebar;
  final bool peekRail;

  /// The workspace whose code step is in focus mode, or null.
  final String? focusWorkspaceId;

  ShellLayout copyWith({
    bool? sidebarOpen,
    bool? railOpen,
    bool? minimal,
    bool? peekSidebar,
    bool? peekRail,
  }) => ShellLayout(
    sidebarOpen: sidebarOpen ?? this.sidebarOpen,
    railOpen: railOpen ?? this.railOpen,
    minimal: minimal ?? this.minimal,
    peekSidebar: peekSidebar ?? this.peekSidebar,
    peekRail: peekRail ?? this.peekRail,
    focusWorkspaceId: focusWorkspaceId,
  );

  factory ShellLayout.fromJson(Map<String, dynamic> j) => ShellLayout(
    sidebarOpen: jBool(j, 'sidebar_open', true),
    railOpen: jBool(j, 'rail_open', true),
    minimal: jBool(j, 'minimal', false),
  );

  Map<String, dynamic> toJson() => {
    'sidebar_open': sidebarOpen,
    'rail_open': railOpen,
    if (minimal) 'minimal': true,
  };

  /// Focus mode is on for this screen: the workspace is the one that entered it and it is
  /// on its code step. Leaving the step (or the workspace) ends it.
  bool focusOn({required String? workspaceId, required bool codeStep}) =>
      codeStep && workspaceId != null && focusWorkspaceId == workspaceId;
}

class ShellLayoutNotifier extends Notifier<ShellLayout> {
  bool _touched = false;
  Future<void> _writes = Future.value();

  @override
  ShellLayout build() {
    _load();
    return const ShellLayout();
  }

  Future<void> _load() async {
    try {
      final file = await ref.read(devicePrefsStoreProvider).read();
      if (!ref.mounted || _touched) return;
      final saved = ShellLayout.fromJson(asJson(file['shell']));
      state = state.copyWith(
        sidebarOpen: saved.sidebarOpen,
        railOpen: saved.railOpen,
        minimal: saved.minimal,
      );
    } catch (_) {}
  }

  /// The top bar's menu button: the sidebar's width, or in minimal view a peek at it.
  void toggleSidebar() => state.minimal
      ? state = state.copyWith(peekSidebar: !state.peekSidebar)
      : _set(sidebarOpen: !state.sidebarOpen);

  void toggleMinimal() => setMinimal(!state.minimal);

  void setMinimal(bool on) =>
      _set(minimal: on, peekSidebar: false, peekRail: false);

  void peekSidebar(bool on) {
    if (!state.minimal || state.peekSidebar == on) return;
    state = state.copyWith(peekSidebar: on);
  }

  void peekRail(bool on) {
    if (!state.minimal || state.peekRail == on) return;
    state = state.copyWith(peekRail: on);
  }

  void toggleRail() => _set(railOpen: !state.railOpen);

  void setRailOpen(bool open) => _set(railOpen: open);

  void _set({
    bool? sidebarOpen,
    bool? railOpen,
    bool? minimal,
    bool? peekSidebar,
    bool? peekRail,
  }) {
    _touched = true;
    state = state.copyWith(
      sidebarOpen: sidebarOpen,
      railOpen: railOpen,
      minimal: minimal,
      peekSidebar: peekSidebar,
      peekRail: peekRail,
    );
    final snapshot = state.toJson();
    final store = ref.read(devicePrefsStoreProvider);
    _writes = _writes.then((_) async {
      try {
        await store.update((file) => {...file, 'shell': snapshot});
      } catch (_) {}
    });
  }

  void enterFocus(String workspaceId) {
    if (state.focusWorkspaceId == workspaceId) return;
    state = ShellLayout(
      sidebarOpen: state.sidebarOpen,
      railOpen: state.railOpen,
      minimal: state.minimal,
      focusWorkspaceId: workspaceId,
    );
  }

  void toggleFocus(String workspaceId) => state.focusWorkspaceId == workspaceId
      ? exitFocus()
      : enterFocus(workspaceId);

  void exitFocus() {
    if (state.focusWorkspaceId == null) return;
    state = ShellLayout(
      sidebarOpen: state.sidebarOpen,
      railOpen: state.railOpen,
      minimal: state.minimal,
    );
  }

  @visibleForTesting
  Future<void> get writesSettled => _writes;
}

final shellLayoutProvider = NotifierProvider<ShellLayoutNotifier, ShellLayout>(
  ShellLayoutNotifier.new,
);
