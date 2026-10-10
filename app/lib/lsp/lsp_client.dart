import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'lsp_diagnostics.dart';

enum LspStatus { idle, starting, ready, unavailable }

class LspException implements Exception {
  const LspException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'LspException($code): $message';
}

const lspInstallHint =
    'TS language server not found: npm i -g typescript typescript-language-server';

class _Doc {
  _Doc(this.languageId, this.text);

  final String languageId;
  String text;
  int version = 1;
  bool sent = false;

  /// Editors holding this document open (the same file in both split panes).
  int refs = 1;
}

/// JSON-RPC to the backend's language-server bridge (`/ws/workspaces/{id}/lsp`): one message per
/// text frame, no Content-Length framing. The backend spawns one server per socket, so a
/// workspace keeps exactly one of these. It never throws into the UI: any failure (no server
/// installed, `initialize` refused, socket gone) ends in [LspStatus.unavailable] with a
/// [unavailableReason], and requests then answer null. No reconnect.
class LspClient extends ChangeNotifier {
  LspClient({required this.connect, required this.rootPath});

  final WebSocketChannel Function() connect;

  /// The worktree's absolute path; empty means there is nothing to serve.
  final String rootPath;

  LspStatus _status = LspStatus.idle;
  String? _reason;
  bool _noticeTaken = false;
  bool _disposed = false;
  int _nextId = 0;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _settled = Completer<void>();
  final _pending = <int, Completer<Object?>>{};
  final _docs = <String, _Doc>{};
  final _diagnostics = <String, List<LspDiagnostic>>{};

  /// Fires (debounced) when any document's diagnostics change, and at once when they clear.
  /// Advisory: nothing in the client reads it back.
  final diagnosticsFeed = DiagnosticsFeed();

  LspStatus get status => _status;

  /// Human text for the notice, set once [status] is [LspStatus.unavailable].
  String? get unavailableReason => _reason;

  /// True exactly once after the client became unavailable, so the notice shows once per
  /// workspace however many editors are open.
  bool takeNotice() {
    if (_status != LspStatus.unavailable || _noticeTaken) return false;
    return _noticeTaken = true;
  }

  /// The version the server holds for [uri], bumped on every text change; null when not open.
  int? versionOf(String uri) => _docs[uri]?.version;

  String get rootUri => Uri.file(rootPath).toString();

  /// What the server last published for [uri] (empty when none, or after didClose).
  List<LspDiagnostic> diagnosticsOf(String uri) =>
      _diagnostics[uri] ?? const [];

  /// Every open file's diagnostics by worktree-relative path.
  List<FileDiagnostics> diagnosticsByPath() {
    final prefix = rootUri.endsWith('/') ? rootUri : '$rootUri/';
    return [
      for (final e in _diagnostics.entries)
        if (e.key.startsWith(prefix))
          FileDiagnostics(
            Uri.decodeFull(e.key.substring(prefix.length)),
            e.value,
          ),
    ];
  }

  /// [uri] null clears everything and tells listeners at once (the server is gone). One file
  /// is cleared from didClose, which runs while the editor is being unmounted, so listeners
  /// hear about it on the debounce timer instead of inside that build phase.
  void _clearDiagnostics([String? uri]) {
    final had = uri == null
        ? _diagnostics.isNotEmpty
        : _diagnostics.remove(uri) != null;
    if (uri == null) _diagnostics.clear();
    if (!had || _disposed) return;
    uri == null ? diagnosticsFeed.flushNow() : diagnosticsFeed.schedule();
  }

  void _onDiagnostics(Object? params) {
    if (params is! Map) return;
    final uri = params['uri'];
    final doc = uri is String ? _docs[uri] : null;
    if (uri is! String || doc == null) return;
    final version = params['version'];
    if (version is int && version < doc.version) return;
    final items = parseDiagnostics(params['diagnostics']);
    final before = _diagnostics[uri] ?? const <LspDiagnostic>[];
    if (listEquals(before, items)) return;
    if (items.isEmpty) {
      _diagnostics.remove(uri);
    } else {
      _diagnostics[uri] = items;
    }
    diagnosticsFeed.schedule();
  }

