/// Client-side "which function am I in" for the breadcrumb bar. No language server: a
/// declaration is a line matching a per-language pattern, and it encloses the cursor when it
/// is indented less than everything between it and the cursor. Good enough for the common
/// shapes; anything it cannot read yields no symbol and the crumb stays a plain path.
library;

import 'dart:math' as math;

/// How far up from the cursor to look. A declaration further away than this is not worth
/// a scan on every cursor move.
const _maxScan = 4000;

/// Name declared on line [i], or null. [at] reads any line of the file.
typedef _Decl = String? Function(int i, String Function(int) at, int count);

final _dartType = RegExp(
  r'^\s*(?:(?:abstract|base|final|sealed|interface|mixin|augment)\s+)*'
  r'(class|mixin|enum|extension\s+type|extension)\s+(\w+)?',
);
final _dartFn = RegExp(
  r'^\s*(?:(?:static|external|factory|const|late|final|covariant)\s+)*'
  r'(?:[\w<>?,.\[\]]+(?:\s*<[^>]*>)?\??\s+)?'
  r'((?:get\s+|set\s+)?[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)?)\s*\(',
);

final _tsType = RegExp(
  r'^\s*(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?'
  r'(class|interface|enum|namespace)\s+(\w+)',
);
final _tsFn = RegExp(
  r'^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([\w$]+)',
);
final _tsArrow = RegExp(
  r'^\s*(?:export\s+)?(?:const|let|var)\s+([\w$]+)\s*(?::[^=]+)?=\s*'
  r'(?:async\s+)?(?:function\b|\([^)]*\)\s*(?::[^=]+)?=>|[\w$]+\s*=>)',
);
final _tsMethod = RegExp(
  r'^\s*(?:(?:public|private|protected|static|async|readonly|override|get|set|abstract)\s+)*'
  r'([\w$]+)\s*(?:<[^>]*>)?\s*\([^)]*\)?[^;=]*\{\s*$',
);

final _pyDef = RegExp(r'^\s*(?:async\s+)?def\s+(\w+)');
final _pyClass = RegExp(r'^\s*class\s+(\w+)');

final _goFunc = RegExp(
  r'^func\s+(?:\(\s*\w*\s*\*?\s*(\w+)(?:\[[^\]]*\])?\s*\)\s*)?(\w+)',
);
final _goType = RegExp(r'^type\s+(\w+)\s+(?:struct|interface)\b');

final _rsFn = RegExp(
  r'^\s*(?:pub(?:\([^)]*\))?\s+)?(?:(?:async|unsafe|const|extern(?:\s+"[^"]*")?)\s+)*'
  r'fn\s+(\w+)',
);
final _rsItem = RegExp(
  r'^\s*(?:pub(?:\([^)]*\))?\s+)?(struct|enum|trait|mod|union)\s+(\w+)',
);
final _rsImpl = RegExp(
  r'^\s*(?:unsafe\s+)?impl(?:<[^>]*>)?\s+(?:[\w:<>,\s&\[\]]+?\s+for\s+)?'
  r'([\w:]+)',
);

const _notDeclarations = {
  'if',
  'for',
  'while',
  'switch',
  'catch',
  'return',
  'await',
  'throw',
  'else',
  'new',
  'super',
  'this',
  'assert',
  'do',
  'try',
  'with',
  'yield',
  'in',
  'is',
  'as',
  'case',
  'when',
  'print',
  'function',
  'typeof',
};

/// Names of the declarations enclosing 0-based line [cursor], outermost first, at most
/// [limit] of them (the innermost win). [lang] is a `languageForPath` key.
///
/// Reading [lineAt] is lazy so a caller can hand over a big file without copying it.
List<String> enclosingSymbols({
  required String? lang,
  required int lineCount,
  required String Function(int index) lineAt,
  required int cursor,
  int limit = 2,
}) {
  final decl = _declarationFor(lang);
  if (decl == null || lineCount == 0) return const [];
  String? nameAt(int i) => decl(i, lineAt, lineCount);
  final at = cursor.clamp(0, lineCount - 1);
  final out = <String>[];

  var ceiling = _indentOf(lineAt(at));
  if (lineAt(at).trim().isEmpty) {
    // A blank line sits inside whatever the nearest code above it is inside.
    ceiling = 1 << 20;
    for (var i = at - 1; i >= 0 && at - i < 200; i--) {
      if (lineAt(i).trim().isNotEmpty) {
        ceiling = _indentOf(lineAt(i)) + 1;
        break;
      }
    }
  }

  final own = nameAt(at);
  if (own != null) {
    out.add(own);
    ceiling = _indentOf(lineAt(at));
  }

  final stop = math.max(0, at - _maxScan);
  for (var i = at - 1; i >= stop && ceiling > 0; i--) {
    final line = lineAt(i);
    if (line.trim().isEmpty) continue;
    final ind = _indentOf(line);
    if (ind >= ceiling) continue;
    final name = nameAt(i);
    // A closing bracket line (`) {` ending a wrapped signature) can never enclose the
    // cursor, and letting it lower the ceiling would hide the signature it closes.
    if (name == null && _closes(line)) continue;
    ceiling = ind;
    if (name != null) out.add(name);
  }

  final ordered = out.reversed.toList();
  return ordered.length <= limit
      ? ordered
      : ordered.sublist(ordered.length - limit);
}

