import 'package:flutter/widgets.dart';

import '../../../../api/models/models.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import 'verify_model.dart';

const double _size = 9;
const double _gap = 3;

/// Above this many tests the squares are painted in one pass instead of built as widgets.
const int gridPaintThreshold = 1000;

const double _passedAlpha = .7;
const double _mergedAlpha = .4;

Color _fill(SquareState s, bool dim) => switch (s) {
  SquareState.passed => HaroTokens.gate.withValues(
    alpha: dim ? _mergedAlpha : _passedAlpha,
  ),
  SquareState.failed => HaroTokens.fail,
  SquareState.running => HaroTokens.transparent,
  SquareState.skipped => HaroTokens.line30,
  SquareState.pending => HaroTokens.line12,
};

/// The live grid (spec 5.6 evidence 3): one square per ~3 tests, clustered by file. Green
/// here is the gate's own colour; a square still running is hollow ink.
class TestGrid extends StatefulWidget {
  const TestGrid({
    super.key,
    required this.cells,
    this.expectedTotal = 0,
    this.dim = false,
    this.maxWidth = 700,
    this.retried = const {},
  });

  final List<Cell> cells;

  /// `file::name` ids that passed only on the known-flaky retry: marked with a dot.
  final Set<String> retried;
  final int expectedTotal;

  /// A merged tree: the squares fade back, the result is history.
  final bool dim;
  final double maxWidth;

  @override
  State<TestGrid> createState() => _TestGridState();
}

class _TestGridState extends State<TestGrid> {
  int? _hover;

  List<GridSquare> _squares = const [];
  Object? _cellsKey;
  Object? _retriedKey;
  int _keyTotal = -1;

  List<GridSquare> get squares {
    if (!identical(_cellsKey, widget.cells) ||
        _keyTotal != widget.expectedTotal ||
        !identical(_retriedKey, widget.retried)) {
      _retriedKey = widget.retried;
      _cellsKey = widget.cells;
      _keyTotal = widget.expectedTotal;
      _squares = gridSquares(
        widget.cells,
        expectedTotal: widget.expectedTotal,
        retried: widget.retried,
      );
    }
    return _squares;
  }

  @override
  Widget build(BuildContext context) {
    final list = squares;
    final painted = widget.cells.length > gridPaintThreshold;
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth < widget.maxWidth
            ? c.maxWidth
            : widget.maxWidth;
        final layout = layoutGrid(list, width: width, size: _size, gap: _gap);
        final grid = painted
            ? CustomPaint(
                key: const ValueKey('test-grid-painter'),
                size: Size(width, layout.height),
                painter: _GridPainter(list, layout, widget.dim),
              )
            : SizedBox(
                key: const ValueKey('test-grid-squares'),
                width: width,
                height: layout.height,
                child: Stack(
                  children: [
                    for (var i = 0; i < list.length; i++)
                      Positioned(
                        left: layout.positions[i].x,
                        top: layout.positions[i].y,
                        child: _Square(list[i], widget.dim),
                      ),
                  ],
                ),
              );
        final hovered = _hover;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MouseRegion(
              onHover: (e) {
                final i = _hit(layout, e.localPosition);
                if (i != _hover) setState(() => _hover = i);
              },
              onExit: (_) {
                if (_hover != null) setState(() => _hover = null);
              },
              child: grid,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 16,
              child: Text(
                hovered != null && hovered < list.length
                    ? list[hovered].label
                    : 'one square ≈ $cellsPerSquare tests · grouped by file',
                key: const ValueKey('test-grid-caption'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HaroText.mono(
                  size: 11,
                  color: hovered != null ? HaroTokens.ink66 : HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  int? _hit(GridLayout layout, Offset p) {
    for (var i = 0; i < layout.positions.length; i++) {
      final s = layout.positions[i];
      if (p.dx >= s.x &&
          p.dx < s.x + _size + 1 &&
          p.dy >= s.y &&
          p.dy < s.y + _size + 1) {
        return i;
      }
    }
    return null;
  }
}

class _Square extends StatelessWidget {
  const _Square(this.square, this.dim);

  final GridSquare square;
  final bool dim;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: _size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: _fill(square.state, dim),
        border: square.state == SquareState.running
            ? Border.all(color: HaroTokens.ink)
            : null,
      ),
      child: square.retried
          ? Center(
              child: SizedBox.square(
                dimension: 3,
                child: DecoratedBox(
                  key: const ValueKey('retried-mark'),
                  decoration: BoxDecoration(color: HaroTokens.bg),
                ),
              ),
            )
          : null,
    ),
  );
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.squares, this.layout, this.dim);

  final List<GridSquare> squares;
  final GridLayout layout;
  final bool dim;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = HaroTokens.ink;
    for (var i = 0; i < squares.length; i++) {
      final p = layout.positions[i];
      final rect = Rect.fromLTWH(p.x, p.y, _size, _size);
      final s = squares[i].state;
      if (s == SquareState.running) {
        canvas.drawRect(rect.deflate(.5), stroke);
      } else {
        canvas.drawRect(rect, fill..color = _fill(s, dim));
        if (squares[i].retried) {
          canvas.drawRect(
            Rect.fromCenter(center: rect.center, width: 3, height: 3),
            fill..color = HaroTokens.bg,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      !identical(old.squares, squares) || old.dim != dim;
}
