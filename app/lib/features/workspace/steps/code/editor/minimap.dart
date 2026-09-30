import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../../theme/tokens.dart';
import 'editor_marks.dart';
import 'minimap_math.dart';

abstract final class MinimapTokens {
  static const double width = 92;
  static const double padX = 8;
  static const double padY = 10;
}

/// Overview of the file on the editor's right edge: one thin bar per line (added lines tinted
/// as the gate's colour), a box for the visible part, click or drag to scroll.
class Minimap extends StatefulWidget {
  const Minimap({
    super.key,
    required this.controller,
    required this.scroll,
    required this.added,
  });

  final CodeLineEditingController controller;
  final ScrollController scroll;

  /// 1-based numbers of the lines to tint (added lines of the saved text).
  final Set<int> added;

  @override
  State<Minimap> createState() => _MinimapState();
}

class _MinimapState extends State<Minimap> {
  List<double> _widths = const [];
  List<double> _indents = const [];
  int _lines = 0;
  bool _stale = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    widget.scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(Minimap old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
      _stale = true;
    }
    if (old.scroll != widget.scroll) {
      old.scroll.removeListener(_onScroll);
      widget.scroll.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    widget.scroll.removeListener(_onScroll);
    super.dispose();
  }

  void _onText() {
    _stale = true;
    _refresh();
  }

  void _onScroll() => _refresh();

  /// The controller notifies from `CodeEditor.initState`, which is mid-build.
  void _refresh() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  void _measure() {
    if (!_stale) return;
    _stale = false;
    final lines = widget.controller.codeLines;
    _lines = lines.length;
    _widths = List.filled(_lines, 0);
    _indents = List.filled(_lines, 0);
    for (var i = 0; i < _lines; i++) {
      final t = lines[i].text;
      final bar = minimapBar(
        t,
        maxWidth: MinimapTokens.width - MinimapTokens.padX * 2,
        indentColumns: leadingColumns(t),
      );
      _widths[i] = bar.width;
      _indents[i] = bar.indent;
    }
  }

  MinimapGeometry _geometry(double height) {
    final s = widget.scroll;
    final pos = s.hasClients && s.position.hasContentDimensions
        ? s.position
        : null;
    final viewport = pos?.viewportDimension ?? 0;
    final content = pos == null ? 0.0 : pos.maxScrollExtent + viewport;
    return MinimapGeometry(
      lineCount: _lines,
      trackHeight: math.max(0, height - MinimapTokens.padY * 2),
      contentHeight: content,
      viewportHeight: viewport,
      scrollOffset: pos?.pixels ?? 0,
    );
  }

  void _scrollTo(double dy, double height) {
    final s = widget.scroll;
    if (!s.hasClients) return;
    final g = _geometry(height);
    s.jumpTo(g.scrollFor(dy - MinimapTokens.padY).clamp(0, g.maxScroll));
  }

  @override
  Widget build(BuildContext context) {
    _measure();
    return SizedBox(
      width: MinimapTokens.width,
      child: LayoutBuilder(
        builder: (context, box) {
          final g = _geometry(box.maxHeight);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _scrollTo(d.localPosition.dy, box.maxHeight),
            onVerticalDragStart: (d) =>
                _scrollTo(d.localPosition.dy, box.maxHeight),
            onVerticalDragUpdate: (d) =>
                _scrollTo(d.localPosition.dy, box.maxHeight),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: HaroTokens.line08)),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        key: const ValueKey('minimap-lines'),
                        painter: _LinesPainter(
                          widths: _widths,
                          indents: _indents,
                          added: widget.added,
                          mapHeight: g.mapHeight,
                        ),
                      ),
                    ),
                  ),
                  if (g.scrollable)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: MinimapTokens.padY + g.viewportBox.top,
                      height: g.viewportBox.height,
                      child: const DecoratedBox(
                        key: ValueKey('minimap-viewport'),
                        decoration: BoxDecoration(
                          color: HaroTokens.line08,
                          border: Border.symmetric(
                            horizontal: BorderSide(color: HaroTokens.line12),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LinesPainter extends CustomPainter {
  _LinesPainter({
    required this.widths,
    required this.indents,
    required this.added,
    required this.mapHeight,
  });

  final List<double> widths;
  final List<double> indents;
  final Set<int> added;
  final double mapHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final n = widths.length;
    if (n == 0 || mapHeight <= 0) return;
    final per = linesPerBucket(n, mapHeight);
    final plain = Paint()..color = HaroTokens.line20;
    final tinted = Paint()..color = HaroTokens.gate.withValues(alpha: .6);
    final rows = (n / per).ceil();
    for (var r = 0; r < rows; r++) {
      var best = -1;
      var w = 0.0;
      var hit = false;
      final end = math.min(n, (r + 1) * per);
      for (var i = r * per; i < end; i++) {
        if (added.contains(i + 1)) hit = true;
        if (widths[i] > w) {
          w = widths[i];
          best = i;
        }
      }
      if (best < 0 && !hit) continue;
      final indent = best < 0 ? 0.0 : indents[best];
      final y = MinimapTokens.padY + r * minimapRowPitch;
      canvas.drawRect(
        Rect.fromLTWH(
          MinimapTokens.padX + indent,
          y,
          math.max(2, w),
          math.min(2, mapHeight / rows),
        ),
        hit ? tinted : plain,
      );
    }
  }

  @override
  bool shouldRepaint(_LinesPainter old) =>
      old.widths != widths ||
      old.indents != indents ||
      old.added != added ||
      old.mapHeight != mapHeight;
}
