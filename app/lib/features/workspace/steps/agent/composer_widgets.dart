import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kPrimaryMouseButton;
import 'package:flutter/material.dart';

import '../../../../api/models/models.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../../../widgets/status_square.dart';
import 'agent_tokens.dart';
import 'composer_logic.dart';

/// Colours `/command` and `@file` tokens as the user types. Only decoration changes, never
/// metrics, so the caret stays glyph-aligned.
class MentionController extends TextEditingController {
  MentionController({super.text});

  static final _known = {for (final c in slashCommands) c.name};

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final token = (style ?? const TextStyle()).copyWith(
      decoration: TextDecoration.underline,
      decorationColor: HaroTokens.line30,
    );
    final spans = <InlineSpan>[];
    final t = text;
    var buf = StringBuffer();

    void flush() {
      if (buf.isEmpty) return;
      spans.add(TextSpan(text: buf.toString()));
      buf = StringBuffer();
    }

    var i = 0;
    while (i < t.length) {
      final boundary = i == 0 || RegExp(r'\s').hasMatch(t[i - 1]);
      if (boundary && (t[i] == '@' || (i == 0 && t[i] == '/'))) {
        final m = RegExp(r'^\S+').firstMatch(t.substring(i));
        final word = m?.group(0) ?? '';
        final isFile = t[i] == '@' && word.length > 1;
        final isCommand = t[i] == '/' && _known.contains(word);
        if (isFile || isCommand) {
          flush();
          spans.add(TextSpan(text: word, style: token));
          i += word.length;
          continue;
        }
      }
      buf.write(t[i]);
      i++;
    }
    flush();
    return TextSpan(style: style, children: spans);
  }
}

class CompletionItem {
  const CompletionItem({
    required this.insert,
    required this.label,
    this.hint,
    this.drillable = false,
  });

  final String insert;
  final String label;
  final String? hint;

  /// Shows a chevron that steps into the item (a folder) instead of choosing it.
  final bool drillable;
}

/// Dropdown above the field. It never takes focus: the field keeps the caret and routes
/// arrow keys, Enter, Tab and Escape here through its own key handler.
class CompletionMenu extends StatelessWidget {
  const CompletionMenu({
    super.key,
    required this.link,
    required this.items,
    required this.selected,
    required this.loading,
    required this.onPick,
    required this.onHover,
    this.onDrill,
    this.footer,
  });

  final LayerLink link;
  final List<CompletionItem> items;
  final int selected;
  final bool loading;
  final ValueChanged<CompletionItem> onPick;
  final ValueChanged<int> onHover;
  final ValueChanged<CompletionItem>? onDrill;

  /// A dim line under the rows saying what the clicks do.
  final String? footer;

  static const double rowHeight = 28;
  static const double footerHeight = 24;

