import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/backend/backend_config.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('config resolves paths against the base url', () {
    const c = BackendConfig(baseUrl: 'http://127.0.0.1:8000/');
    expect(c.healthUri.toString(), 'http://127.0.0.1:8000/health');
    expect(c.hostLabel, '127.0.0.1:8000');
  });

  test('reports down, then up once the backend answers', () async {
    var alive = false;
    final health = BackendHealth(
      config: const BackendConfig(baseUrl: 'http://127.0.0.1:8000'),
      client: MockClient((req) async {
        expect(req.url.path, '/health');
        if (!alive) throw http.ClientException('refused');
        return http.Response('{"ok":true}', 200);
      }),
      upInterval: const Duration(milliseconds: 10),
      downInterval: const Duration(milliseconds: 10),
    )..start();
    addTearDown(health.dispose);

    final seen = <BackendStatus>[];
    final sub = health.status.listen(seen.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    alive = true;
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(seen, [
      BackendStatus.connecting,
      BackendStatus.down,
      BackendStatus.up,
    ]);
  });

  test('one missed poll while up does not flip to down; two do', () async {
    var calls = 0;
    var failFrom = 1 << 30;
    var failUntil = 0;
    final health = BackendHealth(
      config: const BackendConfig(baseUrl: 'http://127.0.0.1:8000'),
      client: MockClient((req) async {
        final n = calls++;
        if (n >= failFrom && n < failUntil) {
          throw http.ClientException('busy');
        }
        return http.Response('{"ok":true}', 200);
      }),
      upInterval: const Duration(milliseconds: 10),
      downInterval: const Duration(milliseconds: 10),
    )..start();
    addTearDown(health.dispose);
    final seen = <BackendStatus>[];
    final sub = health.status.listen(seen.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 40));
    failFrom = calls;
    failUntil = calls + 1;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(seen, [BackendStatus.connecting, BackendStatus.up]);

    failFrom = calls;
    failUntil = calls + 1000;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(seen.last, BackendStatus.down);
  });
}
