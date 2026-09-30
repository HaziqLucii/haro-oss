import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../../../../../widgets/haro_pressable.dart';
import '../diff_model.dart';
import 'editor_icons.dart';
import 'editor_tabs.dart';

abstract final class TabTokens {
  static const double height = 36;
  static const double maxWidth = 220;

  /// Room for a letter, the unsaved dot, the close button and a few characters of the name.
  static const double minWidth = 100;
  static const double doubleTapMs = 300;

  /// Narrowest pane that still draws the rail and focus buttons.
  static const double trailingMinPane = 340;
}

/// The letter after a tab's name: A for a file the workspace added, M for one it changed.
String? changeLetter(DiffFile? file) {
  if (file == null) return null;
  return file.tag == DiffFileTag.added ? 'A' : 'M';
}

/// One pane's tab strip: italic for a preview tab, `●` for unsaved, a close button, the
/// Diff | Edit toggle and split control on the right.
class TabStrip extends StatefulWidget {
  const TabStrip({
    super.key,
    required this.pane,
    required this.changed,
    required this.mode,
    required this.onActivate,
    required this.onPin,
    required this.onClose,
    required this.onMode,
    required this.onSplit,
    required this.split,
    this.focused = true,
    this.trailing,
  });

  final EditorPane pane;

  /// Diff data by path, for the A/M letters.
  final Map<String, DiffFile> changed;

  /// The active tab's resolved mode; null when nothing is open.
  final CodeMode? mode;
  final ValueChanged<String> onActivate;
  final ValueChanged<String> onPin;
  final ValueChanged<String> onClose;
  final ValueChanged<CodeMode> onMode;
  final VoidCallback onSplit;

  /// Whether the editor is split (the split button is then lit).
  final bool split;
  final bool focused;

  /// Window controls after the split button (the rightmost pane's strip only).
  final Widget? trailing;

  @override
  State<TabStrip> createState() => _TabStripState();
}

class _TabStripState extends State<TabStrip> {
  String? _lastTap;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _tap(String path) {
    final now = DateTime.now();
    final isDouble =
        _lastTap == path &&
        now.difference(_lastTapAt).inMilliseconds < TabTokens.doubleTapMs;
    _lastTap = isDouble ? null : path;
    _lastTapAt = now;
    widget.onActivate(path);
    if (isDouble) widget.onPin(path);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = widget.pane.tabs;
    return LayoutBuilder(
      builder: (context, box) => _strip(
        tabs,
        // The window controls live elsewhere too (activity bar, rail); a narrow pane
        // gives the room to its tabs instead.
        showTrailing: box.maxWidth >= TabTokens.trailingMinPane,
      ),
    );
  }

