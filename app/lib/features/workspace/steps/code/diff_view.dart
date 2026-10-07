import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/gestures.dart' show PointerDownEvent, kPrimaryButton;
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
  const LineRowData(
    this.line,
    this.dot, {
    this.editLine = 1,
    this.survivor = false,
  });

  final DiffLine line;
  final LineDot dot;

  /// The new-file line "Edit here" opens on (see [lineFor]).
  final int editLine;

  /// A mutation run left a surviving mutant on this line of the saved file.
  final bool survivor;
}

/// What the hover label says: the gate's evidence for the line, then the action.
String editHint(LineRowData d) => d.survivor
    ? 'mutant survived · Edit here'
    : d.dot == LineDot.cold
    ? 'never ran · Edit here'
    : 'Edit here';

class NoteRowData extends DiffRowData {
  const NoteRowData(this.text);

  final String text;
}

/// Flattens one file into fixed-height rows so the list can be virtualized however large the
/// diff is. [proof] is null when the gate left no per-line data for this file.
List<DiffRowData> buildDiffRows(
  DiffFile file,
  VerifiedFile? proof, {
  Set<int> survivors = const {},
}) {
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
    for (var i = 0; i < h.lines.length; i++) {
      final l = h.lines[i];
      rows.add(
        LineRowData(
          l,
          l.kind == DiffLineKind.add ? lineDot(proof, l.newNo) : LineDot.none,
          editLine: lineFor(h, i),
          survivor: l.kind != DiffLineKind.del && survivors.contains(l.newNo),
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
  const DiffView({
    super.key,
    required this.file,
    this.proof,
    this.onEdit,
    this.survivors = const {},
  });

  final DiffFile file;
  final VerifiedFile? proof;

  /// Opens the file in the editor at a new-file line. Null leaves the diff read-only (a
  /// deleted file has nothing to edit).
  final ValueChanged<int>? onEdit;

  /// Saved-file lines that carry a surviving mutant, for the hover label.
  final Set<int> survivors;

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
    if (old.file != widget.file ||
        old.proof != widget.proof ||
        !setEquals(old.survivors, widget.survivors)) {
      _rebuild();
    }
  }

  void _rebuild() {
    _rows = buildDiffRows(
      widget.file,
      widget.proof,
      survivors: widget.survivors,
    );
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
                      onEdit: widget.onEdit,
                      hintScroll: _h,
                      hintViewport: box.maxWidth,
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
    this.onEdit,
    this.hintScroll,
    this.hintViewport = 0,
  });

  final DiffRowData data;
  final String? lang;
  final bool hasProof;
  final String codingFont;
  final bool syntaxColour;

  /// Makes line rows clickable (gutter) and double-clickable (text) to open the editor.
  final ValueChanged<int>? onEdit;

  /// The diff's horizontal scroll and viewport width, so the hover label stays in view.
  final ScrollController? hintScroll;
  final double hintViewport;

  TextStyle _t({Color color = HaroTokens.ink}) =>
      CodeTokens.diffText(codingFont, color: color);

  @override
  Widget build(BuildContext context) => switch (data) {
    HunkRowData d => _hunk(d),
    NoteRowData d => _note(d),
    LineRowData d => _line(d),
  };

  Widget _gutterCell(double width, Widget child, {VoidCallback? onTap}) {
    if (onTap == null) {
      return SelectionContainer.disabled(
        child: SizedBox(width: width, child: child),
      );
    }
    return SelectionContainer.disabled(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            height: CodeTokens.diffRowHeight,
            child: Align(
              widthFactor: 1,
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      ),
    );
  }

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
    final edit = onEdit;
    final VoidCallback? tap = edit == null ? null : () => edit(d.editLine);
    final row = Row(
      children: [
        _gutterCell(
          CodeTokens.diffMarkerCol,
          hasProof ? _marker(d.dot) : const SizedBox.shrink(),
          onTap: tap,
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
          onTap: tap,
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
          onTap: tap,
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
    );
    return ColoredBox(
      color: add
          ? HaroTokens.diffAddBg
          : del
          ? HaroTokens.diffDelBg
          : HaroTokens.transparent,
      child: edit == null
          ? row
          : _EditHint(
              text: editHint(d),
              onDoubleClick: tap!,
              scroll: hintScroll,
              viewport: hintViewport,
              child: row,
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

/// The hover label inside a fixed-extent diff row: right-aligned to the visible edge (the
/// diff scrolls sideways, so the row's own right edge may be off screen). Also reads a
/// double click on the row from raw pointer events: a double-tap recognizer would hold the
/// arena and delay the text selection's own click by its 300ms window.
class _EditHint extends StatefulWidget {
  const _EditHint({
    required this.text,
    required this.onDoubleClick,
    required this.scroll,
    required this.viewport,
    required this.child,
  });

  final String text;
  final VoidCallback onDoubleClick;
  final ScrollController? scroll;
  final double viewport;
  final Widget child;

  @override
  State<_EditHint> createState() => _EditHintState();
}

class _EditHintState extends State<_EditHint> {
  static const _window = Duration(milliseconds: 300);
  static const _slop = 6.0;

  bool _hovered = false;
  Timer? _firstClick;
  Offset _firstAt = Offset.zero;

  void _down(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    if (_firstClick?.isActive ?? false) {
      _firstClick!.cancel();
      if ((e.position - _firstAt).distance <= _slop) widget.onDoubleClick();
      return;
    }
    _firstAt = e.position;
    _firstClick = Timer(_window, () {});
  }

  @override
  void dispose() {
    _firstClick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scroll = widget.scroll;
    return Listener(
      onPointerDown: _down,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (_hovered)
              ListenableBuilder(
                listenable: scroll ?? const AlwaysStoppedAnimation(0),
                builder: (context, _) => Positioned(
                  left: scroll != null && scroll.hasClients ? scroll.offset : 0,
                  top: 0,
                  bottom: 0,
                  width: widget.viewport,
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        key: const ValueKey('diff-edit-hint'),
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        color: HaroTokens.panel,
                        child: Text(
                          widget.text,
                          maxLines: 1,
                          softWrap: false,
                          style: HaroText.mono(
                            size: 11,
                            color: HaroTokens.ink42,
                            tracking: 0,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
