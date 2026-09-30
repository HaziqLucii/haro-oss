import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../shortcuts/platform_keys.dart';
import '../../../../theme/coding_font.dart';
import '../../../../theme/display_scope.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/haro_pressable.dart';
import 'code_tokens.dart';
import 'edit_buffer.dart';
import 'editor/deferred_listenable.dart';
import 'editor/editor_gutter.dart';
import 'editor/editor_marks.dart';
import 'editor/editor_tabs.dart' show EditorJump;
import 'editor/minimap.dart';
import 'syntax.dart';

/// Syntax highlighting runs in a background isolate, which widget tests cannot pump.
@visibleForTesting
bool codeEditorHighlighting = true;

/// Edit tab body: the editor with its gutter, indent guides and minimap, a find bar (⌘F) and the
/// status footer. The buffer belongs to the store; this only draws it.
class EditPane extends StatelessWidget {
  const EditPane({
    super.key,
    required this.buffer,
    required this.onSave,
    this.fontSize = 13,
    this.minimap = true,
    this.marks = const {},
    this.ran = const {},
    this.jump,
    this.onJumped,
  });

  final EditBuffer buffer;
  final VoidCallback onSave;
  final int fontSize;
  final bool minimap;

  /// Change bars and "line ran" dots for the saved text; empty while the buffer is dirty.
  final Map<int, ChangeMark> marks;
  final Set<int> ran;

  /// A line to reveal once the editor is up, and the callback that marks it handled.
  final EditorJump? jump;
  final ValueChanged<int>? onJumped;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: buffer,
    builder: (context, _) => switch (buffer.phase) {
      BufferPhase.loading => const _Note('LOADING…'),
      BufferPhase.failed => _Note(
        'Could not read this file: ${buffer.loadError ?? 'unknown error'}',
        error: true,
      ),
      BufferPhase.guarded => _Note(_guardText(buffer)),
      BufferPhase.mixedEndings => const _Note(mixedEndingsNote),
      BufferPhase.ready => _ReadyEditor(
        key: ValueKey(buffer.path),
        buffer: buffer,
        onSave: onSave,
        fontSize: fontSize,
        minimap: minimap,
        marks: marks,
        ran: ran,
        jump: jump,
        onJumped: onJumped,
      ),
    },
  );

  String _guardText(EditBuffer b) {
    final why = b.guardReason ?? 'not editable';
    final size = b.guardSize;
    return size == null
        ? 'Not opened: $why.'
        : 'Not opened: $why ($size bytes).';
  }
}

class _ReadyEditor extends StatefulWidget {
  const _ReadyEditor({
    super.key,
    required this.buffer,
    required this.onSave,
    required this.fontSize,
    required this.minimap,
    required this.marks,
    required this.ran,
    this.jump,
    this.onJumped,
  });

  final EditBuffer buffer;
  final VoidCallback onSave;
  final int fontSize;
  final bool minimap;
  final Map<int, ChangeMark> marks;
  final Set<int> ran;
  final EditorJump? jump;
  final ValueChanged<int>? onJumped;

  @override
  State<_ReadyEditor> createState() => _ReadyEditorState();
}

class _ReadyEditorState extends State<_ReadyEditor> {
  late final CodeFindController _find = CodeFindController(
    widget.buffer.controller!,
  );
  final _scroll = CodeScrollController();
  final _themes = <bool, CodeHighlightTheme?>{};
  CodeIndicatorValueNotifier? _indicator;
  late final int _unit = _detectUnit(widget.buffer.controller!.codeLines);
  int _jumped = 0;

  static int _detectUnit(CodeLines lines) => indentUnit([
    for (var i = 0; i < lines.length && i < 400; i++) lines[i].text,
  ]);

