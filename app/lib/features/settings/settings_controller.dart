import 'package:flutter/foundation.dart';

import '../../api/haro_api.dart';
import '../../api/models/json_util.dart' show asJson;
import '../../api/models/models.dart';
import '../../shortcuts/app_commands.dart';
import '../open_in/open_in_errors.dart';
import 'device_prefs.dart';
import 'settings_layers.dart';
import 'settings_scope.dart';
import 'settings_section.dart';

/// Git tab: the base branch and remote are their own resources on the backend, so the draft
/// carries them together and [put] only calls what changed.
class GitDraft {
  const GitDraft({
    required this.branches,
    required this.branch,
    required this.remote,
    required this.mergeMode,
  });

  final List<String> branches;
  final String branch;
  final String remote;
  final String mergeMode;

  GitDraft copyWith({String? branch, String? remote, String? mergeMode}) =>
      GitDraft(
        branches: branches,
        branch: branch ?? this.branch,
        remote: remote ?? this.remote,
        mergeMode: mergeMode ?? this.mergeMode,
      );

  Object fingerprint() => {
    'branch': branch,
    'remote': remote.trim(),
    'merge_mode': mergeMode,
  };
}

/// Instructions tab: two files, one visible at a time. Which one is showing is view state,
/// not part of the saved value.
class InstructionsDraft {
  const InstructionsDraft({
    required this.scope,
    required this.shared,
    required this.local,
  });

  /// `local` (personal) or `shared` (team).
  final String scope;
  final String shared;
  final String local;

  String get text => scope == 'shared' ? shared : local;

  InstructionsDraft withText(String value) => scope == 'shared'
      ? InstructionsDraft(scope: scope, shared: value, local: local)
      : InstructionsDraft(scope: scope, shared: shared, local: value);

  InstructionsDraft withScope(String value) =>
      InstructionsDraft(scope: value, shared: shared, local: local);

  Object fingerprint() => {'shared': shared, 'local': local};
}

/// Agent, Gate and Roles: the value plus which file a save lands in. The backend rewrites
/// every field on each save, so [target] `shared` is only offered when [teamSafe] (see
/// [SettingsLayerReader]); `local` pins the values in the personal file instead.
class ScopedDraft<T> {
  const ScopedDraft(this.value, {required this.target, required this.teamSafe});

  final T value;

  /// `shared` (Team, `.haro/settings.toml`) or `local` (Personal, `.haro/settings.local.toml`).
  final String target;
  final bool teamSafe;

  ScopedDraft<T> withValue(T v) =>
      ScopedDraft(v, target: target, teamSafe: teamSafe);

  ScopedDraft<T> withTarget(String t) =>
      ScopedDraft(value, target: t, teamSafe: teamSafe);
}

String _stripOrigin(String b) =>
    b.startsWith('origin/') ? b.substring('origin/'.length) : b;

/// Branch names for the base-branch menu: remote-tracking copies folded into their local
/// name (the backend strips `origin/` on save anyway), `origin` and `HEAD` noise dropped.
List<String> baseBranchChoices(List<String> raw, String current) {
  final seen = <String>{};
  final out = <String>[];
  for (final b in [...raw, current]) {
    final name = _stripOrigin(b);
    if (name.isEmpty || name == 'origin' || name == 'HEAD') continue;
    if (seen.add(name)) out.add(name);
  }
  return out;
}

/// All settings state for one open overlay. Sections load when their tab is first shown and
/// keep their edits when you switch tabs; [dirty] is the total across every tab.
class SettingsController extends ChangeNotifier {
  SettingsController({
    required this.api,
    required this.devicePrefs,
    required this.projects,
    String? projectId,
    this.layers = const FileSettingsLayerReader(),
    this.onDisplaySaved,
    this.onEditorSaved,
    this.onXpSaved,
  }) {
    // Never a silent default: with several projects and no context nothing is selected, so
    // a save cannot land in a repo the user did not pick.
    _projectId = projects.any((p) => p.id == projectId)
        ? projectId
        : (projects.length == 1 ? projects.first.id : null);
    _buildAppSections();
    _buildProjectSections();
  }

