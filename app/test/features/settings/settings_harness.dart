import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_store.dart' show haroApiProvider;
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/settings_layers.dart';
import 'package:haro_app/features/settings/settings_overlay.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const proj1 = Project(
  id: 'p1',
  name: 'haro',
  path: '/x/haro',
  defaultBranch: 'main',
  remoteUrl: 'https://github.com/o/haro.git',
);
const proj2 = Project(
  id: 'p2',
  name: 'sandbox',
  path: '/x/sandbox',
  defaultBranch: 'main',
);

Map<String, dynamic> gateJson() => {
  'runner': 'vitest',
  'command': '',
  'format': '',
  'gate_dir': 'frontend',
  'default_scope': 'all',
  'merge_result': false,
  'flaky_rerun': false,
  'coverage_guard': 'off',
  'coverage_tolerance': 0.0,
  'tamper_alarm': 'warn',
  'code_to_check': 'warn',
  'watch': false,
  'verified_hunks': true,
  'secrets_scan': true,
  'run_on_save': false,
};

/// A stand-in backend: GETs answer from [routes], PUTs echo the request body back the way
/// the real endpoints answer with the stored config. Every request is kept in [log].
class FakeBackend {
  FakeBackend() {
    routes.addAll({
      '/projects': [
        {
          'id': 'p1',
          'name': 'haro',
          'path': '/x/haro',
          'default_branch': 'main',
          'remote_url': 'https://github.com/o/haro.git',
        },
        {
          'id': 'p2',
          'name': 'sandbox',
          'path': '/x/sandbox',
          'default_branch': 'main',
        },
      ],
      '/projects/p1/gate': gateJson(),
      '/projects/p2/gate': {...gateJson(), 'gate_dir': 'web'},
      '/projects/p1/agent': {
        'default_model': 'opus',
        'default_effort': 'high',
        'max_budget_usd': 0.0,
        'cost_warn_usd': 20.0,
        'max_parallel': 4,
        'adapter': 'claude-code',
        'local_base_url': 'http://localhost:11434/v1',
        'local_model': 'qwen',
      },
      '/projects/p1/roles': {
        'enabled': true,
        'plan': 'opus:high',
        'build': 'sonnet:high',
        'review': 'opus:high',
        'scout': 'haiku',
        'review_enforce': 'off',
        'review_max_rounds': 2,
      },
      '/projects/p1/workflow': {'merge_mode': 'both'},
      '/projects/p1/branches': {
        'branches': ['main', 'origin', 'origin/main', 'origin/feat/x', 'dev'],
        'default': 'main',
      },
      '/projects/p1/remote': {'url': 'https://github.com/o/haro.git'},
      '/projects/p1/scripts': {
        'setup': 'npm install',
        'run': 'npm run dev',
        'runs': [
          {'id': 'app', 'command': 'npm run dev', 'default': true},
        ],
        'archive': 'echo bye',
        'run_mode': 'nonconcurrent',
        'login_shell': true,
      },
      '/projects/p1/env': {'content': 'API_KEY=abc\n'},
      '/projects/p1/instructions': {'shared': 'team text', 'local': 'mine'},
      '/usage': {
        'available': true,
        'account': {'plan': 'Claude Max', 'org': 'Acme'},
        'limits': [
          {
            'kind': 'session',
            'label': 'Current session',
            'percent': 39,
            'severity': 'normal',
            'is_active': true,
          },
          {
            'kind': 'weekly_all',
            'label': 'Weekly (all models)',
            'percent': 12,
            'severity': 'normal',
          },
        ],
      },
      '/update/status': {
        'supported': true,
        'available': false,
        'buildSha': 'f4803ada',
        'headSha': 'f4803ada',
        'mode': 'auto',
      },
    });
  }

  final Map<String, Object?> routes = {};
  final List<http.Request> log = [];

  /// Paths whose PUTs answer with this status instead.
  final Map<String, int> failing = {};
  final Map<String, int> failingGet = {};

