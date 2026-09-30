import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../api/models/models.dart';
import '../../../../theme/display_scope.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import 'code_tokens.dart';
import 'diff_model.dart';
import 'proof.dart';
import 'syntax.dart';

sealed class DiffRowData {
  const DiffRowData();
}

class HunkRowData extends DiffRowData {
  const HunkRowData(this.range, this.section, this.badge, this.badgeKind);

  /// `@@ -a,b +c,d @@`.
  final String range;

  /// The enclosing function or class git names after the range, if any.
  final String section;
  final String? badge;
  final HunkKind? badgeKind;

  int get length => range.length + section.length + (badge?.length ?? 0) + 6;
}

class LineRowData extends DiffRowData {
  const LineRowData(this.line, this.dot);

  final DiffLine line;
  final LineDot dot;
}

class NoteRowData extends DiffRowData {
  const NoteRowData(this.text);

  final String text;
}

/// Flattens one file into fixed-height rows so the list can be virtualized however large the
/// diff is. [proof] is null when the gate left no per-line data for this file.
List<DiffRowData> buildDiffRows(DiffFile file, VerifiedFile? proof) {
  final rows = <DiffRowData>[];
  for (final h in file.hunks) {
    final hp = proof == null ? null : hunkProof(proof, h.addedLineNos);
    rows.add(
      HunkRowData(
        _hunkRange(h.header),
        h.section,
        hunkBadgeLabel(hp),
        hp?.kind,
      ),
    );
    for (final l in h.lines) {
      rows.add(
        LineRowData(
          l,
          l.kind == DiffLineKind.add ? lineDot(proof, l.newNo) : LineDot.none,
        ),
      );
      if (l.noNewline) {
        rows.add(const NoteRowData(r'\ No newline at end of file'));
      }
    }
  }
  return rows;
}

String _hunkRange(String header) {
  final end = header.indexOf('@@', 2);
  return end < 0 ? header : header.substring(0, end + 2);
}

/// The custom diff surface (§9.1): marker, line number, sign, highlighted code. Owns its
/// scrolling in both axes.
class DiffView extends StatefulWidget {
  const DiffView({super.key, required this.file, this.proof});

  final DiffFile file;
  final VerifiedFile? proof;

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  late List<DiffRowData> _rows;
  late double _contentChars;
  final _h = ScrollController();
  final _v = ScrollController();
  double _charWidth = 7.6;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(DiffView old) {
    super.didUpdateWidget(old);
    if (old.file != widget.file || old.proof != widget.proof) _rebuild();
  }

