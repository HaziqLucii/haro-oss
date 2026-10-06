import 'dart:io';

import 'lsp_client.dart';

/// Where a definition lives: the server's `file://` [uri] and the 0-based start position.
class DefinitionTarget {
  const DefinitionTarget(this.uri, this.line, this.character);

  final String uri;
  final int line;
  final int character;
}

/// What the editor should do with a definition.
sealed class DefinitionJump {
  const DefinitionJump();
}

/// A file the workspace's file API can open. [line] and [column] are 1-based.
class OpenDefinition extends DefinitionJump {
  const OpenDefinition(this.path, this.line, this.column);

  final String path;
  final int line;
  final int column;
}

/// A target the editor cannot open (a dependency outside the worktree). [label] is what the
/// toast shows.
class OutsideDefinition extends DefinitionJump {
  const OutsideDefinition(this.label);

  final String label;
}

/// The first location of a `textDocument/definition` result (a Location, a list of Locations
/// or of LocationLinks). Later ones are dropped: there is no picker.
DefinitionTarget? firstDefinition(Object? raw) {
  final first = raw is List ? raw.firstOrNull : raw;
  if (first is! Map) return null;
  final link = first['targetUri'];
  final uri = link ?? first['uri'];
  final range = link != null
      ? (first['targetSelectionRange'] ?? first['targetRange'])
      : first['range'];
  final start = range is Map ? range['start'] : null;
  if (uri is! String || start is! Map) return null;
  final line = start['line'];
  final character = start['character'];
  if (line is! int || line < 0) return null;
  return DefinitionTarget(
    uri,
    line,
    character is int && character >= 0 ? character : 0,
  );
}

typedef RealPath = String? Function(String absolute);

String? _diskRealPath(String absolute) {
  try {
    return File(absolute).resolveSymbolicLinksSync();
  } on Object {
    return null;
  }
}

String _label(String absolute) {
  final at = absolute.lastIndexOf('/node_modules/');
  return at < 0 ? absolute : absolute.substring(at + 1);
}

/// Maps [target] to a worktree-relative path, or to [OutsideDefinition].
///
/// A worktree's `node_modules` is a symlink to the project's, and the server reports the real
/// path, so a dependency's `.d.ts` normally arrives as a path outside the worktree. The file
/// API resolves symlinks and refuses such a path, so it is reported rather than opened. A
/// `node_modules` path under the worktree is opened only when it really lives inside it.
/// [realPath] is for tests.
DefinitionJump jumpForDefinition(
  String rootPath,
  DefinitionTarget target, {
  RealPath realPath = _diskRealPath,
}) {
  final uri = Uri.tryParse(target.uri);
  if (uri == null || uri.scheme != 'file') {
    return OutsideDefinition(target.uri);
  }
  final absolute = uri.toFilePath();
  final root = rootPath.endsWith('/')
      ? rootPath.substring(0, rootPath.length - 1)
      : rootPath;
  final realRoot = realPath(root);
  String? rel;
  for (final r in {root, ?realRoot}) {
    if (absolute.startsWith('$r/') && absolute.length > r.length + 1) {
      rel = absolute.substring(r.length + 1);
      break;
    }
  }
  if (rel == null) return OutsideDefinition(_label(absolute));
  if (rel.split('/').contains('node_modules')) {
    final real = realPath(absolute);
    final base = realRoot ?? root;
    if (real == null || !real.startsWith('$base/')) {
      return OutsideDefinition(_label(absolute));
    }
  }
  return OpenDefinition(rel, target.line + 1, target.character + 1);
}

/// Asks the server for the definition at the 0-based [line] and [character] of [uri]. Null
/// when there is nothing to jump to (no server, no answer, empty answer).
Future<DefinitionJump?> resolveDefinition(
  LspClient client,
  String uri,
  int line,
  int character, {
  RealPath realPath = _diskRealPath,
}) async {
  final target = firstDefinition(await client.definition(uri, line, character));
  if (target == null) return null;
  return jumpForDefinition(client.rootPath, target, realPath: realPath);
}
