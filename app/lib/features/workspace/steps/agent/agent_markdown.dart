import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../theme/coding_font.dart';
import '../../../../theme/display_scope.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../overlays/toast.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../../../widgets/shell_icons.dart';
import '../code/syntax.dart';
import 'agent_tokens.dart';
import 'prose_details.dart';

/// Agent prose. Fenced blocks use the shared syntax styles (the muted palette, or monochrome
/// when Display turns colour off); inline code stays plain in the coding font on the raised
/// surface.
MarkdownConfig buildAgentMarkdownConfig([
  String codingFont = DisplayScope.defaultCodingFont,
  bool syntaxColour = true,
  double scale = 1,
  ValueChanged<String>? onLink,
  String Function(String url)? imageUrl,
]) {
  TextStyle heading(double size) => HaroText.text(
    size: size * scale,
    weight: FontWeight.w500,
    color: HaroTokens.ink,
    height: 1.35,
  );
  final prose = scale == 1
      ? AgentTokens.prose
      : AgentTokens.prose.copyWith(
          fontSize: (AgentTokens.prose.fontSize ?? 15) * scale,
        );
  final mono = codingTextStyle(
    codingFont,
    fontSize: 12.5 * scale,
    color: HaroTokens.ink86,
  );

  return MarkdownConfig(
    configs: [
      PConfig(textStyle: prose),
      H1Config(style: heading(22)),
      H2Config(style: heading(19)),
      H3Config(style: heading(16.5)),
      H4Config(style: heading(15)),
      H5Config(style: heading(15)),
      H6Config(style: heading(15)),
      CodeConfig(style: _inlineCodeStyle(codingFont)),
      PreConfig(
        textStyle: mono,
        styleNotMatched: mono,
        builder: (code, language) => _CodeBlock(
          code: code,
          language: language,
          style: mono,
          colour: syntaxColour,
        ),
      ),
      LinkConfig(
        style: TextStyle(
          color: HaroTokens.ink,
          decoration: TextDecoration.underline,
          decorationColor: HaroTokens.line30,
        ),
        onTap: (url) {
          // A caller that owns some links (the Notes tab's `[[wikilinks]]`) gets them first.
          if (onLink != null && url.contains(':')) {
            final scheme = url.substring(0, url.indexOf(':'));
            if (scheme != 'http' && scheme != 'https' && scheme != 'mailto') {
              onLink(url);
              return;
            }
          }
          final uri = safeLinkUri(url);
          if (uri != null) launchUrl(uri);
        },
      ),
      // Markdown here can be written by someone else (a GitHub issue or comment): never fetch
      // an image from it. The alt text stands in.
      ImgConfig(
        builder: (url, attributes) {
          final alt = (attributes['alt'] ?? '').trim();
          final text = Text(
            '▫ ${alt.isEmpty ? 'image' : alt}',
            style: TextStyle(color: HaroTokens.ink42, fontSize: 13 * scale),
          );
          // Only a caller that owns its images (a note's own `assets/`) gets them fetched, and
          // only a relative path: a web URL still stays an alt-text stand-in.
          if (imageUrl == null || url.contains(':') || url.startsWith('/')) {
            return text;
          }
          return Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640, maxHeight: 420),
              child: Image.network(
                imageUrl(url),
                errorBuilder: (_, _, _) => text,
              ),
            ),
          );
        },
        errorBuilder: (url, alt, error) => Text(
          '▫ ${alt.trim().isEmpty ? 'image' : alt.trim()}',
          style: TextStyle(color: HaroTokens.ink42, fontSize: 13 * scale),
        ),
      ),
      BlockquoteConfig(
        sideColor: HaroTokens.line20,
        textColor: HaroTokens.ink66,
        sideWith: 2,
      ),
      HrConfig(height: 1, color: HaroTokens.line12),
      ListConfig(
        marginLeft: 24 * scale,
        marginBottom: 4,
        marker: (ordered, depth, index) => ordered
            ? Align(
                alignment: Alignment.topLeft,
                child: Text(
                  '${index + 1}.',
                  style: HaroText.mono(
                    size: 12.5,
                    color: HaroTokens.ink42,
                    tracking: 0,
                    height: 1.6 * 15 / 12.5,
                  ),
                ),
              )
            : Padding(
                padding: const EdgeInsets.only(top: 9),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox.square(
                    dimension: 5,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: depth == 0
                            ? HaroTokens.ink42
                            : HaroTokens.transparent,
                        border: Border.all(color: HaroTokens.ink42),
                      ),
                    ),
                  ),
                ),
              ),
      ),
      TableConfig(
        wrapper: (table) => HorizontalScroll(
          key: const ValueKey('agent-table-scroll'),
          child: table,
        ),
        border: TableBorder.all(color: HaroTokens.line12),
        headerStyle: prose.copyWith(
          color: HaroTokens.ink,
          fontWeight: FontWeight.w500,
        ),
        bodyStyle: prose,
      ),
    ],
  );
}

