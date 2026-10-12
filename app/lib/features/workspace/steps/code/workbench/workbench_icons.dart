import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../theme/tokens.dart';

/// The code step's icon set, mapped to Lucide in [WorkbenchIconView].
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

/// One icon, tinted [color]: Lucide at the regular weight (the hand-drawn outlines showed their
/// steps on a 1x screen).
class WorkbenchIconView extends StatelessWidget {
  WorkbenchIconView(this.icon, {super.key, this.size = 16, Color? color})
    : color = color ?? HaroTokens.ink66;

  final WorkbenchIcon icon;
  final double size;
  final Color color;

  static IconData lucide(WorkbenchIcon icon) => switch (icon) {
    WorkbenchIcon.files => LucideIcons.files400,
    WorkbenchIcon.search => LucideIcons.search400,
    WorkbenchIcon.changes => LucideIcons.gitBranch400,
    WorkbenchIcon.gate => LucideIcons.listChecks400,
    WorkbenchIcon.folder => LucideIcons.folder400,
    WorkbenchIcon.folderOpen => LucideIcons.folderOpen400,
    WorkbenchIcon.file => LucideIcons.file400,
    WorkbenchIcon.chevronRight => LucideIcons.chevronRight400,
    WorkbenchIcon.chevronDown => LucideIcons.chevronDown400,
    WorkbenchIcon.newFile => LucideIcons.filePlus400,
    WorkbenchIcon.newFolder => LucideIcons.folderPlus400,
    WorkbenchIcon.collapseAll => LucideIcons.listChevronsDownUp400,
    WorkbenchIcon.reveal => LucideIcons.crosshair400,
    WorkbenchIcon.close => LucideIcons.x400,
    WorkbenchIcon.check => LucideIcons.check400,
  };

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Icon(lucide(icon), size: size, color: color),
  );
}