  /// Kept per mode: re_editor re-highlights whenever the theme instance changes.
  CodeHighlightTheme? _theme(bool colour) => _themes.putIfAbsent(colour, () {
    final lang = languageForPath(widget.buffer.path);
    final mode = modeForLanguage(lang);
    if (mode == null || !codeEditorHighlighting) return null;
    return CodeHighlightTheme(
      languages: {lang!: CodeHighlightThemeMode(mode: mode)},
      theme: syntaxStyles(colour: colour),
    );
  });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final y = widget.buffer.scrollOffset;
      final s = _scroll.verticalScroller;
      if (y > 0 && s.hasClients) {
        s.jumpTo(y.clamp(0, s.position.maxScrollExtent));
      }
      s.addListener(_rememberScroll);
      _maybeJump();
    });
  }

  @override
  void didUpdateWidget(_ReadyEditor old) {
    super.didUpdateWidget(old);
    if (widget.jump?.serial != old.jump?.serial) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeJump());
    }
  }

  void _maybeJump() {
    final j = widget.jump;
    if (!mounted || j == null || j.serial <= _jumped) return;
    _jumped = j.serial;
    final c = widget.buffer.controller!;
    final index = (j.line - 1).clamp(0, c.codeLines.length - 1);
    c.selection = CodeLineSelection.collapsed(index: index, offset: 0);
    _scroll.makeCenterIfInvisible(CodeLinePosition(index: index, offset: 0));
    widget.onJumped?.call(j.serial);
  }

  /// Remembered as it changes: by dispose the scrollable is already detached.
  void _rememberScroll() {
    final s = _scroll.verticalScroller;
    if (s.hasClients) widget.buffer.scrollOffset = s.offset;
  }

  @override
  void dispose() {
    _scroll.verticalScroller.removeListener(_rememberScroll);
    _find.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.buffer;
    final controller = b.controller!;
    final codingFont = DisplayScope.codingFontOf(context);
    final size = widget.fontSize.toDouble();
    final lineStyle = codingTextStyle(
      codingFont,
      fontSize: size,
      height: CodeTokens.editorLineHeight,
    );
    final charWidth = measureCharWidth(lineStyle);
    final editor = CodeEditor(
      controller: controller,
      scrollController: _scroll,
      findController: _find,
      autofocus: true,
      wordWrap: false,
      autocompleteSymbols: false,
      padding: const EdgeInsets.symmetric(vertical: 8),
      style: CodeEditorStyle(
        fontSize: size,
        fontFamily: codingFontFamily(codingFont),
        fontHeight: CodeTokens.editorLineHeight,
        textColor: HaroTokens.ink,
        backgroundColor: HaroTokens.bg,
        selectionColor: HaroTokens.line30,
        highlightColor: HaroTokens.line20,
        cursorColor: HaroTokens.ink,
        cursorWidth: 1.5,
        cursorLineColor: HaroTokens.line12,
        chunkIndicatorColor: HaroTokens.ink42,
        codeTheme: _theme(DisplayScope.syntaxColourOf(context)),
      ),
      indicatorBuilder: (context, editing, chunks, notifier) {
        if (!identical(_indicator, notifier)) {
          _indicator = notifier;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
        return DeferredListenableBuilder(
          listenable: editing,
          builder: (context) => EditorGutter(
            editing: editing,
            chunks: chunks,
            notifier: notifier,
            textStyle: lineStyle,
            charWidth: charWidth,
            marks: widget.marks,
            ran: widget.ran,
          ),
        );
      },
      leadingDivider: const SizedBox(
        width: 1,
        child: ColoredBox(color: HaroTokens.line08),
      ),
      findBuilder: (context, find, readOnly) => FindBar(controller: find),
      shortcutOverrideActions: {
        CodeShortcutSaveIntent: CallbackAction<CodeShortcutSaveIntent>(
          onInvoke: (_) {
            widget.onSave();
            return null;
          },
        ),
      },
    );
    final indicator = _indicator;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: editor),
                    if (indicator != null)
                      Positioned.fill(
                        child: DeferredListenableBuilder(
                          listenable: controller,
                          builder: (context) => IndentGuides(
                            editing: controller,
                            notifier: indicator,
                            scroll: _scroll.horizontalScroller,
                            charWidth: charWidth,
                            textLeft:
                                GutterMetrics.total(
                                  controller.lineCount,
                                  charWidth,
                                ) +
                                1,
                            unit: _unit,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.minimap)
                Minimap(
                  controller: controller,
                  scroll: _scroll.verticalScroller,
                  added: {
                    for (final e in widget.marks.entries)
                      if (e.value == ChangeMark.added) e.key,
                  },
                ),
            ],
          ),
        ),
        _Footer(buffer: b, onSave: widget.onSave),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Align(
      alignment: Alignment.topLeft,
      child: Text(
        text,
        style: HaroText.mono(
          color: error ? HaroTokens.fail : HaroTokens.ink42,
          tracking: 0,
          size: 12,
        ),
      ),
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.buffer, required this.onSave});

  final EditBuffer buffer;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0);
    final Widget status;
    if (buffer.saveError != null) {
      status = Text(
        'Save failed: ${buffer.saveError}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style.copyWith(color: HaroTokens.fail),
      );
    } else {
      status = const SizedBox.shrink();
    }
    return Container(
      height: CodeTokens.editorFooterHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: HaroTokens.bg,
        border: Border(top: BorderSide(color: HaroTokens.line08)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: status),
          ),
          const SizedBox(width: 12),
          HaroButton(
            label: 'Save',
            kbd: primaryLabel('S'),
            height: 22,
            fontSize: 12,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            onPressed: buffer.canSave && buffer.dirty ? onSave : null,
          ),
        ],
      ),
    );
  }
}

