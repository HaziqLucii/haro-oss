import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../overlays/toast.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../../widgets/page_tabs.dart';
import '../new_workspace/creation_widgets.dart';
import '../new_workspace/new_workspace_overlay.dart';
import 'backlog_detail.dart';
import 'backlog_model.dart';
import 'capture_todo_overlay.dart' show backlogProjectId;
import 'gh_account_hint.dart';
import 'notes_tab.dart';
import 'sync_notice.dart';

const _gutter = 56.0;
const _gutterNarrow = 24.0;
const _contentMax = 1400.0;
const _listWidth = 340.0;
const _listWidthNarrow = 250.0;

enum BacklogTab { todo, issues, notes }

/// §6.6. `Start as workspace` opens New workspace pre-filled; items can also be added, checked,
/// edited, deleted, reordered and moved between files, and files created or renamed, each as one
/// backend write followed by a reload. It is a page of the shell (`/backlog`), so the sidebar
/// stays and switching to and from the dashboard is a route change.
class BacklogPage extends ConsumerStatefulWidget {
  const BacklogPage({super.key, this.projectId});

  final String? projectId;

  @override
  ConsumerState<BacklogPage> createState() => _BacklogPageState();
}

class _BacklogPageState extends ConsumerState<BacklogPage> {
  final _query = TextEditingController();
  final _name = TextEditingController();
  final _nameFocus = FocusNode();

  /// Set while the file list asks for a name: a new file, or the rename of [_renaming].
  bool _naming = false;
  String? _renaming;
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
    backlogProjectId.value = _projectId;
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
    if (backlogProjectId.value == _projectId) backlogProjectId.value = null;
    _notifySub?.cancel();
    _query.dispose();
    _name.dispose();
    _nameFocus.dispose();
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
    backlogProjectId.value = id;
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

  void _start(NewWorkspacePrefill prefill) =>
      showNewWorkspace(context, projectId: _projectId, prefill: prefill);

