import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/models/models.dart' show WorkspaceMode;
import '../capture/capture_mode.dart';
import '../backend/backend_health.dart';
import '../theme/tokens.dart';
import '../widgets/panel_switcher.dart';
import 'shell_models.dart';
import 'sidebar.dart';
import 'sidebar_strip.dart';
import 'top_bar.dart';

/// Builds the focus-mode bar once the shell knows about the traffic lights and dragging.
typedef FocusBarBuilder = Widget Function({
  required bool trafficLightRoom,
  required bool draggable,
});

/// Top bar 48 + Row[Sidebar 220 or strip 52, Expanded(child)] + status bar 24. Focus mode
/// swaps the top bar for the 34px [focusBar] and drops the sidebar. Pure view: all data and
/// callbacks come in through the constructor.
class HaroShell extends StatelessWidget {
  const HaroShell({
    super.key,
    required this.data,
    this.actions = const ShellActions(),
    required this.crumb1,
    this.crumb2,
    this.selectedWorkspaceId,
    this.triageSelected = false,
    this.workspaceMode,
    this.backendStatus = BackendStatus.up,
    this.backendHost,
    this.macTrafficLights,
    this.draggable = true,
    this.sidebarOpen = true,
    this.focus = false,
    this.focusBar,
    this.statusBar,
    required this.child,
  });

  final ShellData data;
  final ShellActions actions;
  final String crumb1;
  final String? crumb2;
  final String? selectedWorkspaceId;
  final bool triageSelected;

  /// The open workspace's mode; null on screens without one (no switch in the top bar).
  final WorkspaceMode? workspaceMode;
  final BackendStatus backendStatus;
  final String? backendHost;

  /// Null means auto-detect (macOS with the hidden title bar).
  final bool? macTrafficLights;

  /// False in widget tests, where no window plugin is present.
  final bool draggable;

  /// Expanded sidebar (220px) or the 52px strip.
  final bool sidebarOpen;

  /// Focus mode: no top bar, no sidebar, [focusBar] in their place.
  final bool focus;
  final FocusBarBuilder? focusBar;

  /// The 24px bar along the bottom; null draws none.
  final Widget? statusBar;
  final Widget child;

  bool get _trafficLightRoom =>
      macTrafficLights ??
      (!captureMode &&
          !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.macOS);

  Widget _chrome() => focus
      ? (focusBar?.call(
              trafficLightRoom: _trafficLightRoom,
              draggable: draggable,
            ) ??
            const SizedBox.shrink())
      : TopBar(
          crumb1: crumb1,
          crumb2: crumb2,
          needYouCount: data.needYouCount,
          actions: actions,
          workspaceMode: workspaceMode,
          trafficLightRoom: _trafficLightRoom,
          draggable: draggable,
        );

  @override
  Widget build(BuildContext context) => Material(
    color: HaroTokens.bg,
    child: Column(
      children: [
        AnimatedSwitcher(
          duration: HaroTokens.fade,
          switchInCurve: HaroTokens.curve,
          switchOutCurve: HaroTokens.curve,
          child: KeyedSubtree(
            key: ValueKey(focus ? 'focus-bar' : 'top-bar'),
            child: _chrome(),
          ),
        ),
        Expanded(
          child: Row(
            children: [
              if (focus)
                const PanelSwitcher(
                  variant: 'hidden',
                  width: 0,
                  alignment: Alignment.centerLeft,
                  child: SizedBox.shrink(),
                )
              else if (sidebarOpen)
                PanelSwitcher(
                  variant: 'open',
                  width: HaroTokens.sidebarWidth,
                  alignment: Alignment.centerLeft,
                  child: Sidebar(
                    data: data,
                    actions: actions,
                    selectedWorkspaceId: selectedWorkspaceId,
                    triageSelected: triageSelected,
                    backendStatus: backendStatus,
                    backendHost: backendHost,
                  ),
                )
              else
                PanelSwitcher(
                  variant: 'strip',
                  width: HaroTokens.sidebarStripWidth,
                  alignment: Alignment.centerLeft,
                  child: SidebarStrip(
                    data: data,
                    actions: actions,
                    selectedWorkspaceId: selectedWorkspaceId,
                    onExpand: actions.onToggleSidebar,
                  ),
                ),
              Expanded(child: ClipRect(child: child)),
            ],
          ),
        ),
        ?statusBar,
      ],
    ),
  );
}
