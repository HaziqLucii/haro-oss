import 'package:flutter/widgets.dart';

import '../../../../../theme/tokens.dart';

/// The code step's icon set: stroked line art on an 18 unit grid, drawn from SVG path data
/// so the shapes are the ones in the Finalized UI. No package: [parseSvgPath] covers the
/// M L H V C Z commands (absolute and relative) that these icons use.
enum WorkbenchIcon {
  files,
  search,
  changes,
  gate,
  folder,
  folderOpen,
  file,
  chevronRight,
  chevronDown,
  newFile,
  newFolder,
  collapseAll,
  reveal,
  close,
  check,
}

sealed class _Shape {
  const _Shape();
}

class _PathShape extends _Shape {
  const _PathShape(this.d);
  final String d;
}

class _CircleShape extends _Shape {
  const _CircleShape(this.cx, this.cy, this.r);
  final double cx;
  final double cy;
  final double r;
}

class _RectShape extends _Shape {
  const _RectShape(this.x, this.y, this.w, this.h);
  final double x;
  final double y;
  final double w;
  final double h;
}

const Map<WorkbenchIcon, List<_Shape>> _shapes = {
  WorkbenchIcon.files: [
    _PathShape('M5.5 2.5h5l3 3v10h-8z'),
    _PathShape('M10.5 2.5v3h3'),
    _PathShape('M3.5 5.5v11h8'),
  ],
  WorkbenchIcon.search: [_CircleShape(8, 8, 4.5), _PathShape('M11.5 11.5l4 4')],
  WorkbenchIcon.changes: [
    _CircleShape(5, 4, 1.8),
    _CircleShape(5, 14, 1.8),
    _CircleShape(13, 6, 1.8),
    _PathShape('M5 6v6'),
    _PathShape('M13 8c0 3-4 3-7.2 4.6'),
  ],
  WorkbenchIcon.gate: [
    _RectShape(3, 3, 12, 12),
    _PathShape('M6 9.2l2.2 2.2 4-4.6'),
  ],
  WorkbenchIcon.folder: [_PathShape('M2 4.5h5l1.5 1.5H16v8.5H2z')],
  WorkbenchIcon.folderOpen: [
    _PathShape('M2 5.5h5l1.5 1.5H16v7.5H2z'),
    _PathShape('M2 8.5h14'),
  ],
  WorkbenchIcon.file: [
    _PathShape('M4.5 2h6l3 3v11h-9z'),
    _PathShape('M10.5 2v3h3'),
  ],
  WorkbenchIcon.chevronRight: [_PathShape('M7 4.5l4.5 4.5L7 13.5')],
  WorkbenchIcon.chevronDown: [_PathShape('M4.5 7l4.5 4.5L13.5 7')],
  WorkbenchIcon.newFile: [
    _PathShape('M4 2.5h6l3.5 3.5v9.5H4z'),
    _PathShape('M10 2.5V6h3.5'),
    _PathShape('M8.75 8.75v4M6.75 10.75h4'),
  ],
  WorkbenchIcon.newFolder: [
    _PathShape('M2 4.5h5l1.5 1.5H16v8.5H2z'),
    _PathShape('M9 8v4M7 10h4'),
  ],
  WorkbenchIcon.collapseAll: [_RectShape(3, 3, 12, 12), _PathShape('M6 9h6')],
  WorkbenchIcon.reveal: [_CircleShape(9, 9, 5), _CircleShape(9, 9, 1.3)],
  WorkbenchIcon.close: [_PathShape('M4.5 4.5l9 9M13.5 4.5l-9 9')],
  WorkbenchIcon.check: [_PathShape('M4 9.5l3.2 3.2 6.8-7.4')],
};

/// One icon, tinted [color]. Mitred and butt-capped: the brand has no rounded corners.
class WorkbenchIconView extends StatelessWidget {
  const WorkbenchIconView(
    this.icon, {
    super.key,
    this.size = 16,
    this.color = HaroTokens.ink66,
  });

  final WorkbenchIcon icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _IconPainter(icon, color)),
  );
}

class _IconPainter extends CustomPainter {
  const _IconPainter(this.icon, this.color);

  final WorkbenchIcon icon;
  final Color color;

  static const double _grid = 18;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / _grid;
    canvas.scale(scale);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = color
      ..strokeWidth = 1.3
      ..strokeJoin = StrokeJoin.miter;
    for (final s in _shapes[icon]!) {
      switch (s) {
        case _PathShape():
          canvas.drawPath(parseSvgPath(s.d), paint);
        case _CircleShape():
          canvas.drawCircle(Offset(s.cx, s.cy), s.r, paint);
        case _RectShape():
          canvas.drawRect(Rect.fromLTWH(s.x, s.y, s.w, s.h), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.icon != icon || old.color != color;
}

final _number = RegExp(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?');
final _token = RegExp(
  r'[MmLlHhVvCcZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?',
);

/// SVG path data to a [Path]. Supports M m L l H h V v C c Z z with implicit command
/// repeats, which is everything the icons above use; anything else throws so a typo in an
/// icon fails a test instead of drawing nothing.
Path parseSvgPath(String d) {
  final tokens = _token.allMatches(d).map((m) => m.group(0)!).toList();
  final path = Path();
  var i = 0;
  var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0;
  String? cmd;

  bool isNum(int at) => at < tokens.length && _number.hasMatch(tokens[at]);
  double num() {
    if (!isNum(i)) throw FormatException('expected a number in "$d"');
    return double.parse(tokens[i++]);
  }

  while (i < tokens.length) {
    if (!isNum(i)) {
      cmd = tokens[i++];
    } else if (cmd == null) {
      throw FormatException('path data must start with a command: "$d"');
    } else if (cmd == 'M') {
      cmd = 'L';
    } else if (cmd == 'm') {
      cmd = 'l';
    }
    final command = cmd;
    final rel = command == command.toLowerCase();
    switch (command.toUpperCase()) {
      case 'M':
        final nx = num(), ny = num();
        x = rel ? x + nx : nx;
        y = rel ? y + ny : ny;
        startX = x;
        startY = y;
        path.moveTo(x, y);
      case 'L':
        final nx = num(), ny = num();
        x = rel ? x + nx : nx;
        y = rel ? y + ny : ny;
        path.lineTo(x, y);
      case 'H':
        final nx = num();
        x = rel ? x + nx : nx;
        path.lineTo(x, y);
      case 'V':
        final ny = num();
        y = rel ? y + ny : ny;
        path.lineTo(x, y);
      case 'C':
        final x1 = num(), y1 = num(), x2 = num(), y2 = num();
        final nx = num(), ny = num();
        final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
        path.cubicTo(ox + x1, oy + y1, ox + x2, oy + y2, ox + nx, oy + ny);
        x = ox + nx;
        y = oy + ny;
      case 'Z':
        path.close();
        x = startX;
        y = startY;
      default:
        throw FormatException('unsupported path command "$cmd" in "$d"');
    }
  }
  return path;
}

/// The path data behind an icon, for tests.
List<String> workbenchIconPaths(WorkbenchIcon icon) => [
  for (final s in _shapes[icon]!)
    if (s is _PathShape) s.d,
];
