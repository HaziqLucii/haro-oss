import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../overlays/overlay.dart';
import '../../shortcuts/app_commands.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../../util/home_dir.dart';
import 'controls/select.dart';
import 'device_prefs.dart';
import 'settings_controller.dart';
import 'settings_layers.dart';
import 'settings_scope.dart';
import 'settings_section.dart';
import 'settings_tab_spec.dart';
import 'settings_tokens.dart';
import 'tabs/app_tabs.dart';
import 'tabs/project_tabs.dart';

/// Remembered across opens: "opens Settings on its last (or first) tab" (app_commands).
SettingsTab _lastTab = SettingsTab.display;

Future<void> showSettingsOverlay(
  BuildContext context, {
  required HaroApi api,
  required DevicePrefsStore devicePrefs,
  required List<Project> projects,
  String? projectId,
  SettingsTab? tab,
  SettingsLayerReader layers = const FileSettingsLayerReader(),
  void Function(DisplayPrefs saved)? onDisplaySaved,
  void Function(EditorPrefs saved)? onEditorSaved,
  void Function(XpPrefs saved)? onXpSaved,
}) => showHaroOverlay<void>(
  context,
  width: SettingsTokens.overlayWidth,
  height: SettingsTokens.overlayHeight,
  child: SettingsOverlay(
    api: api,
    devicePrefs: devicePrefs,
    projects: projects,
    projectId: projectId,
    layers: layers,
    initialTab: tab,
    onDisplaySaved: onDisplaySaved,
    onEditorSaved: onEditorSaved,
    onXpSaved: onXpSaved,
  ),
);

SettingsTabSpec specFor(SettingsController c, SettingsTab tab) {
  if (tab.project && c.projectId == null) {
    return SettingsTabSpec(
      tab: tab,
      title: tab.label,
      intro: 'Pick a project first.',
      scope: SettingsScope.readOnly,
    );
  }
  return switch (tab) {
    SettingsTab.display => displayTab(c),
    SettingsTab.editor => editorTab(c),
    SettingsTab.notifications => notificationsTab(c),
    SettingsTab.xp => xpTab(c),
    SettingsTab.usage => usageTab(c),
    SettingsTab.system => systemTab(c),
    SettingsTab.git => gitTab(c),
    SettingsTab.setup => setupTab(c),
    SettingsTab.gate => gateTab(c),
    SettingsTab.agent => agentTab(c),
    SettingsTab.roles => rolesTab(c),
    SettingsTab.environment => environmentTab(c),
    SettingsTab.instructions => instructionsTab(c),
  };
}

/// §6.1: one surface for app and project settings. All edits stay local until the save bar's
/// Save; tabs keep their edits while you look at another one.
class SettingsOverlay extends StatefulWidget {
  const SettingsOverlay({
    super.key,
    required this.api,
    required this.devicePrefs,
    required this.projects,
    this.projectId,
    this.layers = const FileSettingsLayerReader(),
    this.initialTab,
    this.onDisplaySaved,
    this.onEditorSaved,
    this.onXpSaved,
  });

  final HaroApi api;
  final DevicePrefsStore devicePrefs;
  final List<Project> projects;
  final String? projectId;
  final SettingsLayerReader layers;

  /// `null` reopens the last tab, or Display when that needs a project and none is chosen.
  final SettingsTab? initialTab;

  final void Function(DisplayPrefs saved)? onDisplaySaved;
  final void Function(EditorPrefs saved)? onEditorSaved;
  final void Function(XpPrefs saved)? onXpSaved;

  @override
  State<SettingsOverlay> createState() => _SettingsOverlayState();
}

class _SettingsOverlayState extends State<SettingsOverlay> {
  late final SettingsController _c = SettingsController(
    api: widget.api,
    devicePrefs: widget.devicePrefs,
    projects: widget.projects,
    projectId: widget.projectId,
    layers: widget.layers,
    onDisplaySaved: widget.onDisplaySaved,
    onEditorSaved: widget.onEditorSaved,
    onXpSaved: widget.onXpSaved,
  );
  late SettingsTab _tab =
      widget.initialTab ??
      (_lastTab.project && _c.projectId == null
          ? SettingsTab.display
          : _lastTab);
  String _query = '';
  bool _nudge = false;
  Timer? _nudgeTimer;

  @override
  void initState() {
    super.initState();
    _c.ensureLoaded(_tab);
  }

