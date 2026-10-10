import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/features/add_project/clone_runner.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../api/fixtures.dart';

/// Registers the brand fonts so text measures as it does in the app (the default test font
/// is far wider and makes overflow checks meaningless).
Future<void> loadBrandFonts() async {
  const families = {
    'SpaceGrotesk': [
      'SpaceGrotesk-400.ttf',
      'SpaceGrotesk-500.ttf',
      'SpaceGrotesk-600.ttf',
      'SpaceGrotesk-700.ttf',
    ],
    'SpaceMono': ['SpaceMono-400.ttf', 'SpaceMono-700.ttf'],
    'Fraunces': ['Fraunces-500.ttf'],
  };
  for (final e in families.entries) {
    final loader = FontLoader(e.key);
    for (final f in e.value) {
      final bytes = File('assets/fonts/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}

class Call {
  Call(this.method, this.path, this.query, this.body);
  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic>? body;

  @override
  String toString() => '$method $path';
}

typedef Handler = http.Response Function(Call call);

http.Response jsonRes(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response errorRes(String detail, [int status = 409]) =>
    jsonRes({'detail': detail}, status);

/// Records every request and answers from [routes] (`'GET /fs'` style keys). An unrouted
/// request fails the test loudly instead of silently returning nothing.
class MockBackend {
  MockBackend(this.routes);

  final Map<String, Handler> routes;
  final calls = <Call>[];

  late final client = MockClient((req) async {
    Map<String, dynamic>? body;
    if (req.body.isNotEmpty) {
      body = jsonDecode(req.body) as Map<String, dynamic>;
    }
    final call = Call(req.method, req.url.path, req.url.queryParameters, body);
    final key = '${req.method} ${req.url.path}';
    // The real shell data provider starts XP; a suite that does not care answers "no XP here"
    // instead of routing it, and the startup load stays out of the recorded calls.
    if (call.path.startsWith('/xp') &&
        !routes.keys.any((k) => k.contains(' /xp'))) {
      return errorRes('not found', 404);
    }
    // The dashboard reads the plan usage on mount; suites that do not route it get a quiet 404.
    if (call.path == '/usage' &&
        !routes.keys.any((k) => k.contains(' /usage'))) {
      return errorRes('not found', 404);
    }
    // The top bar's GitHub avatar asks for the accounts on mount; suites that do not route
    // that get a quiet 404 (no account, person icon).
    if (call.path == '/github/accounts' &&
        !routes.keys.any((k) => k.contains(' /github/accounts'))) {
      return errorRes('not found', 404);
    }
    // The Backlog asks the backend to sync the project's checkout when it opens; suites that
    // do not route that get a quiet 404 so their call logs stay about what they test.
    if (call.path.startsWith('/projects/') &&
        call.path.contains('/sync') &&
        !routes.keys.any((k) => k.contains('/sync'))) {
      return errorRes('not found', 404);
    }
    calls.add(call);
    final handler =
        routes[key] ??
        routes.entries
            .where(
              (e) =>
                  e.key.endsWith('/*') &&
                  key.startsWith(e.key.substring(0, e.key.length - 1)),
            )
            .map((e) => e.value)
            .firstOrNull;
    if (handler == null) {
      throw TestFailure('unrouted request: $call');
    }
    return handler(call);
  });

  late final api = HaroApi(Uri.parse('http://test'), client: client);

  List<Call> where(String method, String path) => [
    for (final c in calls)
      if (c.method == method && c.path == path) c,
  ];
}

class FakeStore extends WorkspaceStore {
  FakeStore(this.snapshot);

  final WorkspaceSnapshot snapshot;
  int reloads = 0;

  @override
  WorkspaceSnapshot build() => snapshot;

  @override
  Future<void> reload() async => reloads++;
}

class FakeActions extends WorkspaceActions {
  FakeActions(super.ref, super.id, this.started, {this.fail});

  final List<(String, String)> started;
  final String? fail;

  @override
  Future<AgentRun?> startAgent(
    String task, {
    bool plan = false,
    String? model,
    String? effort,
    String? role,
    String? adapter,
    bool testFirst = false,
    List<String>? scope,
  }) async {
    started.add((workspaceId, task));
    if (fail != null) throw HaroApiException(500, fail!);
    return null;
  }
}

Project project(String id, String name) =>
    Project(id: id, name: name, path: '/x/$name', defaultBranch: 'main');

WorkspaceSnapshot snapshotOf(
  List<Project> projects, [
  Map<String, List<Workspace>> workspaces = const {},
]) => WorkspaceSnapshot(
  loaded: true,
  projects: projects,
  workspaces: {for (final p in projects) p.id: workspaces[p.id] ?? const []},
);

Map<String, dynamic> createdWorkspace([String id = 'ws_new']) =>
    workspaceJson(id: id, overrides: {'project_id': 'p1', 'name': 'new'});

class Harness {
  Harness({
    required this.backend,
    required this.store,
    required this.router,
    required this.started,
    required this.container,
  });

  final MockBackend backend;
  final FakeStore store;
  final GoRouter router;
  final List<(String, String)> started;
  final ProviderContainer container;

  String get location =>
      router.routerDelegate.currentConfiguration.uri.toString();
}

/// A bare app (real theme, real router) whose home page has one button that runs [open].
/// The 960x640 window is the smallest the app supports.
Future<Harness> pumpCreation(
  WidgetTester tester, {
  required MockBackend backend,
  required void Function(BuildContext context) open,
  List<Project>? projects,
  Map<String, List<Workspace>> workspaces = const {},
  String initialLocation = '/',
  String? agentFails,
  CloneRunner? cloneRunner,
  TargetProbe? targetProbe,
  String? homeDir,
  Size size = const Size(960, 640),
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final started = <(String, String)>[];
  final store = FakeStore(
    snapshotOf(
      projects ?? [project('p1', 'haro'), project('p2', 'sandbox')],
      workspaces,
    ),
  );
  Widget page(BuildContext context, String label) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          GestureDetector(
            onTap: () => open(context),
            child: const Text('open overlay'),
          ),
        ],
      ),
    ),
  );
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', builder: (context, state) => page(context, 'HOME')),
      GoRoute(
        path: '/w/:id/:step',
        builder: (context, state) =>
            page(context, 'WS ${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/first-run',
        builder: (context, state) =>
            page(context, 'FIRST RUN ${state.uri.queryParameters['project']}'),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      haroApiProvider.overrideWithValue(backend.api),
      workspaceStoreProvider.overrideWith(() => store),
      if (targetProbe != null)
        cloneTargetProbeProvider.overrideWithValue(targetProbe),
      if (homeDir != null) homeDirProvider.overrideWithValue(homeDir),
      if (cloneRunner != null)
        cloneRunnerProvider.overrideWithValue(cloneRunner),
      workspaceActionsProvider.overrideWith(
        (ref, id) => FakeActions(ref, id, started, fail: agentFails),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildHaroTheme(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open overlay'));
  await tester.pumpAndSettle();
  return Harness(
    backend: backend,
    store: store,
    router: router,
    started: started,
    container: container,
  );
}
