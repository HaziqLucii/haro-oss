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
    this.focusWorkspaceId,
  });

  /// Left sidebar: 220px when open, the 52px strip when not.
  final bool sidebarOpen;

  /// Right rail: 290px when open, the 44px strip when not.
  final bool railOpen;

  /// The workspace whose code step is in focus mode, or null.
  final String? focusWorkspaceId;

  factory ShellLayout.fromJson(Map<String, dynamic> j) => ShellLayout(
    sidebarOpen: jBool(j, 'sidebar_open', true),
    railOpen: jBool(j, 'rail_open', true),
  );

  Map<String, dynamic> toJson() => {
    'sidebar_open': sidebarOpen,
    'rail_open': railOpen,
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
      state = ShellLayout(
        sidebarOpen: saved.sidebarOpen,
        railOpen: saved.railOpen,
        focusWorkspaceId: state.focusWorkspaceId,
      );
    } catch (_) {}
  }

  void toggleSidebar() => _set(sidebarOpen: !state.sidebarOpen);

  void toggleRail() => _set(railOpen: !state.railOpen);

  void setRailOpen(bool open) => _set(railOpen: open);

  void _set({bool? sidebarOpen, bool? railOpen}) {
    _touched = true;
    state = ShellLayout(
      sidebarOpen: sidebarOpen ?? state.sidebarOpen,
      railOpen: railOpen ?? state.railOpen,
      focusWorkspaceId: state.focusWorkspaceId,
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
    );
  }

  @visibleForTesting
  Future<void> get writesSettled => _writes;
}

final shellLayoutProvider = NotifierProvider<ShellLayoutNotifier, ShellLayout>(
  ShellLayoutNotifier.new,
);
