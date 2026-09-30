import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../theme/coding_font.dart';
import '../../../../theme/display_scope.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../code/syntax.dart';
import 'agent_tokens.dart';

/// Agent prose. Fenced blocks use the shared syntax styles (the muted palette, or monochrome
/// when Display turns colour off); inline code stays plain in the coding font on the raised
/// surface.
MarkdownConfig buildAgentMarkdownConfig([
  String codingFont = DisplayScope.defaultCodingFont,
  bool syntaxColour = true,
]) {
  TextStyle heading(double size) => HaroText.ui(
    size: size,
    weight: FontWeight.w500,
    color: HaroTokens.ink,
    height: 1.35,
  );
  final mono = codingTextStyle(
    codingFont,
    fontSize: 12.5,
    color: HaroTokens.ink86,
  );

  return MarkdownConfig(
    configs: [
      PConfig(textStyle: AgentTokens.prose),
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
        style: const TextStyle(
          color: HaroTokens.ink,
          decoration: TextDecoration.underline,
          decorationColor: HaroTokens.line30,
        ),
        onTap: (url) {
          final uri = Uri.tryParse(url);
          if (uri != null) launchUrl(uri);
        },
      ),
      BlockquoteConfig(
        sideColor: HaroTokens.line20,
        textColor: HaroTokens.ink66,
        sideWith: 2,
      ),
      const HrConfig(height: 1, color: HaroTokens.line12),
      ListConfig(
        marginLeft: 24,
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
        border: TableBorder.all(color: HaroTokens.line12),
        headerStyle: AgentTokens.prose.copyWith(
          color: HaroTokens.ink,
          fontWeight: FontWeight.w500,
        ),
        bodyStyle: AgentTokens.prose,
      ),
    ],
  );
}

/// markdown_widget's own fenced-block pipeline (the `highlight` package) uses other scope
/// names than the editor and diff, so blocks are drawn here with the same re_highlight
/// styles instead.
class _CodeBlock extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final body = code.trimRight();
    final span = LineHighlighter.shared.highlightBlock(
      body,
      languageForFence(language),
      colour: colour,
    );
    return Container(
      key: const ValueKey('agent-code-block'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: HaroTokens.panel,
        border: Border.all(color: HaroTokens.line12),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text.rich(
          span ?? TextSpan(text: body, style: style),
          softWrap: false,
          style: style,
        ),
      ),
    );
  }
}

TextStyle _inlineCodeStyle(String codingFont) => codingTextStyle(
  codingFont,
  fontSize: 13,
  color: HaroTokens.ink86,
).copyWith(backgroundColor: HaroTokens.raised);

/// markdown_widget merges the parent (prose) style over `CodeConfig.style`, so the prose font
/// would win. This node applies the code style last.
class _InlineCodeNode extends SpanNode {
  _InlineCodeNode(this.text, this.codeStyle);

  final String text;
  final TextStyle codeStyle;

  @override
  InlineSpan build() => TextSpan(
    text: text,
    style: (parentStyle ?? const TextStyle()).merge(codeStyle),
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
class AgentProse extends StatelessWidget {
  const AgentProse(this.text, {super.key});

  final String text;

  static final _configs =
      <(String, bool), (MarkdownConfig, MarkdownGenerator)>{};

  @override
  Widget build(BuildContext context) {
    final font = DisplayScope.codingFontOf(context);
    final colour = DisplayScope.syntaxColourOf(context);
    final (config, generator) = _configs.putIfAbsent(
      (font, colour),
      () => (
        buildAgentMarkdownConfig(font, colour),
        buildAgentMarkdownGenerator(font),
      ),
    );
    return MarkdownBlock(
      data: text,
      selectable: false,
      config: config,
      generator: generator,
    );
  }
}
