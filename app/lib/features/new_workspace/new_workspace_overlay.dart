import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_actions.dart';
import '../../data/workspace_store.dart';
import '../../data/xp_store.dart';
import '../../overlays/overlay.dart';
import '../../shortcuts/platform_keys.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../add_project/add_project_overlay.dart';
import '../settings/xp_prefs_provider.dart';
import '../../widgets/haro_segmented.dart';
import 'branch_naming.dart';
import 'creation_widgets.dart';
import 'prefill.dart';

export 'prefill.dart';

const manualHint = 'No agent. haro’s AI only plans and researches.';

/// Given project, else the project of the open workspace, else the first one.
String? defaultProjectId({
  required List<Project> projects,
  String? given,
  String? openWorkspaceProjectId,
}) {
  bool has(String? id) => id != null && projects.any((p) => p.id == id);
  if (has(given)) return given;
  if (has(openWorkspaceProjectId)) return openWorkspaceProjectId;
  return projects.isEmpty ? null : projects.first.id;
}

/// Project of the workspace the router is showing (`/w/:id/...`), if any.
String? openWorkspaceProjectId(BuildContext context, WorkspaceSnapshot store) {
  final List<String> segments;
  try {
    segments = GoRouter.of(context)
        .routerDelegate
        .currentConfiguration
        .uri
        .pathSegments;
  } catch (_) {
    return null;
  }
  if (segments.length < 2 || segments.first != 'w') return null;
  for (final entry in store.workspaces.entries) {
    if (entry.value.any((w) => w.id == segments[1])) return entry.key;
  }
  return null;
}

Future<void> showNewWorkspace(
  BuildContext context, {
  String? projectId,
  NewWorkspacePrefill? prefill,
}) => showHaroOverlay<void>(
  context,
  width: 580,
  child: NewWorkspaceOverlay(projectId: projectId, prefill: prefill),
);

/// ⌘N (§6.4). Creates the worktree, optionally starts the agent, then opens `/w/<id>/agent`.
class NewWorkspaceOverlay extends ConsumerStatefulWidget {
  const NewWorkspaceOverlay({super.key, this.projectId, this.prefill});

  final String? projectId;
  final NewWorkspacePrefill? prefill;

  @override
  ConsumerState<NewWorkspaceOverlay> createState() =>
      _NewWorkspaceOverlayState();
}

class _NewWorkspaceOverlayState extends ConsumerState<NewWorkspaceOverlay> {
  late final TextEditingController _task = TextEditingController(
    text: widget.prefill?.inputText ?? '',
  );
  late final TextEditingController _branchText = TextEditingController();
  BranchDraft _draft = const BranchDraft();

  String? _projectId;
  List<String> _branches = const [];
  String? _baseRef;
  bool _run = true;
  bool _startFromTest = false;
  WorkspaceMode _who = WorkspaceMode.agent;
  bool _busy = false;
  String? _error;

  /// Set once the workspace exists, so a failed agent start retries without creating twice.
  Workspace? _created;

  @override
  void initState() {
    super.initState();
    final store = ref.read(workspaceStoreProvider);
    _projectId = defaultProjectId(
      projects: store.projects,
      given: widget.projectId,
      openWorkspaceProjectId: openWorkspaceProjectId(context, store),
    );
    _syncBranch();
    _loadBranches();
  }

  @override
  void dispose() {
    _task.dispose();
    _branchText.dispose();
    super.dispose();
  }

  Project? get _project {
    for (final p in ref.read(workspaceStoreProvider).projects) {
      if (p.id == _projectId) return p;
    }
    return null;
  }

  String get _branch => _draft.branchFor(_task.text);

