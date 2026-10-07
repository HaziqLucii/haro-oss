import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_ws.dart';
import 'package:haro_app/api/models/models.dart';

import 'fixtures.dart';

/// A real loopback WebSocket server, so reconnect behaviour is exercised end to end.
class TestServer {
  TestServer._(this._http, this.port);

  final HttpServer _http;
  final int port;
  final sockets = <WebSocket>[];
  final paths = <String>[];
  final received = <dynamic>[];
  final _connected = StreamController<WebSocket>.broadcast();

  Stream<WebSocket> get onConnect => _connected.stream;
  Uri get baseUri => Uri.parse('http://127.0.0.1:$port');

  static Future<TestServer> start([int port = 0]) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final s = TestServer._(http, http.port);
    http.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      s.paths.add(req.uri.path);
      s.sockets.add(ws);
      ws.listen((m) => s.received.add(m), onError: (_) {});
      s._connected.add(ws);
    });
    return s;
  }

  void send(Map<String, dynamic> msg) {
    for (final s in sockets) {
      if (s.readyState == WebSocket.open) s.add(jsonEncode(msg));
    }
  }

  Future<void> dropAll() async {
    for (final s in [...sockets]) {
      await s.close();
    }
    sockets.clear();
  }

  Future<void> stop() async {
    await dropAll();
    await _http.close(force: true);
    await _connected.close();
  }
}

const fast = ReconnectPolicy(
  initial: Duration(milliseconds: 20),
  max: Duration(milliseconds: 60),
);

