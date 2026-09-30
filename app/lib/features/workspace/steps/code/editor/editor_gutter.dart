import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../../theme/tokens.dart';
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

  @override
  Widget build(BuildContext context) {
    final numbersW = GutterMetrics.numbers(editing.lineCount, charWidth);
    return Row(
      children: [
        SizedBox(
          width: GutterMetrics.bar + GutterMetrics.mark + numbersW,
          height: double.infinity,
          child: CustomPaint(
            painter: _GutterPainter(
              editing: editing,
              notifier: notifier,
              textStyle: textStyle,
              numbersWidth: numbersW,
              marks: marks,
              ran: ran,
            ),
          ),
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

class _GutterPainter extends CustomPainter {
  _GutterPainter({
    required this.editing,
    required this.notifier,
    required this.textStyle,
    required this.numbersWidth,
    required this.marks,
    required this.ran,
  }) : super(repaint: Listenable.merge([notifier, editing]));

  final CodeLineEditingController editing;
  final CodeIndicatorValueNotifier notifier;
  final TextStyle textStyle;
  final double numbersWidth;
  final Map<int, ChangeMark> marks;
  final Set<int> ran;

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
      if (ran.contains(lineNo)) {
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
