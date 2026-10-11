import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/haro_ws.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/fixtures.dart';

const wsId = 'ws_1';
const projectId = 'proj_9f8e7d6c';

class FakeChannel implements WebSocketChannel {
  final _in = StreamController<dynamic>();
  final sent = <dynamic>[];
  bool closed = false;

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

  void deliver(Map<String, dynamic> msg) => _in.add(jsonEncode(msg));

  Future<void> dropFromServer() => _in.close();

  // pipe/transform/change/... come from StreamChannelMixin and are never used here.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sink implements WebSocketSink {
  _Sink(this._c);
  final FakeChannel _c;

  @override
  void add(dynamic data) => _c.sent.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _c.closed = true;
    if (!_c._in.isClosed) await _c._in.close();
  }

  @override
  Future<void> get done => Future.value();
}

/// Every socket the app opens, in order.
class FakeWsNet {
  final channels = <FakeChannel>[];
  final uris = <Uri>[];

  WebSocketChannel connect(Uri uri) {
    uris.add(uri);
    final c = FakeChannel();
    channels.add(c);
    return c;
  }

  FakeChannel get latest => channels.last;

  int get workspaceSockets =>
      uris.where((u) => u.path == '/ws/workspaces/$wsId').length;

  void send(Map<String, dynamic> msg) => latest.deliver(msg);
}

class Call {
  Call(this.method, this.path, this.query, this.body);
  final String method;
  final String path;
  final Map<String, String> query;
  final Object? body;

  @override
  String toString() => '$method $path $query $body';
}

/// A routing MockClient: `'GET /workspaces/ws_1/diff'` -> handler. Records every call.
class FakeBackend {
  FakeBackend() {
    routes.addAll({
      'GET /workspaces/$wsId': (_) => workspaceJson(id: wsId),
      'GET /workspaces/$wsId/events': (_) => {'events': events},
      'GET /workspaces/$wsId/tests': (_) => null,
      'GET /workspaces/$wsId/diff': (_) => diffJson(),
      'GET /workspaces/$wsId/watch': (_) => {'enabled': false, 'run': null},
      'GET /workspaces/$wsId/setup': (_) => {'status': 'ok', 'exit': 0},
      'GET /projects/$projectId/gate': (_) => <String, dynamic>{},
    });
  }

  final routes = <String, Object? Function(Call)>{};
  final calls = <Call>[];
  final events = <Map<String, dynamic>>[];
  Duration latency = Duration.zero;

  Map<String, dynamic> diffJson({
    int files = 0,
    int added = 0,
    int removed = 0,
  }) {
    final b = StringBuffer();
    for (var f = 0; f < files; f++) {
      b.writeln('diff --git a/f$f b/f$f\n@@ -1 +1 @@');
      for (var i = 0; i < added; i++) {
        b.writeln('+a');
      }
      for (var i = 0; i < removed; i++) {
        b.writeln('-r');
      }
    }
    return {
      'base_ref': 'origin/main',
      'diff': b.toString(),
      'files_changed': files,
    };
  }

  int count(String method, String path) =>
      calls.where((c) => c.method == method && c.path == path).length;

  Call last(String method, String path) =>
      calls.lastWhere((c) => c.method == method && c.path == path);

  http.Client get client => MockClient((req) async {
    Object? body;
    if (req.body.isNotEmpty) body = jsonDecode(req.body);
    final call = Call(req.method, req.url.path, req.url.queryParameters, body);
    calls.add(call);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final h = routes['${req.method} ${req.url.path}'];
    if (h == null) {
      return _json({'detail': 'no route ${req.method} ${req.url.path}'}, 404);
    }
    try {
      return _json(h(call));
    } on _Fail catch (f) {
      return _json({'detail': f.message}, f.status);
    }
  });

  static http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  /// Make a route answer with an HTTP error.
  static Never fail(int status, String message) => throw _Fail(status, message);
}

class _Fail implements Exception {
  _Fail(this.status, this.message);
  final int status;
  final String message;
}

const fastTuning = WorkspaceDetailTuning(
  diffDebounce: Duration(milliseconds: 40),
  liveFlush: Duration.zero,
  keepAlive: Duration(seconds: 30),
  tickElapsed: false,
);

class Harness {
  Harness({
    FakeBackend? backend,
    WorkspaceDetailTuning tuning = fastTuning,
    ReconnectPolicy policy = const ReconnectPolicy(
      initial: Duration(milliseconds: 10),
      max: Duration(milliseconds: 20),
    ),
  }) : backend = backend ?? FakeBackend(),
       net = FakeWsNet() {
    container = ProviderContainer(
      overrides: [
        haroApiProvider.overrideWithValue(
          HaroApi(
            Uri.parse('http://127.0.0.1:8000'),
            client: this.backend.client,
          ),
        ),
        haroWsProvider.overrideWithValue(
          HaroWs(
            Uri.parse('http://127.0.0.1:8000'),
            connector: net.connect,
            policy: policy,
          ),
        ),
        backendStatusProvider.overrideWith(
          (ref) => Stream.value(BackendStatus.down),
        ),
        workspaceDetailTuningProvider.overrideWithValue(tuning),
      ],
    );
    addTearDown(container.dispose);
  }

  final FakeBackend backend;
  final FakeWsNet net;
  late final ProviderContainer container;

  /// Holds the detail provider open like a mounted screen would.
  ProviderSubscription<WorkspaceDetail> open([String id = wsId]) =>
      container.listen(workspaceDetailProvider(id), (_, _) {});

  WorkspaceDetail get detail => container.read(workspaceDetailProvider(wsId));

  /// Opens the detail and waits for the initial REST batch.
  Future<void> openAndLoad() async {
    open();
    await settleLoad();
  }

  Future<void> settleLoad() async {
    for (var i = 0; i < 50 && !detail.loaded; i++) {
      await pumpEventQueue();
    }
    await pumpEventQueue();
  }

  Future<void> send(Map<String, dynamic> msg) async {
    net.send(msg);
    await pumpEventQueue();
  }
}

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

Map<String, dynamic> agentMsg(
  String type, {
  Map<String, dynamic> payload = const {},
  double ts = 1790000200,
  String runId = 'run_1',
  String? sessionId = 'main',
}) => {
  'channel': 'agent',
  'session_id': ?sessionId,
  'event': {
    'run_id': runId,
    'workspace_id': wsId,
    'ts': ts,
    'type': type,
    'payload': payload,
  },
};

Map<String, dynamic> eventJson(
  String type, {
  double ts = 1790000000,
  Map<String, dynamic> payload = const {},
  String runId = 'run_1',
}) => {
  'run_id': runId,
  'workspace_id': wsId,
  'ts': ts,
  'type': type,
  'payload': payload,
};

Map<String, dynamic> statusMsg(String status, {Map<String, dynamic>? gate}) => {
  'channel': 'status',
  'workspace_id': wsId,
  'status': status,
  'gate': ?gate,
};

Map<String, dynamic> cellMsg(String channel, String id, String status) => {
  'channel': channel,
  'kind': 'cell',
  'cell': cellJson(id, status),
};
