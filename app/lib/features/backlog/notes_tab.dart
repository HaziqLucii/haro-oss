import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../overlays/confirm_overlay.dart';
import '../../overlays/toast.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../util/clipboard_image.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_menu.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/path_line.dart';
import '../../widgets/haro_tag.dart';
import '../../widgets/haro_text_field.dart';
import '../../widgets/shell_icons.dart';
import '../new_workspace/creation_widgets.dart';
import '../../widgets/haro_segmented.dart';
import '../new_workspace/prefill.dart';
import '../open_in/open_in_launcher.dart';
import '../workspace/steps/agent/agent_markdown.dart' show AgentProse;
import 'backlog_jump.dart';
import 'backlog_prompts.dart';
import 'inline_name_field.dart';
import 'file_tree.dart';
import 'list_loading.dart';
import 'note_files_ui.dart';
import 'note_history.dart';
import 'notes_model.dart';

enum _Save { saved, editing, saving }

class _PasteNoteIntent extends Intent {
  const _PasteNoteIntent();
}

/// The Backlog's Notes tab: markdown pages in `<project>/.haro/notes/` for the thinking that
/// comes before a todo. The note list on the left, one editor on the right that saves by
/// itself. A save quotes the hash it last read, so a note that changed on disk (another
/// editor, a `git pull`) is never overwritten without being asked.
class NotesTab extends ConsumerStatefulWidget {
  const NotesTab({
    super.key,
    required this.projectId,
    required this.listWidth,
    required this.onStart,
    this.openPath,
  });

  final String projectId;
  final double listWidth;
  final ValueChanged<NewWorkspacePrefill> onStart;

  /// A note to open when the tab appears or when this changes (the quick switcher and the review
  /// jump here).
  final String? openPath;

