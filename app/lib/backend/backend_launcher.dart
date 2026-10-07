import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../util/home_dir.dart';
import 'app_lock.dart';
import 'backend_config.dart';
import 'backend_plan.dart';
import 'login_path.dart';

sealed class LaunchOutcome {
  const LaunchOutcome();
}

class LaunchReady extends LaunchOutcome {
  const LaunchReady(this.config, {required this.spawned});
  final BackendConfig config;

  /// True when this launcher started the process (and so owns stopping it).
  final bool spawned;
}

/// Another app instance holds the lock; this one must not start or reuse a backend.
class LaunchAlreadyRunning extends LaunchOutcome {
  const LaunchAlreadyRunning();
}

class LaunchFailed extends LaunchOutcome {
  const LaunchFailed(this.message, {this.logPath});
  final String message;
  final String? logPath;
}

class HealthInfo {
  const HealthInfo({required this.worktreeRoot, this.db});
  final String worktreeRoot;

  /// The database file the backend writes to; absent on backends older than this field.
  final String? db;
}

/// Returns the parsed body when [healthUri] answers like a haro backend, else null.
typedef HealthProbe = Future<HealthInfo?> Function(Uri healthUri);

/// Absolute, `..`-collapsed and, where the parent dir exists, symlink-resolved: the backend
/// reports its resolved path, so the expectation must be compared in the same form.
String normalizeDbPath(String path) {
  final abs = Uri.file(path).normalizePath().toFilePath();
  try {
    if (File(abs).existsSync()) return File(abs).resolveSymbolicLinksSync();
  } on FileSystemException {
    // Fall through to resolving the parent.
  }
  final slash = abs.lastIndexOf('/');
  if (slash <= 0) return abs;
  try {
    final parent = Directory(abs.substring(0, slash))
        .resolveSymbolicLinksSync();
    return '$parent${abs.substring(slash)}';
  } on FileSystemException {
    return abs;
  }
}

typedef BackendSpawner = Future<Process> Function(
  String executable,
  List<String> args,
  Map<String, String> env,
  String logPath,
);

