import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models/json_util.dart';
import 'models/models.dart';

enum WsConnectionState { connecting, connected, reconnecting, closed }

typedef WsConnector = WebSocketChannel Function(Uri uri);

WebSocketChannel defaultWsConnector(Uri uri) =>
    IOWebSocketChannel.connect(uri, pingInterval: const Duration(seconds: 20));

/// Exponential backoff: [initial], doubling per failed attempt, capped at [max].
class ReconnectPolicy {
  const ReconnectPolicy({
    this.initial = const Duration(milliseconds: 500),
    this.max = const Duration(seconds: 10),
  });

  final Duration initial;
  final Duration max;

  Duration delayFor(int attempt) {
    final ms = initial.inMilliseconds * math.pow(2, math.min(attempt, 20));
    return Duration(milliseconds: math.min(ms.toInt(), max.inMilliseconds));
  }
}

Uri wsUri(Uri baseUri, String path) => Uri(
  scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
  host: baseUri.host,
  port: baseUri.hasPort ? baseUri.port : null,
  path: path,
);

/// A JSON-envelope socket that reconnects forever (until [dispose]).
///
/// The backend does not replay missed traffic on the global feed, and on a workspace socket
/// it replays everything EXCEPT agent events. So after a drop the consumer must refetch:
/// listen to [reconnected] and reload the workspace list (global) or the transcript via
/// `GET /workspaces/{id}/events` (workspace). The React client never reconnected; this one
/// has to, because a desktop app sits open for days and the backend gets restarted under it.
abstract class ReconnectingSocket {
  ReconnectingSocket(
    this.uri, {
    WsConnector? connector,
    this.policy = const ReconnectPolicy(),
  }) : _connector = connector ?? defaultWsConnector;

  final Uri uri;
  final ReconnectPolicy policy;
  final WsConnector _connector;

  final _events = StreamController<WsEvent>.broadcast();
  final _states = StreamController<WsConnectionState>.broadcast();
  final _reconnected = StreamController<void>.broadcast();

  WsConnectionState _state = WsConnectionState.connecting;
  bool _started = false;
  bool _disposed = false;
  bool _everConnected = false;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _sleepTimer;
  Completer<void>? _sleeper;

  /// Every parsed message.
  Stream<WsEvent> get events => _events.stream;

  WsConnectionState get state => _state;

  /// Emits on change only. Read [state] for the current value (a provider's initial value).
  Stream<WsConnectionState> get connectionStates => _states.stream;

  /// Fires after each successful reconnect, never on the first connect.
  Stream<void> get reconnected => _reconnected.stream;

  bool get isDisposed => _disposed;

