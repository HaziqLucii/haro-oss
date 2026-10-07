import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../overlays/overlay.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../new_workspace/creation_widgets.dart';
import '../new_workspace/new_workspace_overlay.dart';
import 'backlog_detail.dart';
import 'backlog_model.dart';
import 'gh_account_hint.dart';
import 'sync_notice.dart';

Future<void> showBacklog(BuildContext context, {String? projectId}) =>
    showHaroOverlay<void>(
      context,
      width: 1080,
      height: 660,
      child: BacklogOverlay(projectId: projectId),
    );

enum BacklogTab { todo, issues }

/// §6.6. Read-only: the one action is `Start as workspace`, which closes this overlay and
/// opens New workspace pre-filled. The "edit in your editor" link stays disabled: Open in...
/// is per workspace, and the todo file is in the project root.
class BacklogOverlay extends ConsumerStatefulWidget {
  const BacklogOverlay({super.key, this.projectId});

  final String? projectId;

  @override
  ConsumerState<BacklogOverlay> createState() => _BacklogOverlayState();
}

class _BacklogOverlayState extends ConsumerState<BacklogOverlay> {
  final _query = TextEditingController();
  String? _projectId;
  BacklogTab _tab = BacklogTab.todo;

  TodoResponse? _todo;
  String? _todoError;
  String? _selectedPath;
  String? _pickedKey;

  IssuesResponse? _issues;
  String? _issuesError;
  bool _issuesLoading = false;
  IssueStateFilter _state = IssueStateFilter.open;
  bool _mine = false;
  String? _label;
  int? _selectedIssue;
  IssueDetailResponse? _detail;
  int _issueRequest = 0;

  ProjectSync? _sync;
  bool _switching = false;
  String? _switchError;
  StreamSubscription<NotifyEvent>? _notifySub;

  HaroApi get _api => ref.read(haroApiProvider);

  @override
  void initState() {
    super.initState();
    final store = ref.read(workspaceStoreProvider);
    _projectId = defaultProjectId(
      projects: store.projects,
      given: widget.projectId,
      openWorkspaceProjectId: openWorkspaceProjectId(context, store),
    );
    _loadTodo();
    _syncNow();
    // A pull (ours or a merge) changes the files under the Backlog: keep it live.
    _notifySub = ref
        .read(workspaceStoreProvider.notifier)
        .notifyEvents
        .listen(_onNotify);
  }

  void _onNotify(NotifyEvent e) {
    final id = _projectId;
    if (id == null) return;
    if (e is BacklogChangedNotify && e.projectId == id) {
      _loadTodo();
    } else if (e is ProjectSyncNotify && e.projectId == id) {
      _refreshSync();
    }
  }

  /// Asks the backend to bring the checkout level with origin (a safe fast-forward) and shows
  /// why when it cannot. Failures are not worth an error: the Backlog works either way.
  Future<void> _syncNow() async {
    final id = _projectId;
    if (id == null) return;
    try {
      final r = await _api.syncProject(id);
      if (!mounted || id != _projectId) return;
      setState(() => _sync = r);
      if (r.pulled > 0) _loadTodo();
    } on HaroApiException {
      // Not a git project or no remote: nothing to report.
    }
  }

  Future<void> _refreshSync() async {
    final id = _projectId;
    if (id == null) return;
    try {
      final r = await _api.projectSyncStatus(id);
      if (!mounted || id != _projectId) return;
      setState(() => _sync = r);
      if (r.pulled > 0) _loadTodo();
    } on HaroApiException {
      // Same: the notice just stays as it was.
    }
  }

