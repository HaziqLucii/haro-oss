import 'package:flutter/foundation.dart';

import '../api/models/models.dart' show WorkspaceMode;
import '../features/workspace/mode_switch.dart' show switchModeLabel;
import '../shell/shell_models.dart';
import '../shortcuts/app_commands.dart';
import '../shortcuts/platform_keys.dart';
import '../state/display_state.dart';
import 'fuzzy.dart';

enum PaletteGroup {
  workspaces('Workspaces'),
  actions('Actions'),
  settings('Settings');

  const PaletteGroup(this.title);
  final String title;
}

@immutable
class PaletteItem {
  const PaletteItem({
    required this.id,
    required this.group,
    required this.label,
    required this.run,
    this.meta = '',
    this.state,
  });

  final String id;
  final PaletteGroup group;
  final String label;

  /// Right-aligned hint: project name, shortcut, or settings scope.
  final String meta;

  /// Only workspaces carry a status square.
  final DisplayState? state;
  final VoidCallback run;
}

/// [worktreeLabel] is the `Open worktree in <editor>` action's text; null (no workspace
/// open) leaves the action out.
/// [commands] is read when an item runs, so callbacks registered after the palette opened
/// are still the ones called.
List<PaletteItem> buildPaletteItems({
  required ShellData data,
  required AppCommands Function() commands,
  required void Function(String workspaceId, String step) openWorkspace,
  PrimaryModifier? modifier,
  String? worktreeLabel,
  WorkspaceMode? openWorkspaceMode,
  bool focusAvailable = false,
  bool railAvailable = false,
}) {
  String primary(String key) => primaryLabel(key, modifier: modifier);
  return [
    for (final p in data.projects)
      for (final w in p.workspaces)
        PaletteItem(
          id: 'ws:${w.id}',
          group: PaletteGroup.workspaces,
          label: w.name,
          meta: p.name,
          state: w.state,
          run: () => openWorkspace(w.id, w.defaultStep.name),
        ),
    PaletteItem(
      id: 'action:need-you',
      group: PaletteGroup.actions,
      label: 'Next workspace that needs you',
      meta: primary('J'),
      run: () => commands().nextNeedYou(),
    ),
    PaletteItem(
      id: 'action:new-workspace',
      group: PaletteGroup.actions,
      label: 'New workspace',
      meta: primary('N'),
      run: () => commands().openNewWorkspace(null),
    ),
    PaletteItem(
      id: 'action:run-gate',
      group: PaletteGroup.actions,
      label: 'Run gate',
      meta: primary('G'),
      run: () => commands().runGate(),
    ),
    if (openWorkspaceMode != null)
      PaletteItem(
        id: 'action:switch-mode',
        group: PaletteGroup.actions,
        label: switchModeLabel(
          openWorkspaceMode == WorkspaceMode.manual
              ? WorkspaceMode.agent
              : WorkspaceMode.manual,
        ),
        run: () => commands().setWorkspaceMode(
          openWorkspaceMode == WorkspaceMode.manual
              ? WorkspaceMode.agent
              : WorkspaceMode.manual,
        ),
      ),
    PaletteItem(
      id: 'action:backlog',
      group: PaletteGroup.actions,
      label: 'Open backlog',
      run: () => commands().openBacklog(),
    ),
    if (worktreeLabel != null)
      PaletteItem(
        id: 'action:open-worktree',
        group: PaletteGroup.actions,
        label: worktreeLabel,
        meta: primaryLabel('O', shift: true, modifier: modifier),
        run: () => commands().openWorktree(),
      ),
    PaletteItem(
      id: 'action:terminal',
      group: PaletteGroup.actions,
      label: 'Toggle terminal',
      meta: controlLabel('`', modifier: modifier),
      run: () => commands().toggleTerminal(),
    ),
    PaletteItem(
      id: 'action:toggle-sidebar',
      group: PaletteGroup.actions,
      label: 'Toggle sidebar',
      run: () => commands().toggleSidebar(),
    ),
    if (railAvailable)
      PaletteItem(
        id: 'action:toggle-rail',
        group: PaletteGroup.actions,
        label: 'Toggle right rail',
        run: () => commands().toggleRail(),
      ),
    if (focusAvailable)
      PaletteItem(
        id: 'action:toggle-focus',
        group: PaletteGroup.actions,
        label: 'Toggle focus mode',
        meta: primaryLabel('↵', shift: true, modifier: modifier),
        run: () => commands().toggleFocus(),
      ),
    PaletteItem(
      id: 'action:shortcuts',
      group: PaletteGroup.actions,
      label: 'Keyboard shortcuts',
      meta: '?',
      run: () => commands().openShortcuts(),
    ),
    PaletteItem(
      id: 'action:archive-merged',
      group: PaletteGroup.actions,
      label: 'Archive merged workspaces',
      run: () => commands().archiveMerged(),
    ),
    for (final p in data.projects)
      PaletteItem(
        id: 'action:remove-project:${p.id}',
        group: PaletteGroup.actions,
        label: 'Remove project · ${p.name}',
        run: () => commands().removeProject(p.id),
      ),
    for (final tab in SettingsTab.values)
      PaletteItem(
        id: 'setting:${tab.name}',
        group: PaletteGroup.settings,
        label: tab.label,
        meta: tab.project ? 'Project settings' : 'App settings',
        run: () => commands().openSettings(tab),
      ),
  ];
}

/// Fuzzy-filtered items per group, in group order, empty groups dropped. The whole query is
/// matched against the label first; items that fail that are kept when every word of the
/// query matches the label or the meta, so "sandbox ship" finds a workspace of that project.
List<(PaletteGroup, List<PaletteItem>)> filterPalette(
  List<PaletteItem> items,
  String query,
) {
  final out = <(PaletteGroup, List<PaletteItem>)>[];
  for (final group in PaletteGroup.values) {
    final inGroup = [
      for (final i in items)
        if (i.group == group) i,
    ];
    final hits = _rank(inGroup, query);
    if (hits.isNotEmpty) out.add((group, hits));
  }
  return out;
}

List<PaletteItem> _rank(List<PaletteItem> items, String query) {
  if (query.trim().isEmpty) return items;
  final byLabel = fuzzyFind<PaletteItem>(query, items, (i) => i.label);
  final seen = {for (final r in byLabel) r.value.id};
  final words = query.trim().split(RegExp(r'\s+'));
  final byWords = <(PaletteItem, double)>[];
  for (final item in items) {
    if (seen.contains(item.id)) continue;
    var total = 0.0;
    var all = true;
    for (final w in words) {
      final l = fuzzyMatch(w, item.label);
      final m = fuzzyMatch(w, item.meta);
      if (l == null && m == null) {
        all = false;
        break;
      }
      total += [
        l?.score,
        m?.score,
      ].whereType<double>().reduce((a, b) => a > b ? a : b);
    }
    if (all) byWords.add((item, total));
  }
  byWords.sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final r in byLabel) r.value, for (final r in byWords) r.$1];
}