/// ⌘F find bar in the brand chrome: input, `n of m`, prev/next, case and regex toggles.
class FindBar extends StatelessWidget implements PreferredSizeWidget {
  const FindBar({super.key, required this.controller});

  final CodeFindController controller;

  static const double height = 36;

  @override
  Size get preferredSize =>
      Size(double.infinity, controller.value == null ? 0 : height);

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final result = value.result;
    final label = value.option.pattern.isEmpty
        ? ''
        : result == null || result.matches.isEmpty
        ? 'none'
        : '${result.index + 1} of ${result.matches.length}';
    final small = HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0);
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: HaroTokens.panel,
        border: Border(bottom: BorderSide(color: HaroTokens.line08)),
      ),
      child: Row(
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Container(
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  border: Border.all(color: HaroTokens.line30),
                  borderRadius: BorderRadius.circular(HaroTokens.radius),
                ),
                child: TextField(
                  controller: controller.findInputController,
                  focusNode: controller.findInputFocusNode,
                  style: HaroText.mono(
                    size: 12,
                    color: HaroTokens.ink,
                    tracking: 0,
                  ),
                  cursorColor: HaroTokens.ink,
                  cursorWidth: 1,
                  decoration: const InputDecoration.collapsed(hintText: ''),
                  onSubmitted: (_) {
                    controller.nextMatch();
                    controller.focusOnFindInput();
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(label, style: small),
          const SizedBox(width: 8),
          _Tap('↑', controller.previousMatch),
          _Tap('↓', controller.nextMatch),
          _Tap(
            'Aa',
            controller.toggleCaseSensitive,
            on: value.option.caseSensitive,
          ),
          _Tap('.*', controller.toggleRegex, on: value.option.regex),
          const Spacer(),
          _Tap('esc', controller.close),
        ],
      ),
    );
  }
}

class _Tap extends StatelessWidget {
  const _Tap(this.label, this.onTap, {this.on = false});

  final String label;
  final VoidCallback onTap;
  final bool on;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    builder: (context, hovered) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        label,
        style: HaroText.mono(
          size: 11,
          color: on || hovered ? HaroTokens.ink : HaroTokens.ink42,
          tracking: 0,
        ),
      ),
    ),
  );
}