  @override
  ConsumerState<NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends ConsumerState<NotesTab> {
  static const _autosave = Duration(milliseconds: 700);

  final _search = TextEditingController();
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  final _text = TextEditingController();
  final _editorFocus = FocusNode();

  List<NoteSummary>? _notes;
  bool _listLoading = false;

  /// The files beside the notes (PDFs, sheets, drawings...), listed under the notes.
  List<NoteFile> _files = const [];
  bool? _filesOpen;

  /// Folder paths of the notes tree that are open. Null until the tree is first drawn.
  Set<String>? _expanded;
  String? _listError;

  /// The list can show every open `- [ ]` in the notes instead of the notes themselves.
  bool _showTasks = false;
  List<NoteTask>? _tasks;
  String? _path;
  String _etag = '';
  bool _dirty = false;
  bool _inFlight = false;

  /// Bumped whenever the editor switches to another note, so a late save response for the
  /// previous one is ignored.
  int _gen = 0;

  /// Saves run one after another, so each quotes the etag the one before returned.
  Future<void> _saveChain = Future.value();
  _Save get _save => _inFlight
      ? _Save.saving
      : _dirty
      ? _Save.editing
      : _Save.saved;
  bool _conflict = false;

  /// Edit shows the markdown source; View shows it rendered. A note opens in View, a new one in Edit.
  bool _editing = false;

  /// The text selected in the rendered view, for Make todo and Start as workspace there.
  String _viewSelection = '';
  bool _naming = false;
  String? _renaming;
  String? _error;

  /// What links to and from the open note (tags, backlinks, mentions), read from the files.
  NoteLinks? _links;
  int _linksGen = 0;
  Timer? _timer;
  Timer? _searchTimer;
  StreamSubscription<NotifyEvent>? _sub;

  // Read once: `ref` is not usable from dispose, where the last save still has to go out.
  late final HaroApi _api;
  String get _project => widget.projectId;

  @override
  void initState() {
    super.initState();
    _api = ref.read(haroApiProvider);
    _loadList();
    _sub = ref.read(workspaceStoreProvider.notifier).notifyEvents.listen((e) {
      if (e is NotesChangedNotify && e.projectId == _project) _onDisk();
    });
    final first = widget.openPath;
    if (first != null) unawaited(_open(first));
  }

  @override
  void didUpdateWidget(NotesTab old) {
    super.didUpdateWidget(old);
    final next = widget.openPath;
    if (next != null && next != old.openPath && next != _path) {
      unawaited(_open(next));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchTimer?.cancel();
    _sub?.cancel();
    // Edits are saved as they are typed; this sends the last few hundred milliseconds. It runs
    // after any save in flight and quotes the etag that one returned.
    final path = _path;
    final text = _text.text;
    if (path != null && _dirty && !_conflict) {
      _saveChain = _saveChain.then<void>(
        (_) => _api
            .writeNote(_project, path, text, etag: _etag)
            .then<void>((_) {}, onError: (_) {}),
        onError: (_) {},
      );
    }
    _search.dispose();
    _name.dispose();
    _nameFocus.dispose();
    _text.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  // ---- loading ----

  Future<void> _loadList() async {
    // A search reads every note, so it shows the loader; a plain refresh (after a save) does not.
    final searching = _search.text.trim().isNotEmpty;
    if (searching && mounted) setState(() => _listLoading = true);
    try {
      final list = await _api.listNotes(_project, q: _search.text);
      if (!mounted) return;
      setState(() {
        _notes = list;
        _listError = null;
      });
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _listError = e.message);
    }
    if (mounted && _listLoading) setState(() => _listLoading = false);
    unawaited(_loadFiles());
  }

  Future<void> _loadFiles() async {
    try {
      final f = await _api.listNoteFiles(_project);
      if (mounted) setState(() => _files = f);
    } on HaroApiException {
      // The files are extra: the notes work without them.
    }
  }

  /// Opens a file with the system's own app. [target] is a path or a name as a link writes it.
  Future<void> _openFile(String target) async {
    try {
      await _api.openNoteFile(_project, target);
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    }
  }

  List<NoteFile> get _shownFiles {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _files;
    return [
      for (final f in _files)
        if (f.path.toLowerCase().contains(q)) f,
    ];
  }

  /// Something under `.haro/notes` changed on disk: refresh the list, and the open note too
  /// unless it holds edits that are not saved yet (then the next save reports the clash).
  Future<void> _onDisk() async {
    await _loadList();
    final path = _path;
    if (path == null || _save != _Save.saved) return;
    try {
      final doc = await _api.readNote(_project, path);
      if (!mounted || _path != path || _save != _Save.saved) return;
      if (doc.etag != _etag) _show(doc);
    } on HaroApiException {
      // Deleted or renamed elsewhere: the list shows it; the editor keeps what it has.
    }
  }

  void _show(NoteDoc doc) {
    final keep = _text.selection.baseOffset;
    _text.value = TextEditingValue(
      text: doc.content,
      selection: TextSelection.collapsed(
        offset: keep < 0 ? 0 : keep.clamp(0, doc.content.length),
      ),
    );
    _gen++;
    final sameNote = doc.path == _path;
    setState(() {
      // The panels belong to the note they were read for: another note starts with none.
      if (!sameNote) _links = null;
      _path = doc.path;
      _expanded?.addAll(ancestorsOf(doc.path));
      _etag = doc.etag;
      _dirty = false;
      _inFlight = false;
      _conflict = false;
      _error = null;
    });
    unawaited(_loadLinks());
  }

  /// Reads what connects the open note to the others. A reply for a note that is no longer open
  /// is dropped; a failed read leaves the panel empty, never an error over the note.
  Future<void> _loadLinks() async {
    final path = _path;
    if (path == null) return;
    final gen = ++_linksGen;
    try {
      final links = await _api.noteLinks(_project, path);
      if (mounted && _path == path && gen == _linksGen) {
        setState(() => _links = links);
      }
    } on HaroApiException {
      if (mounted && _path == path && gen == _linksGen) {
        setState(() => _links = null);
      }
    }
  }

  /// A `[[link]]` or `#tag` tapped in View. A tag searches the notes for it. A link opens the note
  /// it names, or creates that note when none has the name yet. That is decided from the backend's
  /// reading of the SAVED note (after saving what is pending), never from a guess: a link that is
  /// still loading, or not in the saved text yet, must not create a second copy of a note that
  /// exists under another spelling (a title, a different case, a folder).
  Future<void> _onNoteLink(String url) async {
    final link = noteLinkFrom(url);
    if (link == null) return;
    if (link.tag) {
      _search.text = '#${link.value}';
      await _loadList();
      return;
    }
    await _flush();
    await _loadLinks();
    final known = _links?.outgoing.where((l) => l.target == link.value);
    if (known == null || known.isEmpty) return;
    final path = known.first.path;
    if (path != null) {
      await _open(path);
      return;
    }
    final created = notePathFrom(link.value);
    if (created == null) return;
    try {
      await _api.writeNote(
        _project,
        created,
        '# ${link.value.trim()}\n\n',
        create: true,
      );
      await _loadList();
      await _open(created);
      _setEditing(true);
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    }
  }

  Future<void> _open(String path) async {
    await _flush();
    try {
      final doc = await _api.readNote(_project, path);
      if (!mounted) return;
      _text.selection = const TextSelection.collapsed(offset: 0);
      _editing = false;
      _viewSelection = '';
      _show(doc);
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  // ---- today, templates, tasks, history ----

  Future<void> _today() async {
    try {
      final path = await _api.openDailyNote(_project);
      await _loadList();
      await _open(path);
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    }
  }

  Future<void> _fromTemplate(BuildContext at) async {
    List<NoteTemplate> templates;
    try {
      templates = await _api.noteTemplates(_project);
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
      return;
    }
    if (!mounted || !at.mounted) return;
    final box = at.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(0, box.size.height));
    showHaroMenu(
      at,
      position: pos,
      items: [
        for (final t in templates)
          HaroMenuItem(
            label: t.name,
            hint: t.source == 'project' ? 'project' : null,
            onSelected: () => unawaited(_newFromTemplate(t)),
          ),
      ],
    );
  }

  Future<void> _newFromTemplate(NoteTemplate t) async {
    final name = await showTextPrompt(
      context,
      title: t.name,
      hint: 'Name, e.g. caching-ideas',
      confirm: 'Create',
    );
    if (name == null || !mounted) return;
    final path = notePathFrom(name);
    if (path == null) return;
    try {
      await _flush();
      await _api.noteFromTemplate(
        _project,
        template: t.id,
        path: path,
        title: name.trim(),
      );
      await _loadList();
      await _open(path);
      _setEditing(true);
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    }
  }

  Future<void> _toggleTasks() async {
    if (_showTasks) {
      setState(() => _showTasks = false);
      return;
    }
    setState(() => _showTasks = true);
    try {
      final t = await _api.noteTasks(_project);
      if (mounted) setState(() => _tasks = t);
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    }
  }

  Future<void> _history() async {
    final path = _path;
    if (path == null) return;
    await _flush();
    if (!mounted) return;
    final text = await showNoteHistory(
      context,
      api: _api,
      projectId: _project,
      path: path,
    );
    if (text == null || !mounted || _path != path) return;
    _text.text = text;
    _edited(text);
    await _flush();
  }

  // ---- pasting a picture ----

  /// Cmd/Ctrl+V in Edit: a copied picture is stored under the notes' `assets/` and linked as
  /// `![](assets/...)`; anything else is the ordinary text paste.
  Future<void> _paste() async {
    final bytes = await readClipboardImage();
    if (!mounted) return;
    if (bytes == null) return _pasteText();
    try {
      final path = await _api.addNoteAsset(_project, bytes);
      if (mounted) _insert('![]($path)\n');
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    }
  }

  void _pasteText() {
    final ctx = _editorFocus.context;
    final done = ctx == null
        ? null
        : Actions.maybeInvoke(
            ctx,
            const PasteTextIntent(SelectionChangedCause.keyboard),
          );
    if (done == null) {
      unawaited(
        Clipboard.getData(Clipboard.kTextPlain).then((d) {
          if (mounted && d?.text != null) _insert(d!.text!);
        }),
      );
    }
  }

  void _insert(String s) {
    final v = _text.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    final next = v.text.replaceRange(sel.start, sel.end, s);
    _text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start + s.length),
    );
    _edited(next);
  }

  // ---- links to todos, issues and code ----

  Future<void> _onAnyLink(String url) async {
    final file = fileLinkFrom(url);
    if (file != null) return _openFile(file);
    final todo = todoIdFrom(url);
    if (todo != null) return _jumpTodo(todo);
    final issue = issueNumberFrom(url);
    if (issue != null) {
      ref
          .read(backlogJumpProvider.notifier)
          .jump(BacklogJump(projectId: _project, kind: 'issue', number: issue));
      return;
    }
    final code = codeRefFrom(url);
    if (code != null) {
      return ref
          .read(openInLauncherProvider)
          .launch(
            context,
            projectId: _project,
            source: 'project:${code.$1}',
            path: code.$1,
            line: code.$2,
          );
    }
    return _onNoteLink(url);
  }

  Future<void> _jumpTodo(String id) async {
    await _flush();
    await _loadLinks();
    if (!mounted) return;
    final row = _links?.outgoing
        .where((l) => l.isTodo && l.target.toLowerCase().startsWith('todo:$id'))
        .firstOrNull;
    final file = row?.todoPath;
    if (row == null || file == null || row.todoText == null) {
      showHaroToast(
        context,
        'That todo is gone: it was deleted or reworded past recognition.',
      );
      return;
    }
    ref
        .read(backlogJumpProvider.notifier)
        .jump(
          BacklogJump(
            projectId: _project,
            kind: 'todo',
            file: file,
            text: row.todoText,
          ),
        );
  }

  // ---- saving ----

  void _edited(String _) {
    if (_conflict) return;
    setState(() => _dirty = true);
    _timer?.cancel();
    _timer = Timer(_autosave, () => unawaited(_flush()));
  }

  Future<void> _flush() {
    _timer?.cancel();
    return _saveChain = _saveChain.then<void>((_) => _saveOnce());
  }

  Future<void> _saveOnce() async {
    final path = _path;
    if (!mounted || path == null || !_dirty || _conflict) return;
    final gen = _gen;
    final sent = _text.text;
    setState(() {
      _dirty = false;
      _inFlight = true;
    });
    try {
      final etag = await _api.writeNote(_project, path, sent, etag: _etag);
      if (gen != _gen) return;
      _etag =
          etag; // also when the tab closed meanwhile: the final save quotes it
      if (!mounted) return;
      setState(() => _inFlight = false);
      if (_dirty) _timer = Timer(_autosave, () => unawaited(_flush()));
      _loadList();
      unawaited(_loadLinks());
    } on HaroApiException catch (e) {
      _failed(gen, e.message, conflict: e.status == 409);
    } catch (e) {
      _failed(gen, '$e');
    }
  }

  void _failed(int gen, String message, {bool conflict = false}) {
    if (!mounted || gen != _gen) return;
    setState(() {
      _inFlight = false;
      _dirty = true; // still unsaved
      if (conflict) {
        _conflict = true;
      } else {
        _error = message;
      }
    });
  }

  Future<void> _reload() async {
    final path = _path;
    if (path == null) return;
    try {
      final doc = await _api.readNote(_project, path);
      if (mounted) _show(doc);
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _keepMine() async {
    final path = _path;
    if (path == null) return;
    final gen = _gen;
    final sent = _text.text;
    try {
      final etag = await _api.writeNote(_project, path, sent);
      if (!mounted || gen != _gen) return;
      _etag = etag;
      setState(() {
        _conflict = false;
        _dirty = _text.text != sent;
      });
      if (_dirty) _timer = Timer(_autosave, () => unawaited(_flush()));
      _loadList();
    } on HaroApiException catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e.message);
    }
  }

  // ---- files ----

  void _startNaming({String? renaming, String? prefix}) {
    setState(() {
      _naming = true;
      _renaming = renaming;
      _name.text = renaming ?? prefix ?? '';
      if (renaming != null) {
        _name.selection = nameStemSelection(renaming);
      } else {
        _name.selection = TextSelection.collapsed(offset: _name.text.length);
      }
    });
  }

  void _cancelNaming() {
    if (!_naming) return;
    setState(() {
      _naming = false;
      _renaming = null;
    });
  }

  /// A rename edits the note's own row; when that row is not in the list (a search hides it) the
  /// field is shown at the top instead.
  bool get _renamingInList =>
      _renaming != null && (_notes ?? const []).any((n) => n.path == _renaming);

  Future<void> _commitName(String raw) async {
    final path = notePathFrom(raw);
    final from = _renaming;
    setState(() {
      _naming = false;
      _renaming = null;
    });
    if (path == null || path == from) return;
    try {
      if (from != null) {
        await _flush();
        await _api.renameNote(_project, from, path);
      } else {
        await _api.writeNote(
          _project,
          path,
          '# ${noteTitleFor(path)}\n\n',
          create: true,
        );
      }
      await _loadList();
      await _open(path);
      if (from == null) _setEditing(true);
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    }
  }

  /// Asks in a modal first: a note is a file, and deleting it cannot be undone from here.
  Future<void> _confirmAndDelete() async {
    final path = _path;
    if (path == null) return;
    final ok = await showConfirm(
      context,
      title: 'Delete this note?',
      body:
          '$path is removed from the project. If it was committed, git still has its history.',
    );
    if (ok && mounted && _path == path) await _delete();
  }

  Future<void> _delete() async {
    final path = _path;
    if (path == null) return;
    _timer?.cancel();
    try {
      await _api.deleteNote(_project, path);
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return;
    }
    if (!mounted) return;
    _text.clear();
    _gen++;
    setState(() {
      _editing = false;
      _path = null;
      _dirty = false;
      _inFlight = false;
      _conflict = false;
    });
    _loadList();
  }

  void _setEditing(bool edit) {
    setState(() {
      _editing = edit;
      _viewSelection = '';
    });
    if (edit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editorFocus.requestFocus();
      });
    }
  }

  // ---- promoting a line ----

  /// What Make todo and Start as workspace act on: the selection in the rendered view, or in
  /// Edit mode the selection or the cursor's line.
  String get _source => _editing
      ? lineOrSelection(_text.text, _text.selection)
      : _viewSelection.trim();

  String get _picked => todoTextFrom(_source);

  String get _nothingPicked => _editing
      ? 'Put the cursor on a line, or select some text.'
      : 'Select some text in the note first.';

  Future<void> _makeTodo() async {
    final title = _picked;
    if (title.isEmpty) {
      showHaroToast(context, _nothingPicked);
      return;
    }
    try {
      await _api.addTodoItem(
        _project,
        title,
        evidence: 'from notes/$_path',
        inbox: true,
      );
      if (mounted) showHaroToast(context, 'Added to the inbox');
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    }
  }

  void _startWorkspace() {
    final raw = _source;
    final title = todoTextFrom(raw);
    if (title.isEmpty) {
      showHaroToast(context, _nothingPicked);
      return;
    }
    widget.onStart(NewWorkspacePrefill(task: raw.trim(), title: title));
  }

  // ---- widgets ----

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        width: widget.listWidth,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: HaroTokens.line12)),
        ),
        child: _list(),
      ),
      Expanded(child: _editor()),
    ],
  );

  Widget _list() {
    final notes = _notes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: HaroTextField(
            key: const Key('notes-search'),
            controller: _search,
            height: 30,
            fontSize: 13,
            hintText: 'Search notes',
            onChanged: (_) {
              _searchTimer?.cancel();
              _searchTimer = Timer(
                const Duration(milliseconds: 250),
                _loadList,
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: _naming && !_renamingInList
              ? InlineNameField(
                  key: const Key('notes-name'),
                  controller: _name,
                  focusNode: _nameFocus,
                  hint: _renaming == null
                      ? 'Name, e.g. caching-ideas. Enter to create'
                      : 'New name. Enter to rename',
                  onSubmit: _commitName,
                  onCancel: _cancelNaming,
                )
              : Row(
                  children: [
                    HaroButton(
                      key: const Key('notes-new'),
                      label: 'New note',
                      leading: ShellIcon.plus,
                      height: 28,
                      fontSize: 12,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      onPressed: _startNaming,
                    ),
                    const Spacer(),
                    Builder(
                      builder: (ctx) => ShellIconButton(
                        key: const Key('notes-template'),
                        icon: ShellIcon.template,
                        tooltip: 'New note from a template',
                        bordered: true,
                        width: 30,
                        onTap: () => unawaited(_fromTemplate(ctx)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ShellIconButton(
                      key: const Key('notes-today'),
                      icon: ShellIcon.calendar,
                      tooltip: "Today's note",
                      bordered: true,
                      width: 30,
                      onTap: () => unawaited(_today()),
                    ),
                    const SizedBox(width: 6),
                    ShellIconButton(
                      key: const Key('notes-tasks'),
                      icon: ShellIcon.listChecks,
                      tooltip: _showTasks
                          ? 'Back to the notes'
                          : 'Open tasks in all notes',
                      bordered: true,
                      on: _showTasks,
                      width: 30,
                      onTap: () => unawaited(_toggleTasks()),
                    ),
                  ],
                ),
        ),
        Divider(height: 1, color: HaroTokens.line08),
        Expanded(
          child: _showTasks
              ? _taskList()
              : _listError != null
              ? _hint(_listError!, error: true)
              : notes == null || _listLoading
              ? const ListLoading('Loading notes')
              : notes.isEmpty &&
                    (_search.text.trim().isNotEmpty || _files.isEmpty)
              ? _hint(
                  _search.text.trim().isEmpty
                      ? 'No notes yet. + NEW NOTE starts one.'
                      : 'No note mentions that.',
                )
              : _search.text.trim().isNotEmpty
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
                  children: [for (final n in notes) _row(n), ..._fileSection()],
                )
              : _tree(notes),
        ),
      ],
    );
  }

  /// Notes and the files beside them as one folder tree, `a/b/note.md` under `a` under `b`.
  /// Searching leaves it for the flat list, whose rows carry the matching lines.
  Widget _tree(List<NoteSummary> notes) {
    final root = buildTree<Object>([
      ...notes,
      ..._files,
    ], (o) => o is NoteSummary ? o.path : (o as NoteFile).path);
    final expanded = _expanded ??= defaultExpanded(root, _path);
    final rows = flattenTree(root, expanded);
    return ListView(
      key: const Key('notes-tree'),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
      children: [
        for (final r in rows)
          switch (r) {
            FolderRow<Object>(:final folder, :final depth, :final open) =>
              TreeFolderRow(
                key: Key('notes-folder-${folder.path}'),
                name: folder.name,
                depth: depth,
                open: open,
                count: folder.total,
                onTap: () => setState(
                  () => open
                      ? expanded.remove(folder.path)
                      : expanded.add(folder.path),
                ),
                onMenu: (at) => _folderMenu(root, folder, at),
              ),
            ItemRow<Object>(:final item, :final depth) => switch (item) {
              NoteSummary n => _treeNote(n, depth),
              NoteFile f => TreeLeafRow(
                key: Key('notes-file-${f.path}'),
                depth: depth,
                icon: fileIconFor(f.kind),
                label: f.name,
                trailing: fileSizeText(f.size),
                tooltip: 'Open ${f.name} with your default app',
                onTap: () => unawaited(_openFile(f.path)),
              ),
              _ => const SizedBox.shrink(),
            },
          },
      ],
    );
  }

  Widget _treeNote(NoteSummary n, int depth) {
    if (_naming && _renaming == n.path) {
      return Padding(
        padding: EdgeInsets.only(left: 6 + depth * 16.0, top: 2, bottom: 2),
        child: InlineNameField(
          key: const Key('notes-name'),
          controller: _name,
          focusNode: _nameFocus,
          hint: 'New name. Enter to rename',
          onSubmit: _commitName,
          onCancel: _cancelNaming,
        ),
      );
    }
    return TreeLeafRow(
      key: Key('note-${n.path}'),
      depth: depth,
      icon: ShellIcon.fileText,
      label: noteFileLabel(n.path),
      trailing: relativeTime(n.modified, DateTime.now()),
      tooltip: n.path,
      selected: n.path == _path,
      onTap: () => unawaited(_open(n.path)),
      onMenu: (at) => unawaited(_noteMenu(n, at)),
    );
  }

  void _folderMenu(TreeFolder<Object> root, TreeFolder<Object> f, Offset at) {
    final expanded = _expanded ??= <String>{};
    showHaroMenu(
      context,
      position: at,
      items: [
        HaroMenuItem(
          label: 'New note here',
          onSelected: () => _startNaming(prefix: '${f.path}/'),
        ),
        const HaroMenuItem.separator(),
        HaroMenuItem(
          label: 'Expand all',
          onSelected: () => setState(() {
            expanded
              ..add(f.path)
              ..addAll(allFolders(f));
          }),
        ),
        HaroMenuItem(
          label: 'Collapse all',
          onSelected: () => setState(() {
            expanded
              ..remove(f.path)
              ..removeAll(allFolders(f));
          }),
        ),
      ],
    );
  }

  Widget _taskList() {
    final tasks = _tasks;
    if (tasks == null) return const ListLoading('Loading tasks');
    if (tasks.isEmpty) return _hint('No open tasks in the notes.');
    return ListView(
      key: const Key('notes-task-list'),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
      children: [
        for (final t in tasks)
          HaroPressable(
            onTap: () => _open(t.path),
            semanticLabel: t.text,
            builder: (context, hovered) => Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              margin: const EdgeInsets.only(bottom: 2),
              decoration: BoxDecoration(
                color: hovered ? HaroTokens.raised : HaroTokens.transparent,
                borderRadius: BorderRadius.circular(HaroTokens.radius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.ui(size: 13.5, color: HaroTokens.ink86),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HaroText.mono(
                            size: 10,
                            tracking: 0,
                            color: HaroTokens.ink42,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      HaroTag('line ${t.line}'),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _fileSection() {
    final files = _shownFiles;
    if (files.isEmpty) return const [];
    // A few files are shown; a vault's worth of source material starts folded.
    final open =
        _filesOpen ?? (files.length <= 6 || _search.text.trim().isNotEmpty);
    return [
      NoteFilesSection(
        files: files,
        open: open,
        onToggle: () => setState(() => _filesOpen = !open),
        onOpen: (f) => unawaited(_openFile(f.path)),
      ),
    ];
  }

  Widget _hint(String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.all(18),
    child: Text(
      text,
      style: HaroText.mono(
        size: 11,
        tracking: 0,
        color: error ? HaroTokens.fail : HaroTokens.ink42,
        height: 1.5,
      ),
    ),
  );

  Widget _row(NoteSummary n) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onSecondaryTapDown: (d) => unawaited(_noteMenu(n, d.globalPosition)),
    child: _rowBody(n),
  );

  /// Right-click on a note in the list: open it, then the same actions as its menu button.
  Future<void> _noteMenu(NoteSummary n, Offset at) async {
    if (n.path != _path) await _open(n.path);
    if (!mounted) return;
    showHaroMenu(
      context,
      position: at,
      items: [
        HaroMenuItem(
          label: 'Rename',
          onSelected: () => _startNaming(renaming: n.path),
        ),
        HaroMenuItem(label: 'History', onSelected: () => unawaited(_history())),
        const HaroMenuItem.separator(),
        HaroMenuItem(
          label: 'Delete',
          destructive: true,
          onSelected: () => unawaited(_confirmAndDelete()),
        ),
      ],
    );
  }

  Widget _rowBody(NoteSummary n) {
    if (_naming && _renaming == n.path) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: InlineNameField(
          key: const Key('notes-name'),
          controller: _name,
          focusNode: _nameFocus,
          hint: 'New name. Enter to rename',
          onSubmit: _commitName,
          onCancel: _cancelNaming,
        ),
      );
    }
    final selected = n.path == _path;
    return HaroPressable(
      onTap: () => _open(n.path),
      semanticLabel: n.title,
      builder: (context, hovered) => Container(
        key: Key('note-${n.path}'),
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: selected || hovered
              ? HaroTokens.raised
              : HaroTokens.transparent,
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              n.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(
                size: 13.5,
                color: selected ? HaroTokens.ink : HaroTokens.ink86,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Flexible(
                  child: Text(
                    n.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.mono(
                      size: 10,
                      tracking: 0,
                      color: HaroTokens.ink42,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  relativeTime(n.modified, DateTime.now()),
                  maxLines: 1,
                  style: HaroText.mono(
                    size: 10,
                    tracking: 0,
                    color: HaroTokens.ink42,
                  ),
                ),
              ],
            ),
            for (final s in n.snippets)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  s,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.ui(size: 12, color: HaroTokens.ink66),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String get _status => switch (_save) {
    _Save.saved => 'SAVED',
    _Save.editing => 'EDITING',
    _Save.saving => 'SAVING',
  };

  Widget _editor() {
    final path = _path;
    if (path == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              'Notes are plain markdown files in .haro/notes in this project: '
              'brainstorms, sketches, what you tried. They go with git, open in any '
              'editor, and haro never writes one by itself: you do, or an agent does when you ask. Pick one, or start a new '
              'one. Select a line and make it a todo, or start a workspace from it.',
              style: HaroText.ui(
                size: 14,
                color: HaroTokens.ink42,
                height: 1.6,
              ),
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 10),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        path.substring(path.lastIndexOf('/') + 1),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HaroText.mono(
                          size: 11,
                          tracking: 0,
                          color: HaroTokens.ink66,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _status,
                      key: const Key('notes-status'),
                      style: HaroText.mono(size: 10.5, color: HaroTokens.ink42),
                    ),
                  ],
                ),
              ),
              HaroSegmented<bool>(
                keyPrefix: 'notes-mode',
                segments: const [
                  HaroSegment(false, 'View', tooltip: 'Read it rendered'),
                  HaroSegment(true, 'Edit', tooltip: 'Edit the markdown'),
                ],
                selected: _editing,
                onChanged: _setEditing,
              ),
              const SizedBox(width: 8),
              HaroButton(
                key: const Key('notes-make-todo'),
                label: 'Make todo',
                onPressed: _makeTodo,
              ),
              const SizedBox(width: 8),
              HaroButton(
                key: const Key('notes-start'),
                label: 'Start as workspace',
                variant: HaroButtonVariant.primary,
                onPressed: _startWorkspace,
              ),
              const SizedBox(width: 8),
              Builder(
                builder: (ctx) => ShellIconButton(
                  key: const Key('notes-menu'),
                  icon: ShellIcon.ellipsis,
                  onTap: () {
                    final box = ctx.findRenderObject() as RenderBox;
                    showHaroMenu(
                      ctx,
                      position: box.localToGlobal(
                        Offset(box.size.width, box.size.height),
                      ),
                      items: [
                        HaroMenuItem(
                          label: 'Rename',
                          onSelected: () => _startNaming(renaming: path),
                        ),
                        HaroMenuItem(
                          label: 'History',
                          onSelected: () => unawaited(_history()),
                        ),
                        const HaroMenuItem.separator(),
                        HaroMenuItem(
                          label: 'Delete',
                          destructive: true,
                          onSelected: () => unawaited(_confirmAndDelete()),
                        ),
                      ],
                    );
                  },
                  tooltip: 'Rename, history or delete',
                ),
              ),
            ],
          ),
        ),
        if (_conflict)
          _banner(
            key: const Key('notes-conflict'),
            text: 'This note changed on disk since you opened it.',
            actions: [
              HaroButton(
                key: const Key('notes-reload'),
                label: 'Reload it',
                onPressed: _reload,
              ),
              HaroButton(
                key: const Key('notes-keep'),
                label: 'Keep mine',
                onPressed: _keepMine,
              ),
            ],
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: ErrorLine(_error!),
          ),
        Divider(height: 1, color: HaroTokens.line08),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
            child: _editing ? _sourceField() : _rendered(),
          ),
        ),
        Container(
          key: const Key('notes-path'),
          padding: const EdgeInsets.fromLTRB(24, 7, 24, 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: HaroTokens.line08)),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: PathLine(path, prefix: '.haro/notes/'),
          ),
        ),
      ],
    );
  }

  Widget _sourceField() {
    final field = _sourceTextField();
    if (!clipboardImageSupported) return field;
    return Shortcuts(
      shortcuts: {
        SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            const _PasteNoteIntent(),
      },
      child: Actions(
        actions: {
          _PasteNoteIntent: CallbackAction<_PasteNoteIntent>(
            onInvoke: (_) {
              unawaited(_paste());
              return null;
            },
          ),
        },
        child: field,
      ),
    );
  }

  Widget _sourceTextField() => TextField(
    key: const Key('notes-editor'),
    controller: _text,
    focusNode: _editorFocus,
    expands: true,
    maxLines: null,
    minLines: null,
    textAlignVertical: TextAlignVertical.top,
    onChanged: _edited,
    cursorColor: HaroTokens.ink,
    style: HaroText.mono(
      size: 13.5,
      tracking: 0,
      color: HaroTokens.ink86,
      height: 1.65,
    ),
    decoration: const InputDecoration(
      border: InputBorder.none,
      isCollapsed: true,
      hintText: 'Write. Markdown.',
    ),
  );

  /// The note as the markdown it is. Selectable, so a line can still become a todo. `[[links]]`
  /// and `#tags` are links the tab handles; below the text, what links to this note.
  Widget _rendered() => SelectionArea(
    onSelectionChanged: (c) => _viewSelection = c?.plainText ?? '',
    child: ListView(
      key: const Key('notes-view'),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _text.text.trim().isEmpty
                    ? Text(
                        'Empty note. Switch to Edit to write in it.',
                        key: const Key('notes-view-empty'),
                        style: HaroText.ui(size: 14, color: HaroTokens.ink42),
                      )
                    : _body(),
                ..._fileLinkPanel(),
                ..._linkPanels(),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  /// The note's text: its Obsidian properties (a leading `---` block) as a quiet list, then the
  /// markdown with its wikilinks, embeds and file links read.
  Widget _body() {
    final (props, body) = splitFrontMatter(_text.text.trim());
    final known = {for (final f in _files) f.name.toLowerCase()};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (props.isNotEmpty) NoteProperties(props),
        if (body.trim().isNotEmpty)
          AgentProse(
            wikiToMarkdown(body.trim(), knownFiles: known),
            onLink: (url) => unawaited(_onAnyLink(url)),
            imageUrl: (p) =>
                _api.noteAssetUrl(_project, Uri.decodeComponent(p)).toString(),
          ),
      ],
    );
  }

  /// The files this note links or embeds, as buttons that open them.
  List<Widget> _fileLinkPanel() {
    final out = _links?.outgoing ?? const <NoteLinkOut>[];
    final seen = <String>{};
    final files = <NoteFile>[];
    for (final l in out) {
      final path = l.file;
      if (path == null || !seen.add(path)) continue;
      final hit = _files.where((f) => f.path == path).firstOrNull;
      files.add(
        hit ?? NoteFile(path: path, name: path.split('/').last, kind: 'other'),
      );
    }
    if (files.isEmpty) return const [];
    return [
      LinkedFilesPanel(
        files: files,
        onOpen: (f) => unawaited(_openFile(f.path)),
      ),
    ];
  }

  /// Linked from / Mentioned in: other notes that link to this one, and ones that only name it.
  List<Widget> _linkPanels() {
    final links = _links;
    if (links == null) return const [];
    Widget section(String key, String label, List<NoteRef> refs) => Container(
      key: Key(key),
      margin: const EdgeInsets.only(top: 22),
      padding: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: MonoCaption(label, count: refs.length),
          ),
          const SizedBox(height: 6),
          for (final r in refs)
            HaroPressable(
              onTap: () => unawaited(_open(r.path)),
              semanticLabel: 'Open ${r.title}',
              builder: (context, hovered) => Padding(
                key: Key('$key-${r.path}'),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.title,
                      style: HaroText.ui(
                        size: 13.5,
                        color: hovered ? HaroTokens.ink : HaroTokens.ink86,
                      ),
                    ),
                    if (r.snippet.isNotEmpty)
                      Text(
                        r.snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HaroText.mono(
                          size: 11,
                          color: HaroTokens.ink42,
                          tracking: 0,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    return [
      if (links.backlinks.isNotEmpty)
        section('notes-backlinks', 'LINKED FROM', links.backlinks),
      if (links.mentions.isNotEmpty)
        section('notes-mentions', 'MENTIONED IN, NOT LINKED', links.mentions),
    ];
  }

  Widget _banner({
    required Key key,
    required String text,
    required List<Widget> actions,
  }) => Container(
    key: key,
    margin: const EdgeInsets.fromLTRB(24, 0, 24, 10),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: HaroTokens.panel,
      border: Border.all(color: HaroTokens.line12),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: HaroText.mono(
              size: 11,
              tracking: 0,
              color: HaroTokens.ink66,
            ),
          ),
        ),
        for (final a in actions) ...[const SizedBox(width: 8), a],
      ],
    ),
  );
}
