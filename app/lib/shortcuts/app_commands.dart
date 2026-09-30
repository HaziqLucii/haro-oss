import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/models.dart' show WorkspaceMode;

/// Settings tabs the palette deep-links into (§6.1).
enum SettingsTab {
  display('Display', project: false),
  editor('Editor', project: false),
  notifications('Notifications', project: false),
  xp('XP', project: false),
  usage('Usage', project: false),
  system('System', project: false),
  git('Git', project: true),
  setup('Setup', project: true),
  gate('Gate', project: true),
  agent('Agent', project: true),
  roles('Roles', project: true),
  environment('Environment', project: true),
  instructions('Instructions', project: true);

  const SettingsTab(this.label, {required this.project});

  final String label;

  /// Project tabs live under the "Project" group of the nav, the rest under "App".
  final bool project;
}

/// Every action the shortcuts, the palette and the top bar can trigger. The screens that own
/// an action register the real callback; until then the default does nothing.
@immutable
class AppCommands {
  const AppCommands({
    this.openPalette = _none,
    this.openShortcuts = _none,
    this.nextNeedYou = _none,
    this.goToStep = _noStep,
    this.openSettings = _noTab,
    this.openNewWorkspace = _noProject,
    this.openBacklog = _none,
    this.openAddProject = _none,
    this.removeProject = _noProjectId,
    this.runGate = _none,
    this.runDevServer = _none,
    this.toggleTerminal = _none,
    this.focusComposer = _none,
    this.archiveMerged = _none,
    this.openWorktree = _none,
    this.setWorkspaceMode = _noMode,
    this.saveFile = _none,
    this.splitEditor = _none,
    this.toggleFocus = _none,
    this.toggleSidebar = _none,
    this.toggleRail = _none,
  });

  final VoidCallback openPalette;
  final VoidCallback openShortcuts;

  /// Opens the next workspace in the Needs-you group (⌘J).
  final VoidCallback nextNeedYou;

  /// 1-based step number (1 agent, 2 code, 3 verify, 4 ship) of the open workspace.
  final ValueChanged<int> goToStep;

  /// `null` opens Settings on its last (or first) tab.
  final ValueChanged<SettingsTab?> openSettings;

  /// `null` when invoked from the bottom button or the palette rather than a project's `+`.
  final ValueChanged<String?> openNewWorkspace;
  final VoidCallback openBacklog;
  final VoidCallback openAddProject;

  /// Opens the confirm for untracking the project with this id.
  final ValueChanged<String> removeProject;
  final VoidCallback runGate;
  final VoidCallback runDevServer;
  final VoidCallback toggleTerminal;
  final VoidCallback focusComposer;
  final VoidCallback archiveMerged;

  /// Opens the open workspace's worktree in the preferred editor (⌘⇧O).
  final VoidCallback openWorktree;

  /// Flips who writes the code in the open workspace (asks first when going to agent).
  final ValueChanged<WorkspaceMode> setWorkspaceMode;

  /// Saves the active editor buffer, then runs the gate when Run on save is on (⌘S). Registered
  /// by the code step's editor while it is on screen.
  final VoidCallback saveFile;

  /// Opens or closes the second editor pane (⌘\).
  final VoidCallback splitEditor;

  /// Focus mode on the open workspace's code step (⌘⇧↵); does nothing on any other screen.
  final VoidCallback toggleFocus;

  /// Left sidebar between 220px and the 52px strip.
  final VoidCallback toggleSidebar;

  /// Right rail between 290px and the 44px strip.
  final VoidCallback toggleRail;

  AppCommands copyWith({
    VoidCallback? openPalette,
    VoidCallback? openShortcuts,
    VoidCallback? nextNeedYou,
    ValueChanged<int>? goToStep,
    ValueChanged<SettingsTab?>? openSettings,
    ValueChanged<String?>? openNewWorkspace,
    VoidCallback? openBacklog,
    VoidCallback? openAddProject,
    ValueChanged<String>? removeProject,
    VoidCallback? runGate,
    VoidCallback? runDevServer,
    VoidCallback? toggleTerminal,
    VoidCallback? focusComposer,
    VoidCallback? archiveMerged,
    VoidCallback? openWorktree,
    ValueChanged<WorkspaceMode>? setWorkspaceMode,
    VoidCallback? saveFile,
    VoidCallback? splitEditor,
    VoidCallback? toggleFocus,
    VoidCallback? toggleSidebar,
    VoidCallback? toggleRail,
  }) => AppCommands(
    openPalette: openPalette ?? this.openPalette,
    openShortcuts: openShortcuts ?? this.openShortcuts,
    nextNeedYou: nextNeedYou ?? this.nextNeedYou,
    goToStep: goToStep ?? this.goToStep,
    openSettings: openSettings ?? this.openSettings,
    openNewWorkspace: openNewWorkspace ?? this.openNewWorkspace,
    openBacklog: openBacklog ?? this.openBacklog,
    openAddProject: openAddProject ?? this.openAddProject,
    removeProject: removeProject ?? this.removeProject,
    runGate: runGate ?? this.runGate,
    runDevServer: runDevServer ?? this.runDevServer,
    toggleTerminal: toggleTerminal ?? this.toggleTerminal,
    focusComposer: focusComposer ?? this.focusComposer,
    archiveMerged: archiveMerged ?? this.archiveMerged,
    openWorktree: openWorktree ?? this.openWorktree,
    setWorkspaceMode: setWorkspaceMode ?? this.setWorkspaceMode,
    saveFile: saveFile ?? this.saveFile,
    splitEditor: splitEditor ?? this.splitEditor,
    toggleFocus: toggleFocus ?? this.toggleFocus,
    toggleSidebar: toggleSidebar ?? this.toggleSidebar,
    toggleRail: toggleRail ?? this.toggleRail,
  );

  static void _none() {}
  static void _noStep(int _) {}
  static void _noTab(SettingsTab? _) {}
  static void _noProject(String? _) {}
  static void _noProjectId(String _) {}
  static void _noMode(WorkspaceMode _) {}
}

/// Swap callbacks in from `initState` (or a post-frame callback), never from `build`:
/// Riverpod rejects provider writes while the tree is building.
///
/// ```dart
/// ref.read(appCommandsProvider.notifier)
///     .register((c) => c.copyWith(runGate: _runGate));
/// ```
/// To unregister, put back the default: `c.copyWith(runGate: const AppCommands().runGate)`.
class AppCommandsNotifier extends Notifier<AppCommands> {
  @override
  AppCommands build() => const AppCommands();

  /// False once the provider container is gone; a widget unregistering late must check it.
  bool get alive => ref.mounted;

  void register(AppCommands Function(AppCommands current) update) {
    state = update(state);
  }
}

final appCommandsProvider = NotifierProvider<AppCommandsNotifier, AppCommands>(
  AppCommandsNotifier.new,
);