  @override
  void dispose() {
    _nudgeTimer?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _pick(SettingsTab t) {
    _lastTab = t;
    setState(() => _tab = t);
    _c.ensureLoaded(t);
  }

  void _flashUnsaved() {
    _nudgeTimer?.cancel();
    setState(() => _nudge = true);
    _nudgeTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _nudge = false);
    });
  }

  void _close() {
    if (_c.dirty) {
      _flashUnsaved();
    } else {
      closeHaroOverlay(context);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _c,
    builder: (context, _) {
      final q = _query.trim();
      final specs = <SettingsTab, SettingsTabSpec>{};
      SettingsTabSpec spec(SettingsTab t) => specs[t] ??= specFor(_c, t);
      final matching = [
        for (final t in SettingsTab.values)
          if (q.isEmpty || tabMatches(spec(t), q)) t,
      ];
      final shown = matching.contains(_tab)
          ? _tab
          : (matching.isEmpty ? null : matching.first);
      if (shown != null && shown != _tab) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _c.ensureLoaded(shown);
        });
      }
      return PopScope(
        canPop: !_c.dirty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _flashUnsaved();
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: (node, e) {
            if (e is KeyDownEvent &&
                e.logicalKey == LogicalKeyboardKey.escape &&
                _c.dirty) {
              _flashUnsaved();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: SettingsTokens.navWidth,
                child: _Nav(
                  controller: _c,
                  selected: shown,
                  matching: matching.toSet(),
                  query: _query,
                  onQuery: (v) => setState(() => _query = v),
                  onPick: _pick,
                  onProjectBlocked: _flashUnsaved,
                ),
              ),
              Container(width: 1, color: HaroTokens.line12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (shown == null)
                      _NoMatch(query: q, onClose: _close)
                    else
                      Expanded(
                        child: _Pane(
                          key: ValueKey(shown),
                          controller: _c,
                          spec: spec(shown),
                          query: q,
                          onClose: _close,
                        ),
                      ),
                    _SaveBar(controller: _c, nudge: _nudge),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.query, required this.onClose});

  final String query;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Stack(
      children: [
        Center(
          child: Text(
            'No settings match “$query”.',
            style: HaroText.ui(size: 14, color: HaroTokens.ink66),
          ),
        ),
        Positioned(top: 26, right: 32, child: _CloseButton(onClose)),
      ],
    ),
  );
}

class _Nav extends StatelessWidget {
  const _Nav({
    required this.controller,
    required this.selected,
    required this.matching,
    required this.query,
    required this.onQuery,
    required this.onPick,
    required this.onProjectBlocked,
  });

  final SettingsController controller;
  final SettingsTab? selected;
  final Set<SettingsTab> matching;
  final String query;
  final ValueChanged<String> onQuery;
  final ValueChanged<SettingsTab> onPick;
  final VoidCallback onProjectBlocked;

  @override
  Widget build(BuildContext context) {
    final app = SettingsTab.values.where(
      (t) => !t.project && matching.contains(t),
    );
    final proj = SettingsTab.values.where(
      (t) => t.project && matching.contains(t),
    );
    final project = controller.project;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      children: [
        HaroTextField(
          hintText: 'Search settings',
          height: SettingsTokens.fieldHeight,
          fontSize: 13,
          onChanged: onQuery,
        ),
        if (app.isNotEmpty) ...[
          const SizedBox(height: 18),
          const _GroupTitle('App'),
          for (final t in app) _NavItem(controller, t, selected == t, onPick),
        ],
        if (proj.isNotEmpty) ...[
          const SizedBox(height: 18),
          _GroupTitle('Project · ${project?.name ?? 'choose'}'),
          _ProjectPicker(controller: controller, onBlocked: onProjectBlocked),
          const SizedBox(height: 6),
          for (final t in proj) _NavItem(controller, t, selected == t, onPick),
        ],
      ],
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
    child: Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: HaroText.mono(size: 10, tracking: .16, color: HaroTokens.ink42),
    ),
  );
}

/// `~/Projects/haro` for a path under [home].
String tildePath(String path, String? home) {
  if (home == null || home.isEmpty) return path;
  if (path == home) return '~';
  return path.startsWith('$home/') ? '~${path.substring(home.length)}' : path;
}

String projectLabel(Project p, {String? home}) =>
    '${p.name} · ${tildePath(p.path, home ?? userHomeDir())}';

/// The project every project tab acts on. Several projects: a select. One: the same box,
/// not interactive. None chosen yet: a placeholder, and the project tabs stay disabled.
class _ProjectPicker extends StatelessWidget {
  const _ProjectPicker({required this.controller, required this.onBlocked});