  @override
  Widget build(BuildContext context) {
    final height = math.min(
      AgentTokens.menuMaxHeight,
      math.max(items.length, 1) * rowHeight +
          8 +
          (footer != null && items.isNotEmpty ? footerHeight : 0),
    );
    return CompositedTransformFollower(
      link: link,
      showWhenUnlinked: false,
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      offset: const Offset(0, -6),
      child: Align(
        alignment: Alignment.bottomLeft,
        // On desktop a text field unfocuses on any pointer-down outside it, which closed this
        // menu before the click landed. Taps on the menu count as taps on the field.
        child: TextFieldTapRegion(
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              key: const ValueKey('completion-menu'),
              width: AgentTokens.menuWidth,
              height: height,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: HaroTokens.raised,
                border: Border.all(color: HaroTokens.line20),
                borderRadius: BorderRadius.circular(HaroTokens.radius),
              ),
              child: items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        loading ? 'loading files…' : 'no matches',
                        style: AgentTokens.hint,
                      ),
                    )
                  : Column(
                      children: [
                        Expanded(
                          child: _Items(
                            items: items,
                            selected: selected,
                            onPick: onPick,
                            onHover: onHover,
                            onDrill: onDrill,
                          ),
                        ),
                        if (footer != null)
                          Container(
                            key: const ValueKey('completion-footer'),
                            height: footerHeight,
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: const BoxDecoration(
                              border: Border(
                                top: BorderSide(color: HaroTokens.line08),
                              ),
                            ),
                            child: Text(
                              footer!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AgentTokens.hint,
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Items extends StatefulWidget {
  const _Items({
    required this.items,
    required this.selected,
    required this.onPick,
    required this.onHover,
    this.onDrill,
  });

  final List<CompletionItem> items;
  final int selected;
  final ValueChanged<CompletionItem> onPick;
  final ValueChanged<int> onHover;
  final ValueChanged<CompletionItem>? onDrill;

  @override
  State<_Items> createState() => _ItemsState();
}

class _ItemsState extends State<_Items> {
  final _scroll = ScrollController();

  // The chevron sits inside its row and both listen for the press; the chevron's fires first.
  bool _drilled = false;

  @override
  void didUpdateWidget(_Items old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  void _reveal() {
    if (!_scroll.hasClients || widget.selected < 0) return;
    final top = widget.selected * CompletionMenu.rowHeight;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + CompletionMenu.rowHeight > _scroll.offset + view) {
      _scroll.jumpTo(top + CompletionMenu.rowHeight - view);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: _scroll,
    padding: EdgeInsets.zero,
    itemExtent: CompletionMenu.rowHeight,
    itemCount: widget.items.length,
    itemBuilder: (context, i) {
      final it = widget.items[i];
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => widget.onHover(i),
        // A pick lands on pointer-down: nothing between the press and the release (the field
        // losing focus, a rebuild) can swallow it, and the row reads as a button either way.
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (e.kind == PointerDeviceKind.mouse &&
                e.buttons != kPrimaryMouseButton) {
              return;
            }
            if (_drilled) {
              _drilled = false;
              return;
            }
            widget.onPick(it);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            color: i == widget.selected
                ? HaroTokens.line08
                : HaroTokens.transparent,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    it.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AgentTokens.chip(),
                  ),
                ),
                if (it.hint != null) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      it.hint!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AgentTokens.hint,
                    ),
                  ),
                ],
                const Spacer(),
                if (it.drillable && widget.onDrill != null)
                  _OpenPill(
                    key: ValueKey('completion-drill-${it.insert}'),
                    onPress: () {
                      _drilled = true;
                      widget.onDrill!(it);
                    },
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The "Open" button on a folder row: look inside the folder instead of adding it. A real
/// button (hairline, label, hover) so it reads as a second choice next to the row's own click.
class _OpenPill extends StatefulWidget {
  const _OpenPill({super.key, required this.onPress});

  final VoidCallback onPress;

  @override
  State<_OpenPill> createState() => _OpenPillState();
}

class _OpenPillState extends State<_OpenPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => widget.onPress(),
      child: Tooltip(
        message: 'Show what is inside this folder',
        waitDuration: const Duration(milliseconds: 500),
        child: AnimatedContainer(
          duration: HaroTokens.fadeFast,
          height: 20,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovered ? HaroTokens.line12 : HaroTokens.transparent,
            border: Border.all(
              color: _hovered ? HaroTokens.line30 : HaroTokens.line20,
            ),
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
          child: Text(
            'Open \u203a',
            style: AgentTokens.chip(
              color: _hovered ? HaroTokens.ink : HaroTokens.ink66,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Composer buttons: a hairline chip, mono 11.5.
class ComposerChip extends StatelessWidget {
  const ComposerChip({
    super.key,
    required this.label,
    required this.onTap,
    this.bordered = true,
    this.active = false,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onTap;
  final bool bordered;

  /// Toggled on: brighter border and text.
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: tooltip,
    semanticLabel: label,
    builder: (context, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      height: AgentTokens.composerChipHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HaroTokens.radius),
        border: bordered
            ? Border.all(
                color: active
                    ? HaroTokens.line30
                    : hovered
                    ? HaroTokens.line30
                    : HaroTokens.line14,
              )
            : null,
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: AgentTokens.chip(
            color: active || hovered
                ? HaroTokens.ink
                : (bordered ? HaroTokens.ink86 : HaroTokens.ink66),
          ),
        ),
      ),
    ),
  );
}

class AttachmentChip extends StatelessWidget {
  const AttachmentChip({
    super.key,
    required this.attachment,
    required this.onRemove,
  });

  final Attachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
    height: 24,
    padding: const EdgeInsets.only(left: 8),
    decoration: BoxDecoration(
      border: Border.all(color: HaroTokens.line14),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            '${attachment.name} · ${attachment.stat}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AgentTokens.chip(color: HaroTokens.ink66),
          ),
        ),
        HaroPressable(
          onTap: onRemove,
          tooltip: 'Remove attachment',
          semanticLabel: 'Remove ${attachment.name}',
          builder: (context, hovered) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '×',
              style: AgentTokens.chip(
                color: hovered ? HaroTokens.ink : HaroTokens.ink42,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// One option in a picker section.
class PickerOption {
  const PickerOption({
    required this.id,
    required this.label,
    this.value,
    this.selected = false,
    this.onTap,
  });

  final String id;
  final String label;
  final String? value;
  final bool selected;

  /// Null makes the row read-only (a role the composer cannot choose).
  final VoidCallback? onTap;
}

class PickerSection {
  const PickerSection(this.title, this.options);

  final String title;
  final List<PickerOption> options;
}

/// The popover behind the `build · sonnet-5 · high ▾` chip.
class PickerPanel extends StatelessWidget {
  const PickerPanel({
    super.key,
    required this.link,
    required this.sections,
    required this.footer,
    required this.onFooter,
    required this.onClose,
  });

  final LayerLink link;
  final List<PickerSection> sections;
  final String footer;
  final VoidCallback onFooter;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onClose,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.bottomLeft,
          offset: const Offset(0, -6),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                key: const ValueKey('role-picker-panel'),
                width: 280,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: HaroTokens.raised,
                  border: Border.all(color: HaroTokens.line20),
                  borderRadius: BorderRadius.circular(HaroTokens.radius),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final s in sections) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                        child: Text(
                          s.title.toUpperCase(),
                          style: AgentTokens.label(),
                        ),
                      ),
                      for (final o in s.options) _OptionRow(option: o),
                    ],
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: HaroTokens.line08),
                        ),
                      ),
                      child: HaroPressable(
                        onTap: onFooter,
                        semanticLabel: footer,
                        builder: (context, hovered) => Container(
                          key: const ValueKey('role-picker-settings'),
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                          child: Text(
                            footer,
                            style: HaroText.ui(
                              size: 13,
                              color: hovered
                                  ? HaroTokens.ink
                                  : HaroTokens.ink66,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.option});

  final PickerOption option;

  @override
  Widget build(BuildContext context) {
    final enabled = option.onTap != null;
    return HaroPressable(
      onTap: option.onTap,
      semanticLabel: option.label,
      builder: (context, hovered) => Container(
        key: ValueKey('picker-${option.id}'),
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: hovered ? HaroTokens.line08 : HaroTokens.transparent,
        child: Row(
          children: [
            StatusSquare(
              size: 7,
              color: option.selected ? HaroTokens.ink : HaroTokens.ink42,
              filled: option.selected,
            ),
            const SizedBox(width: 10),
            Text(
              option.label,
              style: AgentTokens.chip(
                color: enabled ? HaroTokens.ink86 : HaroTokens.ink42,
              ),
            ),
            const Spacer(),
            if (option.value != null)
              Text(
                option.value!,
                style: AgentTokens.chip(color: HaroTokens.ink42),
              ),
          ],
        ),
      ),
    );
  }
}

/// Sections for `[roles]` on: what the NEXT run will use, plan or build, selectable through
/// the "plan first" toggle they mirror. Review and scout are not picked per run (review backs
/// the on-demand "Review with AI", scout is a sub-agent the agent calls when it wants), so
/// they live in Settings only and never appear here as if they were a step.
List<PickerSection> roleSections(
  RolesConfig cfg, {
  required bool planFirst,
  required ValueChanged<bool> onPlanFirst,
}) => [
  PickerSection('Next run', [
    PickerOption(
      id: 'plan',
      label: 'plan',
      value: roleLabel(cfg.plan),
      selected: planFirst,
      onTap: () => onPlanFirst(true),
    ),
    PickerOption(
      id: 'build',
      label: 'build',
      value: roleLabel(cfg.build),
      selected: !planFirst,
      onTap: () => onPlanFirst(false),
    ),
  ]),
];

/// Sections for `[roles]` off: a model and an effort for this run only.
List<PickerSection> modelSections({
  required String? model,
  required String? effort,
  required String defaultModel,
  required String defaultEffort,
  required ValueChanged<String?> onModel,
  required ValueChanged<String?> onEffort,
}) => [
  PickerSection('Model', [
    PickerOption(
      id: 'model-default',
      label: 'default',
      value: defaultModel.isEmpty ? null : defaultModel,
      selected: model == null,
      onTap: () => onModel(null),
    ),
    for (final m in AgentConfig.modelOptions)
      PickerOption(
        id: 'model-$m',
        label: m,
        selected: model == m,
        onTap: () => onModel(m),
      ),
  ]),
  PickerSection('Effort', [
    PickerOption(
      id: 'effort-default',
      label: 'default',
      value: defaultEffort.isEmpty ? null : defaultEffort,
      selected: effort == null,
      onTap: () => onEffort(null),
    ),
    for (final e in AgentConfig.effortOptions)
      if (e.isNotEmpty)
        PickerOption(
          id: 'effort-$e',
          label: e,
          selected: effort == e,
          onTap: () => onEffort(e),
        ),
  ]),
];

/// One entry of the Scope box: a folder (everything inside it), a file, or a pattern.
class ScopeChip extends StatelessWidget {
  const ScopeChip({
    super.key,
    required this.entry,
    required this.kind,
    required this.count,
    required this.onRemove,
  });

  final String entry;
  final ScopeKind kind;
  final int? count;
  final VoidCallback onRemove;

  String get _tip => switch (kind) {
    ScopeKind.folder =>
      'Everything inside $entry'
          '${count == null ? '' : ' ($count ${count == 1 ? 'file' : 'files'})'}',
    ScopeKind.file =>
      count == 0 ? 'A new file: it does not exist yet' : 'Only this file',
    ScopeKind.pattern => 'Files matching this pattern',
  };

  @override
  Widget build(BuildContext context) {
    final label = kind == ScopeKind.folder && !entry.endsWith('/')
        ? '$entry/'
        : entry;
    return Tooltip(
      message: _tip,
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        height: 20,
        padding: const EdgeInsets.only(left: 7),
        decoration: BoxDecoration(
          border: Border.all(color: HaroTokens.line20),
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: AgentTokens.chip()),
            if (kind == ScopeKind.folder && count != null) ...[
              const SizedBox(width: 6),
              Text('$count', style: AgentTokens.hint),
            ],
            HaroPressable(
              key: ValueKey('scope-chip-remove-$entry'),
              onTap: onRemove,
              tooltip: 'Remove',
              builder: (context, hovered) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '\u00d7',
                  style: AgentTokens.chip(
                    color: hovered ? HaroTokens.ink : HaroTokens.ink42,
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

/// The "+N more" / "fewer" chip that folds a long list of scope entries.
class ScopeToggle extends StatelessWidget {
  const ScopeToggle({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    builder: (context, hovered) => Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      child: Text(
        label,
        style: AgentTokens.chip(
          color: hovered ? HaroTokens.ink : HaroTokens.ink66,
        ),
      ),
    ),
  );
}
