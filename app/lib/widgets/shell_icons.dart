import 'package:flutter/widgets.dart';

import '../features/workspace/steps/code/workbench/workbench_icons.dart'
    show parseSvgPath;
import '../theme/tokens.dart';
import 'haro_pressable.dart';

/// Stroke icons for the window chrome (top bar, strips, focus mode, status bar), drawn from
/// SVG path data on an 18 unit grid with the same mitred, butt-capped stroke as the code
/// step's icons. The Finalized UI's glyph arrows and chevrons become these.
enum ShellIcon {
  menu,

  /// A panel with its divider on the right: the right rail.
  panelRight,
  chevronsRight,
  chevronsLeft,
  expand,
  shrink,
  terminal,
  plus,
  branch,
  close,
  person,
}

const Map<ShellIcon, List<String>> _paths = {
  ShellIcon.menu: ['M3 5h12M3 9h12M3 13h12'],
  ShellIcon.panelRight: ['M2.5 3.5h13v11h-13z', 'M11.5 3.5v11'],
  ShellIcon.chevronsRight: ['M4.5 4.5L9 9l-4.5 4.5', 'M9.5 4.5L14 9l-4.5 4.5'],
  ShellIcon.chevronsLeft: ['M13.5 4.5L9 9l4.5 4.5', 'M8.5 4.5L4 9l4.5 4.5'],
  ShellIcon.expand: [
    'M10.5 3.5h4v4',
    'M14.5 3.5l-4.5 4.5',
    'M7.5 14.5h-4v-4',
    'M3.5 14.5l4.5-4.5',
  ],
  ShellIcon.shrink: [
    'M14.5 7.5h-4v-4',
    'M10.5 7.5l4-4',
    'M3.5 10.5h4v4',
    'M7.5 10.5l-4 4',
  ],
  ShellIcon.terminal: ['M3 5l4 4-4 4', 'M9 14h6'],
  ShellIcon.plus: ['M9 3.5v11M3.5 9h11'],
  ShellIcon.close: ['M4.5 4.5l9 9', 'M13.5 4.5l-9 9'],
  ShellIcon.branch: ['M5 6v6', 'M13 8c0 3-4 3-7.2 4.6'],
  ShellIcon.person: [
    'M3.8 15.5c0-2.4 1.6-4.6 5.2-4.6',
    'M9 10.9c3.6 0 5.2 2.2 5.2 4.6',
  ],
};

const Map<ShellIcon, List<(double, double, double)>> _circles = {
  ShellIcon.branch: [(5, 4, 1.8), (5, 14, 1.8), (13, 6, 1.8)],
  ShellIcon.person: [(9, 6.4, 2.7)],
};

/// The path data behind an icon, for tests.
List<String> shellIconPaths(ShellIcon icon) => _paths[icon]!;

class ShellIconView extends StatelessWidget {
  const ShellIconView(
    this.icon, {
    super.key,
    this.size = 16,
    this.color = HaroTokens.ink66,
  });

  final ShellIcon icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _Painter(icon, color)),
  );
}

/// A square icon button: raised fill on hover, ink at rest [dim] or lit [on].
class ShellIconButton extends StatelessWidget {
  const ShellIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.width = 28,
    this.height = 28,
    this.iconSize = 16,
    this.on = false,
  });

  final ShellIcon icon;
  final String tooltip;
  final VoidCallback onTap;
  final double width;
  final double height;
  final double iconSize;

  /// Lit: the thing it toggles is showing.
  final bool on;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: tooltip,
    semanticLabel: tooltip,
    builder: (context, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: hovered ? HaroTokens.raised : HaroTokens.transparent,
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: ShellIconView(
        icon,
        size: iconSize,
        color: hovered || on ? HaroTokens.ink : HaroTokens.ink66,
      ),
    ),
  );
}

class _Painter extends CustomPainter {
  const _Painter(this.icon, this.color);

  final ShellIcon icon;
  final Color color;

  static const double _grid = 18;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / _grid);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = color
      ..strokeWidth = 1.3
      ..strokeJoin = StrokeJoin.miter;
    for (final d in _paths[icon]!) {
      canvas.drawPath(parseSvgPath(d), paint);
    }
    for (final (cx, cy, r)
        in _circles[icon] ?? const <(double, double, double)>[]) {
      canvas.drawCircle(Offset(cx, cy), r, paint);
    }
  }

  @override
  bool shouldRepaint(_Painter old) => old.icon != icon || old.color != color;
}
