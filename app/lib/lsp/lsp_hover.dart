import 'dart:async';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';

import 'lsp_client.dart';

const _maxChars = 800;

/// The signature a `textDocument/hover` result should show: its first content item, as plain
/// text. A fenced block (what typescript-language-server sends first) is shown without the
/// fences; prose falls back to its first paragraph. Null when there is nothing to show.
String? hoverText(Object? raw) {
  final contents = raw is Map ? raw['contents'] : null;
  final items = contents is List ? contents : [contents];
  for (final item in items) {
    final text = _itemText(item);
    if (text != null) return text;
  }
  return null;
}

String? _itemText(Object? item) {
  String value;
  if (item is String) {
    value = item;
  } else if (item is Map && item['value'] is String) {
    value = item['value'] as String;
    // A MarkedString with a language is code already.
    if (item['language'] is String) return _clean(value);
  } else {
    return null;
  }
  final fence = RegExp(r'```[^\n]*\n([\s\S]*?)(?:\n?```|$)').firstMatch(value);
  if (fence != null) return _clean(fence.group(1)!);
  final paragraph = value
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.replaceAll('`', '').trim())
      .firstWhere((p) => p.isNotEmpty && p != '---', orElse: () => '');
  return _clean(paragraph);
}

String? _clean(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  return t.length > _maxChars ? '${t.substring(0, _maxChars)}...' : t;
}

/// The word under a pointer: [line] and [character] are the 0-based start of the word the
/// server is asked about, [rect] is the word's box in the editor's coordinates.
@immutable
class HoverSpot {
  const HoverSpot({
    required this.line,
    required this.character,
    required this.rect,
  });

  final int line;
  final int character;
  final Rect rect;

  bool sameWord(HoverSpot o) => o.line == line && o.character == character;
}

@immutable
class HoverTip {
  const HoverTip(this.text, this.spot);

  final String text;
  final HoverSpot spot;
}

/// Pointer rest to tooltip: [rest] is called on every pointer move over a word and asks the
/// server once the pointer has stayed on that word for [delay]; [dismiss] clears everything. An
/// answer that arrives after the pointer left (or the buffer changed) is dropped.
class LspHoverController extends ChangeNotifier {
  LspHoverController({
    required this.client,
    required this.uri,
    this.delay = const Duration(milliseconds: 400),
  });

  final LspClient client;
  final String uri;
  final Duration delay;

  HoverTip? _tip;
  HoverSpot? _spot;
  Timer? _timer;
  int _ticket = 0;
  bool _disposed = false;

  HoverTip? get tip => _tip;

  void rest(HoverSpot spot) {
    final current = _spot;
    if (current != null && current.sameWord(spot)) return;
    dismiss();
    _spot = spot;
    final ticket = _ticket;
    _timer = Timer(delay, () => _ask(spot, ticket));
  }

  Future<void> _ask(HoverSpot spot, int ticket) async {
    _timer = null;
    final text = hoverText(await client.hover(uri, spot.line, spot.character));
    if (_disposed || ticket != _ticket || text == null) return;
    _tip = HoverTip(text, spot);
    notifyListeners();
  }

  void dismiss() {
    _ticket++;
    _timer?.cancel();
    _timer = null;
    _spot = null;
    if (_tip == null) return;
    _tip = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Where the tip's top-left goes inside an editor of [size]: under the word, or above it when
/// the word sits in the lower part of the view.
({double left, double? top, double? bottom}) placeTip(
  Rect word,
  Size size, {
  double maxWidth = 480,
}) => (
  left: word.left
      .clamp(0, (size.width - maxWidth).clamp(0, double.infinity))
      .toDouble(),
  top: word.bottom > size.height * .6 ? null : word.bottom + 2,
  bottom: word.bottom > size.height * .6 ? size.height - word.top + 2 : null,
);