  final HaroApi api;
  final DevicePrefsStore devicePrefs;
  final List<Project> projects;
  final SettingsLayerReader layers;

  /// Called with the value that was just written to the device file, so the running app
  /// applies it without a restart.
  final void Function(DisplayPrefs saved)? onDisplaySaved;
  final void Function(EditorPrefs saved)? onEditorSaved;
  final void Function(XpPrefs saved)? onXpSaved;

  /// Detected editors for the Display tab's Preferred editor row. Not a tab of its own, and
  /// read-only: the choice is saved with the Display prefs.
  late final LoadableSection<List<EditorInfo>> editors =
      LoadableSection<List<EditorInfo>>(() async {
        try {
          return await api.listEditors();
        } on HaroApiException catch (e) {
          throw Exception(editorsLoadError(e));
        }
      });

  String? _projectId;
  final Map<SettingsTab, LoadableSection<dynamic>> _sections = {};
  bool saving = false;
  String? saveError;
  bool _disposed = false;

  String? get projectId => _projectId;
  Project? get project => projects.where((p) => p.id == _projectId).firstOrNull;

  LoadableSection<dynamic>? section(SettingsTab tab) => _sections[tab];

  ConfigSection<T> config<T>(SettingsTab tab) =>
      _sections[tab]! as ConfigSection<T>;

  LoadableSection<T> loadable<T>(SettingsTab tab) =>
      _sections[tab]! as LoadableSection<T>;

  Iterable<SettingsTab> get dirtyTabs => [
    for (final t in SettingsTab.values)
      if (_sections[t]?.dirty ?? false) t,
  ];

  bool get dirty => dirtyTabs.isNotEmpty;

  bool get projectDirty => dirtyTabs.any((t) => t.project);

  Set<SettingsScope> get dirtyScopes => {
    for (final s in _sections.values) ...s.dirtyScopes,
  };

  SettingsTab? _active;

  void ensureLoaded(SettingsTab tab) {
    _active = tab;
    if (tab == SettingsTab.display) editors.load();
    if (tab.project && _projectId == null) return;
    _sections[tab]?.load();
  }

  /// Refused (false) while project tabs hold unsaved edits.
  bool selectProject(String id) {
    if (id == _projectId) return true;
    if (projectDirty || !projects.any((p) => p.id == id)) return false;
    for (final t in SettingsTab.values.where((t) => t.project)) {
      _sections.remove(t)?.dispose();
    }
    _projectId = id;
    _buildProjectSections();
    saveError = null;
    final active = _active;
    if (active != null && active.project) _sections[active]?.load();
    _notify();
    return true;
  }

  void discardAll() {
    for (final s in _sections.values) {
      if (s is ConfigSection) s.discard();
    }
    saveError = null;
    _notify();
  }

