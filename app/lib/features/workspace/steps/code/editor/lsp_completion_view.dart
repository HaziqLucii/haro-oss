import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../../lsp/lsp_completion.dart';
import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../code_tokens.dart';

/// The overlay's view builder for [controller]: a small hairline list, nothing at all while the
/// server has not answered.
/// [child] (the editor) wrapped in re_editor's overlay, fed by [controller]. The inner Actions
/// answer the arrow keys first, so they only navigate once there are rows to navigate.
Widget lspAutocomplete(LspCompletionController controller, Widget child) =>
    CodeAutocomplete(
      promptsBuilder: controller,
      viewBuilder: lspViewBuilder(controller),
      child: Actions(actions: controller.actions, child: child),
    );

CodeAutocompleteWidgetBuilder lspViewBuilder(
  LspCompletionController controller,
) =>
    (context, notifier, onSelected) => PreferredSize(
      preferredSize: Size(
        CodeTokens.completionWidth,
        CodeTokens.completionRowHeight * CodeTokens.completionMaxRows + 2,
      ),
      child: LspCompletionView(
        controller: controller,
        notifier: notifier,
        onSelected: onSelected,
      ),
    );

class LspCompletionView extends StatefulWidget {
  const LspCompletionView({
    super.key,
    required this.controller,
    required this.notifier,
    required this.onSelected,
  });

  final LspCompletionController controller;
  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;

  @override
  State<LspCompletionView> createState() => _LspCompletionViewState();
}

class _LspCompletionViewState extends State<LspCompletionView> {
  final _scroll = ScrollController();
  late VoidCallback _detach;

  @override
  void initState() {
    super.initState();
    _detach = widget.controller.attach(widget.notifier, widget.onSelected);
  }

  @override
  void didUpdateWidget(LspCompletionView old) {
    super.didUpdateWidget(old);
    if (!identical(old.notifier, widget.notifier)) {
      _detach();
      _detach = widget.controller.attach(widget.notifier, widget.onSelected);
    }
  }

  @override
  void dispose() {
    _detach();
    _scroll.dispose();
    super.dispose();
  }

  void _reveal(int index) {
    if (!_scroll.hasClients) return;
    const h = CodeTokens.completionRowHeight;
    final top = index * h;
    final p = _scroll.position;
    if (top < p.pixels) {
      _scroll.jumpTo(top);
    } else if (top + h > p.pixels + p.viewportDimension) {
      _scroll.jumpTo(top + h - p.viewportDimension);
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<CodeAutocompleteEditingValue>(
    valueListenable: widget.notifier,
    builder: (context, value, _) {
      final rows = value.prompts.whereType<LspPrompt>().toList();
      if (rows.isEmpty) return const SizedBox.shrink();
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(value.index));
      final visible = math.min(rows.length, CodeTokens.completionMaxRows);
      return Container(
        key: const ValueKey('lsp-completion'),
        width: CodeTokens.completionWidth,
        height: CodeTokens.completionRowHeight * visible + 2,
        decoration: BoxDecoration(
          color: HaroTokens.raised,
          border: Border.all(color: HaroTokens.line30),
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.zero,
          itemExtent: CodeTokens.completionRowHeight,
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final selected = i == value.index;
            return GestureDetector(
              key: ValueKey('lsp-item-${rows[i].item.label}'),
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  widget.onSelected(value.copyWith(index: i).autocomplete),
              child: Container(
                color: selected ? HaroTokens.line12 : HaroTokens.transparent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      child: Text(
                        rows[i].item.kindLetter,
                        style: HaroText.mono(
                          size: 11,
                          color: HaroTokens.ink42,
                          tracking: 0,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        rows[i].item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HaroText.mono(
                          size: 12,
                          color: selected ? HaroTokens.ink : HaroTokens.ink66,
                          tracking: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    },
  );
}
