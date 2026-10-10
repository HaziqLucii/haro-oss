import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import 'haro_pressable.dart';

class HaroMenuItem {
  const HaroMenuItem({
    required this.label,
    required this.onSelected,
    this.destructive = false,
    this.hint,
  }) : heading = false,
       separator = false;

  /// A hairline between groups of rows. Not clickable.
  const HaroMenuItem.separator()
    : label = '',
      onSelected = _noop,
      destructive = false,
      heading = false,
      hint = null,
      separator = true;

  /// A dim mono caption that groups the rows after it. Not clickable.
  const HaroMenuItem.heading(this.label)
    : onSelected = _noop,
      destructive = false,
      heading = true,
      hint = null,
      separator = false;

  final String label;
  final VoidCallback onSelected;

  /// Red text, for an action that deletes something.
  final bool destructive;
  final bool heading;
  final bool separator;

  /// A dim shortcut hint at the trailing edge, e.g. `F2`.
  final String? hint;

  static void _noop() {}
}

const double _menuWidth = 204;
const double _rowHeight = 30;
const double _separatorHeight = 9;
const double _headingHeight = 26;
const double _edge = 8;

/// A small context menu at [position] (window coordinates): raised panel, hairline border,
/// fade in. Picking an item closes the menu first, then runs it.
Future<void> showHaroMenu(
  BuildContext context, {
  required Offset position,
  required List<HaroMenuItem> items,
  double width = _menuWidth,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close menu',
  barrierColor: HaroTokens.transparent,
  transitionDuration: HaroTokens.fadeFast,
  pageBuilder: (context, _, _) =>
      _MenuFrame(position: position, items: items, width: width),
  transitionBuilder: (context, animation, _, page) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: HaroTokens.curve),
    child: page,
  ),
);

class _MenuFrame extends StatelessWidget {
  const _MenuFrame({
    required this.position,
    required this.items,
    required this.width,
  });

  final Offset position;
  final List<HaroMenuItem> items;
  final double width;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height =
        items.fold<double>(
          0,
          (sum, i) =>
              sum +
              (i.heading
                  ? _headingHeight
                  : i.separator
                  ? _separatorHeight
                  : _rowHeight),
        ) +
        8;
    final left = math.max(
      _edge,
      math.min(position.dx, size.width - width - _edge),
    );
    final top = math.max(
      _edge,
      math.min(position.dy, size.height - height - _edge),
    );
    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context, rootNavigator: true).maybePop(),
        },
        child: Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: width,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: HaroTokens.raised,
                    border: Border.all(color: HaroTokens.line20),
                    borderRadius: BorderRadius.circular(HaroTokens.radius),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in items)
                        if (item.heading)
                          _MenuHeading(item.label)
                        else if (item.separator)
                          const _MenuSeparator()
                        else
                          _MenuRow(
                            item: item,
                            onTap: () {
                              Navigator.of(context, rootNavigator: true).pop();
                              item.onSelected();
                            },
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuHeading extends StatelessWidget {
  const _MenuHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    height: _headingHeight,
    padding: const EdgeInsets.only(left: 12, right: 12, top: 6),
    alignment: Alignment.centerLeft,
    child: Text(
      label.toUpperCase(),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .14),
    ),
  );
}

class _MenuSeparator extends StatelessWidget {
  const _MenuSeparator();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: _separatorHeight,
    child: Center(
      child: Divider(height: 1, thickness: 1, color: HaroTokens.line08),
    ),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.item, required this.onTap});

  final HaroMenuItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: item.label,
    builder: (_, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      height: _rowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      color: hovered ? HaroTokens.line08 : HaroTokens.transparent,
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: HaroText.ui(
                size: 13,
                color: item.destructive
                    ? HaroTokens.fail
                    : hovered
                    ? HaroTokens.ink
                    : HaroTokens.ink86,
              ),
            ),
          ),
          if (item.hint != null) ...[
            const SizedBox(width: 12),
            Text(
              item.hint!,
              maxLines: 1,
              softWrap: false,
              style: HaroText.mono(
                size: 10.5,
                color: HaroTokens.ink42,
                tracking: 0,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
