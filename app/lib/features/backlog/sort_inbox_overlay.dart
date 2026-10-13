import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../overlays/overlay.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../new_workspace/creation_widgets.dart';
import 'backlog_prompts.dart';
import 'backlog_query.dart';

bool isInboxFile(TodoFile f) =>
    f.path.split('/').last.toLowerCase() == 'inbox.md';

/// The items waiting in the inbox: open, not archived, not snoozed.
List<TodoHit> inboxItems(List<TodoFile> files) => [
  for (final f in files)
    if (isInboxFile(f))
      for (var i = 0; i < f.items.length; i++)
        if (!f.items[i].done && !f.items[i].archived && !f.items[i].snoozed)
          TodoHit(f, i, f.items[i]),
];

/// Go through the inbox one item at a time from the keyboard: promote it to a backlog file, put it
/// in a note, snooze it a week, tag it or discard it. A very similar item elsewhere is pointed out
/// (plain word overlap, nothing smarter).
Future<void> showSortInbox(
  BuildContext context, {
  required HaroApi api,
  required String projectId,
  required VoidCallback onChanged,
}) => showHaroOverlay<void>(
  context,
  width: 720,
  height: 560,
  child: SortInboxOverlay(api: api, projectId: projectId, onChanged: onChanged),
);

enum _Mode { main, promote, note }

class SortInboxOverlay extends StatefulWidget {
  const SortInboxOverlay({
    super.key,
    required this.api,
    required this.projectId,
    required this.onChanged,
  });

  final HaroApi api;
  final String projectId;
  final VoidCallback onChanged;

  @override
  State<SortInboxOverlay> createState() => _SortInboxOverlayState();
}

class _SortInboxOverlayState extends State<SortInboxOverlay> {
  List<TodoFile> _files = const [];
  List<NoteSummary> _notes = const [];
  bool _loaded = false;
  String? _error;
  int _i = 0;
  _Mode _mode = _Mode.main;
  final _focus = FocusNode(debugLabel: 'sort-inbox');
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _focus.dispose();
    _filter.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final t = await widget.api.getTodo(widget.projectId);
      if (!mounted) return;
      setState(() {
        _files = t.files;
        _loaded = true;
        final n = inboxItems(_files).length;
        if (_i >= n) _i = n == 0 ? 0 : n - 1;
      });
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  TodoHit? get _current {
    final items = inboxItems(_files);
    return items.isEmpty ? null : items[_i.clamp(0, items.length - 1)];
  }

  Future<void> _run(Future<void> Function() call) async {
    try {
      await call();
      _error = null;
      widget.onChanged();
    } on HaroApiException catch (e) {
      _error = e.status == 409
          ? 'The file changed while you were looking at it. Reloaded.'
          : e.message;
    }
    if (!mounted) return;
    setState(() => _mode = _Mode.main);
    await _reload();
    _focus.requestFocus();
  }

  Future<void> _promote(String to) {
    final h = _current;
    if (h == null) return Future.value();
    return _run(
      () => widget.api.todoItemOp(
        widget.projectId,
        file: h.file.path,
        index: h.index,
        expect: h.item.text,
        op: 'move',
        toFile: to,
      ),
    );
  }

  Future<void> _attach(String notePath) {
    final h = _current;
    if (h == null) return Future.value();
    return _run(() async {
      final doc = await widget.api.readNote(widget.projectId, notePath);
      final sep = doc.content.endsWith('\n') ? '' : '\n';
      await widget.api.writeNote(
        widget.projectId,
        notePath,
        '${doc.content}$sep- ${h.item.text}\n',
        etag: doc.etag,
      );
      await widget.api.todoItemOp(
        widget.projectId,
        file: h.file.path,
        index: h.index,
        expect: h.item.text,
        op: 'delete',
      );
    });
  }

  Future<void> _snooze() {
    final h = _current;
    if (h == null) return Future.value();
    final d = DateTime.now().add(const Duration(days: 7));
    String two(int n) => n.toString().padLeft(2, '0');
    return _run(
      () => widget.api.setTodoMeta(
        widget.projectId,
        file: h.file.path,
        index: h.index,
        expect: h.item.text,
        snooze: '${d.year}-${two(d.month)}-${two(d.day)}',
      ),
    );
  }

  Future<void> _discard() {
    final h = _current;
    if (h == null) return Future.value();
    return _run(
      () => widget.api.todoItemOp(
        widget.projectId,
        file: h.file.path,
        index: h.index,
        expect: h.item.text,
        op: 'delete',
      ),
    );
  }

  Future<void> _tag() async {
    final h = _current;
    if (h == null) return;
    final v = await showTextPrompt(
      context,
      title: 'Tags',
      caption: h.item.text,
      hint: 'ui perf/db (separated by spaces)',
      initial: h.item.tags.join(' '),
    );
    if (!mounted) return;
    if (v == null) {
      _focus.requestFocus();
      return;
    }
    final tags = [
      for (final t in v.split(RegExp(r'[\s,]+')))
        if (t.replaceAll('#', '').isNotEmpty) t.replaceAll('#', ''),
    ];
    await _run(
      () => widget.api.setTodoMeta(
        widget.projectId,
        file: h.file.path,
        index: h.index,
        expect: h.item.text,
        tags: tags,
      ),
    );
  }

