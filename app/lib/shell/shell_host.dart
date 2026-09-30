import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../backend/backend_health.dart';
import '../data/workspace_store.dart' show haroApiProvider;
import '../data/xp_store.dart';
import '../features/settings/xp_prefs_provider.dart';
import '../features/settings/settings_register.dart';
import '../features/workspace/mode_switch.dart';
import '../features/workspace/workspace_ui.dart' show workspaceStepPath;
import '../overlays/toast.dart';
import '../overlays/xp_rules_popover.dart';
import '../shortcuts/app_commands.dart';
import '../shortcuts/shortcuts_host.dart';
import '../state/workspace_flow.dart' show StepKey;
import '../theme/tokens.dart';
import '../widgets/haro_menu.dart';
import 'focus_bar.dart';
import 'haro_shell.dart';
import 'shell_models.dart';
import 'shell_layout.dart';
import 'shell_providers.dart';
import 'status_bar.dart';

/// Binds `HaroShell` to riverpod state and the router.
class ShellHost extends ConsumerWidget {
  const ShellHost({super.key, required this.state, required this.child});

  final GoRouterState state;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(shellDataProvider);
    final status =
        ref.watch(backendStatusProvider).value ?? BackendStatus.connecting;
    final host = ref.watch(backendConfigProvider).hostLabel;

    final segments = state.uri.pathSegments;
    final onWorkspace = segments.length >= 2 && segments.first == 'w';
    final workspaceId = onWorkspace ? segments[1] : null;
    final workspace = workspaceId == null
        ? null
        : data.workspaceById(workspaceId);
    final project = workspaceId == null ? null : data.projectOf(workspaceId);

    final String crumb1 = onWorkspace
        ? (project?.name ?? '')
        : segments.firstOrNull == 'first-run'
        ? 'First run'
        : 'Triage';
    final String? crumb2 = onWorkspace
        ? (workspace?.name ?? workspaceId)
        : null;

    final layout = ref.watch(shellLayoutProvider);
    final codeStep =
        onWorkspace && segments.length >= 3 && segments[2] == 'code';
    final focus = layout.focusOn(workspaceId: workspaceId, codeStep: codeStep);
    if (layout.focusWorkspaceId != null && !focus) {
      // Focus belongs to one workspace's code step; anywhere else it is stale.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          ref.read(shellLayoutProvider.notifier).exitFocus();
        }
      });
    }

    // Read at click time: screens register their real callbacks after the shell is built.
    AppCommands live() => ref.read(appCommandsProvider);

    ref.listen(xpStoreProvider.select((s) => s.notice), (prev, next) {
      if (next == null || next.seq == prev?.seq) return;
      if (!ref.read(xpPrefsProvider).showXp) return;
      showHaroToast(context, next.message);
    });

    return ShortcutsHost(
      child: HaroShell(
        data: data,
        crumb1: crumb1,
        crumb2: crumb2,
        selectedWorkspaceId: workspaceId,
        triageSelected: segments.isEmpty,
        workspaceMode: workspace?.mode,
        backendStatus: status,
        backendHost: host,
        sidebarOpen: layout.sidebarOpen,
        focus: focus,
        focusBar: focus
            ? ({required trafficLightRoom, required draggable}) =>
                  WorkspaceFocusBar(
                    workspaceId: workspaceId!,
                    name: workspace?.name ?? workspaceId,
                    onExit: () =>
                        ref.read(shellLayoutProvider.notifier).exitFocus(),
                    trafficLightRoom: trafficLightRoom,
                    draggable: draggable,
                  )
            : null,
        statusBar: onWorkspace
            ? WorkspaceStatusBar(
                workspaceId: workspaceId!,
                codeStep: codeStep,
                onGate: () =>
                    context.go(workspaceStepPath(workspaceId, StepKey.verify)),
              )
            : BackendStatusBar(down: status == BackendStatus.down, host: host),
        actions: ShellActions(
          onToggleSidebar: () =>
              ref.read(shellLayoutProvider.notifier).toggleSidebar(),
          onXpHelp: () {
            final xp = ref.read(xpStoreProvider);
            showHowXpWorks(
              context,
              loadRules: () async =>
                  xp.rules ?? await ref.read(haroApiProvider).getXpRules(),
              status: xp.status,
              left: layout.sidebarOpen ? 12 : HaroTokens.sidebarStripWidth + 8,
            );
          },
          onHome: () => context.go('/'),
          onTriage: () => context.go('/'),
          onBacklog: () => live().openBacklog(),
          onSearch: () => live().openPalette(),
          onNeedYou: () => live().nextNeedYou(),
          onShortcuts: () => live().openShortcuts(),
          onSettings: () => live().openSettings(null),
          onOpenWorkspace: (id) => context.go(
            '/w/$id/${(data.workspaceById(id)?.defaultStep ?? StepKey.agent).name}',
          ),
          onSetMode: (mode) {
            final id = workspaceId;
            if (id == null) return;
            requestWorkspaceModeSwitch(
              context,
              ref,
              workspaceId: id,
              target: mode,
            );
          },
          onNewWorkspace: (projectId) => live().openNewWorkspace(projectId),
          onAddProject: () => live().openAddProject(),
          onProjectMenu: (projectId, position) => showHaroMenu(
            context,
            position: position,
            items: [
              HaroMenuItem(
                label: 'New workspace',
                onSelected: () => live().openNewWorkspace(projectId),
              ),
              HaroMenuItem(
                label: 'Project settings',
                onSelected: () => openSettingsFor(
                  ref,
                  context,
                  tab: SettingsTab.git,
                  projectId: projectId,
                ),
              ),
              HaroMenuItem(
                label: 'Remove project…',
                destructive: true,
                onSelected: () => live().removeProject(projectId),
              ),
            ],
          ),
        ),
        child: child,
      ),
    );
  }
}