/// Anything that is not `{"ok": true, "worktree_root": <string>}` (a random dev server on the
/// port, a proxy's 200) is not a haro backend.
Future<HealthInfo?> httpHealthProbe(Uri uri) async {
  final client = http.Client();
  try {
    final res = await client.get(uri).timeout(const Duration(seconds: 1));
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    if (body is Map && body['ok'] == true && body['worktree_root'] is String) {
      final db = body['db'];
      return HealthInfo(
        worktreeRoot: body['worktree_root'] as String,
        db: db is String ? db : null,
      );
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// `sh` does the redirect and the `setsid`: the backend gets its own process group (so quit
/// can take agents and dev servers down with it) and `exec` keeps the pid we signal.
const _wrapper =
    r'log=$1; shift; if command -v setsid >/dev/null 2>&1; then '
    r'exec setsid "$@" >"$log" 2>&1; else exec "$@" >"$log" 2>&1; fi';

Future<Process> spawnInOwnGroup(
  String executable,
  List<String> args,
  Map<String, String> env,
  String logPath,
) {
  final dir = File(logPath).parent;
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return Process.start('/bin/sh', [
    '-c',
    _wrapper,
    'sh',
    logPath,
    executable,
    ...args,
  ], environment: env);
}

/// Owns the backend process for a packaged build. A backend that already answers is reused,
/// never doubled up: two backends on one `~/.haro/haro.db` corrupt it.
class BackendLauncher {
  BackendLauncher({
    Map<String, String>? env,
    String? appExecutable,
    this._define = const String.fromEnvironment('HARO_BACKEND'),
    HealthProbe? probe,
    BackendSpawner? spawner,
    Future<String> Function()? resolvePath,
    Future<int> Function()? pickPort,
    String? logPath,
    int? appPid,
    AppLock? Function()? acquireLock,
    this.budget = const Duration(seconds: 45),
    this.pollEvery = const Duration(milliseconds: 300),
  }) : _env = env ?? Platform.environment,
       _appExecutable = appExecutable ?? Platform.resolvedExecutable,
       _probe = probe ?? httpHealthProbe,
       _spawner = spawner ?? spawnInOwnGroup,
       _resolvePath = resolvePath ?? resolveLoginPath,
       _pickPort = pickPort ?? pickBackendPort,
       _logPath =
           logPath ??
           '${userHomeDir(env ?? Platform.environment) ?? ''}/.haro/backend.log',
       _appPid = appPid ?? pid,
       _acquireLock =
           acquireLock ??
           (() => AppLock.tryAcquire(
             '${userHomeDir(env ?? Platform.environment) ?? ''}/.haro/app.lock',
           ));

  final Map<String, String> _env;
  final String _appExecutable;
  final String _define;
  final HealthProbe _probe;
  final BackendSpawner _spawner;
  final Future<String> Function() _resolvePath;
  final Future<int> Function() _pickPort;
  final String _logPath;
  final int _appPid;
  final AppLock? Function() _acquireLock;
  AppLock? _lock;
  final Duration budget;
  final Duration pollEvery;

  Process? _proc;

  late final BackendPlan plan = selectBackendPlan(
    env: _env,
    appExecutable: _appExecutable,
    define: _define,
  );

  /// True when this build will start its own backend (drives the splash and quit hook).
  bool get willSpawn => plan is SpawnPlan;

  /// Set when nothing needs starting or waiting for, so the app can render on the first frame.
  LaunchReady? get immediate {
    final p = plan;
    return p is ConnectPlan
        ? LaunchReady(BackendConfig(baseUrl: p.baseUrl), spawned: false)
        : null;
  }

  String get _expectedDb {
    final fromEnv = _env['HARO_DB'];
    final raw = fromEnv != null && fromEnv.isNotEmpty
        ? fromEnv
        : '${userHomeDir(_env) ?? ''}/.haro/haro.db';
    return normalizeDbPath(raw);
  }

  Future<LaunchOutcome> start() async {
    final p = plan;
    if (p is ConnectPlan) {
      return LaunchReady(BackendConfig(baseUrl: p.baseUrl), spawned: false);
    }
    p as SpawnPlan;

    try {
      _lock = _acquireLock();
    } catch (e) {
      return LaunchFailed('Cannot create ~/.haro/app.lock ($e).');
    }
    if (_lock == null) return const LaunchAlreadyRunning();

    // A slow shell rc must not serialize behind the probes.
    final pathFuture = _resolvePath();
    for (final url in [
      'http://127.0.0.1:$preferredBackendPort',
      legacyBackendUrl,
    ]) {
      final config = BackendConfig(baseUrl: url);
      final info = await _probe(config.healthUri);
      if (info == null) continue;
      if (info.db == null) {
        // Cannot tell whose database it owns; a second backend would sweep its dev servers.
        return LaunchFailed(
          'An older haro backend is running on port ${config.healthUri.port}. '
          'Stop it and reopen haro.',
        );
      }
      if (info.db == _expectedDb) return LaunchReady(config, spawned: false);
    }

    final int port;
    try {
      port = await _pickPort();
    } catch (e) {
      return LaunchFailed('Could not find a free local port ($e).');
    }
    final path = await pathFuture;
    final Process proc;
    try {
      proc = await _spawner(
        p.executable,
        ['--port', '$port'],
        {..._env, 'PATH': path, 'HARO_PARENT_PID': '$_appPid'},
        _logPath,
      );
    } catch (e) {
      return LaunchFailed(
        'Could not start the bundled backend ($e).',
        logPath: _logPath,
      );
    }
    _proc = proc;

    final config = BackendConfig(baseUrl: 'http://127.0.0.1:$port');
    int? exitCode;
    unawaited(proc.exitCode.then((c) => exitCode = c));
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      if (exitCode != null) {
        _proc = null;
        return LaunchFailed(
          'The backend exited during startup (code $exitCode).',
          logPath: _logPath,
        );
      }
      if (await _probe(config.healthUri) != null) {
        return LaunchReady(config, spawned: true);
      }
      await Future<void>.delayed(pollEvery);
    }
    await stop();
    return LaunchFailed(
      'The backend did not answer within ${budget.inSeconds} seconds.',
      logPath: _logPath,
    );
  }

  /// SIGTERM the whole process group (backend plus agents and dev servers it spawned), then
  /// SIGKILL it if it lingers.
  Future<void> stop() async {
    final proc = _proc;
    if (proc == null) return;
    _proc = null;
    await _signalGroup(proc.pid, 'TERM');
    try {
      await proc.exitCode.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      await _signalGroup(proc.pid, 'KILL');
    }
  }

  Future<void> _signalGroup(int groupPid, String signal) async {
    try {
      final r = await Process.run('kill', ['-$signal', '--', '-$groupPid']);
      if (r.exitCode == 0) return;
    } catch (_) {
      // Fall through to signalling the pid alone.
    }
    Process.killPid(
      groupPid,
      signal == 'KILL' ? ProcessSignal.sigkill : ProcessSignal.sigterm,
    );
  }
}
