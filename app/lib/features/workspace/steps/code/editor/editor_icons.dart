import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum EditorIconKind {
  close,

  /// A window split into two side-by-side panes.
  splitRight,
}

/// Icons for the editor chrome, from Lucide at the regular weight. They take the colour they
/// are given.
class EditorIcon extends StatelessWidget {
  const EditorIcon(this.kind, {super.key, required this.color, this.size = 12});

  final EditorIconKind kind;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Icon(
      switch (kind) {
        EditorIconKind.close => LucideIcons.x400,
        EditorIconKind.splitRight => LucideIcons.columns2400,
      },
      size: size,
      color: color,
    ),
  );
}