/// markdown_widget's own fenced-block pipeline (the `highlight` package) uses other scope
/// names than the editor and diff, so blocks are drawn here with the same re_highlight
/// styles instead. A click anywhere on the block copies its code; the text inside is not
/// selectable, so a drag never starts a selection that has nothing to show.
class _CodeBlock extends StatefulWidget {
  const _CodeBlock({
    required this.code,
    required this.language,
    required this.style,
    required this.colour,
  });

  final String code;
  final String language;
  final TextStyle style;
  final bool colour;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy(String body) async {
    await Clipboard.setData(ClipboardData(text: body));
    if (!mounted) return;
    showHaroToast(context, 'Copied', duration: const Duration(seconds: 2));
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.code.trimRight();
    final span = LineHighlighter.shared.highlightBlock(
      body,
      languageForFence(widget.language),
      colour: widget.colour,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: HaroPressable(
        onTap: () => _copy(body),
        tooltip: 'Click to copy',
        semanticLabel: 'Copy code',
        builder: (context, hovered) => Container(
          key: const ValueKey('agent-code-block'),
          width: double.infinity,
          decoration: BoxDecoration(
            color: HaroTokens.panel,
            border: Border.all(
              color: hovered ? HaroTokens.line30 : HaroTokens.line12,
            ),
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                child: SelectionContainer.disabled(
                  child: HorizontalScroll(
                    gap: 6,
                    child: Text.rich(
                      span ?? TextSpan(text: body, style: widget.style),
                      softWrap: false,
                      style: widget.style,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 10,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: hovered || _copied ? 1 : 0,
                    child: ShellIconView(
                      _copied ? ShellIcon.check : ShellIcon.copy,
                      key: const ValueKey('agent-code-copy-icon'),
                      size: 14,
                      color: HaroTokens.ink66,
                    ),
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

/// A wide child (a table, a fenced block) that scrolls sideways with a visible bar. The bar
/// is what makes it reachable with a mouse wheel, which only scrolls vertically, and it only
/// draws when the child actually overflows.
class HorizontalScroll extends StatefulWidget {
  const HorizontalScroll({super.key, required this.child, this.gap = 10});

  final Widget child;

  /// Room under the child for the bar, so it does not sit on the last line.
  final double gap;

  @override
  State<HorizontalScroll> createState() => _HorizontalScrollState();
}

class _HorizontalScrollState extends State<HorizontalScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _controller,
    thumbVisibility: true,
    notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
    child: SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.only(bottom: widget.gap),
      child: widget.child,
    ),
  );
}

TextStyle _inlineCodeStyle(String codingFont) =>
    codingTextStyle(codingFont, fontSize: 13, color: HaroTokens.ink86);

/// markdown_widget merges the parent (prose) style over `CodeConfig.style`, so the prose font
/// would win. This node applies the code style last. Inline code is a small button: one click
/// copies it.
class _InlineCodeNode extends SpanNode {
  _InlineCodeNode(this.text, this.codeStyle);

  final String text;
  final TextStyle codeStyle;

  @override
  InlineSpan build() => WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: _InlineCode(
      text: text,
      style: (parentStyle ?? const TextStyle()).merge(codeStyle),
    ),
  );
}

class _InlineCode extends StatelessWidget {
  const _InlineCode({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: () async {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        showHaroToast(context, 'Copied', duration: const Duration(seconds: 2));
      }
    },
    semanticLabel: 'Copy $text',
    builder: (context, hovered) => Container(
      key: const ValueKey('agent-inline-code'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: hovered ? HaroTokens.line12 : HaroTokens.raised,
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      // Selectable like the text around it, so copying a paragraph keeps its inline code.
      child: Text(text, style: style),
    ),
  );
}

MarkdownGenerator buildAgentMarkdownGenerator(String codingFont) =>
    MarkdownGenerator(
      generators: [
        SpanNodeGeneratorWithTag(
          tag: MarkdownTag.code.name,
          generator: (e, config, visitor) =>
              _InlineCodeNode(e.textContent, _inlineCodeStyle(codingFont)),
        ),
      ],
    );

/// The markdown body of one prose row. Selection comes from the list's own `SelectionArea`.
/// The URL a markdown link may open: web pages and mail only. A link in an issue comment is
/// attacker-controlled text, and `file:`, `smb:`, `vscode:` and the like launch apps or mount
/// shares when handed to the OS.
Uri? safeLinkUri(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  return const {'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase())
      ? uri
      : null;
}

class AgentProse extends StatelessWidget {
  const AgentProse(
    this.text, {
    super.key,
    this.compact = false,
    this.onLink,
    this.imageUrl,
  });

  final String text;

  /// Smaller type for the narrow rail (a sub-agent's feed), the same renderer otherwise.
  final bool compact;

  /// Told of a link whose scheme is not http, https or mailto (the Notes tab's own links);
  /// without it such a link is dropped, as before. Not cached: the handler belongs to the caller.
  final ValueChanged<String>? onLink;

  /// Maps a relative image path to where it is served from (the Notes tab's `assets/`). Without
  /// it no image is ever fetched.
  final String Function(String url)? imageUrl;

  static final _configs =
      <
        (String, bool, bool, String, String),
        (MarkdownConfig, MarkdownGenerator)
      >{};

  @override
  Widget build(BuildContext context) {
    final font = DisplayScope.codingFontOf(context);
    final colour = DisplayScope.syntaxColourOf(context);
    final (config, generator) = onLink != null || imageUrl != null
        ? (
            buildAgentMarkdownConfig(
              font,
              colour,
              compact ? .84 : 1,
              onLink,
              imageUrl,
            ),
            buildAgentMarkdownGenerator(font),
          )
        : _configs.putIfAbsent(
            (font, colour, compact, HaroTokens.palette.id, HaroTokens.fontText),
            () => (
              buildAgentMarkdownConfig(font, colour, compact ? .84 : 1),
              buildAgentMarkdownGenerator(font),
            ),
          );
    // Keyed by everything the config was built from: MarkdownBlock keeps the widgets it generated
    // until its text changes, so without this a theme or font switch left text already on screen
    // in the old colours (dark-theme bone on Paper's white).
    // Plus the segment's index: a text with `<details>` has several blocks in one column.
    Widget block(String data, [int index = 0]) => MarkdownBlock(
      key: ValueKey((
        font,
        colour,
        compact,
        HaroTokens.palette.id,
        HaroTokens.fontText,
        index,
      )),
      data: data,
      selectable: false,
      config: config,
      generator: generator,
    );
    final segments = splitDetails(text);
    if (segments.length == 1 && segments.first is MarkdownSegment) {
      return block(text);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, seg) in segments.indexed)
          switch (seg) {
            MarkdownSegment(:final text) =>
              text.trim().isEmpty ? const SizedBox.shrink() : block(text, i),
            DetailsSegment() => ProseDetails(
              summary: seg.summary,
              open: seg.open,
              compact: compact,
              child: seg.body.isEmpty
                  ? const SizedBox.shrink()
                  : AgentProse(
                      seg.body,
                      compact: compact,
                      onLink: onLink,
                      imageUrl: imageUrl,
                    ),
            ),
          },
      ],
    );
  }
}

/// A `<details>` block: the summary line with a chevron, the body below once opened.
class ProseDetails extends StatefulWidget {
  const ProseDetails({
    super.key,
    required this.summary,
    required this.child,
    this.open = false,
    this.compact = false,
  });

  final String summary;
  final Widget child;
  final bool open;
  final bool compact;

  @override
  State<ProseDetails> createState() => _ProseDetailsState();
}

class _ProseDetailsState extends State<ProseDetails> {
  late bool _open = widget.open;

  @override
  Widget build(BuildContext context) {
    final size = widget.compact ? 12.0 : 14.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HaroPressable(
            onTap: () => setState(() => _open = !_open),
            semanticLabel: widget.summary,
            builder: (context, hovered) => Row(
              children: [
                ShellIconView(
                  _open ? ShellIcon.chevronDown : ShellIcon.chevronRight,
                  size: size + 2,
                  color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    widget.summary,
                    style: HaroText.ui(
                      size: size,
                      weight: FontWeight.w500,
                      color: hovered ? HaroTokens.ink : HaroTokens.ink86,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_open)
            Container(
              margin: const EdgeInsets.only(left: 7, top: 6),
              padding: const EdgeInsets.only(left: 14),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: HaroTokens.line14)),
              ),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}