  final SettingsController controller;
  final VoidCallback onBlocked;

  @override
  Widget build(BuildContext context) {
    final chosen = controller.project;
    final many = controller.projects.length > 1;
    return SettingSelect<String>(
      key: const ValueKey('project-picker'),
      options: [for (final p in controller.projects) (p.id, projectLabel(p))],
      value: controller.projectId,
      minWidth: 340,
      onChanged: many
          ? (id) {
              if (!controller.selectProject(id)) onBlocked();
            }
          : null,
      child: (context, label, hovered) => AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        height: SettingsTokens.fieldHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          border: Border.all(
            color: hovered && many ? HaroTokens.line30 : HaroTokens.line20,
          ),
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                chosen == null ? 'Choose a project' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(
                  size: 12.5,
                  color: chosen == null ? HaroTokens.ink66 : HaroTokens.ink,
                ),
              ),
            ),
            if (many) ...[const SizedBox(width: 8), const SettingChevron()],
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem(this.controller, this.tab, this.selected, this.onPick);

  final SettingsController controller;
  final SettingsTab tab;
  final bool selected;
  final ValueChanged<SettingsTab> onPick;

  @override
  Widget build(BuildContext context) {
    final dirty = controller.section(tab)?.dirty ?? false;
    final enabled = !tab.project || controller.projectId != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: HaroPressable(
        onTap: enabled ? () => onPick(tab) : null,
        tooltip: enabled ? null : 'Pick a project first',
        semanticLabel: tab.label,
        builder: (context, hovered) => Opacity(
          opacity: enabled ? 1 : .4,
          child: AnimatedContainer(
            duration: HaroTokens.fadeFast,
            curve: HaroTokens.curve,
            height: SettingsTokens.navItemHeight,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? HaroTokens.raised : HaroTokens.transparent,
              borderRadius: BorderRadius.circular(HaroTokens.radius),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tab.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.ui(
                      size: 14,
                      color: selected || hovered
                          ? HaroTokens.ink
                          : HaroTokens.ink66,
                    ),
                  ),
                ),
                if (dirty)
                  Container(
                    key: ValueKey('dirty-${tab.name}'),
                    width: 6,
                    height: 6,
                    color: HaroTokens.ink,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton(this.onClose);

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => HaroButton(
    width: 28,
    height: 28,
    padding: EdgeInsets.zero,
    label: 'Close',
    tooltip: 'Close (Esc)',
    onPressed: onClose,
    child: const Center(child: Text('✕')),
  );
}

class _Pane extends StatelessWidget {
  const _Pane({
    super.key,
    required this.controller,
    required this.spec,
    required this.query,
    required this.onClose,
  });

  final SettingsController controller;
  final SettingsTabSpec spec;
  final String query;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final project = controller.project;
    final title = spec.tab.project && project != null
        ? '${spec.title} · ${project.name}'
        : spec.title;
    final section = controller.section(spec.tab);
    final scope = section is ConfigSection ? section.scope : spec.scope;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: SettingsTokens.paneHeaderPadding,
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: HaroTokens.line12)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: HaroText.ui(
                        size: 24,
                        weight: FontWeight.w500,
                      ).copyWith(letterSpacing: -.24),
                    ),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 540),
                      child: Text(
                        spec.intro,
                        style: HaroText.ui(
                          size: 14,
                          color: HaroTokens.ink66,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (scope.worthATag) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: HaroTokens.line14),
                    borderRadius: BorderRadius.circular(HaroTokens.radius),
                  ),
                  child: Text(
                    scope.label,
                    key: const ValueKey('scope-tag'),
                    maxLines: 1,
                    softWrap: false,
                    style: HaroText.mono(
                      size: 10.5,
                      tracking: .08,
                      color: HaroTokens.ink42,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              _CloseButton(onClose),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: SettingsTokens.paneBodyPadding,
              child: _Body(
                controller: controller,
                spec: spec,
                section: section,
                query: query,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.controller,
    required this.spec,
    required this.section,
    required this.query,
  });

  final SettingsController controller;
  final SettingsTabSpec spec;
  final LoadableSection<dynamic>? section;
  final String query;

  @override
  Widget build(BuildContext context) {
    final s = section;
    if (s == null) {
      return _Note(
        controller.projects.isEmpty
            ? 'Add a project to configure it.'
            : 'Choose a project in the Project group to configure ${spec.title}.',
      );
    }
    switch (s.state) {
      case SectionLoad.idle:
      case SectionLoad.loading:
        return const _Note('Loading…');
      case SectionLoad.error:
        return Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Could not load ${spec.title.toLowerCase()}: ${s.loadError}',
                  style: HaroText.ui(
                    size: 14,
                    color: HaroTokens.fail,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              HaroButton(label: 'Retry', onPressed: () => s.load(force: true)),
            ],
          ),
        );
      case SectionLoad.loaded:
        break;
    }
    final rows = [
      for (final r in filterRows(spec, query))
        if (r.visible?.call() ?? true) r,
    ];
    final children = <Widget>[?spec.summary, ?spec.banner];
    String? lastSection;
    for (final r in rows) {
      if (r.section != null && r.section != lastSection) {
        children.add(_SectionHead(r.section!));
      }
      if (r.section != null) lastSection = r.section;
      children.add(_RowView(r));
    }
    if (spec.footer != null && query.isEmpty) children.add(spec.footer!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Text(text, style: HaroText.mono(size: 11, color: HaroTokens.ink42)),
  );
}

