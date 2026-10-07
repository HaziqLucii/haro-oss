import 'dart:async';

import 'package:flutter/foundation.dart';

enum DiagnosticSeverity { error, warning, information, hint }

/// One `textDocument/publishDiagnostics` entry. [line] and [character] are the 0-based start
/// the server sent; nothing is remapped when the buffer changes, the server republishes.
@immutable
class LspDiagnostic {
  const LspDiagnostic({
    required this.line,
    required this.character,
    required this.severity,
    required this.message,
    this.source = '',
    this.code,
  });

  final int line;
  final int character;
  final DiagnosticSeverity severity;
  final String message;

  /// The server's `source` (`typescript` from typescript-language-server), empty when none.
  final String source;

  /// `2322` for `TS2322`; kept as text because servers send numbers or strings.
  final String? code;

  /// Hints are suggestions (unused imports, "could be async"), not problems: the UI skips them.
  bool get shown => severity != DiagnosticSeverity.hint;

  bool get isTypeScript =>
      source.isEmpty || source == 'typescript' || source == 'ts';

  /// `TS2322` for the TypeScript server's numeric codes, the bare code otherwise.
  String? get codeLabel {
    final c = code;
    if (c == null || c.isEmpty) return null;
    return isTypeScript && int.tryParse(c) != null ? 'TS$c' : c;
  }

  /// First line of the message: TS elaborates a type error over several indented lines.
  String get headline => message.split('\n').first.trim();

  @override
  bool operator ==(Object other) =>
      other is LspDiagnostic &&
      other.line == line &&
      other.character == character &&
      other.severity == severity &&
      other.message == message &&
      other.source == source &&
      other.code == code;

  @override
  int get hashCode =>
      Object.hash(line, character, severity, message, source, code);
}

DiagnosticSeverity _severity(Object? n) => switch (n) {
  2 => DiagnosticSeverity.warning,
  3 => DiagnosticSeverity.information,
  4 => DiagnosticSeverity.hint,
  _ => DiagnosticSeverity.error,
};

/// The entries of a `publishDiagnostics` `diagnostics` array; malformed ones are skipped.
List<LspDiagnostic> parseDiagnostics(Object? raw) {
  if (raw is! List) return const [];
  final out = <LspDiagnostic>[];
  for (final d in raw) {
    if (d is! Map) continue;
    final start = (d['range'] as Map?)?['start'];
    final message = d['message'];
    if (start is! Map || message is! String) continue;
    final line = start['line'];
    final character = start['character'];
    if (line is! int || line < 0) continue;
    final code = d['code'];
    out.add(
      LspDiagnostic(
        line: line,
        character: character is int && character >= 0 ? character : 0,
        severity: _severity(d['severity']),
        message: message,
        source: d['source'] is String ? d['source'] as String : '',
        code: code is int || code is String ? '$code' : null,
      ),
    );
  }
  return out;
}

/// Errors first, then by position.
int compareDiagnostics(LspDiagnostic a, LspDiagnostic b) {
  final s = a.severity.index.compareTo(b.severity.index);
  if (s != 0) return s;
  final l = a.line.compareTo(b.line);
  return l != 0 ? l : a.character.compareTo(b.character);
}

/// Diagnostics of one worktree file, for the Problems tab.
@immutable
class FileDiagnostics {
  const FileDiagnostics(this.path, this.items);

  final String path;
  final List<LspDiagnostic> items;
}

/// Coalesces bursts of publishes into one rebuild; clears go out at once.
class DiagnosticsFeed extends ChangeNotifier {
  Timer? _timer;
  bool _disposed = false;

  static const delay = Duration(milliseconds: 120);

  void schedule() {
    if (_disposed || _timer != null) return;
    _timer = Timer(delay, () {
      _timer = null;
      if (!_disposed) notifyListeners();
    });
  }

  void flushNow() {
    _timer?.cancel();
    _timer = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