  /// The store can hydrate after the page opens, or the open project can be removed: pick
  /// a project again whenever the current one is missing from the list.
  void _revalidateProject(List<Project> projects) {
    if (_projectId != null && projects.any((p) => p.id == _projectId)) return;
    final next = defaultProjectId(projects: projects, given: widget.projectId);
    if (next == _projectId) return;
    backlogProjectId.value = next;
    setState(() {
      _projectId = next;
      _todo = null;
      _todoError = null;
      _selectedPath = null;
      _issues = null;
      _sync = null;
    });
    _loadTodo();
    _syncNow();
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(workspaceStoreProvider).projects;
    ref.listen(
      workspaceStoreProvider.select((s) => s.projects),
      (_, next) => _revalidateProject(next),
    );
    return LayoutBuilder(
      builder: (context, box) {
        // The smallest window (960x640) leaves about 740 by 570 for this page: tighter gutter,
        // a narrower list and a smaller headline keep the detail pane readable.
        final narrow = box.maxWidth < 900;
        final short = box.maxHeight < 700;
        final inset = math.max(
          narrow ? _gutterNarrow : _gutter,
          (box.maxWidth - _contentMax) / 2,
        );
        final h = EdgeInsets.symmetric(horizontal: inset);
        final headline = short ? 30.0 : 38.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: h.copyWith(top: short ? 24 : 44),
              child: Text(
                'Backlog.',
                style: HaroText.ui(
                  size: headline,
                  weight: FontWeight.w500,
                  height: 1.1,
                ).copyWith(letterSpacing: -.02 * headline),
              ),
            ),
            if (projects.isNotEmpty)
              Padding(
                padding: h.copyWith(top: short ? 14 : 22),
                child: _projectRow(projects),
              ),
            Padding(
              padding: h.copyWith(top: short ? 14 : 24),
              child: PageTabBar(
                tabs: [
                  PageTab(
                    'TODO FILES',
                    count: _todo?.files.length,
                    tabKey: const Key('bl-tab-todo'),
                  ),
                  PageTab(
                    'GITHUB ISSUES',
                    count: _issues?.issues.length,
                    tabKey: const Key('bl-tab-issues'),
                  ),
                  PageTab('NOTES', tabKey: const Key('bl-tab-notes')),
                ],
                selected: _tab.index,
                onPick: (i) => _pickTab(BacklogTab.values[i]),
                trailing: Text(
                  _summary().toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.mono(
                    size: 11,
                    tracking: .05,
                    color: HaroTokens.ink42,
                  ),
                ),
              ),
            ),
            if (syncNotice(_sync) != null)
              Padding(padding: h.copyWith(top: 16), child: _syncBar()),
            Expanded(
              child: Padding(
                padding: h.copyWith(
                  top: short ? 14 : 20,
                  bottom: short ? 14 : 24,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: HaroTokens.line12),
                    borderRadius: BorderRadius.circular(HaroTokens.radius),
                  ),
                  child: _tab == BacklogTab.notes && _projectId != null
                      ? NotesTab(
                          key: ValueKey('notes-$_projectId'),
                          projectId: _projectId!,
                          listWidth: narrow ? _listWidthNarrow : _listWidth,
                          onStart: _start,
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              width: narrow ? _listWidthNarrow : _listWidth,
                              decoration: const BoxDecoration(
                                border: Border(
                                  right: BorderSide(color: HaroTokens.line12),
                                ),
                              ),
                              child: _tab == BacklogTab.todo
                                  ? _todoList()
                                  : _issueList(),
                            ),
                            Expanded(
                              child: _tab == BacklogTab.todo
                                  ? _todoPane()
                                  : _issuePane(),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _summary() {
    if (_tab == BacklogTab.todo) {
      final files = _todo?.files;
      if (files == null) return '';
      final done = files.fold<int>(0, (n, f) => n + itemsDone(f));
      final total = files.fold<int>(0, (n, f) => n + f.items.length);
      return '$done / $total items done';
    }
    if (_tab == BacklogTab.notes) return '';
    return _issues == null ? '' : '${_issues!.issues.length} issues';
  }

  /// One line under the tabs when haro could not bring the checkout level by itself.
  Widget _syncBar() => Container(
    key: const ValueKey('bl-sync-notice'),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: HaroTokens.panel,
      border: Border.all(color: HaroTokens.line12),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
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

  /// Which project's backlog this is: one pill per project, so the switch is visible rather
  /// than hidden behind a dropdown caret.
  Widget _projectRow(List<Project> projects) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Text(
        'PROJECT',
        style: HaroText.mono(size: 10.5, color: HaroTokens.ink42),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final p in projects)
              _ProjectPill(
                key: Key('bl-project-${p.id}'),
                label: p.name,
                on: p.id == _projectId,
                onTap: () => _pickProject(p.id),
              ),
          ],
        ),
      ),
    ],
  );

  // ---- todo files ----

  TodoFile? get _activeFile {
    final files = _todo?.files ?? const <TodoFile>[];
    for (final f in files) {
      if (f.path == _selectedPath) return f;
    }
    final groups = groupTodoFiles(files);
    return groups.isEmpty ? null : groups.first.files.first;
  }

  /// The folder new files go in: where the existing files live, else `backlog`.
  String get _dirGuess {
    for (final f in _todo?.files ?? const <TodoFile>[]) {
      final i = f.path.lastIndexOf('/');
      if (i > 0) return f.path.substring(0, i);
    }
    return 'backlog';
  }

  String? _pathFrom(String raw) {
    var p = raw.trim();
    if (p.isEmpty) return null;
    if (!p.contains('/')) p = '$_dirGuess/$p';
    if (!p.substring(p.lastIndexOf('/') + 1).contains('.')) p = '$p.md';
    return p;
  }

  void _startNaming({String? renaming}) {
    setState(() {
      _naming = true;
      _renaming = renaming;
      _name.text = renaming ?? '';
    });
    _nameFocus.requestFocus();
  }

  Future<void> _commitName(String raw) async {
    final id = _projectId;
    final path = _pathFrom(raw);
    final from = _renaming;
    setState(() {
      _naming = false;
      _renaming = null;
    });
    if (id == null || path == null || path == from) return;
    await _run(() async {
      if (from != null) {
        await _api.renameTodo(id, from, path);
      } else {
        final base = path.substring(path.lastIndexOf('/') + 1);
        final title = base
            .replaceFirst(RegExp(r'\.[^.]*$'), '')
            .replaceAll(RegExp(r'[-_]+'), ' ');
        await _api.putTodo(
          id,
          path,
          '# ${title.isEmpty ? 'Backlog' : title}\n\n',
        );
      }
      _selectedPath = path;
      _pickedKey = null;
    });
  }