class _SectionHead extends StatelessWidget {
  const _SectionHead(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 4),
    child: Text(
      text.toUpperCase(),
      style: HaroText.mono(size: 10.5, tracking: .16, color: HaroTokens.ink42),
    ),
  );
}

class _RowView extends StatelessWidget {
  const _RowView(this.spec);

  final SettingRowSpec spec;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final labelMax = (box.maxWidth * .48).clamp(200.0, 420.0);
      final label = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(spec.label, style: HaroText.ui(size: 14.5)),
          if (spec.help.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                spec.help,
                style: HaroText.ui(
                  size: 13,
                  color: HaroTokens.ink42,
                  height: 1.45,
                ),
              ),
            ),
        ],
      );
      final control = spec.control(context);
      Widget row = spec.stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(alignment: Alignment.centerLeft, child: label),
                const SizedBox(height: 12),
                control,
              ],
            )
          : Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 24,
              runSpacing: 12,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: labelMax),
                  child: label,
                ),
                control,
              ],
            );
      if (spec.dimmed) row = Opacity(opacity: .5, child: row);
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: HaroTokens.line08)),
        ),
        child: row,
      );
    },
  );
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({required this.controller, required this.nudge});

  final SettingsController controller;
  final bool nudge;

  @override
  Widget build(BuildContext context) {
    final dirty = controller.dirty;
    return AnimatedSwitcher(
      duration: HaroTokens.fadeFast,
      switchInCurve: HaroTokens.curve,
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: !dirty
          ? const SizedBox.shrink(key: ValueKey('bar-off'))
          : Container(
              key: const ValueKey('save-bar'),
              padding: SettingsTokens.barPadding,
              decoration: const BoxDecoration(
                color: HaroTokens.raised,
                border: Border(top: BorderSide(color: HaroTokens.line20)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _BarText(controller: controller, nudge: nudge),
                  ),
                  const SizedBox(width: 16),
                  HaroButton(
                    label: 'Discard',
                    variant: HaroButtonVariant.tertiary,
                    onPressed: controller.saving ? null : controller.discardAll,
                  ),
                  const SizedBox(width: 8),
                  HaroButton(
                    label: controller.saving ? 'Saving…' : 'Save',
                    variant: HaroButtonVariant.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    onPressed: controller.saving ? null : controller.saveAll,
                  ),
                ],
              ),
            ),
    );
  }
}

class _BarText extends StatelessWidget {
  const _BarText({required this.controller, required this.nudge});

  final SettingsController controller;
  final bool nudge;

  @override
  Widget build(BuildContext context) {
    final tabs = controller.dirtyTabs.toList();
    final tabNames = tabs.length > 1 ? tabs.map((t) => t.label).join(', ') : '';
    final String suffix;
    if (nudge) {
      suffix = ' · save or discard them first';
    } else if (onlyDevice(controller.dirtyScopes)) {
      suffix = tabNames.isEmpty ? '' : ' · $tabNames';
    } else {
      final names = tabNames.isEmpty ? '' : '$tabNames · ';
      suffix = ' · ${names}saves to ${scopeSummary(controller.dirtyScopes)}';
    }
    final error = controller.saveError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            style: HaroText.ui(size: 13.5),
            children: [
              const TextSpan(text: 'Unsaved changes'),
              TextSpan(
                text: suffix,
                style: TextStyle(
                  color: nudge ? HaroTokens.ink : HaroTokens.ink42,
                ),
              ),
            ],
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error,
              key: const ValueKey('save-error'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(size: 13, color: HaroTokens.fail),
            ),
          ),
      ],
    );
  }
}
