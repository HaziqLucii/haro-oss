import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../overlays/fuzzy.dart';
import '../../../../overlays/overlay.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_text_field.dart';
import 'code_tokens.dart';

/// ⌘P "go to file". Changed files rank first on an empty query; a typed query is fuzzy
/// over the whole worktree. Resolves to the picked path, or null when dismissed.
Future<String?> showQuickOpen(
  BuildContext context, {
  required List<String> changed,
  required Future<List<String>> Function() loadAll,
}) => showHaroOverlay<String>(
  context,
  width: CodeTokens.quickOpenWidth,
  child: QuickOpen(changed: changed, loadAll: loadAll),
);

/// Changed files first, then the rest, each path once.
List<String> quickOpenCandidates(List<String> changed, List<String> all) {
  final seen = <String>{};
  return [
    for (final p in [...changed, ...all])
      if (seen.add(p)) p,
  ];
}

class QuickOpen extends StatefulWidget {
  const QuickOpen({super.key, required this.changed, required this.loadAll});

  final List<String> changed;
  final Future<List<String>> Function() loadAll;

  @override
  State<QuickOpen> createState() => _QuickOpenState();
}

class _QuickOpenState extends State<QuickOpen> {
  final _controller = TextEditingController();
  final _selectedKey = GlobalKey();
  late List<String> _paths = widget.changed;
  bool _loading = true;
  String _query = '';
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final all = await widget.loadAll();
      if (!mounted) return;
      setState(() {
        _paths = quickOpenCandidates(widget.changed, all);
        _loading = false;
      });
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<FuzzyResult<String>> get _results {
    final all = fuzzyFind(_query, _paths, (p) => p);
    return all.length > CodeTokens.quickOpenMaxRows
        ? all.sublist(0, CodeTokens.quickOpenMaxRows)
        : all;
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _selected = (_selected + delta).clamp(0, count - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx);
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final selected = results.isEmpty
        ? 0
        : _selected.clamp(0, results.length - 1);

    KeyEventResult onKey(FocusNode _, KeyEvent e) {
      if (e is KeyUpEvent) return KeyEventResult.ignored;
      final key = e.logicalKey;
      if (key == LogicalKeyboardKey.arrowDown) {
        _move(1, results.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _move(-1, results.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        if (e is KeyDownEvent && results.isNotEmpty) {
          closeHaroOverlay(context, results[selected].value);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final foot = HaroText.mono(
      size: 10.5,
      color: HaroTokens.ink42,
      tracking: 0,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: HaroTokens.line12)),
          ),
          child: Focus(
            onKeyEvent: onKey,
            child: HaroTextField(
              controller: _controller,
              autofocus: true,
              bordered: false,
              mono: true,
              height: 48,
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              hintText: 'Go to file…',
              onChanged: (v) => setState(() {
                _query = v;
                _selected = 0;
              }),
            ),
          ),
        ),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: results.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: Text(
                        _loading ? 'LOADING…' : 'NO MATCHES',
                        style: CodeTokens.label(),
                      ),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(6),
                    itemCount: results.length,
                    itemBuilder: (context, i) => _Row(
                      key: i == selected ? _selectedKey : null,
                      result: results[i],
                      changed: widget.changed.contains(results[i].value),
                      selected: i == selected,
                      onHover: () => setState(() => _selected = i),
                      onTap: () => closeHaroOverlay(context, results[i].value),
                    ),
                  ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: HaroTokens.line12)),
          ),
          child: Row(
            children: [
              Text('↑↓ move', style: foot),
              const SizedBox(width: 16),
              Text('↵ open', style: foot),
              const SizedBox(width: 16),
              Text('esc close', style: foot),
            ],
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.result,
    required this.changed,
    required this.selected,
    required this.onHover,
    required this.onTap,
  });

  final FuzzyResult<String> result;
  final bool changed;
  final bool selected;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final path = result.value;
    final hit = result.positions.toSet();
    final dirEnd = path.lastIndexOf('/') + 1;
    final base = HaroText.mono(
      size: 12.5,
      color: HaroTokens.ink86,
      tracking: 0,
    );
    final spans = <InlineSpan>[];
    for (var i = 0; i < path.length; i++) {
      final inDir = i < dirEnd;
      spans.add(
        TextSpan(
          text: path[i],
          style: TextStyle(
            color: hit.contains(i)
                ? HaroTokens.ink
                : inDir
                ? HaroTokens.ink42
                : null,
            fontWeight: hit.contains(i) ? FontWeight.w700 : null,
          ),
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onHover: (_) {
        if (!selected) onHover();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Semantics(
          button: true,
          selected: selected,
          label: path,
          child: Container(
            height: CodeTokens.quickOpenRowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? HaroTokens.raised : HaroTokens.transparent,
              borderRadius: BorderRadius.circular(HaroTokens.radius),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(children: spans),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: base,
                  ),
                ),
                if (changed) ...[
                  const SizedBox(width: 10),
                  Text('CHANGED', style: CodeTokens.label(size: 10)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
