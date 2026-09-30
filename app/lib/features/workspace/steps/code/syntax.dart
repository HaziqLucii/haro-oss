import 'package:flutter/painting.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/less.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

import 'code_tokens.dart';

final Map<String, Mode> _modes = {
  'bash': langBash,
  'c': langC,
  'cpp': langCpp,
  'csharp': langCsharp,
  'css': langCss,
  'dart': langDart,
  'dockerfile': langDockerfile,
  'go': langGo,
  'graphql': langGraphql,
  'ini': langIni,
  'java': langJava,
  'javascript': langJavascript,
  'json': langJson,
  'kotlin': langKotlin,
  'less': langLess,
  'lua': langLua,
  'makefile': langMakefile,
  'markdown': langMarkdown,
  'php': langPhp,
  'python': langPython,
  'ruby': langRuby,
  'rust': langRust,
  'scss': langScss,
  'sql': langSql,
  'swift': langSwift,
  'typescript': langTypescript,
  'xml': langXml,
  'yaml': langYaml,
};

const _byExtension = {
  'ts': 'typescript',
  'tsx': 'typescript',
  'mts': 'typescript',
  'cts': 'typescript',
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'json': 'json',
  'jsonc': 'json',
  'md': 'markdown',
  'markdown': 'markdown',
  'mdx': 'markdown',
  'css': 'css',
  'scss': 'scss',
  'less': 'less',
  'html': 'xml',
  'htm': 'xml',
  'xml': 'xml',
  'svg': 'xml',
  'vue': 'xml',
  'py': 'python',
  'pyi': 'python',
  'go': 'go',
  'rs': 'rust',
  'rb': 'ruby',
  'java': 'java',
  'php': 'php',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'cs': 'csharp',
  'c': 'c',
  'h': 'c',
  'cpp': 'cpp',
  'cc': 'cpp',
  'cxx': 'cpp',
  'hpp': 'cpp',
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'fish': 'bash',
  'yaml': 'yaml',
  'yml': 'yaml',
  'sql': 'sql',
  'lua': 'lua',
  'swift': 'swift',
  'dart': 'dart',
  'toml': 'ini',
  'ini': 'ini',
  'graphql': 'graphql',
  'gql': 'graphql',
};

const _byFilename = {
  'dockerfile': 'dockerfile',
  'makefile': 'makefile',
  '.gitignore': 'bash',
  '.env': 'ini',
};

/// The highlight language id for [path], or null for plain text.
String? languageForPath(String path) {
  final name = path.split('/').last.toLowerCase();
  final byName = _byFilename[name];
  if (byName != null) return byName;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  return _byExtension[name.substring(dot + 1)];
}

/// Display name for the edit footer.
String languageLabel(String? lang) => switch (lang) {
  null => 'Plain text',
  'typescript' => 'TypeScript',
  'javascript' => 'JavaScript',
  'cpp' => 'C++',
  'csharp' => 'C#',
  'xml' => 'HTML/XML',
  'json' => 'JSON',
  'css' => 'CSS',
  'scss' => 'SCSS',
  'sql' => 'SQL',
  'php' => 'PHP',
  'yaml' => 'YAML',
  'graphql' => 'GraphQL',
  'ini' => 'INI/TOML',
  final l => l[0].toUpperCase() + l.substring(1),
};

Mode? modeForLanguage(String? lang) => lang == null ? null : _modes[lang];

/// Highlight language for a fenced-block info string (```ts, ```sh, ```json), or null.
String? languageForFence(String? info) {
  final tag = info?.trim().toLowerCase().split(RegExp(r'\s+')).first ?? '';
  if (tag.isEmpty) return null;
  if (_modes.containsKey(tag)) return tag;
  return switch (tag) {
    'shell' || 'console' || 'terminal' => 'bash',
    'text' || 'txt' || 'plain' || 'plaintext' || 'diff' => null,
    _ => languageForPath('x.$tag'),
  };
}

/// Highlighting for diff rows (one line at a time: a diff has no reliable surrounding
/// context) and for whole fenced blocks. Results are cached because a virtualized list
/// rebuilds rows as they scroll back into view.
class LineHighlighter {
  LineHighlighter({int cacheLimit = 4000}) : _limit = cacheLimit;

  static final LineHighlighter shared = LineHighlighter();

  /// Blocks past this are drawn plain: highlighting them would stall the frame.
  static const maxBlockChars = 20000;

  final int _limit;
  final Highlight _highlight = Highlight()..registerLanguages(_modes);
  final _cache = <String, TextSpan?>{};

  /// Null when the language is unknown, the line is too long, or highlighting failed:
  /// callers draw plain text.
  TextSpan? highlight(
    String text,
    String? lang, {
    bool dim = false,
    bool colour = true,
  }) {
    if (lang == null ||
        text.isEmpty ||
        text.length > CodeTokens.diffMaxHighlightChars) {
      return null;
    }
    return _run(text, lang, dim: dim, colour: colour);
  }

  /// A multi-line block, for fenced code in agent prose.
  TextSpan? highlightBlock(String text, String? lang, {bool colour = true}) {
    final tooBig = text.length > maxBlockChars;
    if (lang == null || text.isEmpty || tooBig) return null;
    return _run(text, lang, dim: false, colour: colour);
  }

  TextSpan? _run(
    String text,
    String lang, {
    required bool dim,
    required bool colour,
  }) {
    final key = '${dim ? 1 : 0}${colour ? 1 : 0}$lang\u0000$text';
    if (_cache.containsKey(key)) return _cache[key];
    if (_cache.length >= _limit) _cache.clear();
    TextSpan? span;
    try {
      final result = _highlight.highlight(code: text, language: lang);
      final renderer = TextSpanRenderer(
        null,
        syntaxStyles(colour: colour, dim: dim),
      );
      result.render(renderer);
      span = renderer.span;
    } on Object {
      span = null;
    }
    _cache[key] = span;
    return span;
  }
}