  Future<void> _chooseNote() async {
    try {
      final notes = await widget.api.listNotes(widget.projectId);
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _mode = _Mode.note;
        _filter.clear();
      });
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || _mode != _Mode.main) {
      return KeyEventResult.ignored;
    }
    final kb = HardwareKeyboard.instance;
    if (kb.isMetaPressed || kb.isControlPressed || kb.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final n = inboxItems(_files).length;
    if (k == LogicalKeyboardKey.keyJ || k == LogicalKeyboardKey.arrowDown) {
      if (n > 0) setState(() => _i = (_i + 1) % n);
    } else if (k == LogicalKeyboardKey.keyK ||
        k == LogicalKeyboardKey.arrowUp) {
      if (n > 0) setState(() => _i = (_i - 1 + n) % n);
    } else if (k == LogicalKeyboardKey.keyP) {
      setState(() => _mode = _Mode.promote);
    } else if (k == LogicalKeyboardKey.keyN) {
      _chooseNote();
    } else if (k == LogicalKeyboardKey.keyS) {
      _snooze();
    } else if (k == LogicalKeyboardKey.keyD) {
      _discard();
    } else if (k == LogicalKeyboardKey.keyT) {
      _tag();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _chooser({
    required String title,
    required List<(String label, String sub, VoidCallback onTap)> options,
    bool filterable = false,
  }) {
    final q = _filter.text.trim().toLowerCase();
    final shown = [
      for (final o in options)
        if (q.isEmpty ||
            o.$1.toLowerCase().contains(q) ||
            o.$2.toLowerCase().contains(q))
          o,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonoCaption(title),
        const SizedBox(height: 8),
        if (filterable)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: HaroTextField(
              key: const Key('sort-filter'),
              controller: _filter,
              autofocus: true,
              height: 32,
              fontSize: 13,
              hintText: 'Filter',
              onChanged: (_) => setState(() {}),
            ),
          ),
        Expanded(
          child: ListView(
            children: [
              for (final (label, sub, tap) in shown)
                HaroPressable(
                  key: Key('sort-choice-$label'),
                  onTap: tap,
                  semanticLabel: label,
                  builder: (context, hovered) => Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 9,
                      horizontal: 8,
                    ),
                    color: hovered ? HaroTokens.ink02 : HaroTokens.transparent,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HaroText.ui(
                              size: 14,
                              color: HaroTokens.ink86,
                            ),
                          ),
                        ),
                        MonoCaption(sub),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: HaroButton(
            key: const Key('sort-back'),
            label: 'Back',
            variant: HaroButtonVariant.tertiary,
            onPressed: () {
              setState(() => _mode = _Mode.main);
              _focus.requestFocus();
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = inboxItems(_files);
    final h = _current;
    final similar = h == null
        ? null
        : similarTodo([
            for (final f in _files)
              if (!isInboxFile(f)) f,
          ], h.item.text);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
        child: _mode == _Mode.promote
            ? _chooser(
                title: 'PROMOTE TO',
                options: [
                  for (final f in _files)
                    if (!isInboxFile(f))
                      (
                        f.path,
                        '${f.items.length} items',
                        () => _promote(f.path),
                      ),
                ],
              )
            : _mode == _Mode.note
            ? _chooser(
                title: 'ADD TO A NOTE',
                filterable: true,
                options: [
                  for (final n in _notes)
                    (n.title, n.path, () => _attach(n.path)),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        'Sort inbox',
                        style: HaroText.ui(size: 24, weight: FontWeight.w500),
                      ),
                      const Spacer(),
                      MonoCaption(
                        items.isEmpty ? '' : '${_i + 1} of ${items.length}',
                        key: const Key('sort-count'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'J and K move, P promotes, N adds to a note, S snoozes a week, T tags, D discards.',
                    style: HaroText.ui(size: 12.5, color: HaroTokens.ink42),
                  ),
                  Expanded(
                    child: !_loaded
                        ? const SizedBox.shrink()
                        : h == null
                        ? Center(
                            child: Text(
                              'The inbox is empty.',
                              key: const Key('sort-empty'),
                              style: HaroText.ui(
                                size: 15,
                                color: HaroTokens.ink42,
                              ),
                            ),
                          )
                        : Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  h.item.text,
                                  key: const Key('sort-item'),
                                  style: HaroText.ui(size: 22, height: 1.35),
                                ),
                                if (h.item.tags.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  MonoCaption(
                                    h.item.tags.map((t) => '#$t').join('  '),
                                  ),
                                ],
                                if (similar != null) ...[
                                  const SizedBox(height: 14),
                                  Text(
                                    'Looks like: ${similar.item.text} (${similar.file.path})',
                                    key: const Key('sort-similar'),
                                    style: HaroText.ui(
                                      size: 13,
                                      color: HaroTokens.warn,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _error!,
                        key: const Key('sort-error'),
                        style: HaroText.ui(size: 13, color: HaroTokens.fail),
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      HaroButton(
                        key: const Key('sort-promote'),
                        label: 'Promote',
                        kbd: 'P',
                        onPressed: h == null
                            ? null
                            : () => setState(() => _mode = _Mode.promote),
                      ),
                      HaroButton(
                        key: const Key('sort-note'),
                        label: 'To a note',
                        kbd: 'N',
                        onPressed: h == null ? null : _chooseNote,
                      ),
                      HaroButton(
                        key: const Key('sort-snooze'),
                        label: 'Snooze a week',
                        kbd: 'S',
                        onPressed: h == null ? null : _snooze,
                      ),
                      HaroButton(
                        key: const Key('sort-tag'),
                        label: 'Tag',
                        kbd: 'T',
                        onPressed: h == null ? null : _tag,
                      ),
                      HaroButton(
                        key: const Key('sort-discard'),
                        label: 'Discard',
                        kbd: 'D',
                        variant: HaroButtonVariant.destructive,
                        onPressed: h == null ? null : _discard,
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