  /// Runs one backlog write, then reloads: the file is the truth, so the page never patches
  /// its own copy. A 409 means an agent or the merge tick changed the file meanwhile.
  Future<void> _run(Future<void> Function() call) async {
    try {
      await call();
    } on HaroApiException catch (e) {
      if (mounted) {
        showHaroToast(
          context,
          e.status == 409
              ? 'The file changed while you were looking at it. Reloaded.'
              : e.message,
        );
      }
    }
    await _loadTodo();
  }

  TodoActions _actionsFor(TodoFile f) {
    final id = _projectId!;
    Future<void> op(
      int index,
      TodoItem item,
      String name, {
      String? body,
      String? toFile,
    }) => _run(
      () => _api.todoItemOp(
        id,
        file: f.path,
        index: index,
        expect: item.text,
        op: name,
        body: body,
        toFile: toFile,
      ),
    );
    return TodoActions(
      add: (text) => _run(() => _api.addTodoItem(id, text, file: f.path)),
      toggle: (i, item) => op(i, item, item.done ? 'uncheck' : 'check'),
      edit: (i, item, body) => op(i, item, 'edit', body: body),
      delete: (i, item) => op(i, item, 'delete'),
      move: (i, item, d) => op(i, item, d < 0 ? 'up' : 'down'),
      moveTo: (i, item, to) => op(i, item, 'move', toFile: to),
      rename: () => _startNaming(renaming: f.path),
      otherFiles: [
        for (final o in _todo?.files ?? const <TodoFile>[])
          if (o.path != f.path) o.path,
      ],
    );
  }

  Widget _newFileRow() => Padding(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
    child: _naming
        ? Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
            },
            child: Actions(
              actions: {
                DismissIntent: CallbackAction<DismissIntent>(
                  onInvoke: (_) {
                    setState(() {
                      _naming = false;
                      _renaming = null;
                    });
                    return null;
                  },
                ),
              },
              child: HaroTextField(
                key: const Key('bl-name'),
                controller: _name,
                focusNode: _nameFocus,
                height: 30,
                fontSize: 13,
                hintText: _renaming == null
                    ? 'ideas, or $_dirGuess/ideas.md. Enter to create'
                    : 'New name. Enter to rename',
                onSubmitted: _commitName,
              ),
            ),
          )
        : Align(
            alignment: Alignment.centerLeft,
            child: HaroPressable(
              onTap: _startNaming,
              semanticLabel: 'New backlog file',
              builder: (context, hovered) => Text(
                '+ NEW FILE',
                key: const Key('bl-new-file'),
                style: HaroText.mono(
                  size: 10.5,
                  color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                ),
              ),
            ),
          ),
  );

  Widget _todoList() {
    if (_projectId == null) return const _Note('No project yet.');
    if (_todoError != null) return _Note(_todoError!, error: true);
    if (_todo == null) return const _Note('Loading…');
    final groups = groupTodoFiles(_todo!.files);
    if (groups.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _newFileRow(),
          const Expanded(child: _Note('No backlog files.')),
        ],
      );
    }
    final active = _activeFile;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      children: [
        _newFileRow(),
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
        _todo == null ? '' : 'Add a file with + NEW FILE, or put markdown under backlog/ in the repo.',
      );
    }
    return TodoDetail(
      key: ValueKey(f.path),
      file: f,
      projectId: _projectId!,
      pickedKey: _pickedKey,
      onPick: (k) => setState(() => _pickedKey = k),
      onStart: (item) => _start(todoPrefill(item, f.path)),
      actions: _actionsFor(f),
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

class _ProjectPill extends StatelessWidget {
  const _ProjectPill({
    super.key,
    required this.label,
    required this.on,
    required this.onTap,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: on,
    child: HaroPressable(
      onTap: onTap,
      semanticLabel: label,
      builder: (context, hovered) {
        final fg = on
            ? HaroTokens.bg
            : (hovered ? HaroTokens.ink : HaroTokens.ink66);
        return AnimatedContainer(
          duration: HaroTokens.fadeFast,
          curve: HaroTokens.curve,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: on ? HaroTokens.ink : HaroTokens.transparent,
            borderRadius: BorderRadius.circular(HaroTokens.radius),
            border: Border.all(color: on ? HaroTokens.ink : HaroTokens.line12),
          ),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(size: 13, color: fg),
            ),
          ),
        );
      },
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