Future<void> settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Waits for [done] instead of a fixed delay, so a loaded machine doesn't fail a positive
/// assertion. Fixed [settle] stays for "nothing more arrives" checks.
Future<void> until(bool Function() done, {int ms = 5000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('ReconnectPolicy doubles and caps at 10s by default', () {
    const p = ReconnectPolicy();
    expect(
      [for (var i = 0; i < 7; i++) p.delayFor(i).inMilliseconds],
      [500, 1000, 2000, 4000, 8000, 10000, 10000],
    );
    expect(p.delayFor(500).inMilliseconds, 10000);
  });

  test('wsUri maps http(s) to ws(s) and replaces the path', () {
    expect(
      wsUri(Uri.parse('http://127.0.0.1:8000'), '/ws').toString(),
      'ws://127.0.0.1:8000/ws',
    );
    expect(
      wsUri(Uri.parse('https://h/x?y=1'), '/ws/a').toString(),
      'wss://h/ws/a',
    );
  });

  group('global socket', () {
    late TestServer server;
    setUp(() async => server = await TestServer.start());
    tearDown(() => server.stop());

    test('connects to /ws and routes status and notify events', () async {
      final ws = HaroWs(server.baseUri, policy: fast);
      final g = ws.global();
      addTearDown(g.dispose);

      final status = g.status.first;
      final notify = g.notify.first;
      await server.onConnect.first;
      expect(server.paths.single, '/ws');
      server.send({
        'channel': 'status',
        'workspace_id': 'ws_1',
        'status': 'gate_green',
        'gate': gateSummaryJson(),
      });
      server.send({
        'channel': 'notify',
        'kind': 'agent_done',
        'workspace_id': 'ws_1',
      });

      final s = await status.timeout(const Duration(seconds: 2));
      expect(s.status, WorkspaceStatus.gateGreen);
      expect(s.gate!.passed, 594);
      expect(
        await notify.timeout(const Duration(seconds: 2)),
        isA<AgentDoneNotify>(),
      );
      expect(g.state, WsConnectionState.connected);
    });

    test('ignores malformed frames and keeps going', () async {
      final g = HaroWs(server.baseUri, policy: fast).global();
      addTearDown(g.dispose);
      final events = <WsEvent>[];
      g.events.listen(events.add);
      final sock = await server.onConnect.first;
      sock.add('not json');
      sock.add('[1,2]');
      sock.add(
        jsonEncode({
          'channel': 'status',
          'workspace_id': 'w',
          'status': 'idle',
        }),
      );
      await until(() => events.isNotEmpty);
      expect(events.single, isA<StatusEvent>());
    });

    test(
      'reconnects after a server drop and signals reconnected once',
      () async {
        final g = HaroWs(server.baseUri, policy: fast).global();
        addTearDown(g.dispose);
        final states = <WsConnectionState>[];
        g.connectionStates.listen(states.add);
        var reconnects = 0;
        g.reconnected.listen((_) => reconnects++);

        await server.onConnect.first;
        expect(reconnects, 0);

        final second = server.onConnect.first;
        await server.dropAll();
        await second.timeout(const Duration(seconds: 3));
        await until(
          () => g.state == WsConnectionState.connected && reconnects == 1,
        );

        expect(reconnects, 1);
        expect(g.state, WsConnectionState.connected);
        expect(states, contains(WsConnectionState.reconnecting));
        expect(states.last, WsConnectionState.connected);

        final ev = g.status.first;
        server.send({
          'channel': 'status',
          'workspace_id': 'w',
          'status': 'idle',
        });
        expect(
          await ev.timeout(const Duration(seconds: 2)),
          isA<StatusEvent>(),
        );
      },
    );

    test('keeps retrying while the backend is down, then connects', () async {
      final port = server.port;
      await server.stop();
      final g = HaroWs(
        Uri.parse('http://127.0.0.1:$port'),
        policy: fast,
      ).global();
      addTearDown(g.dispose);
      var reconnects = 0;
      g.reconnected.listen((_) => reconnects++);

      await settle(200);
      expect(g.state, WsConnectionState.connecting);

      server = await TestServer.start(port);
      await server.onConnect.first.timeout(const Duration(seconds: 3));
      await until(() => g.state == WsConnectionState.connected);
      expect(g.state, WsConnectionState.connected);
      expect(
        reconnects,
        0,
        reason: 'first successful connect is not a reconnect',
      );
    });

    test('dispose stops reconnecting and closes streams', () async {
      final g = HaroWs(server.baseUri, policy: fast).global();
      await server.onConnect.first;
      final done = Completer<void>();
      g.events.listen((_) {}, onDone: done.complete);
      await g.dispose();
      expect(g.state, WsConnectionState.closed);
      await done.future.timeout(const Duration(seconds: 1));

      final before = server.paths.length;
      await server.dropAll();
      await settle(200);
      expect(server.paths.length, before, reason: 'no reconnect after dispose');
      await g.dispose();
    });

    test('dispose before the first connection completes is clean', () async {
      final g = HaroWs(server.baseUri, policy: fast).global();
      await g.dispose();
      await settle(100);
      expect(g.state, WsConnectionState.closed);
    });
  });

  group('workspace socket', () {
    late TestServer server;
    setUp(() async => server = await TestServer.start());
    tearDown(() => server.stop());

    test(
      'connects to /ws/workspaces/{id} and multiplexes by channel',
      () async {
        final ws = HaroWs(server.baseUri, policy: fast).workspace('ws_42');
        addTearDown(ws.dispose);
        final agent = <AgentStreamEvent>[];
        final test = <TestEvent>[];
        final watch = <WatchEvent>[];
        final status = <StatusEvent>[];
        final run = <RunEvent>[];
        final fs = <FsEvent>[];
        ws.agent.listen(agent.add);
        ws.test.listen(test.add);
        ws.watch.listen(watch.add);
        ws.status.listen(status.add);
        ws.run.listen(run.add);
        ws.fs.listen(fs.add);

        await server.onConnect.first;
        expect(server.paths.single, '/ws/workspaces/ws_42');

        server.send({
          'channel': 'agent',
          'event': {
            'type': 'token',
            'payload': {'text': 'x'},
          },
        });
        server.send({'channel': 'test', 'kind': 'run_started'});
        server.send({
          'channel': 'test',
          'kind': 'cell',
          'cell': cellJson('c1', 'passed'),
        });
        server.send({
          'channel': 'watch',
          'kind': 'cell',
          'cell': cellJson('w1', 'failed'),
        });
        server.send({
          'channel': 'status',
          'workspace_id': 'ws_42',
          'status': 'tests_running',
        });
        server.send({'channel': 'run', 'line': 'log'});
        server.send({
          'channel': 'fs',
          'kind': 'changed',
          'workspace_id': 'ws_42',
        });
        await until(
          () =>
              agent.isNotEmpty &&
              test.length >= 2 &&
              watch.isNotEmpty &&
              status.isNotEmpty &&
              run.isNotEmpty &&
              fs.isNotEmpty,
        );

        expect(agent, hasLength(1));
        expect(test, hasLength(2));
        expect(watch, hasLength(1));
        expect(status, hasLength(1));
        expect(run.single.line, 'log');
        expect(fs.single.kind, 'changed');
        expect(
          test.whereType<TestCellEvent>().single.cell.id,
          'c1',
          reason: 'the watch cell must not appear on the test stream',
        );
      },
    );

    test(
      'reconnected fires so the caller can refetch the transcript',
      () async {
        final ws = HaroWs(server.baseUri, policy: fast).workspace('ws_1');
        addTearDown(ws.dispose);
        var n = 0;
        ws.reconnected.listen((_) => n++);
        await server.onConnect.first;
        final again = server.onConnect.first;
        await server.dropAll();
        await again.timeout(const Duration(seconds: 3));
        await until(() => n >= 1);
        expect(n, 1);
        expect(server.paths, ['/ws/workspaces/ws_1', '/ws/workspaces/ws_1']);
      },
    );
  });

  group('terminal socket', () {
    late TestServer server;
    setUp(() async => server = await TestServer.start());
    tearDown(() => server.stop());

    test(
      'sends input and resize as JSON, receives binary PTY output',
      () async {
        final t = HaroWs(server.baseUri).terminal('ws_1', 'shell_a');
        final out = <Uint8List>[];
        t.output.listen(out.add);
        final sock = await server.onConnect.first;
        expect(server.paths.single, '/ws/workspaces/ws_1/terminal/shell_a');

        t.resize(120, 30);
        t.sendInput('ls\r');
        await until(() => server.received.length >= 2);
        expect(server.received.map((m) => jsonDecode(m as String)), [
          {'t': 'resize', 'c': 120, 'r': 30},
          {'t': 'in', 'd': 'ls\r'},
        ]);

        sock.add(Uint8List.fromList([0x68, 0x69, 0x1b, 0x5b, 0x30, 0x6d]));
        await until(() => out.isNotEmpty);
        expect(out.single, [0x68, 0x69, 0x1b, 0x5b, 0x30, 0x6d]);

        await t.close();
        expect(t.isClosed, isTrue);
      },
    );

    test('does not reconnect: closed completes when the shell exits', () async {
      final t = HaroWs(server.baseUri).terminal('ws_1', 's');
      await server.onConnect.first;
      await server.dropAll();
      await t.closed.timeout(const Duration(seconds: 2));
      await settle(150);
      expect(server.paths, hasLength(1));
      t.sendInput('ignored after close');
    });

    test('closed completes when the connection cannot be made', () async {
      final port = server.port;
      await server.stop();
      final t = HaroWs(Uri.parse('http://127.0.0.1:$port'))
          .terminal('ws_1', 's');
      await t.closed.timeout(const Duration(seconds: 3));
      expect(t.isClosed, isTrue);
    });
  });
}
