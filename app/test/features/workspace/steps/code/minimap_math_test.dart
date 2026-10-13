import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/code/editor/minimap_math.dart';

MinimapGeometry geo({
  int lines = 100,
  double track = 400,
  double content = 2000,
  double viewport = 500,
  double offset = 0,
}) => MinimapGeometry(
  lineCount: lines,
  trackHeight: track,
  contentHeight: content,
  viewportHeight: viewport,
  scrollOffset: offset,
);

void main() {
  group('map size', () {
    test('a short file is drawn at natural size, three pixels a line', () {
      expect(geo(lines: 40, track: 400).mapHeight, 120);
    });

    test('a long file is squeezed to the track', () {
      expect(geo(lines: 5000, track: 400).mapHeight, 400);
    });
  });

  group('viewport box', () {
    test('at the top it starts at zero and is the visible fraction', () {
      final g = geo(lines: 200, track: 400, content: 2000, viewport: 500);
      final box = g.viewportBox;
      expect(box.top, 0);
      expect(box.height, closeTo(400 * 500 / 2000, .001));
    });

    test('at the bottom it ends at the map end', () {
      final g = geo(
        lines: 200,
        track: 400,
        content: 2000,
        viewport: 500,
        offset: 1500,
      );
      expect(g.viewportBox.bottom, closeTo(g.mapHeight, .001));
    });

    test('halfway scrolled it sits halfway along its travel', () {
      final g = geo(
        lines: 200,
        track: 400,
        content: 2000,
        viewport: 500,
        offset: 750,
      );
      final box = g.viewportBox;
      expect(box.top, closeTo((g.mapHeight - box.height) / 2, .001));
    });

    test('never smaller than the grab size on a huge file', () {
      final g = geo(lines: 100000, track: 400, content: 2e6, viewport: 500);
      expect(g.viewportBox.height, minimapMinBox);
    });

    test('a file that fits has nothing to scroll', () {
      final g = geo(lines: 10, content: 300, viewport: 500);
      expect(g.scrollable, isFalse);
      expect(g.maxScroll, 0);
      expect(g.viewportBox.top, 0);
    });
  });

  group('click and drag', () {
    test('clicking the top scrolls to the top, the bottom to the end', () {
      final g = geo(lines: 200, track: 400, content: 2000, viewport: 500);
      expect(g.scrollFor(0), 0);
      expect(g.scrollFor(g.mapHeight), g.maxScroll);
    });

    test('clicking centres the viewport on the point', () {
      final g = geo(lines: 200, track: 400, content: 2000, viewport: 500);
      final box = g.viewportBox;
      final target = g.mapHeight / 2;
      final offset = g.scrollFor(target);
      final placed = geo(
        lines: 200,
        track: 400,
        content: 2000,
        viewport: 500,
        offset: offset,
      ).viewportBox;
      expect(placed.center.dy, closeTo(target, .5));
      expect(placed.height, box.height);
    });

    test('a drag past either end clamps', () {
      final g = geo(lines: 200, track: 400, content: 2000, viewport: 500);
      expect(g.scrollFor(-50), 0);
      expect(g.scrollFor(9999), g.maxScroll);
    });

    test('nothing to scroll returns zero', () {
      expect(geo(content: 300, viewport: 500).scrollFor(80), 0);
    });
  });

  group('rows', () {
    test('lines map to their own row until the file outgrows the track', () {
      expect(linesPerBucket(50, 300), 1);
      expect(linesPerBucket(100, 300), 1);
      expect(linesPerBucket(1000, 300), 10);
    });

    test('lineAt maps a point on the map back to a source line', () {
      final g = geo(lines: 1000, track: 300);
      expect(g.lineAt(0), 0);
      expect(g.lineAt(150), 500);
      expect(g.lineAt(400), 999);
    });
  });

  group('bars', () {
    test('blank lines draw nothing', () {
      expect(minimapBar('   ').width, 0);
    });

    test('width follows text length and is capped', () {
      final short = minimapBar('ab').width;
      final long = minimapBar('x' * 500).width;
      expect(short, lessThan(long));
      expect(long, lessThanOrEqualTo(76 * .72));
    });

    test('indent shifts the bar right and is capped', () {
      expect(minimapBar('a', indentColumns: 4).indent, closeTo(4.8, .001));
      expect(minimapBar('a', indentColumns: 100).indent, 20);
    });
  });
}
