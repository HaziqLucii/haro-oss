import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/shell/shell_providers.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/state/workspace_flow.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../api/fixtures.dart';

void main() {
  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  ProviderContainer containerWith(
    Future<http.Response> Function(http.Request) handler,
  ) {
    final c = ProviderContainer(
      overrides: [
        haroApiProvider.overrideWithValue(
          HaroApi(
            Uri.parse('http://127.0.0.1:8000'),
            client: MockClient(handler),
          ),
        ),
        backendStatusProvider.overrideWith(
          (ref) => Stream.value(BackendStatus.down),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<http.Response> backend(http.Request r) async => switch (r.url.path) {
    '/projects' => json([
      {'id': 'p1', 'name': 'gate-sandbox', 'path': '/x'},
    ]),
    '/projects/p1/workspaces' => json([
      workspaceJson(
        id: 'w_red',
        status: 'gate_red',
        gate: gateSummaryJson(status: 'failed', failed: 3),
      ),
      workspaceJson(id: 'w_idle', overrides: {'name': 'agent-haro'}),
      workspaceJson(id: 'w_gone', status: 'archived'),
    ]),
    '/projects/p1/todo' => json({'files': [], 'orphaned': []}),
    _ => json({'detail': 'nope'}, 404),
  };

  test(
    'reload maps workspaces into sidebar data and counts need-you',
    () async {
      final c = containerWith(backend);
      await c.read(workspaceStoreProvider.notifier).reload();
      final data = c.read(shellDataProvider);
      final ids = data.projects.single.workspaces.map((w) => w.id);
      expect(ids, ['w_red', 'w_idle']);
      expect(data.workspaceById('w_red')!.state, DisplayState.red);
      expect(data.workspaceById('w_idle')!.state, DisplayState.idle);
      expect(data.workspaceById('w_red')!.defaultStep, StepKey.verify);
      expect(data.workspaceById('w_idle')!.defaultStep, StepKey.agent);
      expect(data.needYouCount, 1);
      expect(data.triageCount, 2);
    },
  );

  test('status events patch a known workspace in place', () async {
    final c = containerWith(backend);
    final store = c.read(workspaceStoreProvider.notifier);
    await store.reload();
    final snap = c.read(workspaceStoreProvider);
    final patched = snap.patch(
      StatusEvent(workspaceId: 'w_idle', status: WorkspaceStatus.agentRunning),
    );
    expect(
      patched.all.firstWhere((w) => w.id == 'w_idle').status,
      WorkspaceStatus.agentRunning,
    );
    expect(
      identical(snap.patch(const StatusEvent(workspaceId: 'x')), snap),
      isTrue,
    );
  });

  test('a status event carrying mode flips it; one without keeps it', () async {
    final c = containerWith(backend);
    final store = c.read(workspaceStoreProvider.notifier);
    await store.reload();
    final snap = c.read(workspaceStoreProvider);
    final manual = snap.patch(
      const StatusEvent(
        workspaceId: 'w_idle',
        status: WorkspaceStatus.idle,
        mode: WorkspaceMode.manual,
      ),
    );
    expect(
      manual.all.firstWhere((w) => w.id == 'w_idle').mode,
      WorkspaceMode.manual,
    );
    final kept = manual.patch(
      const StatusEvent(workspaceId: 'w_idle', status: WorkspaceStatus.idle),
    );
    expect(
      kept.all.firstWhere((w) => w.id == 'w_idle').mode,
      WorkspaceMode.manual,
    );
  });

  test(
    'an API failure keeps the last good data and records the error',
    () async {
      var fail = false;
      final c = containerWith(
        (r) async => fail ? json({'detail': 'boom'}, 500) : backend(r),
      );
      final store = c.read(workspaceStoreProvider.notifier);
      await store.reload();
      fail = true;
      await store.reload();
      final snap = c.read(workspaceStoreProvider);
      expect(snap.all, hasLength(2));
      expect(snap.error, isNotNull);
    },
  );
}
