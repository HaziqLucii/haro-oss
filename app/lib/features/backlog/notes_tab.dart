import 'dart:async';

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
import '../../widgets/haro_menu.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../new_workspace/creation_widgets.dart';
import '../new_workspace/prefill.dart';
import 'notes_model.dart';

enum _Save { saved, editing, saving }

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
  });

  final String projectId;
  final double listWidth;
  final ValueChanged<NewWorkspacePrefill> onStart;

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
  String? _listError;
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
  bool _confirmDelete = false;
  bool _naming = false;
  String? _renaming;
  String? _error;
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
    setState(() {
      _path = doc.path;
      _etag = doc.etag;
      _dirty = false;
      _inFlight = false;
      _conflict = false;
      _confirmDelete = false;
      _error = null;
    });
  }

  Future<void> _open(String path) async {
    await _flush();
    try {
      final doc = await _api.readNote(_project, path);
      if (!mounted) return;
      _text.selection = const TextSelection.collapsed(offset: 0);
      _show(doc);
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
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

  void _startNaming({String? renaming}) {
    setState(() {
      _naming = true;
      _renaming = renaming;
      _name.text = renaming ?? '';
    });
    _nameFocus.requestFocus();
  }

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
      if (from == null) _editorFocus.requestFocus();
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    }
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
      _path = null;
      _dirty = false;
      _inFlight = false;
      _confirmDelete = false;
      _conflict = false;
    });
    _loadList();
  }

  // ---- promoting a line ----

  String get _picked =>
      todoTextFrom(lineOrSelection(_text.text, _text.selection));

  Future<void> _makeTodo() async {
    final title = _picked;
    if (title.isEmpty) {
      showHaroToast(context, 'Put the cursor on a line, or select some text.');
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
    final raw = lineOrSelection(_text.text, _text.selection);
    final title = todoTextFrom(raw);
    if (title.isEmpty) {
      showHaroToast(context, 'Put the cursor on a line, or select some text.');
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
        decoration: const BoxDecoration(
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
                      key: const Key('notes-name'),
                      controller: _name,
                      focusNode: _nameFocus,
                      height: 30,
                      fontSize: 13,
                      hintText: _renaming == null
                          ? 'Name, e.g. caching-ideas. Enter to create'
                          : 'New name. Enter to rename',
                      onSubmitted: _commitName,
                    ),
                  ),
                )
              : Align(
                  alignment: Alignment.centerLeft,
                  child: HaroPressable(
                    onTap: _startNaming,
                    semanticLabel: 'New note',
                    builder: (context, hovered) => Text(
                      '+ NEW NOTE',
                      key: const Key('notes-new'),
                      style: HaroText.mono(
                        size: 10.5,
                        color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                      ),
                    ),
                  ),
                ),
        ),
        const Divider(height: 1, color: HaroTokens.line08),
        Expanded(
          child: _listError != null
              ? _hint(_listError!, error: true)
              : notes == null
              ? _hint('Loading…')
              : notes.isEmpty
              ? _hint(
                  _search.text.trim().isEmpty
                      ? 'No notes yet. + NEW NOTE starts one.'
                      : 'No note mentions that.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
                  children: [for (final n in notes) _row(n)],
                ),
        ),
      ],
    );
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

  Widget _row(NoteSummary n) {
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
              ? HaroTokens.ink02
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
            Text(
              '${n.path} · ${relativeTime(n.modified, DateTime.now())}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 10,
                tracking: 0,
                color: HaroTokens.ink42,
              ),
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
              'editor, and only you write them in haro. Pick one, or start a new '
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
                child: Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '.haro/notes/$path',
                      style: HaroText.mono(
                        size: 11,
                        tracking: 0,
                        color: HaroTokens.ink42,
                      ),
                    ),
                    Text(
                      _status,
                      key: const Key('notes-status'),
                      style: HaroText.mono(size: 10.5, color: HaroTokens.ink42),
                    ),
                  ],
                ),
              ),
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
                builder: (ctx) => HaroPressable(
                  key: const Key('notes-menu'),
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
                        const HaroMenuItem.separator(),
                        HaroMenuItem(
                          label: 'Delete',
                          destructive: true,
                          onSelected: () =>
                              setState(() => _confirmDelete = true),
                        ),
                      ],
                    );
                  },
                  tooltip: 'Rename or delete',
                  semanticLabel: 'Note actions',
                  builder: (context, h) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      '···',
                      style: HaroText.mono(
                        size: 13,
                        color: h ? HaroTokens.ink : HaroTokens.ink42,
                      ),
                    ),
                  ),
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
        if (_confirmDelete)
          _banner(
            key: const Key('notes-confirm-delete'),
            text: 'Delete $path? The file is removed from the project.',
            actions: [
              HaroButton(
                key: const Key('notes-delete'),
                label: 'Delete',
                variant: HaroButtonVariant.destructive,
                onPressed: _delete,
              ),
              HaroButton(
                label: 'Keep',
                onPressed: () => setState(() => _confirmDelete = false),
              ),
            ],
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: ErrorLine(_error!),
          ),
        const Divider(height: 1, color: HaroTokens.line08),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
            child: TextField(
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
            ),
          ),
        ),
      ],
    );
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
