import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../overlays/overlay.dart';
import '../../overlays/toast.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../new_workspace/creation_widgets.dart';
import 'backlog_jump.dart';
import 'capture_todo_overlay.dart' show captureProjectId;

/// Cmd/Ctrl+O: find a todo, a note or a GitHub issue of the project in front of you by what it says
/// (the same operators as the Backlog filter work: `tag:ui`, `stage:red`, `in:notes`) and land on it.
Future<void> showQuickSwitcher(BuildContext context) {
  final container = ProviderScope.containerOf(context);
  final id = captureProjectId(context, container.read(workspaceStoreProvider));
  if (id == null) {
    showHaroToast(context, 'Add a project first.');
    return Future.value();
  }
  return showHaroOverlay<void>(
    context,
    width: 640,
    child: QuickSwitcher(projectId: id),
  );
}

class QuickSwitcher extends ConsumerStatefulWidget {
  const QuickSwitcher({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<QuickSwitcher> createState() => _QuickSwitcherState();
}

class _QuickSwitcherState extends ConsumerState<QuickSwitcher> {
  static const _debounce = Duration(milliseconds: 160);

  final _controller = TextEditingController();
  List<FindResult> _results = const [];
  int _selected = 0;
  int _gen = 0;
  String _resultsFor = '';
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _timer?.cancel();
    _timer = Timer(_debounce, () => _search(v));
  }

  Future<void> _search(String q) async {
    final gen = ++_gen;
    try {
      final r = await ref
          .read(haroApiProvider)
          .find(widget.projectId, q.trim());
      if (!mounted || gen != _gen) return;
      setState(() {
        _results = r;
        _resultsFor = q.trim();
        _selected = 0;
        _error = null;
      });
    } on HaroApiException catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e.message);
    }
  }

  void _move(int d) {
    if (_results.isEmpty) return;
    setState(() => _selected = (_selected + d).clamp(0, _results.length - 1));
  }

  void _go(FindResult r) {
    final id = widget.projectId;
    final router = GoRouter.of(context);
    final api = ref.read(haroApiProvider);
    closeHaroOverlay(context);
    if (r.kind == 'file') {
      // A PDF or a sheet beside the notes: opened with the system's own app, no page change.
      unawaited(api.openNoteFile(id, r.path).catchError((_) {}));
      return;
    }
    ref
        .read(backlogJumpProvider.notifier)
        .jump(
          BacklogJump(
            projectId: id,
            kind: r.kind,
            path: r.path,
            file: r.file,
            index: r.index,
            number: r.number,
          ),
        );
    router.go('/backlog?project=$id');
  }

  /// Enter on text whose search has not come back yet waits for it, so it opens what was typed
  /// and not the result of an older query.
  Future<void> _enter() async {
    final text = _controller.text.trim();
    if (_resultsFor != text) {
      _timer?.cancel();
      await _search(text);
      if (!mounted) return;
    }
    if (_results.isNotEmpty && _resultsFor == text) {
      _go(_results[_selected.clamp(0, _results.length - 1)]);
    }
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      if (e is KeyDownEvent) unawaited(_enter());
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: HaroTokens.line12)),
        ),
        child: Focus(
          onKeyEvent: _key,
          child: HaroTextField(
            key: const Key('switcher-field'),
            controller: _controller,
            autofocus: true,
            bordered: false,
            height: 52,
            fontSize: 16,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            hintText: 'Find a todo, note or issue',
            onChanged: _changed,
          ),
        ),
      ),
      Flexible(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: _error != null
              ? _Message(_error!, error: true)
              : _results.isEmpty
              ? const _Message('Nothing found.')
              : ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(6),
                  children: [
                    for (var i = 0; i < _results.length; i++)
                      _Row(
                        key: Key('switcher-row-$i'),
                        result: _results[i],
                        selected: i == _selected,
                        onHover: () => setState(() => _selected = i),
                        onTap: () => _go(_results[i]),
                      ),
                  ],
                ),
        ),
      ),
    ],
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      text,
      key: const Key('switcher-message'),
      style: HaroText.ui(
        size: 14,
        color: error ? HaroTokens.fail : HaroTokens.ink42,
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.result,
    required this.selected,
    required this.onHover,
    required this.onTap,
  });

  final FindResult result;
  final bool selected;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = [
      if (result.subtitle.isNotEmpty) result.subtitle,
      for (final t in result.tags) '#$t',
    ].join('  ');
    return MouseRegion(
      onHover: (_) => onHover(),
      child: HaroPressable(
        onTap: onTap,
        semanticLabel: result.title,
        builder: (context, hovered) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          color: selected ? HaroTokens.ink02 : HaroTokens.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: MonoCaption(result.kind.toUpperCase()),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaroText.ui(
                        size: 14,
                        color: result.done
                            ? HaroTokens.ink42
                            : HaroTokens.ink86,
                      ),
                    ),
                    if (sub.isNotEmpty)
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HaroText.mono(
                          size: 10.5,
                          color: HaroTokens.ink42,
                        ),
                      ),
                    if (result.snippet.isNotEmpty)
                      Text(
                        result.snippet,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HaroText.ui(size: 12, color: HaroTokens.ink42),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
