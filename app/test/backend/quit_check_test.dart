import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/backend/quit_check.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final base = Uri.parse('http://127.0.0.1:41417');

  test('finds running agents and gates across projects', () async {
    final client = MockClient((req) async {
      return switch (req.url.path) {
        '/projects' => http.Response(
          jsonEncode([
            {'id': 'p1'},
            {'id': 'p2'},
          ]),
          200,
        ),
        '/projects/p1/workspaces' => http.Response(
          jsonEncode([
            {'name': 'streak', 'status': 'agent_running'},
            {'name': 'idle one', 'status': 'idle'},
          ]),
          200,
        ),
        '/projects/p2/workspaces' => http.Response(
          jsonEncode([
            {'name': 'goals', 'status': 'tests_running'},
          ]),
          200,
        ),
        _ => http.Response('nope', 404),
      };
    });
    final busy = await busyWorkspaces(base, client: client);
    expect(
      [for (final b in busy) '${b.name}:${b.what}'],
      ['streak:agent', 'goals:gate'],
    );
  });

  test('a failing or slow backend never blocks the quit', () async {
    final broken = MockClient((_) async => http.Response('boom', 500));
    expect(await busyWorkspaces(base, client: broken), isEmpty);
    final slow = MockClient((_) async {
      await Future<void>.delayed(const Duration(seconds: 5));
      return http.Response('[]', 200);
    });
    expect(
      await busyWorkspaces(
        base,
        client: slow,
        budget: const Duration(milliseconds: 50),
      ),
      isEmpty,
    );
  });
}