  Future<void> _switchToDefault() async {
    final id = _projectId;
    if (id == null || _switching) return;
    setState(() {
      _switching = true;
      _switchError = null;
    });
    try {
      final r = await _api.switchToDefault(id);
      if (!mounted || id != _projectId) return;
      setState(() {
        _sync = r;
        _switching = false;
      });
      _loadTodo();
    } on HaroApiException catch (e) {
      if (mounted) {
        setState(() {
          _switching = false;
          _switchError = e.message;
        });
      }
    }
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadTodo() async {
    final id = _projectId;
    if (id == null) return;
    try {
      final t = await _api.getTodo(id);
      if (!mounted || id != _projectId) return;
      setState(() {
        _todo = t;
        _todoError = null;
      });
    } on HaroApiException catch (e) {
      if (mounted && id == _projectId) setState(() => _todoError = e.message);
    }
  }

  Future<void> _loadIssues() async {
    final id = _projectId;
    if (id == null) return;
    final request = ++_issueRequest;
    setState(() {
      _issuesLoading = true;
      _issuesError = null;
    });
    try {
      final r = await _api.getIssues(
        id,
        state: _state.wire,
        mine: _mine ? true : null,
      );
      if (!mounted || request != _issueRequest) return;
      setState(() {
        _issues = r;
        _issuesLoading = false;
      });
      _ensureSelection();
    } on HaroApiException catch (e) {
      if (!mounted || request != _issueRequest) return;
      setState(() {
        _issuesError = e.message;
        _issuesLoading = false;
      });
    }
  }

  void _pickTab(BacklogTab t) {
    if (t == _tab) return;
    setState(() => _tab = t);
    if (t == BacklogTab.issues && _issues == null && !_issuesLoading) {
      _loadIssues();
    }
  }

  void _pickProject(String id) {
    if (id == _projectId) return;
    setState(() {
      _projectId = id;
      _todo = null;
      _todoError = null;
      _selectedPath = null;
      _pickedKey = null;
      _issues = null;
      _issuesError = null;
      _selectedIssue = null;
      _detail = null;
      _label = null;
    });
    _sync = null;
    _switchError = null;
    _loadTodo();
    _syncNow();
    if (_tab == BacklogTab.issues) _loadIssues();
  }

  Future<void> _selectIssue(int number) async {
    final id = _projectId;
    if (id == null) return;
    setState(() {
      _selectedIssue = number;
      _detail = null;
    });
    try {
      final d = await _api.getIssueDetail(id, number);
      if (mounted && _selectedIssue == number) setState(() => _detail = d);
    } on HaroApiException {
      // The list row already carries the body; only the discussion is missing.
    }
  }

  /// The list always has a selected issue; fetch its discussion when the selection moves.
  void _ensureSelection() {
    final shown = _shownIssues;
    if (shown.isEmpty || shown.any((i) => i.number == _selectedIssue)) return;
    _selectIssue(shown.first.number);
  }

  /// Closes the backlog first: two stacked overlays would both answer Esc and the submit key.
  void _start(NewWorkspacePrefill prefill) {
    final nav = Navigator.of(context, rootNavigator: true);
    final project = _projectId;
    nav.pop();
    showNewWorkspace(nav.context, projectId: project, prefill: prefill);
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(workspaceStoreProvider).projects;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(projects),
        Container(height: 1, color: HaroTokens.line12),
        if (syncNotice(_sync) != null) _syncBar(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 300,
                decoration: const BoxDecoration(
                  border: Border(right: BorderSide(color: HaroTokens.line12)),
                ),
                child: _tab == BacklogTab.todo ? _todoList() : _issueList(),
              ),
              Expanded(
                child: _tab == BacklogTab.todo ? _todoPane() : _issuePane(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One line under the header when haro could not bring the checkout level by itself.
  Widget _syncBar() => Container(
    key: const ValueKey('bl-sync-notice'),
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
    decoration: const BoxDecoration(
      color: HaroTokens.panel,
      border: Border(bottom: BorderSide(color: HaroTokens.line12)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _switchError ?? syncNotice(_sync)!,
            style: HaroText.mono(
              size: 11,
              tracking: 0,
              color: _switchError != null ? HaroTokens.fail : HaroTokens.ink66,
            ),
          ),
        ),
        if (canSwitchToDefault(_sync)) ...[
          const SizedBox(width: 16),
          HaroButton(
            key: const ValueKey('bl-sync-switch'),
            label: _switching
                ? 'Switching…'
                : 'Switch to ${_sync!.defaultBranch} and pull',
            height: 26,
            fontSize: 12,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            onPressed: _switching ? null : _switchToDefault,
          ),
        ],
      ],
    ),
  );

  Widget _header(List<Project> projects) {
    final files = _todo?.files ?? const <TodoFile>[];
    final done = files.fold<int>(0, (n, f) => n + itemsDone(f));
    final total = files.fold<int>(0, (n, f) => n + f.items.length);
    final count = _tab == BacklogTab.todo
        ? (_todo == null ? '' : '$done / $total items done')
        : (_issues == null ? '' : '${_issues!.issues.length} issues');
    final project = projects.where((p) => p.id == _projectId).firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
      child: Row(
        children: [
          Text(
            'Backlog',
            style: HaroText.ui(size: 20, weight: FontWeight.w500),
          ),
          if (project != null) ...[
            const SizedBox(width: 12),
            Flexible(
              flex: 0,
              child: MenuSelect<String>(
                key: const Key('bl-project'),
                value: project.id,
                options: [for (final p in projects) p.id],
                labelOf: (id) => projects.firstWhere((p) => p.id == id).name,
                onSelected: _pickProject,
                upper: true,
                style: HaroText.mono(
                  size: 11,
                  tracking: .1,
                  color: HaroTokens.ink42,
                ),
              ),
            ),
          ],
          const SizedBox(width: 20),
          _TabPill(
            label: 'Todo files',
            count: _todo?.files.length,
            active: _tab == BacklogTab.todo,
            onTap: () => _pickTab(BacklogTab.todo),
          ),
          const SizedBox(width: 4),
          _TabPill(
            label: 'GitHub issues',
            count: _issues?.issues.length,
            active: _tab == BacklogTab.issues,
            onTap: () => _pickTab(BacklogTab.issues),
          ),
          const Spacer(),
          Flexible(
            flex: 0,
            child: Text(
              count.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 11,
                tracking: .05,
                color: HaroTokens.ink42,
              ),
            ),
          ),
          const SizedBox(width: 14),
          const OverlayCloseButton(),
        ],
      ),
    );
  }