  void _set(LspStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_disposed) notifyListeners();
  }

  /// Opens the socket and runs the handshake. Idempotent; callers need not await it.
  Future<void> start() async {
    if (_status != LspStatus.idle || _disposed) return;
    if (rootPath.isEmpty) {
      _fail('TS language server needs a worktree');
      return;
    }
    _set(LspStatus.starting);
    try {
      final ch = connect();
      _channel = ch;
      await ch.ready;
      if (_disposed) return;
      _sub = ch.stream.listen(
        _onFrame,
        onError: (Object _) => _lost('TS language server disconnected'),
        onDone: () => _lost('TS language server disconnected'),
        cancelOnError: true,
      );
    } on Object {
      _fail('TS language server is unreachable');
      return;
    }
    try {
      await _request('initialize', {
        'processId': null,
        'rootUri': rootUri,
        'workspaceFolders': [
          {'uri': rootUri, 'name': 'workspace'},
        ],
        'capabilities': {
          'workspace': {'configuration': false},
          'textDocument': {
            'synchronization': {'dynamicRegistration': false},
            'completion': {
              'completionItem': {'snippetSupport': false},
            },
            'publishDiagnostics': {'versionSupport': true},
            'definition': {'dynamicRegistration': false, 'linkSupport': false},
            'hover': {
              'dynamicRegistration': false,
              'contentFormat': ['markdown', 'plaintext'],
            },
            'formatting': {'dynamicRegistration': false},
          },
        },
      });
    } on LspException catch (e) {
      _fail('TS language server failed to start: ${_oneLine(e.message)}');
      return;
    }
    if (_status != LspStatus.starting) return;
    _notify('initialized', const {});
    _set(LspStatus.ready);
    for (final e in _docs.entries) {
      _sendOpen(e.key, e.value);
    }
    if (!_settled.isCompleted) _settled.complete();
  }

  String _oneLine(String s) {
    final line = s.split('\n').first.trim();
    return line.length > 120 ? '${line.substring(0, 120)}...' : line;
  }

  void _fail(String reason) {
    if (_status == LspStatus.unavailable) return;
    _reason = reason;
    _failPending();
    _clearDiagnostics();
    _set(LspStatus.unavailable);
    if (!_settled.isCompleted) _settled.complete();
  }

  void _lost(String reason) {
    if (_disposed) return;
    _fail(reason);
  }

  void _failPending() {
    final all = _pending.values.toList();
    _pending.clear();
    for (final c in all) {
      c.complete(null);
    }
  }

  void _onFrame(dynamic data) {
    if (data is! String || _disposed) return;
    final Object? msg;
    try {
      msg = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (msg is! Map) return;
    final control = msg['haro'];
    if (control == 'lsp_unavailable') {
      _fail(switch (msg['reason']) {
        'not_installed' => lspInstallHint,
        'spawn_failed' => 'TS language server failed to start',
        final r => 'TS language server unavailable: $r',
      });
      return;
    }
    if (control == 'lsp_exited') {
      _fail('TS language server stopped');
      return;
    }
    final id = msg['id'];
    final method = msg['method'];
    if (method is String) {
      if (method == 'textDocument/publishDiagnostics' && id == null) {
        _onDiagnostics(msg['params']);
        return;
      }
      // Server to client requests (registerCapability, configuration, progress): the
      // client has nothing to offer, and an unanswered request can stall the server.
      if (id != null) _send({'jsonrpc': '2.0', 'id': id, 'result': null});
      return;
    }
    if (id is! int) return;
    final waiting = _pending.remove(id);
    if (waiting == null) return;
    final err = msg['error'];
    if (err is Map) {
      waiting.completeError(
        LspException(
          err['code'] is int ? err['code'] as int : -1,
          '${err['message'] ?? 'language server error'}',
        ),
      );
    } else {
      waiting.complete(msg['result']);
    }
  }

  void _send(Map<String, Object?> msg) {
    if (_disposed) return;
    try {
      _channel?.sink.add(jsonEncode(msg));
    } on Object {
      // A dead sink surfaces through the stream's onDone.
    }
  }

  void _notify(String method, Map<String, Object?> params) =>
      _send({'jsonrpc': '2.0', 'method': method, 'params': params});

  Future<Object?> _request(String method, Map<String, Object?> params) {
    if (_disposed || _status == LspStatus.unavailable) {
      return Future.value(null);
    }
    final id = ++_nextId;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return c.future;
  }

  void _sendOpen(String uri, _Doc d) {
    d.sent = true;
    _notify('textDocument/didOpen', {
      'textDocument': {
        'uri': uri,
        'languageId': d.languageId,
        'version': d.version,
        'text': d.text,
      },
    });
  }

  /// Registers [uri] with [text] and starts the server on the first call. Held back until the
  /// handshake finishes, then sent with whatever the text has become.
  void openDocument(String uri, String languageId, String text) {
    if (_disposed || _status == LspStatus.unavailable) return;
    final existing = _docs[uri];
    if (existing != null) {
      existing.refs++;
      changeDocument(uri, text);
      return;
    }
    final d = _docs[uri] = _Doc(languageId, text);
    if (_status == LspStatus.ready) {
      _sendOpen(uri, d);
    } else {
      unawaited(start());
    }
  }

  /// True while [uri] is open and the server can still use changes to it.
  bool tracks(String uri) =>
      _docs.containsKey(uri) && _status != LspStatus.unavailable;

  void changeDocument(String uri, String text) {
    final d = _docs[uri];
    if (d == null || d.text == text) return;
    d.text = text;
    d.version++;
    if (d.sent && _status == LspStatus.ready) {
      _notify('textDocument/didChange', {
        'textDocument': {'uri': uri, 'version': d.version},
        'contentChanges': [
          {'text': text},
        ],
      });
    }
  }

  void closeDocument(String uri) {
    final d = _docs[uri];
    if (d == null || --d.refs > 0) return;
    _docs.remove(uri);
    _clearDiagnostics(uri);
    if (d.sent && _status == LspStatus.ready) {
      _notify('textDocument/didClose', {
        'textDocument': {'uri': uri},
      });
    }
  }

  /// The raw `textDocument/completion` result (a list or a `CompletionList` map), or null when
  /// the server is unavailable or refused. Waits for the handshake.
  Future<Object?> completion(
    String uri,
    int line,
    int character, {
    String? triggerCharacter,
  }) async {
    return _safe(
      () => _request('textDocument/completion', {
        'textDocument': {'uri': uri},
        'position': {'line': line, 'character': character},
        'context': {
          'triggerKind': triggerCharacter == null ? 1 : 2,
          'triggerCharacter': ?triggerCharacter,
        },
      }),
    );
  }

  /// The raw `textDocument/definition` result (a Location, a list of them, or LocationLinks),
  /// or null when the server is unavailable or refused.
  Future<Object?> definition(String uri, int line, int character) => _safe(
    () => _request('textDocument/definition', {
      'textDocument': {'uri': uri},
      'position': {'line': line, 'character': character},
    }),
  );

  /// The raw `textDocument/hover` result, or null.
  Future<Object?> hover(String uri, int line, int character) => _safe(
    () => _request('textDocument/hover', {
      'textDocument': {'uri': uri},
      'position': {'line': line, 'character': character},
    }),
  );

  /// The raw `textDocument/formatting` result (a list of TextEdits), or null.
  Future<Object?> formatting(
    String uri, {
    required int tabSize,
    required bool insertSpaces,
  }) => _safe(
    () => _request('textDocument/formatting', {
      'textDocument': {'uri': uri},
      'options': {'tabSize': tabSize, 'insertSpaces': insertSpaces},
    }),
  );

  Future<Map<String, Object?>?> resolveCompletionItem(
    Map<String, Object?> item,
  ) async {
    final r = await _safe(() => _request('completionItem/resolve', item));
    return r is Map ? r.cast<String, Object?>() : null;
  }

  Future<Object?> _safe(Future<Object?> Function() call) async {
    await _settled.future;
    if (_status != LspStatus.ready) return null;
    try {
      return await call();
    } on LspException {
      return null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    if (_status == LspStatus.ready) {
      final id = ++_nextId;
      _send({'jsonrpc': '2.0', 'id': id, 'method': 'shutdown'});
      _notify('exit', const {});
    }
    _disposed = true;
    _reason = 'disposed';
    _noticeTaken = true;
    _status = LspStatus.unavailable;
    _failPending();
    _diagnostics.clear();
    diagnosticsFeed.dispose();
    unawaited(_sub?.cancel());
    try {
      unawaited(_channel?.sink.close().catchError((Object _) {}));
    } on Object {
      // Already closed.
    }
    if (!_settled.isCompleted) _settled.complete();
    super.dispose();
  }
}
