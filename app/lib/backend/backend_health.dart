import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'backend_config.dart';

enum BackendStatus { connecting, up, down }

/// Polls `GET /health`. Down is retried faster than up is re-verified so a backend started
/// after the app is picked up quickly.
class BackendHealth {
  BackendHealth({
    required this.config,
    http.Client? client,
    this.upInterval = const Duration(seconds: 5),
    this.downInterval = const Duration(seconds: 2),
    this.timeout = const Duration(seconds: 4),
  }) : _client = client ?? http.Client();

  final BackendConfig config;
  final Duration upInterval;
  final Duration downInterval;
  final Duration timeout;
  final http.Client _client;

  final _controller = StreamController<BackendStatus>.broadcast();
  BackendStatus _current = BackendStatus.connecting;
  Timer? _timer;
  bool _disposed = false;
  int _misses = 0;

  BackendStatus get current => _current;

  /// Emits the current status first, then every change.
  Stream<BackendStatus> get status async* {
    yield _current;
    yield* _controller.stream;
  }

  void start() {
    if (_timer != null || _disposed) return;
    _timer = Timer(Duration.zero, _poll);
  }

  Future<void> _poll() async {
    BackendStatus next;
    try {
      final res = await _client.get(config.healthUri).timeout(timeout);
      next = res.statusCode >= 200 && res.statusCode < 300
          ? BackendStatus.up
          : BackendStatus.down;
    } catch (_) {
      next = BackendStatus.down;
    }
    if (_disposed) return;
    // A busy backend (a gate or mutation run) can miss one poll; only a second miss in a
    // row flips an up backend to down, since down->up triggers a full reload.
    if (next == BackendStatus.down && _current == BackendStatus.up) {
      _misses++;
      if (_misses < 2) {
        _timer = Timer(downInterval, _poll);
        return;
      }
    } else if (next == BackendStatus.up) {
      _misses = 0;
    }
    if (next != _current) {
      _current = next;
      _controller.add(next);
    }
    _timer = Timer(next == BackendStatus.up ? upInterval : downInterval, _poll);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _client.close();
    _controller.close();
  }
}

final backendConfigProvider = Provider<BackendConfig>(
  (ref) => BackendConfig.fromEnvironment(),
);

final backendHealthProvider = Provider<BackendHealth>((ref) {
  final health = BackendHealth(config: ref.watch(backendConfigProvider))
    ..start();
  ref.onDispose(health.dispose);
  return health;
});

final backendStatusProvider = StreamProvider<BackendStatus>(
  (ref) => ref.watch(backendHealthProvider).status,
);