  // ---- todo files ----

  TodoFile? get _activeFile {
    final files = _todo?.files ?? const <TodoFile>[];
    for (final f in files) {
      if (f.path == _selectedPath) return f;
    }
    final groups = groupTodoFiles(files);
    return groups.isEmpty ? null : groups.first.files.first;
  }

  Widget _todoList() {
    if (_projectId == null) return const _Note('No project yet.');
    if (_todoError != null) return _Note(_todoError!, error: true);
    if (_todo == null) return const _Note('Loading…');
    final groups = groupTodoFiles(_todo!.files);
    if (groups.isEmpty) return const _Note('No backlog files.');
    final active = _activeFile;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      children: [
        for (final g in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
            child: MonoCaption(g.category.label),
          ),
          for (final f in g.files)
            _FileRow(
              file: f,
              selected: f.path == active?.path,
              onTap: () => setState(() {
                _selectedPath = f.path;
                _pickedKey = null;
              }),
            ),
        ],
      ],
    );
  }

  Widget _todoPane() {
    final f = _todo == null ? null : _activeFile;
    if (f == null) {
      return _Note(
        _todo == null ? '' : 'Add markdown files under backlog/ in the repo and they show up here.',
      );
    }
    return TodoDetail(
      key: ValueKey(f.path),
      file: f,
      projectId: _projectId!,
      pickedKey: _pickedKey,
      onPick: (k) => setState(() => _pickedKey = k),
      onStart: (item) => _start(todoPrefill(item, f.path)),
    );
  }

  // ---- issues ----

  List<IssueItem> get _shownIssues => filterIssues(
    _issues?.issues ?? const [],
    query: _query.text,
    label: _label,
  );

  Widget _issueList() {
    final r = _issues;
    final shown = _shownIssues;
    final labels = labelCountsOf(r?.issues ?? const []).take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in IssueStateFilter.values)
                    _FilterChip(
                      key: Key('bl-state-${s.wire}'),
                      label: s.label,
                      on: _state == s,
                      onTap: () {
                        setState(() => _state = s);
                        _loadIssues();
                      },
                    ),
                  _FilterChip(
                    key: const Key('bl-mine'),
                    label: 'Mine',
                    on: _mine,
                    onTap: () {
                      setState(() => _mine = !_mine);
                      _loadIssues();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              HaroTextField(
                key: const Key('bl-search'),
                controller: _query,
                height: 30,
                fontSize: 13,
                hintText: 'Search #, title, label',
                onChanged: (_) {
                  setState(() {});
                  _ensureSelection();
                },
              ),
              if (labels.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (l, n) in labels)
                      _FilterChip(
                        key: Key('bl-label-$l'),
                        label: '$l $n',
                        on: _label == l,
                        mono: true,
                        onTap: () {
                          setState(() => _label = _label == l ? null : l);
                          _ensureSelection();
                        },
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        Container(height: 1, color: HaroTokens.line08),
        Expanded(child: _issueRows(r, shown)),
      ],
    );
  }

  Widget _issueRows(IssuesResponse? r, List<IssueItem> shown) {
    if (_issuesError != null) {
      return _Note(
        _issuesError!,
        error: true,
        footer: GhAccountHint(projectId: _projectId, error: _issuesError),
      );
    }
    if (r == null) return const _Note('Loading…');
    if (!r.available) {
      return _Note(
        issuesUnavailableMessage(r.reason),
        footer: GhAccountHint(projectId: _projectId, error: r.reason),
      );
    }
    if (r.issues.isEmpty) {
      return _Note(
        'No ${_state == IssueStateFilter.all ? '' : '${_state.wire} '}issues.',
      );
    }
    if (shown.isEmpty) return const _Note('No issue matches.');
    final selected = _selectedIssue ?? shown.first.number;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
      children: [
        for (final it in shown)
          _IssueRow(
            issue: it,
            selected: it.number == selected,
            onTap: () => _selectIssue(it.number),
          ),
      ],
    );
  }

  Widget _issuePane() {
    final r = _issues;
    if (r == null || !r.available) return const SizedBox.shrink();
    final shown = _shownIssues;
    if (shown.isEmpty) return const SizedBox.shrink();
    final issue = shown.firstWhere(
      (i) => i.number == (_selectedIssue ?? shown.first.number),
      orElse: () => shown.first,
    );
    return IssueDetailPane(
      key: ValueKey(issue.number),
      issue: issue,
      detail: _selectedIssue == issue.number ? _detail : null,
      onStart: (i) => _start(issuePrefill(i)),
    );
  }
}

