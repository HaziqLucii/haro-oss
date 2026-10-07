import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models/json_util.dart';
import 'models/models.dart';

/// Non-2xx response, or a body the client could not read. [message] is already flattened
/// to something showable (FastAPI's `detail` is a string, or a list of `{loc,msg,type}` on 422).
class HaroApiException implements Exception {
  const HaroApiException(this.status, this.message, {this.body});

  final int status;
  final String message;

  /// The decoded JSON error body, when it was an object (a 409 save carries `reason` and `etag`).
  final Map<String, dynamic>? body;

  @override
  String toString() => 'HaroApiException($status): $message';
}

/// Typed REST client for the haro backend. Ported from the React client's `api.ts`; paths
/// were cross-checked against `backend/haro/main.py`.
///
/// Not ported (features removed in the redesign): Race x N (`race/preflight`, `races`,
/// `/races/{id}/*`), the composer `fast` flag on [startAgent], the Monaco-only `tsconfig`
/// route, and the Nvim editor socket.
class HaroApi {
  HaroApi(this.baseUri, {http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final Uri baseUri;
  final http.Client _client;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) _client.close();
  }

  // ---- transport ----

  Uri _uri(String path, [Map<String, String?>? query]) {
    final q = <String, String>{
      if (query != null)
        for (final e in query.entries)
          if (e.value != null) e.key: e.value!,
    };
    return baseUri.replace(path: path, queryParameters: q.isEmpty ? null : q);
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
  }) async {
    final req = http.Request(method, _uri(path, query));
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req));
    } on http.ClientException catch (e) {
      throw HaroApiException(0, e.message);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HaroApiException(
        res.statusCode,
        _errorMessage(res),
        body: _errorBody(res),
      );
    }
    if (res.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw HaroApiException(res.statusCode, 'unreadable response body');
    }
  }

  static Map<String, dynamic>? _errorBody(http.Response res) {
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      return body is Map<String, dynamic> ? body : null;
    } catch (_) {
      return null;
    }
  }

  static String _errorMessage(http.Response res) {
    Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      final reason = res.reasonPhrase;
      return reason == null || reason.isEmpty
          ? 'HTTP ${res.statusCode}'
          : reason;
    }
    final d = body is Map ? (body['detail'] ?? body['message']) : null;
    if (d is String) return d;
    if (d is List) {
      return d
          .map((e) => e is Map && e['msg'] is String ? e['msg'] : jsonEncode(e))
          .join('; ');
    }
    if (d != null) return jsonEncode(d);
    return 'HTTP ${res.statusCode}';
  }

  Future<dynamic> _get(String path, {Map<String, String?>? query}) =>
      _send('GET', path, query: query);
  Future<dynamic> _post(
    String path, {
    Object? body,
    Map<String, String?>? query,
  }) => _send('POST', path, body: body, query: query);
  Future<dynamic> _put(String path, {Object? body}) =>
      _send('PUT', path, body: body);
  Future<dynamic> _patch(String path, {Object? body}) =>
      _send('PATCH', path, body: body);
  Future<dynamic> _delete(String path, {Map<String, String?>? query}) =>
      _send('DELETE', path, query: query);

  Future<List<T>> _list<T>(Future<dynamic> res, T Function(Json) parse) async {
    final v = await res;
    if (v is! List) return <T>[];
    return [
      for (final e in v)
        if (e is Map) parse(asJson(e)),
    ];
  }

  // ---- GitHub accounts ----

  Future<GithubAccounts> getGithubAccounts() async =>
      GithubAccounts.fromJson(asJson(await _get('/github/accounts')));

  Future<void> setGithubDefault(String login) =>
      _post('/github/default', body: {'login': login});

  /// 409 carries a `reason` of `gh_missing` or `login_in_progress` in [HaroApiException.body].
  Future<GithubLoginStart> startGithubLogin() async =>
      GithubLoginStart.fromJson(asJson(await _post('/github/login/start')));

  Future<GithubLoginStatus> getGithubLogin(String id) async =>
      GithubLoginStatus.fromJson(asJson(await _get('/github/login/$id')));

  Future<GithubLoginStatus> cancelGithubLogin(String id) async =>
      GithubLoginStatus.fromJson(
        asJson(await _post('/github/login/$id/cancel')),
      );

  Future<ProjectGhAccount> getProjectGhAccount(String projectId) async =>
      ProjectGhAccount.fromJson(
        asJson(await _get('/projects/$projectId/gh-account')),
      );

  /// A null [login] clears the override (Auto).
  Future<ProjectGhAccount> setProjectGhAccount(
    String projectId,
    String? login,
  ) async => ProjectGhAccount.fromJson(
    asJson(
      await _put('/projects/$projectId/gh-account', body: {'login': login}),
    ),
  );

  // ---- XP ----

  Future<XpStatus> getXp() async =>
      XpStatus.fromJson(asJson(await _get('/xp')));

  Future<XpRules> getXpRules() async =>
      XpRules.fromJson(asJson(await _get('/xp/rules')));

  /// Reports something only the client can see (`docs_read`, `diff_reviewed`). The backend
  /// decides whether it pays and answers with the awards, empty when it did not.
  Future<List<XpAward>> postXpActivity(
    String kind, {
    String? workspaceId,
    List<String> paths = const [],
  }) async {
    final j = asJson(
      await _post(
        '/xp/activity',
        body: {
          'kind': kind,
          'workspace_id': ?workspaceId,
          if (paths.isNotEmpty) 'paths': paths,
        },
      ),
    );
    return jList(j, 'awards', XpAward.fromJson);
  }

  // ---- app ----

  Future<bool> health() async => jBool(asJson(await _get('/health')), 'ok');

  Future<UsageResponse> usage({bool refresh = false}) async =>
      UsageResponse.fromJson(
        asJson(await _get('/usage', query: {'refresh': refresh ? '1' : null})),
      );

  Future<UpdateStatus> updateStatus() async =>
      UpdateStatus.fromJson(asJson(await _get('/update/status')));

  Future<UpdateProgress?> updateProgress() async {
    final v = await _get('/update/progress');
    return v is Map ? UpdateProgress.fromJson(asJson(v)) : null;
  }

  Future<void> applyUpdate() => _post('/update/apply');

  Future<void> setUpdateMode(String mode) =>
      _send('PUT', '/update/settings', query: {'mode': mode});

  // ---- projects ----

  Future<List<Project>> listProjects() =>
      _list(_get('/projects'), Project.fromJson);

  Future<Project> createProject(
    String path, {
    String? name,
    bool init = false,
    String? remoteUrl,
  }) async => Project.fromJson(
    asJson(
      await _post(
        '/projects',
        body: {
          'path': path,
          'name': name,
          'init': init,
          'remote_url': (remoteUrl == null || remoteUrl.isEmpty)
              ? null
              : remoteUrl,
        },
      ),
    ),
  );

  Future<void> removeProject(String projectId) =>
      _delete('/projects/$projectId');

  Future<FsListing> browseFs([String? path]) async =>
      FsListing.fromJson(asJson(await _get('/fs', query: {'path': path})));

  Future<void> mkdirFs(String parent, String name) =>
      _post('/fs/mkdir', body: {'parent': parent, 'name': name});

  Future<StackDetection> detectStack(String projectId) async =>
      StackDetection.fromJson(
        asJson(await _get('/projects/$projectId/detect-stack')),
      );

  Future<void> applyPreset(
    String projectId,
    String presetId, {
    String target = 'shared',
  }) => _post(
    '/projects/$projectId/apply-preset',
    body: {'preset_id': presetId, 'target': target},
  );

  Future<BranchList> listBranches(String projectId) async =>
      BranchList.fromJson(asJson(await _get('/projects/$projectId/branches')));

  Future<Project> setDefaultBranch(String projectId, String branch) async =>
      Project.fromJson(
        asJson(
          await _put(
            '/projects/$projectId/default-branch',
            body: {'branch': branch},
          ),
        ),
      );

  Future<RemoteConfig> getRemote(String projectId) async =>
      RemoteConfig.fromJson(asJson(await _get('/projects/$projectId/remote')));

  Future<RemoteConfig> setRemote(String projectId, String url) async =>
      RemoteConfig.fromJson(
        asJson(await _put('/projects/$projectId/remote', body: {'url': url})),
      );

  Future<Json> pushProject(String projectId) async =>
      asJson(await _post('/projects/$projectId/push'));

  Future<Json> pullProject(String projectId) async =>
      asJson(await _post('/projects/$projectId/pull'));

  /// Brings the project's main checkout level with origin when that is a safe fast-forward;
  /// the result says what happened or why it was left alone.
  Future<ProjectSync> syncProject(String projectId) async =>
      ProjectSync.fromJson(asJson(await _post('/projects/$projectId/sync')));

  /// Stops ONE delegated sub-agent of the run in progress (the run carries on). 409 when it
  /// already finished or the run's adapter cannot.
  Future<void> stopSubAgent(
    String wsId,
    String delegationId, {
    String? session,
  }) async {
    await _post(
      '/workspaces/$wsId/agents/${Uri.encodeComponent(delegationId)}/stop',
      query: {'session': session},
    );
  }

  Future<ProjectSync> projectSyncStatus(String projectId) async =>
      ProjectSync.fromJson(asJson(await _get('/projects/$projectId/sync')));

  /// The Backlog notice's button: switch the checkout to the default branch, then sync it.
  Future<ProjectSync> switchToDefault(String projectId) async =>
      ProjectSync.fromJson(
        asJson(await _post('/projects/$projectId/sync/switch')),
      );

  // ---- project config ----

  Future<WorkflowConfig> getWorkflow(String projectId) async =>
      WorkflowConfig.fromJson(
        asJson(await _get('/projects/$projectId/workflow')),
      );

  Future<WorkflowConfig> setWorkflow(
    String projectId,
    String mergeMode, {
    String target = 'shared',
  }) async => WorkflowConfig.fromJson(
    asJson(
      await _put(
        '/projects/$projectId/workflow',
        body: {'merge_mode': mergeMode, 'target': target},
      ),
    ),
  );

  Future<BaselineState> getBaseline(String projectId) async =>
      BaselineState.fromJson(
        asJson(await _get('/projects/$projectId/baseline')),
      );

  /// Starts the baseline and returns at once (`running: true`); progress and the result
  /// arrive on the global feed. 409 when one is already running for this project.
  Future<BaselineState> runBaseline(String projectId) async =>
      BaselineState.fromJson(
        asJson(await _post('/projects/$projectId/baseline')),
      );

  Future<GateConfig> getGate(String projectId) async =>
      GateConfig.fromJson(asJson(await _get('/projects/$projectId/gate')));

  Future<GateConfig> setGate(
    String projectId,
    GateConfig cfg, {
    String target = 'shared',
  }) async => GateConfig.fromJson(
    asJson(
      await _put(
        '/projects/$projectId/gate',
        body: {...cfg.toJson(), 'target': target},
      ),
    ),
  );

  Future<AgentConfig> getAgent(String projectId) async =>
      AgentConfig.fromJson(asJson(await _get('/projects/$projectId/agent')));

  Future<AgentConfig> setAgent(
    String projectId,
    AgentConfig cfg, {
    String target = 'shared',
  }) async => AgentConfig.fromJson(
    asJson(
      await _put(
        '/projects/$projectId/agent',
        body: {...cfg.toJson(), 'target': target},
      ),
    ),
  );

  Future<LocalModelsResponse> getLocalModels(String projectId) async =>
      LocalModelsResponse.fromJson(
        asJson(await _get('/projects/$projectId/agent/local-models')),
      );

  Future<RolesConfig> getRoles(String projectId) async =>
      RolesConfig.fromJson(asJson(await _get('/projects/$projectId/roles')));

  Future<RolesConfig> setRoles(
    String projectId,
    RolesConfig cfg, {
    String target = 'shared',
  }) async => RolesConfig.fromJson(
    asJson(
      await _put(
        '/projects/$projectId/roles',
        body: {...cfg.toJson(), 'target': target},
      ),
    ),
  );

  Future<EnvConfig> getEnv(String projectId) async =>
      EnvConfig.fromJson(asJson(await _get('/projects/$projectId/env')));

  Future<EnvConfig> setEnv(String projectId, String content) async =>
      EnvConfig.fromJson(
        asJson(
          await _put('/projects/$projectId/env', body: {'content': content}),
        ),
      );

  Future<ScriptsConfig> getProjectScripts(String projectId) async =>
      ScriptsConfig.fromJson(
        asJson(await _get('/projects/$projectId/scripts')),
      );

  Future<ScriptsConfig> saveProjectScripts(
    String projectId,
    ScriptsConfig cfg, {
    String target = 'shared',
  }) async => ScriptsConfig.fromJson(
    asJson(
      await _put(
        '/projects/$projectId/scripts',
        body: {...cfg.toJson(), 'target': target},
      ),
    ),
  );

  Future<InstructionsConfig> getProjectInstructions(String projectId) async =>
      InstructionsConfig.fromJson(
        asJson(await _get('/projects/$projectId/instructions')),
      );

  Future<InstructionsConfig> saveProjectInstructions(
    String projectId,
    String text,
    String target,
  ) async => InstructionsConfig.fromJson(
    asJson(
      await _put(
        '/projects/$projectId/instructions',
        body: {'text': text, 'target': target},
      ),
    ),
  );

  /// Merge Firewall arm/disarm. `backend_url` is the hooks' callback origin.
  Future<FirewallResult> installFirewall(
    String projectId,
    String posture, {
    bool strict = false,
  }) async => FirewallResult.fromJson(
    asJson(
      await _post(
        '/projects/$projectId/firewall',
        body: {
          'firewall': posture,
          'strict': strict,
          'backend_url': baseUri.origin,
        },
      ),
    ),
  );

  Future<FirewallResult> uninstallFirewall(String projectId) async =>
      FirewallResult.fromJson(
        asJson(await _delete('/projects/$projectId/firewall')),
      );

  // ---- backlog ----

  Future<TodoResponse> getTodo(String projectId) async =>
      TodoResponse.fromJson(asJson(await _get('/projects/$projectId/todo')));

  Future<void> putTodo(String projectId, String path, String content) => _put(
    '/projects/$projectId/todo',
    body: {'path': path, 'content': content},
  );

  /// Appends one follow-up line. Omit [file] to use the fixed `backlog/follow-ups.md`.
  Future<void> addTodoItem(
    String projectId,
    String title, {
    String evidence = '',
    String? file,
  }) => _post(
    '/projects/$projectId/todo/items',
    body: {'title': title, 'evidence': evidence, 'file': ?file},
  );

  /// [mine] is tri-state: `null` omits the key so the project's `issue_assignee` applies.
  Future<IssuesResponse> getIssues(
    String projectId, {
    bool refresh = false,
    String? state,
    bool? mine,
  }) async => IssuesResponse.fromJson(
    asJson(
      await _get(
        '/projects/$projectId/issues',
        query: {
          'refresh': refresh ? '1' : null,
          'state': state,
          'mine': mine == null ? null : (mine ? '1' : '0'),
        },
      ),
    ),
  );

  Future<IssueDetailResponse> getIssueDetail(
    String projectId,
    int number,
  ) async => IssueDetailResponse.fromJson(
    asJson(await _get('/projects/$projectId/issues/$number')),
  );

  // ---- workspaces ----

  Future<List<Workspace>> listWorkspaces(String projectId) =>
      _list(_get('/projects/$projectId/workspaces'), Workspace.fromJson);

  Future<Workspace> getWorkspace(String wsId) async =>
      Workspace.fromJson(asJson(await _get('/workspaces/$wsId')));

  Future<Workspace> createWorkspace(
    String projectId,
    String name, {
    String? baseRef,
    String? branch,
    String? seedKey,
    WorkspaceMode? mode,
    bool startFromTest = false,
  }) async => Workspace.fromJson(
    asJson(
      await _post(
        '/projects/$projectId/workspaces',
        body: {
          'name': name,
          'base_ref': baseRef,
          'branch': (branch == null || branch.isEmpty) ? null : branch,
          'seed_key': seedKey,
          'mode': ?mode?.wire,
          if (startFromTest) 'start_from_test': true,
        },
      ),
    ),
  );

  /// Flips who writes the code. The backend checkpoints a dirty tree first and answers 409
  /// while an agent or the gate is running.
  Future<Workspace> setWorkspaceMode(String wsId, WorkspaceMode mode) async =>
      Workspace.fromJson(
        asJson(
          await _post('/workspaces/$wsId/mode', body: {'mode': mode.wire}),
        ),
      );

  // ---- manual rail: plan, search, docs ----

  /// Starts a read-only plan run. The plan arrives on the `assist` channel.
  Future<AssistJob> assistPlan(
    String wsId,
    String prompt, {
    String? model,
    String? effort,
  }) async => AssistJob.fromJson(
    asJson(
      await _post(
        '/workspaces/$wsId/assist/plan',
        body: {'prompt': prompt, 'model': ?model, 'effort': ?effort},
      ),
    ),
  );

  /// The Search tab's one question. The backend defaults `scope` to `ask` (the AI research
  /// job, plus haro's own git lookups for identifiers in the question); it answers on the
  /// `assist` channel and returns a `jobId` here. The other scopes stay server-side only.
  Future<ResearchResponse> assistResearch(
    String wsId,
    String query, {
    String? model,
    String? effort,
  }) async => ResearchResponse.fromJson(
    asJson(
      await _post(
        '/workspaces/$wsId/assist/research',
        body: {'query': query, 'model': ?model, 'effort': ?effort},
      ),
    ),
  );

  Future<AssistJob?> getAssistJob(String wsId) async {
    final v = await _get('/workspaces/$wsId/assist');
    return v is Map ? AssistJob.fromJson(asJson(v)) : null;
  }

  Future<void> stopAssist(String wsId) =>
      _post('/workspaces/$wsId/assist/stop');

  Future<List<ManualPlan>> listPlans(String wsId) =>
      _list(_get('/workspaces/$wsId/plans'), ManualPlan.fromJson);

  /// Replaces the title and/or steps (tick state travels with them) and/or sets `saved`.
  Future<ManualPlan> patchPlan(
    String wsId,
    String planId, {
    String? title,
    List<PlanStep>? steps,
    bool? saved,
  }) async => ManualPlan.fromJson(
    asJson(
      await _patch(
        '/workspaces/$wsId/plans/$planId',
        body: {
          'title': ?title,
          if (steps != null) 'steps': [for (final s in steps) s.toJson()],
          'saved': ?saved,
        },
      ),
    ),
  );

  Future<void> deletePlan(String wsId, String planId) =>
      _delete('/workspaces/$wsId/plans/$planId');

  Future<List<PinnedDoc>> getPinnedDocs(String projectId) =>
      _list(_get('/projects/$projectId/pinned-docs'), PinnedDoc.fromJson);

  Future<List<PinnedDoc>> setPinnedDocs(
    String projectId,
    List<PinnedDoc> docs,
  ) => _list(
    _put(
      '/projects/$projectId/pinned-docs',
      body: {
        'docs': [for (final d in docs) d.toJson()],
      },
    ),
    PinnedDoc.fromJson,
  );

  /// A man page as plain text, read offline by the backend.
  Future<ManPage> getManPage(String page) async =>
      ManPage.fromJson(asJson(await _get('/man/${Uri.encodeComponent(page)}')));

  Future<Workspace> renameWorkspace(
    String wsId, {
    String? name,
    String? branch,
  }) async => Workspace.fromJson(
    asJson(
      await _send(
        'PATCH',
        '/workspaces/$wsId',
        body: {'name': ?name, 'branch': ?branch},
      ),
    ),
  );

  Future<void> archiveWorkspace(String wsId) => _delete('/workspaces/$wsId');

  /// Continue a merged workspace on a fresh branch (same worktree and chat).
  Future<ContinueResult> continueWorkspace(String wsId) async =>
      ContinueResult.fromJson(
        asJson(await _post('/workspaces/$wsId/continue')),
      );

  // ---- agent ----

  /// [plan] requests a Plan-Mode run: the agent plans, edits nothing, and the gate stays idle.
  /// [role] is `plan` | `build` when `[roles]` is enabled.
  Future<AgentRun> startAgent(
    String wsId,
    String task, {
    String? adapter,
    String? model,
    String? effort,
    bool? plan,
    String? sessionId,
    String? role,
    bool? protectTests,
    bool? testFirst,
  }) async => AgentRun.fromJson(
    asJson(
      await _post(
        '/workspaces/$wsId/agent',
        body: {
          'task': task,
          'adapter': adapter,
          'model': model,
          'effort': effort,
          'plan': ?plan,
          'session_id': sessionId,
          'role': role,
          'protect_tests': ?protectTests,
          'test_first': ?testFirst,
        },
      ),
    ),
  );

  /// Leaves test-first mode. An approved contract needs [confirm].
  Future<Workspace> cancelTestFirst(
    String wsId, {
    bool confirm = false,
  }) async => Workspace.fromJson(
    asJson(
      await _post(
        '/workspaces/$wsId/test-first/cancel',
        body: {'confirm': confirm},
      ),
    ),
  );

  /// Approves the proven-red acceptance test and starts the build run.
  Future<AgentRun> approveTestFirst(
    String wsId, {
    String? model,
    String? effort,
  }) async => AgentRun.fromJson(
    asJson(
      await _post(
        '/workspaces/$wsId/test-first/approve',
        body: {'model': model, 'effort': effort},
      ),
    ),
  );

  Future<void> stopAgent(String wsId) => _post('/workspaces/$wsId/agent/stop');

  Future<List<String>> getSessions(String wsId) async {
    final j = asJson(await _get('/workspaces/$wsId/sessions'));
    return jStrList(j, 'sessions');
  }

  /// The durable transcript. Agent events are NOT replayed over the workspace socket, so a
  /// (re)connecting client must load them here.
  Future<List<AgentEvent>> getEvents(String wsId, {String? session}) async {
    final j = asJson(
      await _get('/workspaces/$wsId/events', query: {'session': session}),
    );
    return jList(j, 'events', AgentEvent.fromJson);
  }

  Future<List<TurnMarker>> getTurns(String wsId, {String? session}) async {
    final j = asJson(
      await _get('/workspaces/$wsId/turns', query: {'session': session}),
    );
    return jList(j, 'turns', TurnMarker.fromJson);
  }

  Future<RewindResponse> rewind(
    String wsId,
    int turn, {
    bool checkpoint = true,
    String? session,
  }) async => RewindResponse.fromJson(
    asJson(
      await _post(
        '/workspaces/$wsId/rewind',
        body: {'turn': turn, 'checkpoint': checkpoint, 'session_id': session},
      ),
    ),
  );

  // ---- code ----

  Future<DiffResponse> getDiff(String wsId, {String? commit}) async =>
      DiffResponse.fromJson(
        asJson(await _get('/workspaces/$wsId/diff', query: {'commit': commit})),
      );

  Future<List<FileNode>> listFiles(String wsId) async {
    final j = asJson(await _get('/workspaces/$wsId/files'));
    return jList(j, 'tree', FileNode.fromJson);
  }

  Future<FileContent> readFile(String wsId, String path) async =>
      FileContent.fromJson(
        asJson(await _get('/workspaces/$wsId/file', query: {'path': path})),
      );

  /// Committed content at [ref] (default the workspace's base_ref): one side of a per-file diff.
  Future<FileBase> readFileBase(
    String wsId,
    String path, {
    String? ref,
  }) async => FileBase.fromJson(
    asJson(
      await _get(
        '/workspaces/$wsId/file/base',
        query: {'path': path, 'ref': ref},
      ),
    ),
  );

  /// Returns the new etag, or null on a backend that predates it. With [expectedEtag] the write
  /// is refused with a 409 (`reason: changed | deleted`) when the file moved on since that read.
  Future<String?> writeFile(
    String wsId,
    String path,
    String content, {
    String? expectedEtag,
  }) async {
    final res = await _put(
      '/workspaces/$wsId/file',
      body: {'path': path, 'content': content, 'expected_etag': ?expectedEtag},
    );
    final etag = res is Map ? res['etag'] : null;
    return etag is String ? etag : null;
  }

  /// Raw bytes URL (images, PDFs). Pass [download] to force a Content-Disposition attachment.
  Uri rawUrl(String wsId, String path, {bool download = false}) => _uri(
    '/workspaces/$wsId/raw',
    {'path': path, 'download': download ? '1' : null},
  );

  Future<SearchResult> searchFiles(String wsId, String q) async =>
      SearchResult.fromJson(
        asJson(await _get('/workspaces/$wsId/search', query: {'q': q})),
      );

  Future<void> createEntry(String wsId, String path, {required bool dir}) =>
      _post('/workspaces/$wsId/fs/create', body: {'path': path, 'dir': dir});

  Future<void> renameEntry(String wsId, String path, String to) =>
      _post('/workspaces/$wsId/fs/rename', body: {'path': path, 'to': to});

  Future<void> deleteEntry(String wsId, String path) =>
      _post('/workspaces/$wsId/fs/delete', body: {'path': path});

  /// Promote a pasted block to a git-excluded `.context/` file the agent can @-mention.
  Future<ContextAttachment> attachContext(
    String wsId,
    String content, {
    String? name,
  }) async => ContextAttachment.fromJson(
    asJson(
      await _post(
        '/workspaces/$wsId/context',
        body: {'content': content, 'name': name},
      ),
    ),
  );

  Future<ContextAttachment> uploadContext(
    String wsId,
    String name,
    Uint8List bytes, {
    String? contentType,
  }) async => ContextAttachment.fromJson(
    asJson(
      await _post(
        '/workspaces/$wsId/context/upload',
        body: {
          'content_b64': base64Encode(bytes),
          'name': name,
          'content_type': (contentType == null || contentType.isEmpty)
              ? null
              : contentType,
        },
      ),
    ),
  );

  /// Detected "Open in..." targets. The backend caches the probe; [refresh] re-runs it.
  Future<List<EditorInfo>> listEditors({bool refresh = false}) => _list(
    _get('/editors', query: {'refresh': refresh ? '1' : null}),
    EditorInfo.fromJson,
  );

  /// Opens the worktree (no [path]) or one file at [line] in an external editor. A terminal
  /// editor is not launched: the result carries the command to type into the Shell tab.
  Future<OpenInResult> openIn(
    String wsId,
    String target, {
    String? path,
    int? line,
  }) async => OpenInResult.fromJson(
    asJson(
      await _post(
        '/workspaces/$wsId/open',
        body: {'target': target, 'path': path, 'line': line},
      ),
    ),
  );

  /// Opens one file of the project root (`.haro/instructions.md`, a backlog doc) in a GUI
  /// editor. Terminal editors are refused: they need a workspace's Shell tab.
  Future<OpenInResult> openProjectFile(
    String projectId,
    String target,
    String path,
  ) async => OpenInResult.fromJson(
    asJson(
      await _post(
        '/projects/$projectId/open',
        body: {'target': target, 'path': path},
      ),
    ),
  );

  // ---- gate ----

  /// Runs the gate and resolves when it finishes (the live cells stream on the socket meanwhile).
  Future<TestRun> runTests(
    String wsId, {
    TestScope scope = TestScope.all,
  }) async => TestRun.fromJson(
    asJson(
      await _post('/workspaces/$wsId/tests', query: {'scope': scope.wire}),
    ),
  );

  Future<TestRun?> getTests(String wsId) async {
    final v = await _get('/workspaces/$wsId/tests');
    return v is Map ? TestRun.fromJson(asJson(v)) : null;
  }

  Future<List<TestRun>> getHistory(String wsId) =>
      _list(_get('/workspaces/$wsId/history'), TestRun.fromJson);

  Future<ImpactResponse> getImpact(String wsId) async =>
      ImpactResponse.fromJson(asJson(await _get('/workspaces/$wsId/impact')));

  Future<BlameResponse> getBlame(String wsId) async =>
      BlameResponse.fromJson(asJson(await _get('/workspaces/$wsId/blame')));

  /// Reads the per-line map the last green gate cached; never runs a suite.
  Future<VerifiedHunksResponse> getVerifiedHunks(String wsId) async =>
      VerifiedHunksResponse.fromJson(
        asJson(await _get('/workspaces/$wsId/verified-hunks')),
      );

  /// Reads facts the gate already computed; never runs a test.
  Future<ReceiptResponse> getReceipt(String wsId) async =>
      ReceiptResponse.fromJson(asJson(await _get('/workspaces/$wsId/receipt')));

  /// Returns the PR comment URL, or `null` when nothing was posted.
  Future<String?> postReceiptPrComment(String wsId) async {
    final j = asJson(await _post('/workspaces/$wsId/receipt/pr-comment'));
    return jBool(j, 'posted') ? jStrN(j, 'url') : null;
  }

  /// Re-runs the suite once per injected fault, so it is on demand (POST) and slow.
  Future<MutationResponse> runMutation(String wsId) async =>
      MutationResponse.fromJson(
        asJson(await _post('/workspaces/$wsId/mutation')),
      );

  /// Advisory run of the tests touching one source file. The verdict streams on the `watch`
  /// channel, never `test`. 409 while another run is busy, 400 for a runner that cannot do it.
  Future<void> runRelated(String wsId, String path) =>
      _post('/workspaces/$wsId/watch/related', query: {'path': path});

  /// Tick a "code to check" row off or back on. Returns the workspace's full key list.
  Future<List<String>> setRowChecked(
    String wsId,
    String key, {
    required bool checked,
  }) async {
    final j = asJson(
      await _post(
        '/workspaces/$wsId/checked',
        body: {'key': key, 'checked': checked},
      ),
    );
    return jStrList(j, 'checked_rows');
  }

  Future<TrustReport> getTrust(String wsId) async =>
      TrustReport.fromJson(asJson(await _get('/workspaces/$wsId/trust')));

  Future<WatchState> getWatch(String wsId) async =>
      WatchState.fromJson(asJson(await _get('/workspaces/$wsId/watch')));

  Future<CoverageResponse> getCoverage(String wsId) async =>
      CoverageResponse.fromJson(
        asJson(await _get('/workspaces/$wsId/coverage')),
      );

  Future<FlakyResponse> runFlaky(String wsId, {int runs = 5}) async =>
      FlakyResponse.fromJson(
        asJson(
          await _post('/workspaces/$wsId/flaky', query: {'runs': '$runs'}),
        ),
      );

  Future<List<KnownFlakyTest>> getKnownFlaky(String projectId) =>
      _list(_get('/projects/$projectId/known-flaky'), KnownFlakyTest.fromJson);

  Future<void> removeKnownFlaky(String projectId, KnownFlakyTest test) =>
      _delete(
        '/projects/$projectId/known-flaky',
        query: {'file': test.file, 'name': test.name},
      );

  // ---- dev server and setup ----

  Future<RunAppResult> runApp(String wsId, {String? runId}) async =>
      RunAppResult.fromJson(
        asJson(await _post('/workspaces/$wsId/run', query: {'run_id': runId})),
      );

  /// Omit [runId] to stop every run in the workspace.
  Future<void> stopApp(String wsId, {String? runId}) =>
      _post('/workspaces/$wsId/run/stop', query: {'run_id': runId});

  Future<SetupState> getSetup(String wsId) async =>
      SetupState.fromJson(asJson(await _get('/workspaces/$wsId/setup')));

  Future<void> rerunSetup(String wsId) => _post('/workspaces/$wsId/setup');

  Future<ScriptsConfig> getScripts(String wsId) async =>
      ScriptsConfig.fromJson(asJson(await _get('/workspaces/$wsId/scripts')));

  Future<InstructionsConfig> getInstructions(String wsId) async =>
      InstructionsConfig.fromJson(
        asJson(await _get('/workspaces/$wsId/instructions')),
      );

  Future<InstructionsConfig> saveInstructions(
    String wsId,
    String text,
    String target,
  ) async => InstructionsConfig.fromJson(
    asJson(
      await _put(
        '/workspaces/$wsId/instructions',
        body: {'text': text, 'target': target},
      ),
    ),
  );

  // ---- git and ship ----

  Future<GitStatusResponse> gitStatus(String wsId) async =>
      GitStatusResponse.fromJson(
        asJson(await _get('/workspaces/$wsId/git/status')),
      );

  Future<List<GitCommit>> gitLog(String wsId, {int limit = 30}) async {
    final j = asJson(
      await _get('/workspaces/$wsId/git/log', query: {'limit': '$limit'}),
    );
    return jList(j, 'commits', GitCommit.fromJson);
  }

  /// [stagedOnly] commits just the index (the code step's Changes panel).
  Future<CommitResult> gitCommit(
    String wsId,
    String message, {
    bool stagedOnly = false,
  }) async => CommitResult.fromJson(
    asJson(
      await _post(
        '/workspaces/$wsId/git/commit',
        body: {'message': message, if (stagedOnly) 'staged_only': true},
      ),
    ),
  );

  Future<void> gitStage(String wsId, List<String> paths) =>
      _post('/workspaces/$wsId/git/stage', body: {'paths': paths});

  Future<void> gitUnstage(String wsId, List<String> paths) =>
      _post('/workspaces/$wsId/git/unstage', body: {'paths': paths});

  Future<PrStatusResponse> gitPr(String wsId) async =>
      PrStatusResponse.fromJson(asJson(await _get('/workspaces/$wsId/git/pr')));

  /// Opens a PR without merging. Idempotent: returns the existing PR when one is open.
  Future<CreatePrResult> createPr(String wsId) async =>
      CreatePrResult.fromJson(asJson(await _post('/workspaces/$wsId/git/pr')));

  Future<MergeResult> merge(String wsId, {String? message}) async =>
      MergeResult.fromJson(
        asJson(
          await _post('/workspaces/$wsId/merge', body: {'message': message}),
        ),
      );

  /// On-demand AI review of the worktree diff. Advisory: it never touches the gate. The
  /// backend answers 200 even when the reviewer could not run (`error` is set); no [model]
  /// means the project's review role, else its default model.
  Future<AiReview> runReview(String wsId, {String? model}) async =>
      AiReview.fromJson(
        asJson(
          await _post('/workspaces/$wsId/review', body: {'model': ?model}),
        ),
      );

  Future<MergeQueueResult> mergeQueue(
    String projectId, {
    bool dry = false,
  }) async => MergeQueueResult.fromJson(
    asJson(
      await _post(
        '/projects/$projectId/merge-queue',
        query: {'dry': dry ? 'true' : 'false'},
      ),
    ),
  );

  // ---- bulk archive ----

  /// [dry] previews (nothing torn down); [force] also takes workspaces the planner holds back.
  Future<ArchiveQueueRun> archiveQueue(
    String projectId,
    List<String> workspaceIds, {
    bool dry = false,
    bool force = false,
  }) async => ArchiveQueueRun.fromJson(
    asJson(
      await _post(
        '/projects/$projectId/archive-queue',
        query: {'dry': dry ? 'true' : 'false'},
        body: {'workspace_ids': workspaceIds, 'force': force},
      ),
    ),
  );

  Future<ArchiveQueueRun?> getArchiveQueue(String projectId) async {
    final v = await _get('/projects/$projectId/archive-queue');
    return v is Map ? ArchiveQueueRun.fromJson(asJson(v)) : null;
  }

  Future<ArchiveQueueRun> stopArchiveQueue(String runId) async =>
      ArchiveQueueRun.fromJson(
        asJson(await _post('/archive-queue/$runId/stop')),
      );
}