  Widget _strip(List<EditorTab> tabs, {required bool showTrailing}) {
    return Container(
      height: TabTokens.height,
      decoration: const BoxDecoration(
        color: HaroTokens.bg,
        border: Border(bottom: BorderSide(color: HaroTokens.line08)),
      ),
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                // A pane too narrow for a whole tab squeezes it rather than hiding its close button.
                final maxTab = box.maxWidth.clamp(
                  TabTokens.minWidth,
                  TabTokens.maxWidth,
                );
                return ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    scrollbars: false,
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.trackpad,
                    },
                  ),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final t in tabs)
                          _Tab(
                            key: ValueKey('tab:${t.path}'),
                            tab: t,
                            maxWidth: maxTab,
                            active: t.path == widget.pane.activePath,
                            letter: changeLetter(widget.changed[t.path]),
                            onTap: () => _tap(t.path),
                            onClose: () => widget.onClose(t.path),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.mode != null) ...[
                  _ModeButton(
                    'Edit',
                    on: widget.mode == CodeMode.edit,
                    onTap: () => widget.onMode(CodeMode.edit),
                  ),
                  const SizedBox(width: 4),
                  _ModeButton(
                    'Diff',
                    on: widget.mode == CodeMode.diff,
                    onTap: () => widget.onMode(CodeMode.diff),
                  ),
                  Container(
                    width: 1,
                    height: 14,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    color: HaroTokens.line14,
                  ),
                ],
                HaroPressable(
                  onTap: widget.onSplit,
                  tooltip: widget.split ? 'Close split' : 'Split right',
                  semanticLabel: 'Split right',
                  builder: (context, hovered) => Container(
                    key: const ValueKey('split-button'),
                    height: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.center,
                    child: EditorIcon(
                      EditorIconKind.splitRight,
                      size: 14,
                      color: widget.split || hovered
                          ? HaroTokens.ink
                          : HaroTokens.ink66,
                    ),
                  ),
                ),
                if (showTrailing) ?widget.trailing,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  const _Tab({
    super.key,
    required this.tab,
    required this.maxWidth,
    required this.active,
    required this.letter,
    required this.onTap,
    required this.onClose,
  });

  final EditorTab tab;
  final double maxWidth;
  final bool active;
  final String? letter;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  @override
  void initState() {
    super.initState();
    if (widget.active) _reveal();
  }

  @override
  void didUpdateWidget(_Tab old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _reveal();
  }

  /// A narrow pane scrolls its strip; the tab you are on must stay in view, close button too.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Scrollable.ensureVisible(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final active = widget.active;
    final letter = widget.letter;
    final onTap = widget.onTap;
    final onClose = widget.onClose;
    final name = basenameOf(tab.path);
    return Listener(
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.mouse &&
            e.buttons == kMiddleMouseButton) {
          onClose();
        }
      },
      child: HaroPressable(
        onTap: onTap,
        semanticLabel: name,
        builder: (context, hovered) => Container(
          constraints: BoxConstraints(maxWidth: widget.maxWidth),
          padding: const EdgeInsets.only(left: 14, right: 8),
          decoration: BoxDecoration(
            color: active ? HaroTokens.panel : HaroTokens.transparent,
            border: Border(
              top: BorderSide(
                color: active ? HaroTokens.ink : HaroTokens.transparent,
              ),
              right: const BorderSide(color: HaroTokens.line08),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style:
                      HaroText.mono(
                        size: 11.5,
                        color: active || hovered
                            ? HaroTokens.ink
                            : HaroTokens.ink66,
                        tracking: 0,
                      ).copyWith(
                        fontStyle: tab.preview
                            ? FontStyle.italic
                            : FontStyle.normal,
                      ),
                ),
              ),
              if (letter != null) ...[
                const SizedBox(width: 9),
                Text(
                  letter,
                  style: HaroText.mono(
                    size: 10,
                    color: letter == 'A' ? HaroTokens.gate : HaroTokens.ink66,
                    tracking: 0,
                  ),
                ),
              ],
              if (tab.dirty) ...[
                const SizedBox(width: 8),
                Container(
                  key: ValueKey('tab-dirty:${tab.path}'),
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: HaroTokens.ink,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              const SizedBox(width: 9),
              HaroPressable(
                onTap: onClose,
                semanticLabel: 'Close $name',
                builder: (context, closeHover) => Container(
                  key: ValueKey('tab-close:${tab.path}'),
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: closeHover
                        ? HaroTokens.raised
                        : HaroTokens.transparent,
                    borderRadius: BorderRadius.circular(HaroTokens.radius),
                  ),
                  child: EditorIcon(
                    EditorIconKind.close,
                    size: 12,
                    color: closeHover ? HaroTokens.ink : HaroTokens.ink42,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton(this.label, {required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: label,
    builder: (context, hovered) => AnimatedContainer(
      key: ValueKey('mode-${label.toLowerCase()}'),
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? HaroTokens.raised : HaroTokens.transparent,
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Text(
        label,
        style: HaroText.mono(
          size: 10.5,
          color: on || hovered ? HaroTokens.ink : HaroTokens.ink42,
          tracking: 0,
        ),
      ),
    ),
  );
}
