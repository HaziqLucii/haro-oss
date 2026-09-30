import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../api/haro_ws.dart';
import '../../../data/workspace_detail_models.dart';

const _clear = '\x1b[3J\x1b[2J\x1b[H';

enum ShellPhase { idle, running, ended }

/// The one Shell tab: an xterm fed by the backend's PTY socket. The backend spawns a fresh
/// shell for every connection, so the socket opens lazily, lives as long as the page, and a
/// restart is a new socket under a new id (never a reconnect of the old one).
class ShellSession extends ChangeNotifier {
  ShellSession({required this._connect}) {
    terminal.onOutput = (data) => _socket?.sendInput(data);
    terminal.onResize = (cols, rows, _, _) => _socket?.resize(cols, rows);
  }

  final HaroTerminalSocket Function(String shellId) _connect;
  final terminal = Terminal(maxLines: 5000);

  HaroTerminalSocket? _socket;
  StreamSubscription<String>? _sub;
  int _seq = 0;
  bool _disposed = false;
  ShellPhase _phase = ShellPhase.idle;

  ShellPhase get phase => _phase;

  void start() {
    if (_phase == ShellPhase.idle) _open();
  }

  /// Types [command] and Enter into the shell, opening its socket first when needed (input
  /// sent before the socket is ready is held until it connects). Used by "Open in..." for
  /// terminal editors, so the editor runs in the worktree with haro's shell env.
  void sendCommand(String command) {
    if (_phase == ShellPhase.ended) {
      restart();
    } else {
      start();
    }
    _socket?.sendInput('$command\r');
  }

  void restart() {
    _release();
    terminal.write(_clear);
    _open();
  }

  void _open() {
    final socket = _connect('shell-${_seq++}');
    _socket = socket;
    _phase = ShellPhase.running;
    _sub = socket.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);
    unawaited(
      socket.closed.then((_) {
        if (_disposed || !identical(_socket, socket)) return;
        _phase = ShellPhase.ended;
        notifyListeners();
      }),
    );
    socket.resize(terminal.viewWidth, terminal.viewHeight);
    notifyListeners();
  }

  void _release() {
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(_socket?.close());
    _socket = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _release();
    super.dispose();
  }
}

/// The live Shell sessions by workspace id. The page owns the session; this lets features
/// that live outside the bottom panel (Open in...) type into it.
class ShellSessions {
  final _byWorkspace = <String, ShellSession>{};

  ShellSession? operator [](String workspaceId) => _byWorkspace[workspaceId];

  void register(String workspaceId, ShellSession session) =>
      _byWorkspace[workspaceId] = session;

  /// Only removes [session] itself, so a page that unmounts after its replacement
  /// mounted does not drop the new registration.
  void unregister(String workspaceId, ShellSession session) {
    if (identical(_byWorkspace[workspaceId], session)) {
      _byWorkspace.remove(workspaceId);
    }
  }
}

final shellSessionsProvider = Provider<ShellSessions>((ref) => ShellSessions());

/// The Dev log tab: a read-only xterm mirroring the workspace's ring buffer. The buffer
/// reports a revision that grows by one per line, so what changed since the last [sync] is
/// the revision delta; anything the ring trimmed away in between forces a full rewrite.
class DevLogTerminal {
  final terminal = Terminal(maxLines: 5000);
  int _revision = -1;

  void sync(DevLog log) {
    if (log.revision == _revision) return;
    final lines = log.lines;
    final delta = log.revision - _revision;
    final fresh = _revision < 0 || delta < 0 || delta > lines.length;
    if (fresh) terminal.write(_clear);
    final from = fresh ? 0 : lines.length - delta;
    final out = StringBuffer();
    for (var i = from; i < lines.length; i++) {
      out
        ..write(lines[i].replaceAll(RegExp(r'[\r\n]+$'), ''))
        ..write('\r\n');
    }
    terminal.write(out.toString());
    _revision = log.revision;
  }
}