String issuesUnavailableMessage(String? reason) => switch (reason) {
  'no-remote' => 'Link a GitHub remote to pull issues.',
  'no-gh' => 'Install the GitHub CLI (gh) to pull issues.',
  _ => "Couldn't load issues${reason == null ? '' : ' · $reason'}.",
};

class _Note extends StatelessWidget {
  const _Note(this.text, {this.error = false, this.footer});

  final String text;
  final bool error;
  final Widget? footer;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: HaroText.ui(
              size: 13,
              color: error ? HaroTokens.fail : HaroTokens.ink42,
              height: 1.5,
            ),
          ),
          ?footer,
        ],
      ),
    ),
  );
}

class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  final String label;
  final int? count;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: label,
    builder: (context, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active ? HaroTokens.raised : HaroTokens.transparent,
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Text(
        count == null ? label : '$label $count',
        maxLines: 1,
        style: HaroText.ui(
          size: 13,
          color: active || hovered ? HaroTokens.ink : HaroTokens.ink66,
        ),
      ),
    ),
  );
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.selected,
    required this.onTap,
  });

  final TodoFile file;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: file.label,
    builder: (context, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: selected
            ? HaroTokens.raised
            : hovered
            ? HaroTokens.ink02
            : HaroTokens.transparent,
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              file.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(size: 13.5),
            ),
          ),
          const SizedBox(width: 10),
          ProgressBar(key: Key('bl-bar-${file.path}'), value: progressOf(file)),
        ],
      ),
    ),
  );
}

/// 44 x 2 progress in ink. Never green: green is the gate's colour (§0).
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 2,
    color: HaroTokens.line12,
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(
      widthFactor: value.clamp(0.0, 1.0),
      child: const SizedBox(
        height: 2,
        child: ColoredBox(color: HaroTokens.ink66),
      ),
    ),
  );
}

class _IssueRow extends StatelessWidget {
  const _IssueRow({
    required this.issue,
    required this.selected,
    required this.onTap,
  });

  final IssueItem issue;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final closed = issue.state == 'closed';
    final seeded = issue.seededWorkspace != null;
    return HaroPressable(
      onTap: onTap,
      semanticLabel: '#${issue.number} ${issue.title}',
      builder: (context, hovered) => AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        constraints: const BoxConstraints(minHeight: 34),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? HaroTokens.raised
              : hovered
              ? HaroTokens.ink02
              : HaroTokens.transparent,
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '#${issue.number}',
              style: HaroText.mono(
                size: 11.5,
                tracking: 0,
                color: HaroTokens.ink42,
              ).copyWith(height: 1.45),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                issue.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(
                  size: 13.5,
                  color: closed ? HaroTokens.ink42 : HaroTokens.ink,
                  height: 1.35,
                ),
              ),
            ),
            if (seeded) ...[
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: stageSquare(issue.stage),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.on,
    required this.onTap,
    this.mono = false,
  });

  final String label;
  final bool on;
  final bool mono;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: label,
    builder: (context, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HaroTokens.radius),
        border: Border.all(
          color: on
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
            label,
            maxLines: 1,
            style: mono
                ? HaroText.mono(
                    size: 11,
                    tracking: 0,
                    color: on || hovered ? HaroTokens.ink : HaroTokens.ink66,
                  )
                : HaroText.ui(
                    size: 12.5,
                    color: on || hovered ? HaroTokens.ink : HaroTokens.ink66,
                  ),
          ),
        ],
      ),
    ),
  );
}
