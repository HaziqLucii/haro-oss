import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart' show CodeLineEditingController;

import '../../../../../features/open_in/open_in_button.dart';
import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../../../../../widgets/haro_pressable.dart';
import '../code_tokens.dart';
import '../diff_model.dart';
import '../syntax.dart';
import 'editor_icons.dart';
import 'editor_symbols.dart';

abstract final class CrumbTokens {
  static const double height = 28;

  /// Widths the right side reserves, so nothing overflows however narrow the pane gets.
  static const double minPath = 120;
  static const double openIn = 130;
  static const double legend = 258;
  static const double counts = 72;
  static const double closeButton = 28;
}

/// `lib › src › file.dart › Class › method`: the path, then the declarations around the cursor.
/// Right side: this file's +/- counts, the proof legend in Diff, Open in…, and (on the side
/// pane) a close button.
class Breadcrumbs extends StatelessWidget {
  const Breadcrumbs({
    super.key,
    required this.workspaceId,
    required this.path,
    required this.symbols,
    this.file,
    this.showLegend = false,
    this.onClosePane,
    this.openLine,
  });

  final String workspaceId;
  final String path;

  /// Declarations around the cursor, outermost first. Empty for plain path.
  final List<String> symbols;
  final DiffFile? file;
  final bool showLegend;
  final VoidCallback? onClosePane;
  final int? Function()? openLine;

  @override
  Widget build(BuildContext context) {
    final parts = path.split('/');
    final style = HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0);
    final crumbs = <Widget>[];
    void add(String text, Color color, Key? key) {
      if (crumbs.isNotEmpty) {
        crumbs.add(Text('›', style: style));
        crumbs.add(const SizedBox(width: 8));
      }
      crumbs.add(
        Text(
          text,
          key: key,
          maxLines: 1,
          softWrap: false,
          style: style.copyWith(color: color),
        ),
      );
      crumbs.add(const SizedBox(width: 8));
    }

    for (var i = 0; i < parts.length; i++) {
      final last = i == parts.length - 1;
      add(
        parts[i],
        last ? HaroTokens.ink : HaroTokens.ink42,
        ValueKey(last ? 'crumb-file' : 'crumb-dir-$i'),
      );
    }
    for (var i = 0; i < symbols.length; i++) {
      add(symbols[i], HaroTokens.ink66, ValueKey('crumb-symbol-$i'));
    }
    if (crumbs.isNotEmpty) crumbs.removeLast();

    final f = file;
    return Container(
      height: CrumbTokens.height,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: HaroTokens.line08)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          // What fits beside the path, in priority order: Open in, the legend, the tag, the counts.
          var room = box.maxWidth - CrumbTokens.minPath - CrumbTokens.openIn;
          if (onClosePane != null) room -= CrumbTokens.closeButton;
          bool take(double w) {
            if (room < w) return false;
            room -= w;
            return true;
          }

          final tag = f == null ? null : tagLabel(f);
          final showLegendNow = showLegend && take(CrumbTokens.legend);
          final showTag = tag != null && take(tag.length * 7.4 + 12);
          final showCounts =
              f != null &&
              (f.additions > 0 || f.deletions > 0) &&
              take(CrumbTokens.counts);
          return Row(
            children: [
              Expanded(
                child: ClipRect(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    physics: const NeverScrollableScrollPhysics(),
                    child: Row(children: crumbs),
                  ),
                ),
              ),
              if (showTag) ...[
                const SizedBox(width: 12),
                Text(
                  tag,
                  key: const ValueKey('crumb-tag'),
                  style: CodeTokens.label(size: 10),
                ),
              ],
              if (showCounts) ...[
                const SizedBox(width: 12),
                _Counts(added: f.additions, removed: f.deletions),
              ],
              if (showLegendNow) ...[
                const SizedBox(width: 14),
                const ProofLegend(),
              ],
              const SizedBox(width: 12),
              OpenInButton(
                workspaceId: workspaceId,
                source: 'code',
                path: path,
                line: openLine,
                height: 22,
              ),
              if (onClosePane != null) ...[
                const SizedBox(width: 8),
                HaroPressable(
                  onTap: onClosePane,
                  semanticLabel: 'Close split',
                  builder: (context, hovered) => Padding(
                    key: const ValueKey('close-split'),
                    padding: const EdgeInsets.all(4),
                    child: EditorIcon(
                      EditorIconKind.close,
                      size: 12,
                      color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Counts extends StatelessWidget {
  const _Counts({required this.added, required this.removed});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        if (added > 0)
          TextSpan(
            text: '+$added',
            style: const TextStyle(color: HaroTokens.gate),
          ),
        if (added > 0 && removed > 0) const TextSpan(text: ' '),
        if (removed > 0)
          TextSpan(
            text: '−$removed',
            style: const TextStyle(color: HaroTokens.fail),
          ),
      ],
    ),
    maxLines: 1,
    softWrap: false,
    style: HaroText.mono(size: 11, tracking: 0),
  );
}

/// `● ran in green suite   ○ never ran`, shown over a diff the gate left line data for.
class ProofLegend extends StatelessWidget {
  const ProofLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final small = HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0);
    return Row(
      key: const ValueKey('proof-legend'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(
                text: '●',
                style: TextStyle(color: HaroTokens.gate),
              ),
              const TextSpan(text: ' ran in green suite'),
            ],
          ),
          maxLines: 1,
          softWrap: false,
          style: small,
        ),
        const SizedBox(width: 14),
        Text('○ never ran', maxLines: 1, softWrap: false, style: small),
      ],
    );
  }
}

/// NEW / DELETED / RENAMED after the path; a rename names where it came from.
String? tagLabel(DiffFile f) => switch (f.tag) {
  DiffFileTag.added => 'NEW',
  DiffFileTag.deleted => 'DELETED',
  DiffFileTag.renamed =>
    f.oldPath.isEmpty || f.oldPath == f.newPath
        ? 'RENAMED'
        : 'RENAMED FROM ${basenameOf(f.oldPath)}',
  DiffFileTag.none => null,
};

/// The enclosing declarations for the cursor of [controller] in the file at [path].
List<String> symbolsAtCursor(
  String path,
  CodeLineEditingController controller,
) {
  final lines = controller.codeLines;
  return enclosingSymbols(
    lang: languageForPath(path),
    lineCount: lines.length,
    lineAt: (i) => lines[i].text,
    cursor: controller.selection.extentIndex,
  );
}
