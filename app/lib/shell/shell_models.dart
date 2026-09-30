import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../api/models/models.dart' show WorkspaceMode, XpStatus;
import '../state/format.dart' show groupThousands;
import '../state/display_state.dart';
import '../state/workspace_flow.dart' show StepKey;

@immutable
class SidebarWorkspace {
  const SidebarWorkspace({
    required this.id,
    required this.name,
    required this.state,
    this.defaultStep = StepKey.agent,
    this.word,
    this.mode = WorkspaceMode.agent,
    this.branch = '',
  });

  final String id;
  final String name;
  final DisplayState state;

  /// Git branch, for the row menu's "Copy branch name". Empty hides that item.
  final String branch;

  /// Overrides `state.word` (test-first review reads `test`, not `plan`).
  final String? word;

  /// The step the workspace opens on, which follows its state (§5.1).
  final StepKey defaultStep;

  /// Who writes the code. The palette offers the opposite switch.
  final WorkspaceMode mode;

  bool get manual => mode == WorkspaceMode.manual;
}

@immutable
class SidebarProject {
  const SidebarProject({
    required this.id,
    required this.name,
    required this.workspaces,
  });

  final String id;
  final String name;
  final List<SidebarWorkspace> workspaces;
}

/// What the sidebar footer and the collapsed strip's badge draw. Null in [ShellData] means
/// there is nothing to show (XP is off in Settings, or the backend has not answered yet).
@immutable
class XpFooterData {
  const XpFooterData({
    required this.level,
    required this.rank,
    required this.xp,
    this.nextRankAt,
    this.progress = 0,
    this.streak = const [],
    this.streakDays = 0,
    this.todayDone = false,
    this.latestAmount,
    this.latestLabel,
  });

  factory XpFooterData.fromStatus(XpStatus s) => XpFooterData(
    level: s.level,
    rank: s.rank,
    xp: s.xp,
    nextRankAt: s.nextRankAt,
    progress: s.progress,
    streak: s.streak,
    streakDays: s.streakDays,
    todayDone: s.todayDone,
    latestAmount: s.latest?.amount,
    latestLabel: s.latest?.label,
  );

  final int level;
  final String rank;
  final int xp;
  final int? nextRankAt;
  final double progress;
  final List<bool> streak;
  final int streakDays;
  final bool todayDone;
  final int? latestAmount;
  final String? latestLabel;

  /// `1,240 / 2,000 XP`, or just the total at the top rank.
  String get xpText => nextRankAt == null
      ? '${groupThousands(xp)} XP'
      : '${groupThousands(xp)} / ${groupThousands(nextRankAt!)} XP';

  String get tooltip => 'Level $level · $rank · $xpText';
}

/// Everything the shell renders that comes from the data layer.
@immutable
class ShellData {
  const ShellData({
    required this.triageCount,
    required this.backlogOpen,
    required this.needYouCount,
    required this.projects,
    this.xp,
  });

  /// Count next to "Triage" (all workspaces).
  final int triageCount;

  /// Count next to "Backlog", rendered as "N open".
  final int backlogOpen;

  /// Workspaces in the "needs you" group (top bar pill).
  final int needYouCount;
  final List<SidebarProject> projects;

  /// The sidebar footer and strip badge; null hides both.
  final XpFooterData? xp;

  SidebarWorkspace? workspaceById(String id) {
    for (final p in projects) {
      for (final w in p.workspaces) {
        if (w.id == id) return w;
      }
    }
    return null;
  }

  SidebarProject? projectOf(String workspaceId) {
    for (final p in projects) {
      if (p.workspaces.any((w) => w.id == workspaceId)) return p;
    }
    return null;
  }
}

/// One callback per button. Defaults are no-ops until the screens exist.
@immutable
class ShellActions {
  const ShellActions({
    this.onHome = _noop,
    this.onTriage = _noop,
    this.onBacklog = _noop,
    this.onSearch = _noop,
    this.onNeedYou = _noop,
    this.onShortcuts = _noop,
    this.onSettings = _noop,
    this.onOpenWorkspace = _noopId,
    this.onNewWorkspace = _noopOptionalId,
    this.onAddProject = _noop,
    this.onProjectMenu = _noopMenu,
    this.onWorkspaceMenu = _noopMenu,
    this.onSetMode = _noopMode,
    this.onToggleSidebar = _noop,
    this.onXpHelp = _noop,
  });

  final VoidCallback onHome;
  final VoidCallback onTriage;
  final VoidCallback onBacklog;
  final VoidCallback onSearch;
  final VoidCallback onNeedYou;
  final VoidCallback onShortcuts;
  final VoidCallback onSettings;
  final ValueChanged<String> onOpenWorkspace;

  /// Project id when invoked from a project's `+`, null from the bottom button.
  final ValueChanged<String?> onNewWorkspace;
  final VoidCallback onAddProject;

  /// Right-click on a project header: project id and the pointer position in the window.
  final void Function(String projectId, Offset position) onProjectMenu;

  /// Right-click or the hover `···` on a workspace row: workspace id and the menu position.
  final void Function(String workspaceId, Offset position) onWorkspaceMenu;

  /// The WHO WRITES THE CODE switch in the top bar (only shown with a workspace open).
  final ValueChanged<WorkspaceMode> onSetMode;

  /// The top bar's menu button: sidebar 220px, or the 52px strip.
  final VoidCallback onToggleSidebar;

  /// The footer's "?" and the strip badge: open "How XP works".
  final VoidCallback onXpHelp;

  static void _noop() {}
  static void _noopId(String _) {}
  static void _noopOptionalId(String? _) {}
  static void _noopMenu(String _, Offset _) {}
  static void _noopMode(WorkspaceMode _) {}
}
