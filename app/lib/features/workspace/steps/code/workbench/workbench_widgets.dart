import 'package:flutter/material.dart';

import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../../../../../widgets/haro_pressable.dart';
import 'workbench_icons.dart';

/// Sizes of the workbench (Finalized UI, code step).
abstract final class WorkbenchTokens {
  static const double activityBarWidth = 48;
  static const double activityButton = 36;
  static const double titleHeight = 36;
  static const double actionButton = 24;
  static const double filterHeight = 28;
  static const double searchHeight = 30;
  static const double panelPadX = 10;
  static const double rowPadRight = 12;
  static const double rowIndent = 14;
  static const double chevronWidth = 10;
  static const double iconSize = 16;
  static const double resizeHandle = 6;
}

/// The column of a side panel: a header block over a list. The header may take at most
/// 55% of the height and scrolls inside that, so a short window never overflows and the list
/// always keeps some room.
class PanelColumn extends StatelessWidget {
  const PanelColumn({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => _PanelBox(
      maxHeight: box.maxHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

class _PanelBox extends InheritedWidget {
  const _PanelBox({required this.maxHeight, required super.child});

  final double maxHeight;

  @override
  bool updateShouldNotify(_PanelBox old) => maxHeight != old.maxHeight;
}

/// The block above a panel's list, inside a [PanelColumn].
class PanelHeader extends StatelessWidget {
  const PanelHeader({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final box = context.dependOnInheritedWidgetOfExactType<_PanelBox>();
    final cap = box == null || !box.maxHeight.isFinite
        ? double.infinity
        : box.maxHeight * .55;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: cap),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          WorkbenchTokens.panelPadX,
          0,
          WorkbenchTokens.panelPadX,
          10,
        ),
        child: child,
      ),
    );
  }
}

/// `FILES · PROJECT` style caption with optional trailing actions.
class PanelTitle extends StatelessWidget {
  const PanelTitle(this.title, {super.key, this.actions = const []});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    height: WorkbenchTokens.titleHeight,
    padding: const EdgeInsets.only(left: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            key: const ValueKey('side-title'),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: HaroText.mono(
              size: 10,
              color: HaroTokens.ink42,
              tracking: .16,
            ),
          ),
        ),
        ...actions,
      ],
    ),
  );
}

/// A 24px icon button with a raised hover fill.
class IconAction extends StatelessWidget {
  const IconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 14,
  });

  final WorkbenchIcon icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: tooltip,
    semanticLabel: tooltip,
    builder: (context, hovered) => Container(
      width: WorkbenchTokens.actionButton,
      height: WorkbenchTokens.actionButton,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: hovered ? HaroTokens.raised : HaroTokens.transparent,
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: WorkbenchIconView(
        icon,
        size: size,
        color: hovered ? HaroTokens.ink : HaroTokens.ink66,
      ),
    ),
  );
}

/// The panel-coloured, hairline-bordered box the filter and the search query sit in.
class FieldBox extends StatelessWidget {
  const FieldBox({
    super.key,
    required this.child,
    this.height = WorkbenchTokens.filterHeight,
    this.border = HaroTokens.line14,
    this.leading,
    this.trailing,
  });

  final Widget child;
  final double height;
  final Color border;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 9),
    decoration: BoxDecoration(
      color: HaroTokens.panel,
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 8)],
        Expanded(child: child),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    ),
  );
}

/// The unframed text input inside a [FieldBox]: mono 11.5, no underline.
class BareField extends StatelessWidget {
  const BareField({
    super.key,
    required this.controller,
    required this.hint,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: HaroText.mono(size: 11.5, color: HaroTokens.ink, tracking: 0),
      cursorColor: HaroTokens.ink,
      cursorWidth: 1,
      decoration: InputDecoration.collapsed(
        hintText: hint,
        hintStyle: HaroText.mono(
          size: 11.5,
          color: HaroTokens.ink42,
          tracking: 0,
        ),
      ),
    ),
  );
}

/// A one-line note in a panel body (empty and error states).
class PanelNote extends StatelessWidget {
  const PanelNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
    child: Text(text, style: HaroText.ui(size: 13, color: HaroTokens.ink42)),
  );
}
