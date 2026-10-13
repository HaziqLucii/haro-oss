import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/tokens.dart';
import 'haro_pressable.dart';

/// Icons for the window chrome (top bar, strips, focus mode, status bar), from Lucide. The
/// Finalized UI's glyph arrows and chevrons become these.
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

  /// Run: an outlined triangle.
  play,
  reload,
  restart,
  camera,
  mirror,

  /// Stop: an outlined square.
  stop,

  /// Open in the browser: an arrow leaving a box.
  openExternal,

  /// A log: lines of output.
  log,

  /// Settings: a cog.
  gear,

  /// A dropdown caret and its inverse, a back caret, and a plain arrow to the right.
  chevronDown,
  chevronUp,
  chevronLeft,
  chevronRight,
  arrowRight,

  folder,
  folderOpen,

  /// Copy to the clipboard, and the tick that briefly replaces it.
  copy,
  eraser,
  check,

  /// A pushpin: pinned items.
  pin,

  /// Three dots: a "more" menu.
  ellipsis,
  search,
  filePlus,
  calendar,
  listChecks,
  template,
  pencil,
  help,
  tag,

  /// Files beside the notes, by kind.
  fileText,
  fileSheet,
  fileCode,
  image,
  drawing,
  attach,
}

/// Lucide (outline, rounded) at the regular weight: a 1.3px hand-drawn outline had no pixels to
/// spare on a 1x screen and showed its steps, the font's glyphs are hinted and soft.
IconData lucideFor(ShellIcon icon) => switch (icon) {
  ShellIcon.menu => LucideIcons.menu400,
  ShellIcon.panelRight => LucideIcons.panelRight400,
  ShellIcon.chevronsRight => LucideIcons.chevronsRight400,
  ShellIcon.chevronsLeft => LucideIcons.chevronsLeft400,
  ShellIcon.expand => LucideIcons.maximize2400,
  ShellIcon.shrink => LucideIcons.minimize2400,
  ShellIcon.terminal => LucideIcons.squareTerminal400,
  ShellIcon.plus => LucideIcons.plus400,
  ShellIcon.branch => LucideIcons.gitBranch400,
  ShellIcon.close => LucideIcons.x400,
  ShellIcon.person => LucideIcons.user400,
  ShellIcon.play => LucideIcons.play400,
  ShellIcon.reload => LucideIcons.zap400,
  ShellIcon.restart => LucideIcons.rotateCw400,
  ShellIcon.camera => LucideIcons.camera400,
  ShellIcon.mirror => LucideIcons.monitorSmartphone400,
  ShellIcon.stop => LucideIcons.square400,
  ShellIcon.openExternal => LucideIcons.externalLink400,
  ShellIcon.log => LucideIcons.alignLeft400,
  ShellIcon.gear => LucideIcons.settings400,
  ShellIcon.chevronDown => LucideIcons.chevronDown400,
  ShellIcon.chevronUp => LucideIcons.chevronUp400,
  ShellIcon.chevronLeft => LucideIcons.chevronLeft400,
  ShellIcon.chevronRight => LucideIcons.chevronRight400,
  ShellIcon.arrowRight => LucideIcons.arrowRight400,
  ShellIcon.folder => LucideIcons.folder400,
  ShellIcon.folderOpen => LucideIcons.folderOpen400,
  ShellIcon.copy => LucideIcons.copy400,
  ShellIcon.eraser => LucideIcons.eraser400,
  ShellIcon.check => LucideIcons.check400,
  ShellIcon.pin => LucideIcons.pin400,
  ShellIcon.ellipsis => LucideIcons.ellipsis400,
  ShellIcon.search => LucideIcons.search400,
  ShellIcon.filePlus => LucideIcons.filePlus400,
  ShellIcon.calendar => LucideIcons.calendarDays400,
  ShellIcon.listChecks => LucideIcons.listChecks400,
  ShellIcon.template => LucideIcons.layoutTemplate400,
  ShellIcon.pencil => LucideIcons.pencil400,
  ShellIcon.help => LucideIcons.circleHelp400,
  ShellIcon.tag => LucideIcons.tag400,
  ShellIcon.fileText => LucideIcons.fileText400,
  ShellIcon.fileSheet => LucideIcons.fileSpreadsheet400,
  ShellIcon.fileCode => LucideIcons.fileCode400,
  ShellIcon.image => LucideIcons.image400,
  ShellIcon.drawing => LucideIcons.pencilRuler400,
  ShellIcon.attach => LucideIcons.paperclip400,
};

class ShellIconView extends StatelessWidget {
  ShellIconView(this.icon, {super.key, this.size = 16, Color? color})
    : color = color ?? HaroTokens.ink66;

  final ShellIcon icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Icon(lucideFor(icon), size: size, color: color),
  );
}

/// A square icon button: raised fill on hover, ink at rest or lit [on]. A null [onTap] disables
/// it: dimmed, no hover fill, and the disabled colour wins over [on].
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
    this.filled = false,
    this.bordered = false,
  });

  final ShellIcon icon;
  final String tooltip;

  /// Null disables the button: dimmed, no hover fill.
  final VoidCallback? onTap;
  final double width;
  final double height;
  final double iconSize;

  /// Lit: the thing it toggles is showing.
  final bool on;

  /// A clickable control as a bone squircle with a dark icon. Disabled, it goes back to a
  /// dim ghost: what can be pressed is the bright thing.
  final bool filled;

  /// A hairline box around the icon, so a small action reads as a button and not as a mark.
  final bool bordered;

  @override
  Widget build(BuildContext context) => HaroPressable(
    rippleOnAccent: filled,
    onTap: onTap,
    tooltip: tooltip,
    semanticLabel: tooltip,
    builder: (context, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: filled && onTap != null
          ? ShapeDecoration(
              color: hovered ? HaroTokens.accentHover : HaroTokens.accent,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(
                  HaroTokens.palette.statusRound ? 12 : 9,
                ),
              ),
            )
          : BoxDecoration(
              color: hovered && onTap != null
                  ? HaroTokens.raised
                  : HaroTokens.transparent,
              borderRadius: BorderRadius.circular(
                bordered ? HaroTokens.buttonRadius : HaroTokens.radius,
              ),
              border: bordered
                  ? Border.all(
                      color: on
                          ? HaroTokens.ink
                          : hovered && onTap != null
                          ? HaroTokens.line30
                          : HaroTokens.line14,
                    )
                  : null,
            ),
      child: ShellIconView(
        icon,
        size: iconSize,
        color: onTap == null
            ? HaroTokens.ink42
            : filled
            ? HaroTokens.onAccent
            : hovered || on
            ? HaroTokens.ink
            : HaroTokens.ink66,
      ),
    ),
  );
}