bool _closes(String line) {
  final t = line.trimLeft();
  return t.startsWith(')') || t.startsWith(']') || t.startsWith('}');
}

int _indentOf(String line) {
  var n = 0;
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 0x20) {
      n++;
    } else if (c == 0x09) {
      n += 4;
    } else {
      break;
    }
  }
  return n;
}

_Decl? _declarationFor(String? lang) => switch (lang) {
  'dart' => _dart,
  'typescript' || 'javascript' => _ts,
  'python' => _py,
  'go' => _go,
  'rust' => _rust,
  _ => null,
};

String? _py(int i, String Function(int) at, int count) {
  final line = at(i);
  final d = _pyDef.firstMatch(line) ?? _pyClass.firstMatch(line);
  return d?.group(1);
}

String? _go(int i, String Function(int) at, int count) {
  final line = at(i);
  final t = _goType.firstMatch(line);
  if (t != null) return t.group(1);
  final f = _goFunc.firstMatch(line);
  if (f == null) return null;
  final recv = f.group(1);
  return recv == null ? f.group(2) : '$recv.${f.group(2)}';
}

String? _rust(int i, String Function(int) at, int count) {
  final line = at(i);
  final f = _rsFn.firstMatch(line);
  if (f != null) return f.group(1);
  final item = _rsItem.firstMatch(line);
  if (item != null) return item.group(2);
  final impl = _rsImpl.firstMatch(line);
  if (impl != null && !line.trimLeft().startsWith('//')) {
    return 'impl ${impl.group(1)}';
  }
  return null;
}

String? _ts(int i, String Function(int) at, int count) {
  final line = at(i);
  final t = _tsType.firstMatch(line);
  if (t != null) return t.group(2);
  final f = _tsFn.firstMatch(line);
  if (f != null) return f.group(1);
  final a = _tsArrow.firstMatch(line);
  if (a != null) return a.group(1);
  final m = _tsMethod.firstMatch(line);
  if (m != null) {
    final name = m.group(1)!;
    if (!_notDeclarations.contains(name)) return name;
  }
  return null;
}

const _dartStatements = {
  'if',
  'for',
  'while',
  'switch',
  'catch',
  'return',
  'await',
  'throw',
  'else',
  'new',
  'assert',
  'do',
  'try',
  'case',
  'yield',
};

final _dartBody = RegExp(r'\)\s*(?:async\*?\s*|sync\*\s*)?(?:=>|\{)');

String? _dart(int i, String Function(int) at, int count) {
  final line = at(i);
  final t = _dartType.firstMatch(line);
  if (t != null && t.group(2) != null) return t.group(2);
  final f = _dartFn.firstMatch(line);
  if (f == null) return null;
  final name = f.group(1)!;
  final bare = name.split(RegExp(r'\s+')).last.split('.').first;
  if (_notDeclarations.contains(bare)) return null;
  if (_dartStatements.contains(
    line.trimLeft().split(RegExp(r'[\s(<]')).first,
  )) {
    return null;
  }
  final trimmed = line.trimRight();
  if (_dartBody.hasMatch(trimmed)) return name;
  if (trimmed.endsWith(';') || trimmed.contains('=')) return null;
  if (trimmed.endsWith('(') || trimmed.endsWith(',')) {
    // A wrapped signature: the `)` line at the same indent decides whether it has a body.
    final ind = _indentOf(line);
    for (var j = i + 1; j < count && j < i + 60; j++) {
      final next = at(j);
      if (next.trim().isEmpty) continue;
      if (_indentOf(next) == ind && next.trimLeft().startsWith(')')) {
        return _dartBody.hasMatch(next.trimRight()) ||
                next.trimRight().endsWith('{')
            ? name
            : null;
      }
    }
  }
  return null;
}
