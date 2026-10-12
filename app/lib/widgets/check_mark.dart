import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A passed check: Lucide's tick in the status square's footprint, so a checklist row lines up
/// with the rows that still show a square. A touch heavier than the other icons, since it is
/// small.
class CheckMark extends StatelessWidget {
  const CheckMark({super.key, required this.color, this.size = 12});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Icon(LucideIcons.check500, size: size, color: color),
  );
}