  /// Saves every dirty tab to its own scope. A failing tab stays dirty and its message
  /// lands in [saveError]; the others still go through.
  Future<void> saveAll() async {
    if (saving) return;
    saving = true;
    saveError = null;
    _notify();
    final errors = <String>[];
    for (final e in _sections.entries.toList()) {
      final s = e.value;
      if (s is! ConfigSection || !s.dirty) continue;
      final ok = await s.save();
      if (!ok) errors.add('${e.key.label}: ${s.saveError}');
    }
    saving = false;
    saveError = errors.isEmpty ? null : errors.join(' · ');
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _watch(LoadableSection<dynamic> s) => s.addListener(_notify);

  void _buildAppSections() {
    ConfigSection<T> deviceSection<T extends Object>(
      String key,
      T Function(Map<String, dynamic>) parse,
      Map<String, dynamic> Function(T) toJson,
      SettingsScope scope, {
      void Function(T saved)? onSaved,
    }) {
      return ConfigSection<T>(
        fetch: () async => parse(asJson((await devicePrefs.read())[key])),
        put: (original, draft) async {
          await devicePrefs.update((file) => {...file, key: toJson(draft)});
          onSaved?.call(draft);
          return draft;
        },
        fingerprint: toJson,
        defaultScope: scope,
      );
    }

    _sections[SettingsTab.display] = deviceSection<DisplayPrefs>(
      'display',
      DisplayPrefs.fromJson,
      (d) => d.toJson(),
      SettingsScope.device,
      onSaved: onDisplaySaved,
    );
    _sections[SettingsTab.editor] = deviceSection<EditorPrefs>(
      'editor',
      EditorPrefs.fromJson,
      (d) => d.toJson(),
      SettingsScope.device,
      onSaved: onEditorSaved,
    );
    _sections[SettingsTab.xp] = deviceSection<XpPrefs>(
      'xp',
      XpPrefs.fromJson,
      (d) => d.toJson(),
      SettingsScope.device,
      onSaved: onXpSaved,
    );
    _sections[SettingsTab.notifications] = deviceSection<NotificationPrefs>(
      'notifications',
      NotificationPrefs.fromJson,
      (d) => d.toJson(),
      SettingsScope.device,
    );
    _sections[SettingsTab.usage] = LoadableSection<UsageResponse>(
      () => api.usage(),
    );
    _sections[SettingsTab.system] = LoadableSection<UpdateStatus>(
      () => api.updateStatus(),
    );
    _watch(editors);
    for (final t in [
      SettingsTab.display,
      SettingsTab.editor,
      SettingsTab.notifications,
      SettingsTab.xp,
      SettingsTab.usage,
      SettingsTab.system,
    ]) {
      _watch(_sections[t]!);
    }
  }

  /// The project record is the source of truth for the base branch, and the copy handed to
  /// the overlay can be stale after an earlier save, so ask again and fall back to that copy.
  Future<String> _freshDefaultBranch(String id) async {
    try {
      final fresh = (await api.listProjects()).where((p) => p.id == id);
      if (fresh.isNotEmpty) return fresh.first.defaultBranch;
    } catch (_) {}
    return project?.defaultBranch ?? '';
  }

  ConfigSection<ScopedDraft<T>> _scoped<T>({
    required List<String> tables,
    required Future<T> Function() fetch,
    required Future<T> Function(T value, String target) put,
    required Map<String, dynamic> Function(T) toJson,
  }) {
    final proj = project!;
    return ConfigSection<ScopedDraft<T>>(
      fetch: () async {
        final r = await Future.wait([
          fetch(),
          layers.teamWriteSafe(proj, tables),
        ]);
        final safe = r[1] as bool;
        return ScopedDraft<T>(
          r[0] as T,
          target: safe ? 'shared' : 'local',
          teamSafe: safe,
        );
      },
      put: (original, draft) async {
        if (draft.target == 'shared' &&
            !await layers.teamWriteSafe(proj, tables)) {
          throw Exception(
            'Team saving is unavailable: haro cannot confirm your personal file '
            'leaves these values alone',
          );
        }
        final saved = await put(draft.value, draft.target);
        return ScopedDraft<T>(
          saved,
          target: draft.target,
          teamSafe: await layers.teamWriteSafe(proj, tables),
        );
      },
      fingerprint: (d) => toJson(d.value),
      defaultScope: SettingsScope.team,
      headerScope: (d) =>
          d.target == 'shared' ? SettingsScope.team : SettingsScope.personal,
      scopesOf: (o, d) => {
        d.target == 'shared' ? SettingsScope.team : SettingsScope.personal,
      },
    );
  }

  void _buildProjectSections() {
    final id = _projectId;
    if (id == null) return;
    _sections[SettingsTab.git] = ConfigSection<GitDraft>(
      fetch: () async {
        final r = await Future.wait([
          api.listBranches(id),
          api.getRemote(id),
          api.getWorkflow(id),
          _freshDefaultBranch(id),
        ]);
        final branches = r[0] as BranchList;
        final base = _stripOrigin(r[3] as String);
        return GitDraft(
          branches: baseBranchChoices(branches.branches, base),
          branch: base,
          remote: (r[1] as RemoteConfig).url ?? '',
          mergeMode: (r[2] as WorkflowConfig).mergeMode,
        );
      },
      put: (original, draft) async {
        var out = draft;
        if (draft.branch != original.branch) {
          final p = await api.setDefaultBranch(id, draft.branch);
          out = out.copyWith(branch: p.defaultBranch);
        }
        if (draft.remote.trim() != original.remote.trim()) {
          final r = await api.setRemote(id, draft.remote.trim());
          out = out.copyWith(remote: r.url ?? '');
        }
        if (draft.mergeMode != original.mergeMode) {
          final w = await api.setWorkflow(id, draft.mergeMode);
          out = out.copyWith(mergeMode: w.mergeMode);
        }
        return out;
      },
      fingerprint: (d) => d.fingerprint(),
      defaultScope: SettingsScope.team,
    );
    // Every write path for [scripts] regenerates the whole target file (the backend says
    // hand-added tables are not preserved), which would wipe [agent] and [roles]. So Setup
    // is shown but never saved from here.
    _sections[SettingsTab.setup] = LoadableSection<ScriptsConfig>(
      () => api.getProjectScripts(id),
    );
    _sections[SettingsTab.gate] = _scoped<GateConfig>(
      tables: const ['gate', 'workflow'],
      fetch: () => api.getGate(id),
      put: (v, target) => api.setGate(id, v, target: target),
      toJson: (c) => c.toJson(),
    );
    _sections[SettingsTab.agent] = _scoped<AgentConfig>(
      tables: const ['agent'],
      fetch: () => api.getAgent(id),
      put: (v, target) => api.setAgent(id, v, target: target),
      toJson: (c) => c.toJson(),
    );
    _sections[SettingsTab.roles] = _scoped<RolesConfig>(
      tables: const ['roles'],
      fetch: () => api.getRoles(id),
      put: (v, target) => api.setRoles(id, v, target: target),
      toJson: (c) => c.toJson(),
    );
    _sections[SettingsTab.environment] = ConfigSection<String>(
      fetch: () async => (await api.getEnv(id)).content,
      put: (_, draft) async => (await api.setEnv(id, draft)).content,
      fingerprint: (c) => c,
      defaultScope: SettingsScope.env,
    );
    _sections[SettingsTab.instructions] = ConfigSection<InstructionsDraft>(
      fetch: () async {
        final c = await api.getProjectInstructions(id);
        return InstructionsDraft(
          scope: 'local',
          shared: c.shared,
          local: c.local,
        );
      },
      put: (original, draft) async {
        InstructionsConfig? last;
        if (draft.shared != original.shared) {
          last = await api.saveProjectInstructions(id, draft.shared, 'shared');
        }
        if (draft.local != original.local) {
          last = await api.saveProjectInstructions(id, draft.local, 'local');
        }
        return InstructionsDraft(
          scope: draft.scope,
          shared: last?.shared ?? draft.shared,
          local: last?.local ?? draft.local,
        );
      },
      fingerprint: (d) => d.fingerprint(),
      defaultScope: SettingsScope.personalInstructions,
      headerScope: (d) => d.scope == 'shared'
          ? SettingsScope.teamInstructions
          : SettingsScope.personalInstructions,
      scopesOf: (o, d) => {
        if (o.shared != d.shared) SettingsScope.teamInstructions,
        if (o.local != d.local) SettingsScope.personalInstructions,
      },
    );
    for (final t in SettingsTab.values.where((t) => t.project)) {
      _watch(_sections[t]!);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    editors.dispose();
    for (final s in _sections.values) {
      s.dispose();
    }
    super.dispose();
  }
}
