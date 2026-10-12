/// The arithmetic of the minimap, apart from any widget: where the viewport box sits on the
/// map and what a click or drag on the map scrolls to. The map always shows the whole file, so
/// a position on it is a fraction of the file's scrollable height.
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

/// Pixels one source line takes on the map (a 2px bar and a 1px gap).
const double minimapRowPitch = 3;

/// The smallest the viewport box is drawn, so it stays grabbable on a huge file.
const double minimapMinBox = 10;

class MinimapGeometry {
  const MinimapGeometry({
    required this.lineCount,
    required this.trackHeight,
    required this.contentHeight,
    required this.viewportHeight,
    required this.scrollOffset,
  });

  final int lineCount;

  /// Height available to the map, in pixels.
  final double trackHeight;

  /// Full scrollable height of the editor (viewport included).
  final double contentHeight;
  final double viewportHeight;
  final double scrollOffset;

  /// The map's own height: the file at [minimapRowPitch] per line, squeezed to fit the track.
  double get mapHeight =>
      math.min(trackHeight, math.max(1, lineCount) * minimapRowPitch);

  double get maxScroll => math.max(0, contentHeight - viewportHeight);

  /// Whether there is anything to scroll; without it the box would cover the whole map.
  bool get scrollable => maxScroll > 0.5;

  /// The viewport box on the map.
  Rect get viewportBox {
    if (contentHeight <= 0) return Rect.zero;
    final h = math.min(
      mapHeight,
      math.max(minimapMinBox, viewportHeight / contentHeight * mapHeight),
    );
    final travel = mapHeight - h;
    final t = maxScroll <= 0 ? 0.0 : (scrollOffset / maxScroll).clamp(0.0, 1.0);
    return Rect.fromLTWH(0, travel * t, 0, h);
  }

  /// The scroll offset that puts the box's centre on map position [dy]. Clicking or dragging on
  /// the map centres the viewport there, as in VS Code.
  double scrollFor(double dy) {
    if (maxScroll <= 0) return 0;
    final box = viewportBox;
    final travel = mapHeight - box.height;
    if (travel <= 0) return 0;
    final t = ((dy - box.height / 2) / travel).clamp(0.0, 1.0);
    return t * maxScroll;
  }

  /// Source line (0-based) shown at map position [dy]; used to draw the right row per bucket.
  int lineAt(double dy) {
    if (lineCount <= 1 || mapHeight <= 0) return 0;
    final f = (dy / mapHeight).clamp(0.0, 1.0);
    return math.min(lineCount - 1, (f * lineCount).floor());
  }
}

/// How many source lines share one row of pixels on a map of [mapHeight]: 1 until the file is
/// taller than the track, then the ratio rounded up.
int linesPerBucket(int lineCount, double mapHeight) {
  final rows = math.max(1, (mapHeight / minimapRowPitch).floor());
  return math.max(1, (lineCount / rows).ceil());
}

/// A bar for a source line: its width (0..[maxWidth]) from the trimmed text length, and its left
/// indent, both scaled so a typical line fills a little under half the map.
({double width, double indent}) minimapBar(
  String line, {
  double maxWidth = 76,
  int indentColumns = 0,
}) {
  final text = line.trim();
  if (text.isEmpty) return (width: 0, indent: 0);
  final width = math.min(maxWidth * .72, math.max(2.0, text.length * .9));
  final indent = math.min(20.0, indentColumns * 1.2);
  return (width: width, indent: indent);
}