  Iterable<http.Request> puts(String path) =>
      log.where((r) => r.method == 'PUT' && r.url.path == path);

  Map<String, dynamic> body(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  http.Response _json(Object? v, [int status = 200]) => http.Response(
    jsonEncode(v),
    status,
    headers: {'content-type': 'application/json'},
  );

  Future<http.Response> _handle(http.Request r) async {
    log.add(r);
    final status = (r.method == 'GET' ? failingGet : failing)[r.url.path];
    if (status != null) return _json({'detail': 'backend said no'}, status);
    if (r.method == 'GET') {
      final v = routes[r.url.path];
      return v == null ? _json({'detail': 'nope'}, 404) : _json(v);
    }
    final b = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
    switch (r.url.path) {
      case '/projects/p1/default-branch':
        return _json({
          'id': 'p1',
          'name': 'haro',
          'path': '/x/haro',
          'default_branch': b['branch'],
        });
      case '/projects/p1/remote':
        return _json({'url': (b['url'] as String).isEmpty ? null : b['url']});
      case '/projects/p1/instructions':
        final cur = routes[r.url.path]! as Map<String, dynamic>;
        final next = {
          ...cur,
          b['target'] == 'shared' ? 'shared' : 'local': b['text'],
        };
        routes[r.url.path] = next;
        return _json(next);
      default:
        final echo = {...b}..remove('target');
        routes[r.url.path] = echo;
        return _json(echo);
    }
  }

  HaroApi api() =>
      HaroApi(Uri.parse('http://127.0.0.1:8000'), client: MockClient(_handle));
}

bool _fontsLoaded = false;

/// Real brand fonts, so overflow checks measure real glyph widths instead of the test font.
Future<void> loadBrandFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(rootBundle.load('assets/fonts/$f'));
    }
    await loader.load();
  }

  await family('SpaceGrotesk', [
    'SpaceGrotesk-400.ttf',
    'SpaceGrotesk-500.ttf',
    'SpaceGrotesk-600.ttf',
    'SpaceGrotesk-700.ttf',
  ]);
  await family('SpaceMono', ['SpaceMono-400.ttf', 'SpaceMono-700.ttf']);
}

/// Says whether a Team write is safe, and records what it was asked about.
class FakeLayers implements SettingsLayerReader {
  FakeLayers({this.safe = true});

  bool safe;
  final List<List<String>> asked = [];

  @override
  Future<bool> teamWriteSafe(Project project, List<String> tables) async {
    asked.add(tables);
    return safe;
  }
}

class Opened {
  Opened(this.backend, this.prefs);

  final FakeBackend backend;
  final MemoryDevicePrefsStore prefs;
}

/// Opens the real overlay (via showHaroOverlay, so the 92% / 80% clamp applies) on a
/// window of [size].
Future<Opened> openSettings(
  WidgetTester tester, {
  FakeBackend? backend,
  MemoryDevicePrefsStore? prefs,
  SettingsLayerReader? layers,
  SettingsTab tab = SettingsTab.display,
  List<Project> projects = const [proj1],
  String? projectId,
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final be = backend ?? FakeBackend();
  final store = prefs ?? MemoryDevicePrefsStore();
  final lay = layers ?? FakeLayers();
  haroOverlayDepth.value = 0;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        haroApiProvider.overrideWithValue(be.api()),
        devicePrefsStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        theme: buildHaroTheme(),
        home: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTap: () => showSettingsOverlay(
                context,
                api: be.api(),
                devicePrefs: store,
                projects: projects,
                projectId: projectId,
                layers: lay,
                tab: tab,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return Opened(be, store);
}

Future<void> goTab(WidgetTester tester, String label) async {
  final nav = find.byType(ListView).first;
  final item = find.descendant(of: nav, matching: find.text(label));
  // At 960x640 the last nav items sit below the fold; the nav is a scrolling list.
  if (item.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      item,
      60,
      scrollable: find.descendant(of: nav, matching: find.byType(Scrollable)),
    );
  }
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}
