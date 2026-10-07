import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// A language server on the far end of a fake socket. Answers the handshake, serves queued
/// completion lists and per-label resolve results, and can hold a reply until released.
class FakeLspServer implements WebSocketChannel {
  FakeLspServer({this.initializeError});

  /// When set, `initialize` answers with this JSON-RPC error.
  Map<String, Object?>? initializeError;

  final _in = StreamController<dynamic>();
  final received = <Map<String, dynamic>>[];
  bool closed = false;

  /// Completion answers, one per request in order; the last one repeats.
  final completions = <Object?>[];

  /// `completionItem/resolve` answers keyed by label; a missing label answers the item itself.
  final resolved = <String, Map<String, Object?>>{};

  /// `textDocument/definition` and `textDocument/hover` answers, one per request in order; the
  /// last one repeats, none answers null.
  final definitions = <Object?>[];
  final hovers = <Object?>[];
  int definitionCalls = 0;
  int hoverCalls = 0;

  /// `textDocument/formatting` answers, one per request in order; the last one repeats, none
  /// answers null. [formatError] answers every request with that JSON-RPC error instead.
  final formats = <Object?>[];
  Map<String, Object?>? formatError;
  int formatCalls = 0;
  Completer<void>? _formatGate;

  /// Holds the next formatting reply until the returned callback runs.
  void Function() holdFormat() {
    final c = _formatGate = Completer<void>();
    return () {
      if (!c.isCompleted) c.complete();
    };
  }

  final _gates = <Completer<void>>[];

  /// Holds the next unanswered completion reply until the returned callback runs.
  void Function() holdNextCompletion() {
    final c = Completer<void>();
    _gates.add(c);
    return () {
      if (!c.isCompleted) c.complete();
    };
  }

  Completer<void>? _resolveGate;

  void Function() holdResolve() {
    final c = _resolveGate = Completer<void>();
    return () {
      if (!c.isCompleted) c.complete();
    };
  }

  int completionCalls = 0;
  int resolveCalls = 0;

  List<Map<String, dynamic>> byMethod(String m) => [
    for (final r in received)
      if (r['method'] == m) r,
  ];

  void push(Map<String, Object?> msg) {
    if (!_in.isClosed) _in.add(jsonEncode(msg));
  }

  Future<void> drop() => _in.close();

  void _reply(Object? id, Object? result) =>
      push({'jsonrpc': '2.0', 'id': id, 'result': result});

  Future<void> _handle(Map<String, dynamic> msg) async {
    received.add(msg);
    final id = msg['id'];
    switch (msg['method']) {
      case 'initialize':
        final err = initializeError;
        if (err != null) {
          push({'jsonrpc': '2.0', 'id': id, 'error': err});
        } else {
          _reply(id, {
            'capabilities': {'completionProvider': {}},
          });
        }
      case 'textDocument/completion':
        final n = completionCalls++;
        final gate = _gates.isEmpty ? null : _gates.removeAt(0);
        if (gate != null) await gate.future;
        if (completions.isEmpty) {
          _reply(id, null);
        } else {
          _reply(
            id,
            completions[n < completions.length ? n : completions.length - 1],
          );
        }
      case 'completionItem/resolve':
        resolveCalls++;
        await _resolveGate?.future;
        final params = (msg['params'] as Map).cast<String, Object?>();
        _reply(id, resolved[params['label']] ?? params);
      case 'textDocument/definition':
        final n = definitionCalls++;
        _reply(
          id,
          definitions.isEmpty
              ? null
              : definitions[n < definitions.length
                    ? n
                    : definitions.length - 1],
        );
      case 'textDocument/hover':
        final n = hoverCalls++;
        _reply(
          id,
          hovers.isEmpty
              ? null
              : hovers[n < hovers.length ? n : hovers.length - 1],
        );
      case 'textDocument/formatting':
        final n = formatCalls++;
        final gate = _formatGate;
        _formatGate = null;
        if (gate != null) await gate.future;
        final err = formatError;
        if (err != null) {
          push({'jsonrpc': '2.0', 'id': id, 'error': err});
        } else {
          _reply(
            id,
            formats.isEmpty
                ? null
                : formats[n < formats.length ? n : formats.length - 1],
          );
        }
      case 'shutdown':
        _reply(id, null);
    }
  }

  @override
  Stream<dynamic> get stream => _in.stream;

  @override
  late final WebSocketSink sink = _Sink(this);

  @override
  Future<void> get ready => Future.value();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sink implements WebSocketSink {
  _Sink(this._s);
  final FakeLspServer _s;

  @override
  void add(dynamic data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    scheduleMicrotask(() => _s._handle(msg));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _s.closed = true;
    if (!_s._in.isClosed) await _s._in.close();
  }

  @override
  Future<void> get done => Future.value();
}

Map<String, Object?> item(
  String label, {
  String? sortText,
  int kind = 6,
  Map<String, Object?>? extra,
}) => {'label': label, 'kind': kind, 'sortText': ?sortText, ...?extra};

const importEdit = {
  'additionalTextEdits': [
    {
      'range': {
        'start': {'line': 0, 'character': 0},
        'end': {'line': 0, 'character': 0},
      },
      'newText': 'import { useState } from "react";\n',
    },
  ],
};
