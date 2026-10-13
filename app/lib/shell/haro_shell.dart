import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/models/models.dart' show WorkspaceMode;
import '../capture/capture_mode.dart';
import '../backend/backend_health.dart';
import '../theme/tokens.dart';
import '../features/workspace/fade_in.dart';
import '../widgets/panel_switcher.dart';
import 'shell_models.dart';
import 'sidebar.dart';
import 'sidebar_fold.dart';
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
    this.backlogSelected = false,
    this.fold = const SidebarFold(),
    this.workspaceMode,
    this.backendStatus = BackendStatus.up,
    this.backendHost,
    this.macTrafficLights,
    this.draggable = true,
    this.sidebarOpen = true,
    this.minimal = false,
    this.peekSidebar = false,
    this.railPeekable = false,
    this.focus = false,
    this.focusBar,
    this.statusBar,
    this.account,
    required this.child,
  });

  final ShellData data;
  final ShellActions actions;
  final String crumb1;
  final String? crumb2;
  final String? selectedWorkspaceId;
  final bool triageSelected;
  final bool backlogSelected;
  final SidebarFold fold;

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

  /// Minimal view: a lighter top bar, and the sidebar only while [peekSidebar] (pointer on the
  /// left edge). [railPeekable] adds the matching right edge when the screen has a rail.
  final bool minimal;
  final bool peekSidebar;
  final bool railPeekable;

  /// Focus mode: no top bar, no sidebar, [focusBar] in their place.
  final bool focus;
  final FocusBarBuilder? focusBar;

  /// The 24px bar along the bottom; null draws none.
  final Widget? statusBar;

  /// The avatar button at the top bar's far right.
  final Widget? account;
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
          account: account,
          minimal: minimal,
          xp: data.xp,
        );

  Widget _sidebar() => Sidebar(
    data: data,
    actions: actions,
    selectedWorkspaceId: selectedWorkspaceId,
    triageSelected: triageSelected,
    backlogSelected: backlogSelected,
    fold: fold,
    backendStatus: backendStatus,
    backendHost: backendHost,
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
          child: Stack(
            children: [
              Row(
                children: [
                  if (focus || minimal)
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
                      child: _sidebar(),
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
              if (minimal && !focus && peekSidebar)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: HaroTokens.sidebarWidth,
                  child: FadeIn(
                    child: MouseRegion(
                      key: const ValueKey('sidebar-peek'),
                      onExit: (_) => actions.onPeekSidebar(false),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: HaroTokens.bg,
                          border: Border(
                            right: BorderSide(color: HaroTokens.line12),
                          ),
                        ),
                        child: _sidebar(),
                      ),
                    ),
                  ),
                ),
              if (minimal && !focus) ...[
                _EdgeStrip(
                  left: true,
                  onEnter: () => actions.onPeekSidebar(true),
                ),
                if (railPeekable)
                  _EdgeStrip(
                    left: false,
                    onEnter: () => actions.onPeekRail(true),
                  ),
              ],
            ],
          ),
        ),
        ?statusBar,
      ],
    ),
  );
}

/// The window's own resize handles take the outer 8px on Linux (`DragToResizeArea`, on top of
/// everything), so the hover target reaches past them: the pointer crosses it on its way to
/// the edge.
const double _edgeWidth = 20;

/// A hover target on a window edge in minimal view. Translucent: it only watches the pointer,
/// so the scrollbar underneath stays clickable.
class _EdgeStrip extends StatelessWidget {
  const _EdgeStrip({required this.left, required this.onEnter});

  final bool left;
  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) => Positioned(
    left: left ? 0 : null,
    right: left ? null : 0,
    top: 0,
    bottom: 0,
    width: _edgeWidth,
    child: Listener(
      key: ValueKey(left ? 'edge-left' : 'edge-right'),
      behavior: HitTestBehavior.translucent,
      onPointerHover: (_) => onEnter(),
    ),
  );
}