  void _syncBranch() {
    final next = _branch;
    if (_branchText.text != next) {
      _branchText.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
  }

  Future<void> _loadBranches() async {
    final id = _projectId;
    if (id == null) return;
    try {
      final list = await ref.read(haroApiProvider).listBranches(id);
      if (!mounted || id != _projectId) return;
      setState(() {
        _branches = list.branches;
        _baseRef = list.defaultBranch.isEmpty ? null : list.defaultBranch;
      });
    } on HaroApiException {
      // The backend falls back to the project's default branch when base_ref is omitted.
    }
  }

  void _onTask(String _) {
    setState(() {
      _error = null;
      if (_draft.auto) _syncBranch();
    });
  }

  void _pickPrefix(String prefix) => setState(() {
    _draft = _draft.withChip(prefix, _task.text);
    _syncBranch();
  });

  void _onBranch(String value) => setState(() {
    _draft = _draft.edited(value);
    _error = null;
  });

  void _pickWho(WorkspaceMode next) => setState(() {
    _who = next;
    _syncBranch();
  });

  void _pickProject(String id) {
    if (id == _projectId || _busy) return;
    setState(() {
      _projectId = id;
      _branches = const [];
      _baseRef = null;
    });
    _loadBranches();
  }

  bool get _canSubmit =>
      !_busy &&
      _projectId != null &&
      _task.text.trim().isNotEmpty &&
      _branch.trim().isNotEmpty;

  String get _agentTask {
    final text = _task.text.trim();
    final p = widget.prefill;
    return p != null && text == p.inputText.trim() ? p.task.trim() : text;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final projectId = _projectId!;
    final api = ref.read(haroApiProvider);
    final store = ref.read(workspaceStoreProvider.notifier);
    final navigator = Navigator.of(context, rootNavigator: true);
    GoRouter? router;
    try {
      router = GoRouter.of(context);
    } catch (_) {
      router = null;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    var ws = _created;
    try {
      ws ??= _created = await api.createWorkspace(
        projectId,
        workspaceNameFor(_task.text),
        baseRef: _baseRef,
        branch: _branch.trim(),
        seedKey: widget.prefill?.seedKey,
        mode: _who,
        startFromTest: _who == WorkspaceMode.manual && _startFromTest,
      );
    } catch (e) {
      _fail(_message(e));
      return;
    }
    final manual = _who == WorkspaceMode.manual;
    if (_run && !manual) {
      try {
        await ref.read(workspaceActionsProvider(ws.id)).startAgent(_agentTask);
      } catch (e) {
        unawaited(store.reload());
        _fail('Workspace created, but the agent did not start: ${_message(e)}');
        return;
      }
    }
    await store.reload();
    if (!mounted) return;
    navigator.pop();
    router?.go('/w/${ws.id}/${manual ? 'code' : 'agent'}');
  }

  String? _testFirstHint() {
    if (!ref.watch(xpPrefsProvider.select((p) => p.showXp))) return null;
    final xp = ref
        .watch(xpStoreProvider.select((s) => s.rules))
        ?.rule('test_first')
        ?.manual;
    return xp == null ? null : '+$xp XP';
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  static String _message(Object e) =>
      e is HaroApiException ? e.message : e.toString();

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(workspaceStoreProvider).projects;
    final project = _project;
    final mod = primaryModifier;
    final canOpen = projects.length > 1 && _created == null;
    return CallbackShortcuts(
      bindings: {
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
        ])
          SingleActivator(
            key,
            meta: mod == PrimaryModifier.meta,
            control: mod == PrimaryModifier.control,
          ): _submit,
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
            child: project == null
                ? _NoProject(
                    onAdd: () {
                      final nav = Navigator.of(context, rootNavigator: true);
                      nav.pop();
                      showAddProject(nav.context);
                    },
                  )
                : _form(projects, project, canOpen),
          ),
          _footer(),
        ],
      ),
    );
  }

  Widget _form(List<Project> projects, Project project, bool canOpen) {
    final labelStyle = HaroText.ui(size: 13.5, color: HaroTokens.ink42);
    final baseValue = _baseRef ?? project.defaultBranch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MonoCaption('New workspace'),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.only(bottom: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: HaroTokens.line30)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: TextField(
              key: const Key('nw-task'),
              controller: _task,
              autofocus: true,
              enabled: !_busy,
              onChanged: _onTask,
              onSubmitted: (_) => _submit(),
              cursorColor: HaroTokens.ink,
              cursorWidth: 1,
              style: HaroText.ui(size: 24, weight: FontWeight.w500),
              decoration: InputDecoration.collapsed(
                hintText: "What's the task?",
                hintStyle: HaroText.ui(
                  size: 24,
                  weight: FontWeight.w500,
                  color: HaroTokens.ink42,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Table(
          columnWidths: const {0: FixedColumnWidth(110)},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              children: [
                Text('Project', style: labelStyle),
                Align(
                  alignment: Alignment.centerLeft,
                  child: MenuSelect<String>(
                    key: const Key('nw-project'),
                    value: project.id,
                    options: [for (final p in projects) p.id],
                    labelOf: (id) =>
                        projects.firstWhere((p) => p.id == id).name,
                    enabled: canOpen && !_busy,
                    onSelected: _pickProject,
                  ),
                ),
              ],
            ),
            TableRow(
              children: [
                const SizedBox(height: 14),
                const SizedBox(height: 14),
              ],
            ),
            TableRow(
              children: [
                Text('Branch', style: labelStyle),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in branchPrefixes)
                      _PrefixChip(
                        prefix: p,
                        active: _branch.startsWith(p),
                        onTap: _busy ? null : () => _pickPrefix(p),
                      ),
                  ],
                ),
              ],
            ),
            TableRow(
              children: [
                const SizedBox(height: 14),
                const SizedBox(height: 14),
              ],
            ),
            TableRow(
              children: [
                const SizedBox.shrink(),
                HaroTextField(
                  key: const Key('nw-branch'),
                  controller: _branchText,
                  mono: true,
                  height: 32,
                  enabled: !_busy,
                  hintText: 'feat/task-name',
                  onChanged: _onBranch,
                  onSubmitted: (_) => _submit(),
                ),
              ],
            ),
            TableRow(
              children: [
                const SizedBox(height: 14),
                const SizedBox(height: 14),
              ],
            ),
            TableRow(
              children: [
                Text('From', style: labelStyle),
                Align(
                  alignment: Alignment.centerLeft,
                  child: MenuSelect<String>(
                    key: const Key('nw-base'),
                    value: baseValue,
                    options: [
                      baseValue,
                      ..._branches.where((b) => b != baseValue),
                    ],
                    labelOf: (b) => b,
                    maxVisible: 12,
                    moreLabel: (n) => 'Show all $n branches',
                    enabled: !_busy,
                    onSelected: (b) => setState(() => _baseRef = b),
                  ),
                ),
              ],
            ),
            TableRow(
              children: [
                const SizedBox(height: 14),
                const SizedBox(height: 14),
              ],
            ),
            TableRow(
              children: [
                Text('Who writes it', style: labelStyle),
                Align(
                  alignment: Alignment.centerLeft,
                  child: HaroSegmented<WorkspaceMode>(
                    keyPrefix: 'nw-who',
                    mono: false,
                    height: 30,
                    horizontalPadding: 12,
                    frame: HaroTokens.line20,
                    selected: _who,
                    onChanged: _busy || _created != null ? null : _pickWho,
                    segments: const [
                      HaroSegment(WorkspaceMode.agent, 'Agent'),
                      HaroSegment(WorkspaceMode.manual, 'Manual'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 22),
        if (_who == WorkspaceMode.manual) ...[
          Text(
            manualHint,
            key: const Key('nw-hint'),
            style: HaroText.ui(size: 13, color: HaroTokens.ink66, height: 1.5),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: CheckRow(
              key: const Key('nw-test-first'),
              value: _startFromTest,
              label: 'Start from a test: write the failing test first',
              hint: _testFirstHint(),
              onChanged: _busy || _created != null
                  ? null
                  : (v) => setState(() => _startFromTest = v),
            ),
          ),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: CheckRow(
              key: const Key('nw-run'),
              value: _run,
              label: 'Start the agent with this task right away',
              onChanged: _busy ? null : (v) => setState(() => _run = v),
            ),
          ),
        if (_error != null) ...[const SizedBox(height: 14), ErrorLine(_error!)],
      ],
    );
  }

  Widget _footer() {
    final manual = _who == WorkspaceMode.manual;
    final retry = _created != null && !manual;
    final label = _busy
        ? 'Creating…'
        : manual
        ? 'Create & start writing'
        : retry
        ? 'Start the agent'
        : _run
        ? 'Create & run agent'
        : 'Create workspace';
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line12)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Its own worktree. Your main checkout is untouched.',
              style: HaroText.ui(size: 12.5, color: HaroTokens.ink42),
            ),
          ),
          const SizedBox(width: 12),
          HaroButton(
            label: 'Cancel',
            height: 34,
            variant: HaroButtonVariant.tertiary,
            onPressed: _busy ? null : () => closeHaroOverlay(context),
          ),
          const SizedBox(width: 8),
          HaroButton(
            key: const Key('nw-submit'),
            label: label,
            kbd: primaryLabel('↵'),
            height: 34,
            fontSize: 13.5,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            variant: HaroButtonVariant.primary,
            onPressed: _canSubmit ? _submit : null,
          ),
        ],
      ),
    );
  }
}

class _PrefixChip extends StatelessWidget {
  const _PrefixChip({
    required this.prefix,
    required this.active,
    required this.onTap,
  });

  final String prefix;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: prefix,
    builder: (context, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HaroTokens.radius),
        border: Border.all(
          color: active
              ? HaroTokens.ink
              : hovered
              ? HaroTokens.line30
              : HaroTokens.line12,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            prefix,
            style: HaroText.mono(
              size: 11.5,
              tracking: 0,
              color: active || hovered ? HaroTokens.ink : HaroTokens.ink66,
            ),
          ),
        ],
      ),
    ),
  );
}

class _NoProject extends StatelessWidget {
  const _NoProject({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const MonoCaption('New workspace'),
      const SizedBox(height: 14),
      Text(
        'No project yet.',
        style: HaroText.ui(size: 24, weight: FontWeight.w500),
      ),
      const SizedBox(height: 8),
      Text(
        'A workspace is a worktree of a project. Add one first.',
        style: HaroText.ui(size: 14, color: HaroTokens.ink66),
      ),
      const SizedBox(height: 16),
      HaroButton(label: 'Add project', onPressed: onAdd),
    ],
  );
}
