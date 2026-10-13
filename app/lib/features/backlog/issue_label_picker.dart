import 'package:flutter/material.dart';

import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_popover.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../../widgets/shell_icons.dart';
import '../new_workspace/creation_widgets.dart';

/// Pick issue labels out of however many the repository has: a small popover under the Labels
/// button with a filter box and the number of issues each label has. It stays open, so several
/// labels can be ticked in a row ([onChanged] gets the whole selection each time); a press outside
/// it, Esc or the close button ends it. An issue must carry every ticked label.
Future<void> showLabelPopover(
  BuildContext context, {
  required Offset position,
  required List<(String, int)> labels,
  required Set<String> selected,
  required ValueChanged<Set<String>> onChanged,
}) => showHaroPopover(
  context,
  position: position,
  width: 300,
  height: 360,
  builder: (context, close) => _LabelPopover(
    labels: labels,
    selected: selected,
    onChanged: onChanged,
    onClose: close,
  ),
);

class _LabelPopover extends StatefulWidget {
  const _LabelPopover({
    required this.labels,
    required this.selected,
    required this.onChanged,
    required this.onClose,
  });

  final List<(String, int)> labels;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final VoidCallback onClose;

  @override
  State<_LabelPopover> createState() => _LabelPopoverState();
}

class _LabelPopoverState extends State<_LabelPopover> {
  final _filter = TextEditingController();
  late Set<String> _on = {...widget.selected};

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _set(Set<String> next) {
    setState(() => _on = next);
    widget.onChanged({...next});
  }

  void _toggle(String l) =>
      _set(_on.contains(l) ? ({..._on}..remove(l)) : {..._on, l});

  Widget _row(String label, int count) {
    final on = _on.contains(label);
    return HaroPressable(
      key: Key('bl-label-$label'),
      onTap: () => _toggle(label),
      semanticLabel: label,
      builder: (context, hovered) => Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: hovered ? HaroTokens.ink02 : HaroTokens.transparent,
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: on
                  ? ShellIconView(
                      ShellIcon.check,
                      size: 14,
                      color: HaroTokens.ink,
                    )
                  : null,
            ),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(
                  size: 13,
                  color: on ? HaroTokens.ink : HaroTokens.ink86,
                ),
              ),
            ),
            MonoCaption('$count'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _filter.text.trim().toLowerCase();
    final shown = [
      for (final l in widget.labels)
        if (q.isEmpty || l.$1.toLowerCase().contains(q)) l,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    HaroTextField(
                      key: const Key('label-filter'),
                      controller: _filter,
                      autofocus: true,
                      height: 30,
                      fontSize: 13,
                      padding: const EdgeInsets.only(left: 30, right: 8),
                      hintText: 'Filter labels',
                      onChanged: (_) => setState(() {}),
                    ),
                    Positioned(
                      left: 9,
                      child: IgnorePointer(
                        child: ShellIconView(
                          ShellIcon.search,
                          size: 14,
                          color: HaroTokens.ink42,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              ShellIconButton(
                key: const Key('label-popover-close'),
                icon: ShellIcon.close,
                tooltip: 'Close',
                bordered: true,
                width: 28,
                height: 30,
                iconSize: 14,
                onTap: widget.onClose,
              ),
            ],
          ),
        ),
        if (_on.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 8, 2),
            child: Row(
              children: [
                MonoCaption('${_on.length} SELECTED'),
                const Spacer(),
                HaroPressable(
                  key: const Key('label-clear-all'),
                  onTap: () => _set({}),
                  semanticLabel: 'Clear the selected labels',
                  builder: (context, hovered) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      'Clear',
                      style: HaroText.ui(
                        size: 12,
                        color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    'No label matches.',
                    key: const Key('label-none'),
                    style: HaroText.ui(size: 13, color: HaroTokens.ink42),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
                  children: [for (final (l, n) in shown) _row(l, n)],
                ),
        ),
      ],
    );
  }
}
