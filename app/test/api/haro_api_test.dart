import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

void main() {
  final base = Uri.parse('http://127.0.0.1:8000');

  HaroApi apiWith(
    Future<http.Response> Function(http.Request req) handler, {
    List<http.Request>? log,
  }) => HaroApi(
    base,
    client: MockClient((req) async {
      log?.add(req);
      return handler(req);
    }),
  );

  http.Response jsonRes(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  test('listProjects hits /projects and parses the list', () async {
    final log = <http.Request>[];
    final api = apiWith(
      (r) async => jsonRes([
        {
          'id': 'p1',
          'name': 'haro',
          'path': '/x',
          'default_branch': 'main',
          'remote_url': null,
          'stack': ['python'],
        },
      ]),
      log: log,
    );
    final projects = await api.listProjects();
    expect(projects.single.name, 'haro');
    expect(log.single.method, 'GET');
    expect(log.single.url.toString(), 'http://127.0.0.1:8000/projects');
  });

  test('createWorkspace posts nulls for absent optional fields', () async {
    final log = <http.Request>[];
    final api = apiWith((r) async => jsonRes(workspaceJson()), log: log);
    final ws = await api.createWorkspace('p1', 'add multiply');
    expect(ws.id, 'ws_1a2b3c4d');
    final req = log.single;
    expect(req.method, 'POST');
    expect(req.url.path, '/projects/p1/workspaces');
    expect(req.headers['content-type'], contains('application/json'));
    expect(jsonDecode(req.body), {
      'name': 'add multiply',
      'base_ref': null,
      'branch': null,
      'seed_key': null,
    });
  });

  test('createWorkspace sends the mode when given', () async {
    final log = <http.Request>[];
    final api = apiWith(
      (r) async => jsonRes(workspaceJson(overrides: {'mode': 'manual'})),
      log: log,
    );
    final ws = await api.createWorkspace(
      'p1',
      'fix the rounding',
      mode: WorkspaceMode.manual,
    );
    expect(jsonDecode(log.single.body)['mode'], 'manual');
    expect(ws.mode, WorkspaceMode.manual);
  });

  test('setWorkspaceMode posts {mode} and parses the workspace', () async {
    final log = <http.Request>[];
    final api = apiWith(
      (r) async => jsonRes(
        workspaceJson(
          overrides: {
            'mode': 'manual',
            'mode_switches': [
              {'to': 'manual', 'at': '2026-09-29T10:32:00Z', 'sha': 'abc'},
            ],
          },
        ),
      ),
      log: log,
    );
    final ws = await api.setWorkspaceMode('ws_1a2b3c4d', WorkspaceMode.manual);
    expect(log.single.method, 'POST');
    expect(log.single.url.path, '/workspaces/ws_1a2b3c4d/mode');
    expect(jsonDecode(log.single.body), {'mode': 'manual'});
    expect(ws.mode, WorkspaceMode.manual);
    expect(ws.modeSwitches.single.sha, 'abc');
  });

  test('a mode refusal surfaces the backend message', () async {
    final api = apiWith(
      (r) async => http.Response(
        jsonEncode({'detail': 'stop the agent first'}),
        409,
        headers: {'content-type': 'application/json'},
      ),
    );
    expect(
      () => api.setWorkspaceMode('ws_1', WorkspaceMode.manual),
      throwsA(
        isA<HaroApiException>()
            .having((e) => e.status, 'status', 409)
            .having(
              (e) => e.message,
              'message',
              contains('stop the agent first'),
            ),
      ),
    );
  });

  test(
    'startAgent omits plan when not given (backend rejects plan: null)',
    () async {
      final log = <http.Request>[];
      final api = apiWith(
        (r) async => jsonRes({
          'id': 'run_1',
          'workspace_id': 'ws_1',
          'status': 'running',
        }),
        log: log,
      );
      await api.startAgent('ws_1', 'fix the bug');
      final body = jsonDecode(log.single.body) as Map;
      expect(body.containsKey('plan'), isFalse);
    },
  );

  test(
    'GateConfig round-trips mutation so a gate PUT cannot switch it off',
    () {
      final cfg = GateConfig.fromJson({'mutation': true});
      expect(cfg.mutation, isTrue);
      expect(cfg.toJson()['mutation'], isTrue);
    },
  );

  test('startAgent body carries plan and role but no fast flag', () async {
    final log = <http.Request>[];
    final api = apiWith(
      (r) async =>
          jsonRes({'id': 'run_1', 'workspace_id': 'ws_1', 'status': 'running'}),
      log: log,
    );
    final run = await api.startAgent(
      'ws_1',
      'do it',
      model: 'sonnet',
      effort: 'high',
      plan: true,
      role: 'plan',
    );
    expect(run.status, AgentRunStatus.running);
    final body = jsonDecode(log.single.body) as Map;
    expect(body['plan'], true);
    expect(body['role'], 'plan');
    expect(body.containsKey('fast'), isFalse);
    expect(log.single.url.path, '/workspaces/ws_1/agent');
  });

  test('query parameters: issues tri-state, tests scope, dry flag', () async {
    final log = <http.Request>[];
    final api = apiWith((r) async {
      if (r.url.path.endsWith('/issues')) {
        return jsonRes({'available': true, 'issues': []});
      }
      if (r.url.path.endsWith('/tests')) return jsonRes(testRunJson());
      return jsonRes({'dry': true, 'items': []});
    }, log: log);

    await api.getIssues('p1');
    expect(log.last.url.query, '');
    await api.getIssues('p1', refresh: true, state: 'all', mine: false);
    expect(log.last.url.queryParameters, {
      'refresh': '1',
      'state': 'all',
      'mine': '0',
    });
    await api.getIssues('p1', mine: true);
    expect(log.last.url.queryParameters, {'mine': '1'});

    await api.runTests('ws_1', scope: TestScope.impacted);
    expect(log.last.method, 'POST');
    expect(log.last.url.queryParameters, {'scope': 'impacted'});

    await api.mergeQueue('p1', dry: true);
    expect(log.last.url.queryParameters, {'dry': 'true'});
  });

  test(
    'getTests resolves null for a workspace that never ran the gate',
    () async {
      final api = apiWith((r) async => http.Response('null', 200));
      expect(await api.getTests('ws_1'), isNull);
    },
  );

  test('getArchiveQueue null body', () async {
    final api = apiWith((r) async => http.Response('null', 200));
    expect(await api.getArchiveQueue('p1'), isNull);
  });

  test('getEvents returns the transcript and forwards session', () async {
    final log = <http.Request>[];
    final api = apiWith(
      (r) async => jsonRes({
        'events': [
          {
            'run_id': 'r',
            'workspace_id': 'ws_1',
            'ts': 1.0,
            'type': 'token',
            'payload': {'text': 'a'},
            'turn': 1,
          },
        ],
      }),
      log: log,
    );
    final events = await api.getEvents('ws_1', session: 'side');
    expect(events.single.turn, 1);
    expect(log.single.url.queryParameters, {'session': 'side'});
  });

  test('rename sends only the provided fields', () async {
    final log = <http.Request>[];
    final api = apiWith((r) async => jsonRes(workspaceJson()), log: log);
    await api.renameWorkspace('ws_1', name: 'new name');
    expect(log.single.method, 'PATCH');
    expect(jsonDecode(log.single.body), {'name': 'new name'});
  });

  group('runReview', () {
    test('posts an empty body by default and parses a verdict', () async {
      final log = <http.Request>[];
      final api = apiWith(
        (r) async => jsonRes({
          'ran_at': 1.0,
          'model': 'opus',
          'verdict': 'pass',
          'summary': 'fine',
        }),
        log: log,
      );
      final res = await api.runReview('ws_1');
      expect(log.single.method, 'POST');
      expect(log.single.url.path, '/workspaces/ws_1/review');
      expect(jsonDecode(log.single.body), <String, dynamic>{});
      expect(res, isA<ReviewVerdict>());
      expect((res as ReviewVerdict).pass, isTrue);
    });

    test('sends the model override and parses findings', () async {
      final log = <http.Request>[];
      final api = apiWith(
        (r) async => jsonRes({
          'ran_at': 1.0,
          'model': 'haiku',
          'summary': 's',
          'findings': [
            {
              'file': 'a',
              'line': 1,
              'severity': 'high',
              'category': 'bug',
              'title': 't',
            },
          ],
        }),
        log: log,
      );
      final res = await api.runReview('ws_1', model: 'haiku');
      expect(jsonDecode(log.single.body), {'model': 'haiku'});
      expect((res as ReviewResult).findings.single.severity, 'high');
    });

    test(
      'nothing_to_review and a reviewer-side error both come back as 200',
      () async {
        var body = <String, dynamic>{'ran_at': 1.0, 'nothing_to_review': true};
        final api = apiWith((r) async => jsonRes(body));
        expect((await api.runReview('ws_1')).nothingToReview, isTrue);
        body = {'ran_at': 1.0, 'error': 'reviewer timed out'};
        expect((await api.runReview('ws_1')).error, 'reviewer timed out');
      },
    );

    test('an unknown workspace throws HaroApiException(404)', () async {
      final api = apiWith(
        (r) async => jsonRes({'detail': 'workspace not found'}, 404),
      );
      await expectLater(
        api.runReview('nope'),
        throwsA(
          isA<HaroApiException>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.message, 'message', 'workspace not found'),
        ),
      );
    });
  });

  test('setGate merges the target into the config body', () async {
    final log = <http.Request>[];
    final api = apiWith(
      (r) async => jsonRes(const GateConfig().toJson()),
      log: log,
    );
    await api.setGate(
      'p1',
      const GateConfig(tamperAlarm: 'block'),
      target: 'local',
    );
    final body = jsonDecode(log.single.body) as Map;
    expect(body['target'], 'local');
    expect(body['tamper_alarm'], 'block');
    expect(log.single.method, 'PUT');
  });

  test(
    'installFirewall sends the backend origin, not a browser location',
    () async {
      final log = <http.Request>[];
      final api = apiWith(
        (r) async => jsonRes({
          'firewall': 'warn',
          'strict': false,
          'hooks': [],
          'config_path': '/x',
        }),
        log: log,
      );
      await api.installFirewall('p1', 'warn');
      expect(
        (jsonDecode(log.single.body) as Map)['backend_url'],
        'http://127.0.0.1:8000',
      );
    },
  );

  test('postReceiptPrComment returns the URL only when posted', () async {
    var posted = true;
    final api = apiWith(
      (r) async => jsonRes({'posted': posted, 'url': 'https://x/1#c'}),
    );
    expect(await api.postReceiptPrComment('ws_1'), 'https://x/1#c');
    posted = false;
    expect(await api.postReceiptPrComment('ws_1'), isNull);
  });

  test('setRowChecked returns the full key list', () async {
    final log = <http.Request>[];
    final api = apiWith(
      (r) async => jsonRes({
        'checked_rows': ['a', 'b'],
      }),
      log: log,
    );
    expect(await api.setRowChecked('ws_1', 'a', checked: true), ['a', 'b']);
    expect(jsonDecode(log.single.body), {'key': 'a', 'checked': true});
  });

  test('rawUrl builds a download URL without fetching', () {
    final api = HaroApi(base);
    final u = api.rawUrl('ws_1', 'a b/c.png', download: true);
    expect(u.path, '/workspaces/ws_1/raw');
    expect(u.queryParameters, {'path': 'a b/c.png', 'download': '1'});
    api.close();
  });

  test('uploadContext base64-encodes bytes', () async {
    final log = <http.Request>[];
    final api = apiWith(
      (r) async => jsonRes({
        'path': '.context/a.png',
        'name': 'a.png',
        'kind': 'image',
        'size': 3,
      }),
      log: log,
    );
    final a = await api.uploadContext(
      'ws_1',
      'a.png',
      Uint8List.fromList([1, 2, 3]),
      contentType: 'image/png',
    );
    expect(a.kind, 'image');
    expect(
      (jsonDecode(log.single.body) as Map)['content_b64'],
      base64Encode([1, 2, 3]),
    );
  });

  group('errors', () {
    test('string detail', () async {
      final api = apiWith(
        (r) async => jsonRes({'detail': 'workspace not found'}, 404),
      );
      await expectLater(
        api.getWorkspace('nope'),
        throwsA(
          isA<HaroApiException>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.message, 'message', 'workspace not found'),
        ),
      );
    });

    test('422 array detail flattens to msg list', () async {
      final api = apiWith(
        (r) async => jsonRes({
          'detail': [
            {
              'loc': ['body', 'name'],
              'msg': 'field required',
              'type': 'missing',
            },
            {
              'loc': ['body', 'path'],
              'msg': 'field required',
              'type': 'missing',
            },
          ],
        }, 422),
      );
      await expectLater(
        api.createProject('/x'),
        throwsA(
          isA<HaroApiException>().having(
            (e) => e.message,
            'message',
            'field required; field required',
          ),
        ),
      );
    });

    test('non-JSON error body falls back to the reason phrase', () async {
      final api = apiWith(
        (r) async => http.Response('<html>', 502, reasonPhrase: 'Bad Gateway'),
      );
      await expectLater(
        api.health(),
        throwsA(
          isA<HaroApiException>().having(
            (e) => e.message,
            'message',
            'Bad Gateway',
          ),
        ),
      );
    });

    test('object detail is stringified', () async {
      final api = apiWith(
        (r) async => jsonRes({
          'detail': {
            'refusals': ['x'],
          },
        }, 400),
      );
      await expectLater(
        api.merge('ws_1'),
        throwsA(
          isA<HaroApiException>().having(
            (e) => e.message,
            'message',
            contains('refusals'),
          ),
        ),
      );
    });

    test('connection failure becomes status 0', () async {
      final api = HaroApi(
        base,
        client: MockClient(
          (r) async => throw http.ClientException('Connection refused'),
        ),
      );
      await expectLater(
        api.health(),
        throwsA(isA<HaroApiException>().having((e) => e.status, 'status', 0)),
      );
    });

    test(
      'listEditors parses the targets and refresh adds ?refresh=1',
      () async {
        final log = <http.Request>[];
        final api = apiWith(
          (r) async => jsonRes([
            {'id': 'zed', 'label': 'Zed', 'kind': 'gui', 'available': true},
            {
              'id': 'neovim',
              'label': 'Neovim',
              'kind': 'terminal',
              'available': false,
            },
            {
              'id': 'file_manager',
              'label': 'Files',
              'kind': 'file_manager',
              'available': true,
            },
          ]),
          log: log,
        );
        final editors = await api.listEditors();
        expect(editors.map((e) => e.kind), [
          EditorKind.gui,
          EditorKind.terminal,
          EditorKind.fileManager,
        ]);
        expect(editors.map((e) => e.available), [true, false, true]);
        expect(log.single.url.path, '/editors');
        expect(log.single.url.queryParameters, isEmpty);
        await api.listEditors(refresh: true);
        expect(log.last.url.queryParameters, {'refresh': '1'});
      },
    );

    test('openIn posts the target and parses both modes', () async {
      final log = <http.Request>[];
      final api = apiWith((r) async {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        return body['target'] == 'neovim'
            ? jsonRes({'mode': 'shell', 'command': 'nvim +3 a.ts'})
            : jsonRes({'mode': 'spawned', 'command': null});
      }, log: log);

      final gui = await api.openIn('ws_1', 'zed', path: 'a.ts', line: 3);
      expect(gui.mode, OpenInMode.spawned);
      expect(gui.command, isNull);
      expect(log.single.method, 'POST');
      expect(log.single.url.path, '/workspaces/ws_1/open');
      expect(jsonDecode(log.single.body), {
        'target': 'zed',
        'path': 'a.ts',
        'line': 3,
      });

      final term = await api.openIn('ws_1', 'neovim', path: 'a.ts', line: 3);
      expect(term.mode, OpenInMode.shell);
      expect(term.command, 'nvim +3 a.ts');
    });

    test('openIn surfaces the missing backend route as a 404', () async {
      final api = apiWith((r) async => jsonRes({'detail': 'Not Found'}, 404));
      await expectLater(
        api.openIn('ws_1', 'zed', path: 'a.ts', line: 3),
        throwsA(isA<HaroApiException>().having((e) => e.status, 'status', 404)),
      );
    });
  });

  group('file save', () {
    test('readFile parses the etag, writeFile sends the expected one and returns the new', () async {
      final log = <http.Request>[];
      final api = apiWith((r) async {
        if (r.method == 'GET') {
          return jsonRes({
            'path': 'a.ts',
            'content': 'x',
            'etag': 'abc',
            'size': 1,
          });
        }
        return jsonRes({'saved': true, 'etag': 'def'});
      }, log: log);
      final f = await api.readFile('ws1', 'a.ts');
      expect(f.etag, 'abc');

      final next = await api.writeFile(
        'ws1',
        'a.ts',
        'y',
        expectedEtag: f.etag,
      );
      expect(next, 'def');
      expect(jsonDecode(log.last.body), {
        'path': 'a.ts',
        'content': 'y',
        'expected_etag': 'abc',
      });
    });

    test(
      'an unguarded write omits expected_etag; an old backend returns no etag',
      () async {
        final log = <http.Request>[];
        final api = apiWith((r) async => jsonRes({'ok': true}), log: log);
        expect(await api.writeFile('ws1', 'a.ts', 'y'), isNull);
        expect(jsonDecode(log.single.body), {'path': 'a.ts', 'content': 'y'});
      },
    );

    test('a 409 carries its decoded body', () async {
      final api = apiWith(
        (r) async => jsonRes({
          'detail': 'file changed on disk',
          'reason': 'deleted',
          'etag': null,
        }, 409),
      );
      await expectLater(
        api.writeFile('ws1', 'a.ts', 'y', expectedEtag: 'abc'),
        throwsA(
          isA<HaroApiException>()
              .having((e) => e.status, 'status', 409)
              .having((e) => e.message, 'message', 'file changed on disk')
              .having((e) => e.body?['reason'], 'reason', 'deleted'),
        ),
      );
    });
  });
}
