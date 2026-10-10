import 'package:re_editor/re_editor.dart';

import 'lsp_client.dart';

/// The LSP language id for a path the TS server handles, or null for every other file.
String? lspLanguageId(String path) {
  final name = path.split('/').last.toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (name.substring(dot + 1)) {
    'ts' => 'typescript',
    'tsx' => 'typescriptreact',
    'js' || 'mjs' || 'cjs' => 'javascript',
    'jsx' => 'javascriptreact',
    _ => null,
  };
}

/// `file://` URI of a worktree-relative [path] under [rootPath].
String lspDocumentUri(String rootPath, String path) {
  final root = rootPath.endsWith('/')
      ? rootPath.substring(0, rootPath.length - 1)
      : rootPath;
  return Uri.file('$root/$path').toString();
}

/// Keeps one buffer's text in step with the server (full-text sync) from [open] to [close].
class LspDocument {
  LspDocument({
    required this.client,
    required this.uri,
    required this.languageId,
    required this.controller,
  });

  final LspClient client;
  final String uri;
  final String languageId;
  final CodeLineEditingController controller;

  CodeLines? _lines;
  bool _open = false;

  void open() {
    if (_open) return;
    _open = true;
    _lines = controller.codeLines;
    client.openDocument(uri, languageId, controller.text);
    controller.addListener(_onChanged);
  }

  void _onChanged() {
    // Cursor moves notify too; only an edit swaps the lines.
    if (identical(controller.codeLines, _lines)) return;
    _lines = controller.codeLines;
    if (!client.tracks(uri)) return;
    client.changeDocument(uri, controller.text);
  }

  void close() {
    if (!_open) return;
    _open = false;
    try {
      controller.removeListener(_onChanged);
    } on Object {
      // The store disposed the buffer's controller first.
    }
    client.closeDocument(uri);
  }
}
