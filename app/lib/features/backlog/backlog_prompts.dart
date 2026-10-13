import 'package:flutter/material.dart';

import '../../overlays/overlay.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/check_mark.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../new_workspace/creation_widgets.dart';
import 'backlog_query.dart';

/// Asks for one line of text (tags, a date, a name). Resolves with the text, or null when the
/// prompt was dismissed. Enter confirms.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  String? caption,
  String hint = '',
  String initial = '',
  String confirm = 'Save',
}) => showHaroOverlay<String>(
  context,
  width: 460,
  child: _TextPrompt(
    title: title,
    caption: caption,
    hint: hint,
    initial: initial,
    confirm: confirm,
  ),
);

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.caption,
    required this.hint,
    required this.initial,
    required this.confirm,
  });

  final String title;
  final String? caption;
  final String hint;
  final String initial;
  final String confirm;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.title,
          style: HaroText.ui(size: 20, weight: FontWeight.w500),
        ),
        if (widget.caption != null) ...[
          const SizedBox(height: 4),
          MonoCaption(widget.caption!),
        ],
        const SizedBox(height: 16),
        HaroTextField(
          key: const Key('prompt-text'),
          controller: _ctl,
          autofocus: true,
          height: 38,
          fontSize: 14,
          hintText: widget.hint,
          onSubmitted: (v) => closeHaroOverlay<String>(context, v),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            HaroButton(
              key: const Key('prompt-cancel'),
              label: 'Cancel',
              variant: HaroButtonVariant.tertiary,
              onPressed: () => closeHaroOverlay<String>(context),
            ),
            const SizedBox(width: 8),
            HaroButton(
              key: const Key('prompt-save'),
              label: widget.confirm,
              variant: HaroButtonVariant.primary,
              onPressed: () => closeHaroOverlay<String>(context, _ctl.text),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Pick any number of items from [options] (a filterable list with check marks); [picked] starts
/// ticked. Resolves with the chosen hits, or null when dismissed.
Future<List<TodoHit>?> showItemPicker(
  BuildContext context, {
  required String title,
  required List<TodoHit> options,
  Set<String> picked = const {},
  String confirm = 'Save',
}) => showHaroOverlay<List<TodoHit>>(
  context,
  width: 560,
  height: 520,
  child: _ItemPicker(
    title: title,
    options: options,
    picked: picked,
    confirm: confirm,
  ),
);

String hitKey(TodoHit h) => '${h.file.path}#${h.index}';

class _ItemPicker extends StatefulWidget {
  const _ItemPicker({
    required this.title,
    required this.options,
    required this.picked,
    required this.confirm,
  });

  final String title;
  final List<TodoHit> options;
  final Set<String> picked;
  final String confirm;

  @override
  State<_ItemPicker> createState() => _ItemPickerState();
}

class _ItemPickerState extends State<_ItemPicker> {
  final _filter = TextEditingController();
  late final Set<String> _on = {...widget.picked};

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _filter.text.trim().toLowerCase();
    final shown = [
      for (final h in widget.options)
        if (q.isEmpty || h.item.text.toLowerCase().contains(q)) h,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: HaroText.ui(size: 20, weight: FontWeight.w500),
          ),
          const SizedBox(height: 14),
          HaroTextField(
            key: const Key('picker-filter'),
            controller: _filter,
            autofocus: true,
            height: 34,
            fontSize: 13.5,
            hintText: 'Filter',
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (final h in shown)
                  HaroPressable(
                    key: Key('picker-${hitKey(h)}'),
                    onTap: () => setState(() {
                      final k = hitKey(h);
                      if (!_on.remove(k)) _on.add(k);
                    }),
                    semanticLabel: h.item.text,
                    builder: (context, hovered) => Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 6,
                      ),
                      color: hovered
                          ? HaroTokens.ink02
                          : HaroTokens.transparent,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 18,
                            child: _on.contains(hitKey(h))
                                ? CheckMark(color: HaroTokens.ink, size: 13)
                                : null,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              h.item.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: HaroText.ui(
                                size: 13.5,
                                color: HaroTokens.ink86,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          MonoCaption(h.file.path.split('/').last),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              HaroButton(
                label: 'Cancel',
                variant: HaroButtonVariant.tertiary,
                onPressed: () => closeHaroOverlay<List<TodoHit>>(context),
              ),
              const SizedBox(width: 8),
              HaroButton(
                key: const Key('picker-save'),
                label: widget.confirm,
                variant: HaroButtonVariant.primary,
                onPressed: () => closeHaroOverlay<List<TodoHit>>(context, [
                  for (final h in widget.options)
                    if (_on.contains(hitKey(h))) h,
                ]),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
