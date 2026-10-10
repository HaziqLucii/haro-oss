import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../../lsp/lsp_hover.dart';
import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';

final _identifier = RegExp(r'[A-Za-z0-9_$]+');

/// How far either side of the pointer the identifier scan looks, so a minified one-line file
/// costs the same per pointer move as a short line.
const _scanWindow = 200;

bool _wordChar(int c) =>
    c >= 0x30 && c <= 0x39 ||
    c >= 0x41 && c <= 0x5A ||
    c >= 0x61 && c <= 0x7A ||
    c == 0x5F ||
    c == 0x24;

/// The identifier of [text] that touches column [at], scanning only [_scanWindow] characters
/// either side. The window grows to whole words, so a cut never changes where the word under the
/// pointer starts.
({int start, int end})? identifierAt(String text, int at) {
  var from = (at - _scanWindow).clamp(0, text.length);
  var to = (at + _scanWindow).clamp(0, text.length);
  while (from > 0 && _wordChar(text.codeUnitAt(from - 1))) {
    from--;
  }
  while (to < text.length && _wordChar(text.codeUnitAt(to))) {
    to++;
  }
  for (final w in _identifier.allMatches(text.substring(from, to))) {
    final start = from + w.start;
    final end = from + w.end;
    if (at >= start && at <= end) return (start: start, end: end);
  }
  return null;
}

/// The identifier under [local] (a point in the text area, gutter excluded), found through the
/// paragraphs the gutter is already given: they carry each visible line's box and can turn a
/// point into a character offset, so no layout is recomputed here. Null over whitespace,
/// punctuation, past the end of a line, or a folded line.
HoverSpot? hoverSpotAt(
  CodeIndicatorValue? value,
  CodeLineEditingController editing,
  Offset local,
) {
  if (value == null) return null;
  for (final p in value.paragraphs) {
    if (!p.inVerticalRange(local)) continue;
    if (p.chunkParent || p.index >= editing.codeLines.length) return null;
    final inside = local - p.offset;
    final text = editing.codeLines[p.index].text;
    final at = p.paragraph.getPosition(inside).offset;
    final m = identifierAt(text, at);
    if (m != null) {
      final range = TextRange(start: m.start, end: m.end);
      for (final r in p.paragraph.getRangeRects(range)) {
        if (!r.contains(inside)) continue;
        return HoverSpot(
          line: editing.index2lineIndex(p.index),
          character: m.start,
          rect: r.shift(p.offset),
        );
      }
    }
    return null;
  }
  return null;
}

/// Hover tooltips over the editor: a transparent pointer listener (the editor underneath keeps
/// every event) and the tip itself. Placed over the whole editor, gutter included, so
/// [textLeft] says where the text area starts.
class LspHoverLayer extends StatefulWidget {
  const LspHoverLayer({
    super.key,
    required this.hover,
    required this.editing,
    required this.indicator,
    required this.scroll,
    required this.focus,
    required this.textLeft,
  });

  final LspHoverController hover;
  final CodeLineEditingController editing;
  final CodeIndicatorValueNotifier indicator;
  final CodeScrollController scroll;
  final FocusNode focus;
  final ValueGetter<double> textLeft;

  @override
  State<LspHoverLayer> createState() => _LspHoverLayerState();
}

class _LspHoverLayerState extends State<LspHoverLayer> {
  CodeLines? _lines;

  @override
  void initState() {
    super.initState();
    _lines = widget.editing.codeLines;
    widget.editing.addListener(_onEditing);
    widget.scroll.verticalScroller.addListener(_dismiss);
    widget.scroll.horizontalScroller.addListener(_dismiss);
    widget.focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.editing.removeListener(_onEditing);
    widget.scroll.verticalScroller.removeListener(_dismiss);
    widget.scroll.horizontalScroller.removeListener(_dismiss);
    widget.focus.removeListener(_onFocus);
    super.dispose();
  }

  void _dismiss() => widget.hover.dismiss();

  void _onFocus() {
    if (!widget.focus.hasFocus) _dismiss();
  }

  /// Cursor moves notify too; only an edit swaps the lines.
  void _onEditing() {
    if (identical(widget.editing.codeLines, _lines)) return;
    _lines = widget.editing.codeLines;
    _dismiss();
  }

  void _onHover(PointerHoverEvent e) {
    final spot = hoverSpotAt(
      widget.indicator.value,
      widget.editing,
      e.localPosition - Offset(widget.textLeft(), 0),
    );
    if (spot == null) {
      _dismiss();
    } else {
      widget.hover.rest(spot);
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _dismiss(),
    child: MouseRegion(
      opaque: false,
      onHover: _onHover,
      onExit: (_) => _dismiss(),
      child: ListenableBuilder(
        listenable: widget.hover,
        builder: (context, _) {
          final tip = widget.hover.tip;
          if (tip == null) return const SizedBox.expand();
          return LayoutBuilder(
            builder: (context, box) {
              final rect = tip.spot.rect.shift(Offset(widget.textLeft(), 0));
              final at = placeTip(rect, box.biggest);
              return Stack(
                children: [
                  Positioned(
                    left: at.left,
                    top: at.top,
                    bottom: at.bottom,
                    child: IgnorePointer(child: _Tip(tip.text)),
                  ),
                ],
              );
            },
          );
        },
      ),
    ),
  );
}

class _Tip extends StatelessWidget {
  const _Tip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    key: const ValueKey('lsp-hover-tip'),
    constraints: const BoxConstraints(maxWidth: 480, maxHeight: 160),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: HaroTokens.raised,
        border: Border.all(color: HaroTokens.line30),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: ClipRect(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Text(
            text,
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: HaroText.mono(
              size: 12,
              color: HaroTokens.ink86,
              tracking: 0,
              height: 1.4,
            ),
          ),
        ),
      ),
    ),
  );
}