  void _rebuild() {
    _rows = buildDiffRows(widget.file, widget.proof);
    var longest = 0;
    for (final r in _rows) {
      final n = switch (r) {
        LineRowData(:final line) => line.text.length,
        final HunkRowData h => h.length,
        NoteRowData(:final text) => text.length,
      };
      longest = math.max(longest, n);
    }
    _contentChars = math.min(longest, CodeTokens.diffMaxRenderChars).toDouble();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = TextPainter(
      text: TextSpan(
        text: 'MMMMMMMMMM',
        style: CodeTokens.diffText(DisplayScope.codingFontOf(context)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _charWidth = p.width / 10;
    p.dispose();
  }

  @override
  void dispose() {
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    if (file.isBinary) return const _DiffNote('Binary file · not shown');
    if (_rows.isEmpty) return const _DiffNote('No line changes.');
    final lang = languageForPath(file.path);
    final codingFont = DisplayScope.codingFontOf(context);
    final colour = DisplayScope.syntaxColourOf(context);
    final gutter =
        CodeTokens.diffMarkerCol +
        CodeTokens.diffNumberCol +
        CodeTokens.diffSignCol;
    final contentWidth =
        gutter + CodeTokens.diffTextPad * 2 + _contentChars * _charWidth;
    return LayoutBuilder(
      builder: (context, box) {
        final width = math.max(box.maxWidth, contentWidth);
        return Scrollbar(
          controller: _v,
          notificationPredicate: (n) => n.depth == 1,
          child: Scrollbar(
            controller: _h,
            child: SingleChildScrollView(
              controller: _h,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                height: box.maxHeight,
                child: SelectionArea(
                  child: ListView.builder(
                    controller: _v,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemExtent: CodeTokens.diffRowHeight,
                    itemCount: _rows.length,
                    itemBuilder: (context, i) => DiffRow(
                      data: _rows[i],
                      lang: lang,
                      hasProof: widget.proof != null,
                      codingFont: codingFont,
                      syntaxColour: colour,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DiffNote extends StatelessWidget {
  const _DiffNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Align(
      alignment: Alignment.topLeft,
      child: Text(
        text,
        style: HaroText.mono(size: 12, color: HaroTokens.ink42, tracking: 0),
      ),
    ),
  );
}

class DiffRow extends StatelessWidget {
  const DiffRow({
    super.key,
    required this.data,
    required this.lang,
    required this.hasProof,
    this.codingFont = DisplayScope.defaultCodingFont,
    this.syntaxColour = true,
  });

  final DiffRowData data;
  final String? lang;
  final bool hasProof;
  final String codingFont;
  final bool syntaxColour;

  TextStyle _t({Color color = HaroTokens.ink}) =>
      CodeTokens.diffText(codingFont, color: color);

  @override
  Widget build(BuildContext context) => switch (data) {
    HunkRowData d => _hunk(d),
    NoteRowData d => _note(d),
    LineRowData d => _line(d),
  };

  Widget _gutterCell(double width, Widget child) => SelectionContainer.disabled(
    child: SizedBox(width: width, child: child),
  );

  Widget _hunk(HunkRowData d) {
    final badgeColor = switch (d.badgeKind) {
      HunkKind.executed => HaroTokens.gate,
      HunkKind.partial || HunkKind.unmapped => HaroTokens.ink66,
      _ => HaroTokens.ink42,
    };
    return ColoredBox(
      color: HaroTokens.panel,
      child: Row(
        children: [
          _gutterCell(CodeTokens.diffMarkerCol, const SizedBox.shrink()),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: d.range),
                  if (d.badge != null)
                    TextSpan(
                      text: '   ${d.badge}',
                      style: TextStyle(color: badgeColor),
                    ),
                  if (d.section.isNotEmpty) TextSpan(text: '   ${d.section}'),
                ],
              ),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: _t(color: HaroTokens.ink42),
            ),
          ),
        ],
      ),
    );
  }

  Widget _note(NoteRowData d) => Row(
    children: [
      _gutterCell(
        CodeTokens.diffMarkerCol +
            CodeTokens.diffNumberCol +
            CodeTokens.diffSignCol,
        const SizedBox.shrink(),
      ),
      Padding(
        padding: const EdgeInsets.only(left: CodeTokens.diffTextPad),
        child: Text(
          d.text,
          maxLines: 1,
          softWrap: false,
          style: _t(color: HaroTokens.ink42),
        ),
      ),
    ],
  );

  Widget _line(LineRowData d) {
    final l = d.line;
    final add = l.kind == DiffLineKind.add;
    final del = l.kind == DiffLineKind.del;
    final number = add || l.kind == DiffLineKind.context ? l.newNo : l.oldNo;
    final raw = l.text.length > CodeTokens.diffMaxRenderChars
        ? l.text.substring(0, CodeTokens.diffMaxRenderChars)
        : l.text;
    final textColor = del ? HaroTokens.ink66 : HaroTokens.ink;
    final span = LineHighlighter.shared.highlight(
      raw,
      lang,
      dim: del,
      colour: syntaxColour,
    );
    return ColoredBox(
      color: add
          ? HaroTokens.diffAddBg
          : del
          ? HaroTokens.diffDelBg
          : HaroTokens.transparent,
      child: Row(
        children: [
          _gutterCell(
            CodeTokens.diffMarkerCol,
            hasProof ? _marker(d.dot) : const SizedBox.shrink(),
          ),
          _gutterCell(
            CodeTokens.diffNumberCol,
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                number?.toString() ?? '',
                textAlign: TextAlign.right,
                maxLines: 1,
                style: _t(color: HaroTokens.line30),
              ),
            ),
          ),
          _gutterCell(
            CodeTokens.diffSignCol,
            Text(
              add
                  ? '+'
                  : del
                  ? '−'
                  : ' ',
              maxLines: 1,
              style: _t(
                color: add
                    ? HaroTokens.gate
                    : del
                    ? HaroTokens.fail
                    : HaroTokens.ink42,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: CodeTokens.diffTextPad),
              child: Text.rich(
                span ?? TextSpan(text: raw),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: _t(color: textColor),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _marker(LineDot dot) => switch (dot) {
    LineDot.hit => Center(
      child: Text(
        '●',
        key: const ValueKey('marker-hit'),
        style: _t(color: HaroTokens.gate).copyWith(fontSize: 9),
      ),
    ),
    LineDot.cold => Center(
      child: Text(
        '○',
        key: const ValueKey('marker-cold'),
        style: _t(color: HaroTokens.ink42).copyWith(fontSize: 9),
      ),
    ),
    LineDot.none => const SizedBox.shrink(),
  };
}
