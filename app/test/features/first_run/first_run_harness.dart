import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/add_project/clone_runner.dart';
import 'package:haro_app/features/first_run/first_run_model.dart';
import 'package:haro_app/features/first_run/first_run_providers.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';
import 'package:haro_app/shell/shell_providers.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

import '../../shell/fake_shell_data.dart';
import '../creation_harness.dart';

const projectId = 'p1';

Map<String, dynamic> projectJson({
  String path = '/Users/me/code/shop-api',
  String? remote = 'https://github.com/me/shop-api.git',
}) => {
  'id': projectId,
  'name': 'shop-api',
  'path': path,
  'default_branch': 'main',
  'remote_url': remote,
  'stack': <String>[],
};

Map<String, dynamic> gateJson({
  String runner = 'vitest',
  String dir = 'src',
  String command = '',
}) => {'runner': runner, 'gate_dir': dir, 'command': command};

Map<String, dynamic> scriptsJson({
  String? setup = 'npm install',
  String? run = 'npm run dev',
}) => {
  'setup': setup,
  'run': run,
  'runs': run == null
      ? <Object>[]
      : [
          {'id': 'app', 'command': run, 'default': true, 'running': false},
        ],
};

Map<String, dynamic> presetJson() => {
  'id': 'vitest',
  'label': 'Node (vitest)',
  'blurb': 'Looks like a Node project (vitest)',
  'setup': 'npm install',
  'run': 'npm run dev',
  'gate': {'runner': 'vitest'},
  'toml': '[scripts]\nsetup = "npm install"\n\n[gate]\nrunner = "vitest"\n',
};

Map<String, dynamic> detectionJson({bool proposal = false}) => {
  'ambiguous': false,
  'proposal': proposal ? {'preset': presetJson(), 'confidence': .95} : null,
  'candidates': [
    if (proposal) {'preset': presetJson(), 'confidence': .95},
  ],
};

MockBackend backendFor({
  Map<String, dynamic>? project,
  Map<String, dynamic>? gate,
  Map<String, dynamic>? scripts,
  Map<String, dynamic>? detection,
  String env = 'API_KEY=x\nDB_URL=y\n# note\n',
  Map<String, Handler> extra = const {},
}) => MockBackend({
  'GET /projects': (_) => jsonRes([project ?? projectJson()]),
  'GET /projects/$projectId/gate': (_) => jsonRes(gate ?? gateJson()),
  'GET /projects/$projectId/scripts': (_) => jsonRes(scripts ?? scriptsJson()),
  'GET /projects/$projectId/detect-stack': (_) =>
      jsonRes(detection ?? detectionJson()),
  'GET /projects/$projectId/env': (_) => jsonRes({'content': env}),
  ...extra,
});

class Commands {
  final settings = <SettingsTab?>[];
  final newWorkspace = <String?>[];
}

class FirstRunRig {
  FirstRunRig(this.backend, this.commands, this.router, this.container);

  final MockBackend backend;
  final Commands commands;
  final GoRouter router;
  final ProviderContainer container;

  String get location =>
      router.routerDelegate.currentConfiguration.uri.toString();

  List<Call> get writes => [
    for (final c in backend.calls)
      if (c.method != 'GET') c,
  ];
}

Future<FirstRunRig> pumpFirstRun(
  WidgetTester tester, {
  required MockBackend backend,
  BaselineResult? baseline,
  bool baselineFromBackend = false,
  String location = '/first-run?project=$projectId',
  Size size = const Size(960, 640),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(initialLocation: location);
  final container = ProviderContainer(
    overrides: [
      shellDataProvider.overrideWithValue(fakeShellData),
      devicePrefsStoreProvider.overrideWithValue(MemoryDevicePrefsStore()),
      haroApiProvider.overrideWithValue(backend.api),
      homeDirProvider.overrideWithValue('/Users/me'),
      backendStatusProvider.overrideWith(
        (ref) => Stream.value(BackendStatus.up),
      ),
      if (!baselineFromBackend)
        firstRunBaselineProvider.overrideWith((ref, id) async => baseline),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: HaroApp(router: router),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  final commands = Commands();
  container
      .read(appCommandsProvider.notifier)
      .register(
        (c) => c.copyWith(
          openSettings: commands.settings.add,
          openNewWorkspace: commands.newWorkspace.add,
        ),
      );
  return FirstRunRig(backend, commands, router, container);
}
