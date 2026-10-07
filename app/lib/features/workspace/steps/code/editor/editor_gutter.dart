import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../proof_marks.dart';
import 'editor_marks.dart';

/// Sizes of the gutter columns: a change bar, a column for the "line ran" dot, the numbers,
/// then re_editor's own fold arrow.
abstract final class GutterMetrics {
  static const double bar = 3;
  static const double mark = 18;
  static const double numberPadRight = 16;
  static const double fold = 18;
  static const int minDigits = 3;

  /// Width of the line-number column for a file of [lineCount] lines in a font whose digit is
  /// [charWidth] wide.
  static double numbers(int lineCount, double charWidth) =>
      math.max(minDigits, '$lineCount'.length) * charWidth + numberPadRight;

  /// Everything left of the text, without the 1px divider.
  static double total(int lineCount, double charWidth) =>
      bar + mark + numbers(lineCount, charWidth) + fold;
}

/// Width of one digit of the editor's monospace face at [style].
double measureCharWidth(TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(text: '0', style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

/// The gutter: change bar, "line ran" dot, line number, fold arrow. Built on re_editor's
/// indicator hook so it scrolls with the text and follows folds.
class EditorGutter extends StatelessWidget {
  const EditorGutter({
    super.key,
    required this.editing,
    required this.chunks,
    required this.notifier,
    required this.textStyle,
    required this.charWidth,
    required this.marks,
    required this.ran,
    this.proof = const {},
    this.onProofTap,
  });

  final CodeLineEditingController editing;
  final CodeChunkController chunks;
  final CodeIndicatorValueNotifier notifier;
  final TextStyle textStyle;
  final double charWidth;

  /// Change marks and ran-lines for the SAVED text. They are passed empty while the buffer has
  /// unsaved edits, since line numbers no longer line up with the diff.
  final Map<int, ChangeMark> marks;
  final Set<int> ran;

  /// What the gate knows about saved lines (surviving mutants, needs-your-eyes), by line.
  /// Passed empty with [marks] while the buffer is dirty.
  final Map<int, List<ProofMark>> proof;

  /// A click on a marked line (1-based): the Problems tab opens at that line.
  final ValueChanged<int>? onProofTap;

  @override
  Widget build(BuildContext context) {
    final numbersW = GutterMetrics.numbers(editing.lineCount, charWidth);
    final width = GutterMetrics.bar + GutterMetrics.mark + numbersW;
    final painted = SizedBox(
      width: width,
      height: double.infinity,
      child: CustomPaint(
        painter: _GutterPainter(
          editing: editing,
          notifier: notifier,
          textStyle: textStyle,
          numbersWidth: numbersW,
          marks: marks,
          ran: ran,
          proof: proof,
        ),
      ),
    );
    return Row(
      children: [
        if (proof.isEmpty)
          painted
        else
          _ProofHover(
            editing: editing,
            notifier: notifier,
            proof: proof,
            width: width,
            onTap: onProofTap,
            child: painted,
          ),
        DefaultCodeChunkIndicator(
          width: GutterMetrics.fold,
          controller: chunks,
          notifier: notifier,
          painter: DefaultCodeChunkIndicatorPainter(
            color: HaroTokens.ink42,
            size: const Size(6, 6),
          ),
        ),
      ],
    );
  }
}

const double proofMarkSize = 7;

/// The line number and its paragraph under [dy] in the gutter, or null below the last line.
({int line, CodeLineRenderParagraph paragraph})? gutterLineAt(
  CodeLineEditingController editing,
  CodeIndicatorValue? value,
  double dy,
) {
  if (value == null || value.paragraphs.isEmpty) return null;
  var lineNo = editing.index2lineIndex(value.paragraphs.first.index) + 1;
  for (final p in value.paragraphs) {
    if (dy >= p.offset.dy && dy < p.offset.dy + p.height) {
      return (line: lineNo, paragraph: p);
    }
    lineNo += editing.codeLines[p.index].lineCount;
  }
  return null;
}

/// Hover and click on the gutter's mark column: a small label to the right naming what the
/// gate found on the line, and a click that opens the Problems tab. A real overlay, not a
/// Material tooltip.
class _ProofHover extends StatefulWidget {
  const _ProofHover({
    required this.editing,
    required this.notifier,
    required this.proof,
    required this.width,
    required this.onTap,
    required this.child,
  });

  final CodeLineEditingController editing;
  final CodeIndicatorValueNotifier notifier;
  final Map<int, List<ProofMark>> proof;
  final double width;
  final ValueChanged<int>? onTap;
  final Widget child;

  @override
  State<_ProofHover> createState() => _ProofHoverState();
}

class _ProofHoverState extends State<_ProofHover> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  List<ProofMark>? _marks;
  double _top = 0;

  int _line = 0;

  List<ProofMark>? _marksAt(Offset local) {
    if (local.dx >= GutterMetrics.bar + GutterMetrics.mark) return null;
    final hit = gutterLineAt(widget.editing, widget.notifier.value, local.dy);
    if (hit == null) return null;
    final marks = widget.proof[hit.line];
    if (marks == null) return null;
    _top = hit.paragraph.offset.dy + hit.paragraph.preferredLineHeight / 2;
    _line = hit.line;
    return marks;
  }

  void _hover(Offset local) {
    final marks = _marksAt(local);
    if (marks == null) return _leave();
    setState(() => _marks = marks);
    if (!_portal.isShowing) _portal.show();
  }

  void _leave() {
    if (_marks == null) return;
    setState(() => _marks = null);
    if (_portal.isShowing) _portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    final marks = _marks;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) {
        final m = _marks;
        if (m == null) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            followerAnchor: Alignment.centerLeft,
            offset: Offset(widget.width + 4, _top),
            child: IgnorePointer(
              child: Container(
                key: const ValueKey('gutter-proof-label'),
                constraints: const BoxConstraints(maxWidth: 560),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: HaroTokens.raised,
                  border: Border.all(color: HaroTokens.line20),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  m.map((x) => x.text).join('  '),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.mono(
                    size: 10,
                    color: HaroTokens.ink86,
                    tracking: .12,
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: GestureDetector(
        key: const ValueKey('gutter-proof-hit'),
        behavior: HitTestBehavior.translucent,
        onTapUp: (d) {
          if (_marksAt(d.localPosition) != null) widget.onTap?.call(_line);
        },
        child: MouseRegion(
          cursor: marks == null ? MouseCursor.defer : SystemMouseCursors.click,
          onHover: (e) => _hover(e.localPosition),
          onExit: (_) => _leave(),
          child: CompositedTransformTarget(link: _link, child: widget.child),
        ),
      ),
    );
  }
}

class _GutterPainter extends CustomPainter {
  _GutterPainter({
    required this.editing,
    required this.notifier,
    required this.textStyle,
    required this.numbersWidth,
    required this.marks,
    required this.ran,
    required this.proof,
  }) : super(repaint: Listenable.merge([notifier, editing]));

  final CodeLineEditingController editing;
  final CodeIndicatorValueNotifier notifier;
  final TextStyle textStyle;
  final double numbersWidth;
  final Map<int, ChangeMark> marks;
  final Set<int> ran;
  final Map<int, List<ProofMark>> proof;

  @override
  void paint(Canvas canvas, Size size) {
    final value = notifier.value;
    if (value == null || value.paragraphs.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final bar = Paint();
    final dot = Paint()..color = HaroTokens.gate;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    var lineNo = editing.index2lineIndex(value.paragraphs.first.index) + 1;
    for (final p in value.paragraphs) {
      final top = p.offset.dy;
      final mark = marks[lineNo];
      if (mark != null) {
        bar.color = mark == ChangeMark.added ? HaroTokens.gate : HaroTokens.ink;
        canvas.drawRect(
          Rect.fromLTWH(0, top, GutterMetrics.bar, p.height),
          bar,
        );
      }
      final proofHere = proof[lineNo];
      if (proofHere != null) {
        // A survivor implies the line ran, so the mark takes the dot's place.
        canvas.save();
        canvas.translate(
          GutterMetrics.bar + GutterMetrics.mark / 2 - proofMarkSize / 2,
          top + p.preferredLineHeight / 2 - proofMarkSize / 2,
        );
        ProofMarkPainter(
          kindOfLine(proofHere),
          color: proofMarkColor(proofHere),
        ).paint(canvas, const Size.square(proofMarkSize));
        canvas.restore();
      } else if (ran.contains(lineNo)) {
        canvas.drawCircle(
          Offset(
            GutterMetrics.bar + GutterMetrics.mark / 2,
            top + p.preferredLineHeight / 2,
          ),
          2,
          dot,
        );
      }
      final focused = p.index == value.focusedIndex;
      tp
        ..text = TextSpan(
          text: '$lineNo',
          style: textStyle.copyWith(
            color: focused ? HaroTokens.ink : HaroTokens.ink42,
          ),
        )
        ..layout();
      tp.paint(
        canvas,
        Offset(
          GutterMetrics.bar +
              GutterMetrics.mark +
              numbersWidth -
              GutterMetrics.numberPadRight -
              tp.width,
          top,
        ),
      );
      lineNo += editing.codeLines[p.index].lineCount;
    }
    tp.dispose();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GutterPainter old) =>
      old.marks != marks ||
      old.ran != ran ||
      old.proof != proof ||
      old.numbersWidth != numbersWidth ||
      old.textStyle != textStyle;
}

/// Faint vertical lines at each indent level inside the text, drawn over the editor. It reads
/// the same visible-line list as the gutter so folds and scrolling stay in step.
class IndentGuides extends StatelessWidget {
  const IndentGuides({
    super.key,
    required this.editing,
    required this.notifier,
    required this.scroll,
    required this.charWidth,
    required this.textLeft,
    required this.unit,
  });

  final CodeLineEditingController editing;
  final CodeIndicatorValueNotifier notifier;
  final ScrollController scroll;
  final double charWidth;

  /// x of the first text column, from the editor's left edge.
  final double textLeft;
  final int unit;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _GuidePainter(
        editing: editing,
        notifier: notifier,
        scroll: scroll,
        charWidth: charWidth,
        textLeft: textLeft,
        unit: unit,
      ),
      size: Size.infinite,
    ),
  );
}

class _GuidePainter extends CustomPainter {
  _GuidePainter({
    required this.editing,
    required this.notifier,
    required this.scroll,
    required this.charWidth,
    required this.textLeft,
    required this.unit,
  }) : super(repaint: Listenable.merge([notifier, scroll]));

  final CodeLineEditingController editing;
  final CodeIndicatorValueNotifier notifier;
  final ScrollController scroll;
  final double charWidth;
  final double textLeft;
  final int unit;

  @override
  void paint(Canvas canvas, Size size) {
    final value = notifier.value;
    if (value == null || value.paragraphs.isEmpty) return;
    final dx = scroll.hasClients ? scroll.offset : 0.0;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(textLeft, 0, size.width - textLeft, size.height),
    );
    final paint = Paint()
      ..color = HaroTokens.line08
      ..strokeWidth = 1;
    for (final p in value.paragraphs) {
      final text = editing.codeLines[p.index].text;
      if (text.trim().isEmpty) continue;
      for (final col in guideColumns(leadingColumns(text), unit)) {
        final x = (textLeft + col * charWidth - dx).floorToDouble() + .5;
        canvas.drawLine(
          Offset(x, p.offset.dy),
          Offset(x, p.offset.dy + p.height),
          paint,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GuidePainter old) =>
      old.charWidth != charWidth ||
      old.textLeft != textLeft ||
      old.unit != unit ||
      old.editing != editing;
}