  void connect() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(_run());
  }

  void _setState(WsConnectionState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  Future<void> _run() async {
    var attempt = 0;
    while (!_disposed) {
      _setState(
        _everConnected
            ? WsConnectionState.reconnecting
            : WsConnectionState.connecting,
      );
      WebSocketChannel? ch;
      try {
        ch = _connector(uri);
        _channel = ch;
        await ch.ready;
      } catch (_) {
        _channel = null;
        _closeQuietly(ch);
        if (_disposed) break;
        await _sleep(policy.delayFor(attempt++));
        continue;
      }
      if (_disposed) {
        _closeQuietly(ch);
        break;
      }

      final wasReconnect = _everConnected;
      _everConnected = true;
      attempt = 0;
      _setState(WsConnectionState.connected);
      if (wasReconnect && !_reconnected.isClosed) _reconnected.add(null);

      final dropped = Completer<void>();
      _sub = ch.stream.listen(
        _onData,
        onError: (Object _) {
          if (!dropped.isCompleted) dropped.complete();
        },
        onDone: () {
          if (!dropped.isCompleted) dropped.complete();
        },
        cancelOnError: true,
      );
      await dropped.future;
      await _sub?.cancel();
      _sub = null;
      _channel = null;
      if (_disposed) break;
      await _sleep(policy.delayFor(attempt++));
    }
    _setState(WsConnectionState.closed);
  }

  void _onData(dynamic data) {
    if (data is! String || _events.isClosed) return;
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    _events.add(parseWsEvent(asJson(decoded)));
  }

  Future<void> _sleep(Duration d) {
    final c = Completer<void>();
    _sleeper = c;
    _sleepTimer = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  static void _closeQuietly(WebSocketChannel? ch) {
    if (ch == null) return;
    try {
      unawaited(ch.sink.close().catchError((Object _) {}));
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _sleepTimer?.cancel();
    final s = _sleeper;
    if (s != null && !s.isCompleted) s.complete();
    await _sub?.cancel();
    _sub = null;
    _closeQuietly(_channel);
    _channel = null;
    _setState(WsConnectionState.closed);
    await _events.close();
    await _states.close();
    await _reconnected.close();
  }
}

/// `/ws`: coarse status, gate and notify events for every workspace. It drives the triage
/// list and the "need you" pill. `test` messages here carry `workspaceId` and include every
/// live cell of every workspace, so subscribe to [test] only if you show live gate progress
/// on the dashboard.
class HaroGlobalSocket extends ReconnectingSocket {
  HaroGlobalSocket(Uri baseUri, {super.connector, super.policy})
    : super(wsUri(baseUri, '/ws'));

  Stream<StatusEvent> get status =>
      events.where((e) => e is StatusEvent).cast();
  Stream<NotifyEvent> get notify =>
      events.where((e) => e is NotifyEvent).cast();
  Stream<TestEvent> get test => events.where((e) => e is TestEvent).cast();
  Stream<XpWsEvent> get xp => events.where((e) => e is XpWsEvent).cast();
  Stream<BaselineWsEvent> get baseline =>
      events.where((e) => e is BaselineWsEvent).cast();
}

/// `/ws/workspaces/{id}`, multiplexed by `channel`. Watch (Live Gate) events are a different
/// type from test events on purpose: an advisory run must never land in the state a merge
/// rests on.
class HaroWorkspaceSocket extends ReconnectingSocket {
  HaroWorkspaceSocket(
    Uri baseUri,
    this.workspaceId, {
    super.connector,
    super.policy,
  }) : super(wsUri(baseUri, '/ws/workspaces/$workspaceId'));

  final String workspaceId;

  Stream<AgentStreamEvent> get agent =>
      events.where((e) => e is AgentStreamEvent).cast();
  Stream<TestEvent> get test => events.where((e) => e is TestEvent).cast();
  Stream<WatchEvent> get watch => events.where((e) => e is WatchEvent).cast();
  Stream<StatusEvent> get status =>
      events.where((e) => e is StatusEvent).cast();
  Stream<RunEvent> get run => events.where((e) => e is RunEvent).cast();
  Stream<FsEvent> get fs => events.where((e) => e is FsEvent).cast();
  Stream<AssistEvent> get assist =>
      events.where((e) => e is AssistEvent).cast();
}

/// `/ws/workspaces/{id}/terminal/{shell_id}`: PTY bytes in and out. No auto-reconnect: a new
/// connection spawns a new shell, so reopening is the caller's explicit choice.
///
/// Protocol (Terminal.tsx): server sends binary frames of raw PTY output; client sends text
/// JSON `{"t":"in","d":"<keys>"}` and `{"t":"resize","c":<cols>,"r":<rows>}`.
class HaroTerminalSocket {
  HaroTerminalSocket.connect(
    Uri baseUri,
    String workspaceId,
    String shellId, {
    WsConnector? connector,
  }) {
    final ch = (connector ?? defaultWsConnector)(
      wsUri(baseUri, '/ws/workspaces/$workspaceId/terminal/$shellId'),
    );
    _channel = ch;
    _ready = ch.ready.then((_) => true, onError: (Object _) => false);
    _sub = ch.stream.listen(
      (data) {
        if (data is List<int>) {
          _out.add(data is Uint8List ? data : Uint8List.fromList(data));
        } else if (data is String) {
          _out.add(Uint8List.fromList(utf8.encode(data)));
        }
      },
      onError: (Object _) => _finish(),
      onDone: _finish,
      cancelOnError: true,
    );
    // A failed connect never fires stream.onDone on every platform.
    unawaited(_ready.then((ok) => ok ? null : _finish()));
  }

  late final WebSocketChannel _channel;
  late final Future<bool> _ready;
  late final StreamSubscription<dynamic> _sub;
  final _out = StreamController<Uint8List>.broadcast();
  final _closed = Completer<void>();
  bool _isClosed = false;

  /// Raw PTY output, ready for `Terminal.write`.
  Stream<Uint8List> get output => _out.stream;

  /// Completes when the socket ends (connection lost or [close]). The backend does not close
  /// the socket when the shell exits, so a shell `exit` alone never completes this.
  Future<void> get closed => _closed.future;

  bool get isClosed => _isClosed;

  void _finish() {
    if (_isClosed) return;
    _isClosed = true;
    if (!_out.isClosed) unawaited(_out.close());
    _closed.complete();
  }

  void _send(Map<String, Object?> msg) {
    if (_isClosed) return;
    final text = jsonEncode(msg);
    unawaited(
      _ready.then((ok) {
        if (ok && !_isClosed) _channel.sink.add(text);
      }),
    );
  }

  void sendInput(String data) => _send({'t': 'in', 'd': data});

  void resize(int cols, int rows) =>
      _send({'t': 'resize', 'c': cols, 'r': rows});

  Future<void> close() async {
    if (_isClosed) return;
    _finish();
    await _sub.cancel();
    try {
      await _channel.sink.close();
    } catch (_) {}
  }
}

/// Entry point: builds sockets against one backend and starts the reconnecting ones.
class HaroWs {
  HaroWs(this.baseUri, {this.connector, this.policy = const ReconnectPolicy()});

  final Uri baseUri;
  final WsConnector? connector;
  final ReconnectPolicy policy;

  HaroGlobalSocket global() =>
      HaroGlobalSocket(baseUri, connector: connector, policy: policy)
        ..connect();

  HaroWorkspaceSocket workspace(String workspaceId) => HaroWorkspaceSocket(
    baseUri,
    workspaceId,
    connector: connector,
    policy: policy,
  )..connect();

  /// `/ws/workspaces/{id}/lsp`: one JSON-RPC message per text frame. The backend spawns a
  /// language server per socket, so a workspace must open exactly one.
  WebSocketChannel lsp(String workspaceId) => (connector ?? defaultWsConnector)(
    wsUri(baseUri, '/ws/workspaces/$workspaceId/lsp'),
  );

  HaroTerminalSocket terminal(String workspaceId, String shellId) =>
      HaroTerminalSocket.connect(
        baseUri,
        workspaceId,
        shellId,
        connector: connector,
      );
}
