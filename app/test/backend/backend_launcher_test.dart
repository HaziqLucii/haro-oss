import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/backend/app_lock.dart';
import 'package:haro_app/backend/backend_config.dart';
import 'package:haro_app/backend/backend_launcher.dart';
import 'package:haro_app/backend/backend_plan.dart';
import 'package:haro_app/backend/boot_gate.dart';
import 'package:haro_app/backend/quit_check.dart';
import 'package:haro_app/backend/login_path.dart';

class _FakeProcess implements Process {
  _FakeProcess(this.pid);
  @override
  final int pid;
  final exit = Completer<int>();
  @override
  Future<int> get exitCode => exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
}

class _SequenceLauncher extends BackendLauncher {
  _SequenceLauncher(this.outcomes)
    : super(
        env: const {},
        appExecutable: '/x/haro_app',
        define: '',
        acquireLock: () => null,
      );

  final List<LaunchOutcome> outcomes;
  int calls = 0;

  @override
  LaunchReady? get immediate => null;

  @override
  Future<LaunchOutcome> start() async => outcomes[calls++];
}

class _SlowStopLauncher extends _SequenceLauncher {
  _SlowStopLauncher()
    : super([
        LaunchReady(
          const BackendConfig(baseUrl: 'http://127.0.0.1:41417'),
          spawned: true,
        ),
      ]);

  final stopped = Completer<void>();

  @override
  Future<void> stop() => stopped.future;
}

class _ThrowingLauncher extends BackendLauncher {
  _ThrowingLauncher()
    : super(
        env: const {},
        appExecutable: '/x/haro_app',
        define: '',
        acquireLock: () => null,
      );

  @override
  LaunchReady? get immediate => null;

  @override
  Future<LaunchOutcome> start() async => throw StateError('boom');
}

void main() {
  group('selectBackendPlan', () {
    const exe = '/opt/haro/haro_app';
    test('HARO_BACKEND env connects and spawns nothing', () {
      final p = selectBackendPlan(
        env: {'HARO_BACKEND': 'http://127.0.0.1:9000'},
        appExecutable: exe,
        fileExists: (_) => true,
      );
      expect((p as ConnectPlan).baseUrl, 'http://127.0.0.1:9000');
    });

    test('the dart-define keeps dev mode working', () {
      final p = selectBackendPlan(
        env: {},
        appExecutable: exe,
        define: 'http://127.0.0.1:9100',
        fileExists: (_) => true,
      );
      expect((p as ConnectPlan).baseUrl, 'http://127.0.0.1:9100');
    });

    test('a frozen backend next to the app is spawned', () {
      final p = selectBackendPlan(
        env: {},
        appExecutable: exe,
        fileExists: (path) =>
            path == '/opt/haro/backend/haro-backend/haro-backend',
      );
      expect(
        (p as SpawnPlan).executable,
        '/opt/haro/backend/haro-backend/haro-backend',
      );
    });

    test('a macOS bundle keeps the frozen backend in Contents/Resources', () {
      final p = selectBackendPlan(
        env: {},
        appExecutable: '/Apps/haro.app/Contents/MacOS/haro',
        fileExists: (path) => path == '/Apps/haro.app/Contents/MacOS/../Resources/backend/haro-backend/haro-backend',
      );
      expect(p, isA<SpawnPlan>());
    });

    test('falls back to :8000 with no frozen backend', () {
      final p = selectBackendPlan(
        env: {},
        appExecutable: exe,
        fileExists: (_) => false,
      );
      expect((p as ConnectPlan).baseUrl, 'http://127.0.0.1:8000');
    });
  });

  group('pickBackendPort', () {
    test('uses the preferred port when it binds', () async {
      expect(await pickBackendPort(preferred: 5, tryBind: (p) async => p), 5);
    });

    test('falls back to an OS-assigned port when preferred is taken', () async {
      final asked = <int>[];
      final port = await pickBackendPort(
        preferred: 5,
        tryBind: (p) async {
          asked.add(p);
          return p == 5 ? null : 43210;
        },
      );
      expect(asked, [5, 0]);
      expect(port, 43210);
    });

    test('real bind returns a usable loopback port', () async {
      final port = await pickBackendPort(preferred: 0);
      expect(port, greaterThan(0));
    });
  });

  group('login path', () {
    test('parses the value out of banner noise', () {
      expect(
        parseShellPath('welcome\n__HARO_PATH__/a:/b__HARO_END__\n'),
        '/a:/b',
      );
      expect(parseShellPath('no sentinels'), isNull);
      expect(parseShellPath('__HARO_PATH____HARO_END__'), isNull);
    });

    test('withToolDirs prepends missing dirs and is idempotent', () {
      final once = withToolDirs('/usr/bin:/bin', home: '/home/u');
      expect(once.startsWith('/home/u/.local/bin:/usr/local/bin:'), isTrue);
      expect(once.endsWith(':/usr/bin:/bin'), isTrue);
      expect(withToolDirs(once, home: '/home/u'), once);
    });

    test('withToolDirs falls back to the given PATH', () {
      expect(
        withToolDirs(null, home: '/h', fallback: '/x').endsWith(':/x'),
        isTrue,
      );
    });

    test('resolveLoginPath uses the scraped value', () async {
      final path = await resolveLoginPath(
        env: {'SHELL': '/bin/zsh', 'HOME': '/h', 'PATH': '/min'},
        run: (shell, args, _) async {
          expect(shell, '/bin/zsh');
          expect(args.first, '-ilc');
          return 'banner __HARO_PATH__/nvm/bin:/usr/bin__HARO_END__';
        },
      );
      expect(path, contains('/nvm/bin:/usr/bin'));
      expect(path, isNot(contains('/min')));
      expect(path, contains('/h/.local/bin'));
    });

    test('resolveLoginPath falls back on failure or timeout', () async {
      for (final run in <ShellRunner>[
        (_, _, _) async => null,
        (_, _, _) async => throw TimeoutException('slow'),
      ]) {
        final path = await resolveLoginPath(
          env: {'SHELL': '/bin/zsh', 'HOME': '/h', 'PATH': '/min'},
          run: run,
        );
        expect(path.endsWith(':/min'), isTrue);
        expect(path, contains('/h/.local/bin'));
      }
    });
  });

  group('BackendLauncher', () {
    const home = '/h';
    const env = <String, String>{'HOME': home};
    const expectedDb = '$home/.haro/haro.db';
    HealthInfo good([String db = expectedDb]) =>
        HealthInfo(worktreeRoot: '/w', db: db);

    Directory bundle() {
      final dir = Directory.systemTemp.createTempSync('haro-launch');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/$frozenBackendRelPath')
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      return dir;
    }

    BackendLauncher make(
      Directory dir, {
      required HealthProbe probe,
      BackendSpawner? spawner,
      AppLock? Function()? lock,
      Future<void> Function(String)? reap,
      Map<String, String> e = env,
    }) => BackendLauncher(
      env: e,
      appExecutable: '${dir.path}/haro_app',
      define: '',
      probe: probe,
      spawner: spawner ?? (_, _, _, _) async => fail('must not spawn'),
      resolvePath: () async => '/resolved',
      pickPort: () async => 41999,
      reapOrphans: reap ?? (_) async {},
      logPath: '/tmp/none/backend.log',
      appPid: 777,
      acquireLock: lock ?? () => null,
      pollEvery: const Duration(milliseconds: 5),
    );

    AppLock? Function() freeLock() {
      final d = Directory.systemTemp.createTempSync('haro-lock');
      addTearDown(() => d.deleteSync(recursive: true));
      return () => AppLock.tryAcquire('${d.path}/app.lock');
    }

    group('orphaned backends', () {
      const exe =
          '/A/haro.app/Contents/MacOS/../Resources/backend/haro-backend/haro-backend';
      test('picks only parentless backends of this install', () {
        final ps = [
          '  101     1 $exe --port 41417',
          '  102   555 $exe --port 51808',
          '  103     1 /B/haro.app/Contents/Resources/backend/haro-backend/haro-backend --port 1',
          '  104     1 /usr/bin/python3 server.py',
          '  105     1 $exe',
        ].join('\n');
        expect(orphanBackendPids(ps, exe), [101, 105]);
      });

      test('sweeps only after nothing answers, and before spawning', () async {
        final dir = bundle();
        final order = <String>[];
        final l = make(
          dir,
          probe: (_) async => null,
          lock: freeLock(),
          reap: (e) async => order.add('reap ${e.endsWith('haro-backend')}'),
          spawner: (_, _, _, _) async {
            order.add('spawn');
            throw StateError('stop here');
          },
        );
        await l.start();
        expect(order, ['reap true', 'spawn']);
      });

      test('a healthy backend is reused without a sweep', () async {
        final l = make(
          bundle(),
          probe: (_) async => good(),
          lock: freeLock(),
          reap: (_) async => fail('must not sweep'),
        );
        final out = await l.start() as LaunchReady;
        expect(out.spawned, isFalse);
      });
    });

    test('connect plan never locks, probes or spawns', () async {
      final l = BackendLauncher(
        env: {'HARO_BACKEND': 'http://127.0.0.1:1234'},
        appExecutable: '/x/haro_app',
        define: '',
        probe: (_) async => fail('no probe'),
        acquireLock: () => fail('no lock'),
        spawner: (_, _, _, _) async => fail('no spawn'),
      );
      expect(l.immediate?.config.baseUrl, 'http://127.0.0.1:1234');
      final out = await l.start() as LaunchReady;
      expect(out.spawned, isFalse);
    });

    test('a held lock means already running, with no probe or spawn', () async {
      final l = make(
        bundle(),
        probe: (_) async => fail('no probe'),
        lock: () => null,
      );
      expect(l.immediate, isNull);
      expect(await l.start(), isA<LaunchAlreadyRunning>());
    });

    test('reuses a haro backend on the preferred port', () async {
      final l = make(bundle(), probe: (_) async => good(), lock: freeLock());
      final out = await l.start() as LaunchReady;
      expect(out.spawned, isFalse);
      expect(out.config.baseUrl, 'http://127.0.0.1:$preferredBackendPort');
    });

    test('a backend on another database is not reused', () async {
      var spawns = 0;
      final l = make(
        bundle(),
        probe: (uri) async =>
            uri.port == 41999 ? good() : good('/elsewhere/haro.db'),
        lock: freeLock(),
        spawner: (_, _, _, _) async {
          spawns++;
          return _FakeProcess(1);
        },
      );
      final out = await l.start() as LaunchReady;
      expect(spawns, 1);
      expect(out.spawned, isTrue);
    });

    test('HARO_DB sets the expected database', () async {
      final l = make(
        bundle(),
        probe: (_) async => good('/custom/haro.db'),
        lock: freeLock(),
        e: {...env, 'HARO_DB': '/custom/x/../haro.db'},
      );
      final out = await l.start() as LaunchReady;
      expect(out.spawned, isFalse);
    });

    test('an older backend with no db field blocks the launch', () async {
      final l = make(
        bundle(),
        probe: (uri) async =>
            uri.port == 8000 ? const HealthInfo(worktreeRoot: '/w') : null,
        lock: freeLock(),
      );
      final out = await l.start() as LaunchFailed;
      expect(out.message, contains('older haro backend'));
      expect(out.message, contains('8000'));
    });

    test('a lock setup error becomes a LaunchFailed', () async {
      final l = make(
        bundle(),
        probe: (_) async => fail('no probe'),
        lock: () => throw const FileSystemException('read-only', '/.haro'),
      );
      final out = await l.start() as LaunchFailed;
      expect(out.message, contains('Cannot create ~/.haro/app.lock'));
    });

    test('a non-haro listener is ignored and a backend is spawned', () async {
      List<String>? args;
      final l = make(
        bundle(),
        probe: (uri) async => uri.port == 41999 ? good() : null,
        lock: freeLock(),
        spawner: (_, a, _, _) async {
          args = a;
          return _FakeProcess(4242);
        },
      );
      final out = await l.start() as LaunchReady;
      expect(out.spawned, isTrue);
      expect(args, ['--port', '41999']);
    });

    test('spawn env carries PATH and parent pid', () async {
      Map<String, String>? seen;
      var probes = 0;
      final l = make(
        bundle(),
        probe: (uri) async {
          if (uri.port == 41999) return ++probes >= 3 ? good() : null;
          return null;
        },
        lock: freeLock(),
        spawner: (_, _, e, _) async {
          seen = e;
          return _FakeProcess(4242);
        },
      );
      final out = await l.start() as LaunchReady;
      expect(out.config.baseUrl, 'http://127.0.0.1:41999');
      expect(seen!['PATH'], '/resolved');
      expect(seen!['HARO_PARENT_PID'], '777');
    });

    test('login PATH resolves concurrently with the probes', () async {
      final order = <String>[];
      final l = BackendLauncher(
        env: env,
        appExecutable: '${bundle().path}/haro_app',
        define: '',
        probe: (_) async {
          order.add('probe');
          return null;
        },
        spawner: (_, _, _, _) async => _FakeProcess(1)..exit.complete(0),
        resolvePath: () async {
          order.add('path');
          return '/r';
        },
        pickPort: () async => 41999,
        logPath: '/tmp/none/backend.log',
        acquireLock: freeLock(),
        pollEvery: const Duration(milliseconds: 5),
      );
      await l.start();
      expect(order.first, 'path');
    });

    test('fails fast with the log path when the backend exits', () async {
      final proc = _FakeProcess(1)..exit.complete(3);
      final l = make(
        bundle(),
        probe: (_) async => null,
        lock: freeLock(),
        spawner: (_, _, _, _) async => proc,
      );
      final out = await l.start() as LaunchFailed;
      expect(out.message, contains('code 3'));
      expect(out.logPath, '/tmp/none/backend.log');
    });
  });

  group('httpHealthProbe', () {
    late HttpServer server;
    late String body;
    late int status;

    setUpAll(() => HttpOverrides.global = null);

    setUp(() async {
      body = '';
      status = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response
          ..statusCode = status
          ..write(body)
          ..close();
      });
    });
    tearDown(() => server.close(force: true));

    Uri uri() => Uri.parse('http://127.0.0.1:${server.port}/health');

    test('accepts a haro health body and returns the worktree root', () async {
      body = '{"ok":true,"worktree_root":"/w","db":"/d/haro.db"}';
      final info = await httpHealthProbe(uri());
      expect(info?.worktreeRoot, '/w');
      expect(info?.db, '/d/haro.db');
      body = '{"ok":true,"worktree_root":"/w"}';
      expect((await httpHealthProbe(uri()))?.db, isNull);
    });

    test('rejects a 200 that is not haro', () async {
      for (final b in [
        '<html>hi</html>',
        '{"ok":true}',
        '{"ok":false,"worktree_root":"/w"}',
        '{"ok":true,"worktree_root":5}',
        '[]',
      ]) {
        body = b;
        expect(await httpHealthProbe(uri()), isNull, reason: b);
      }
    });

    test('rejects non-200 and a closed port', () async {
      body = '{"ok":true,"worktree_root":"/w"}';
      status = 503;
      expect(await httpHealthProbe(uri()), isNull);
      final dead = uri();
      await server.close(force: true);
      expect(await httpHealthProbe(dead), isNull);
    });
  });

  test('normalizeDbPath collapses dots and resolves symlinked parents', () {
    final d = Directory.systemTemp.createTempSync('haro-norm');
    addTearDown(() => d.deleteSync(recursive: true));
    Directory('${d.path}/real').createSync();
    Link('${d.path}/link').createSync('${d.path}/real');
    final real = Directory('${d.path}/real').resolveSymbolicLinksSync();
    expect(normalizeDbPath('${d.path}/link/../link/haro.db'), '$real/haro.db');
    File('$real/target.db').writeAsStringSync('');
    Link('$real/haro.db').createSync('$real/target.db');
    expect(normalizeDbPath('${d.path}/link/haro.db'), '$real/target.db');
    expect(
      normalizeDbPath('/nonexistent-dir/a/../haro.db'),
      '/nonexistent-dir/haro.db',
    );
  });

  group('AppLock', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('haro-applock'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('acquire, release, acquire again', () {
      final path = '${dir.path}/sub/app.lock';
      final a = AppLock.tryAcquire(path);
      expect(a, isNotNull);
      a!.release();
      final b = AppLock.tryAcquire(path);
      expect(b, isNotNull);
      b!.release();
    });

    // POSIX record locks are per process, so a second lock in this process would
    // succeed; a separate process is the only honest "second instance".
    test('a lock held by another process is refused', () async {
      final path = '${dir.path}/app.lock';
      final holder = await Process.start('python3', [
        '-c',
        'import fcntl,sys,time\n'
            'f=open(sys.argv[1],"a")\n'
            'fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n'
            'print("held",flush=True)\n'
            'time.sleep(60)',
        path,
      ]);
      addTearDown(holder.kill);
      await holder.stdout.transform(const SystemEncoding().decoder).first;
      expect(AppLock.tryAcquire(path), isNull);
      holder.kill();
      await holder.exitCode;
      final after = AppLock.tryAcquire(path);
      expect(after, isNotNull);
      after!.release();
    }, skip: Platform.isLinux ? false : 'needs python3 + posix locks');
  });

  test(
    'spawnInOwnGroup starts a process group the launcher can signal',
    () async {
      final dir = Directory.systemTemp.createTempSync('haro-spawn');
      addTearDown(() => dir.deleteSync(recursive: true));
      final proc = await spawnInOwnGroup(
        '/bin/sleep',
        ['60'],
        Platform.environment,
        '${dir.path}/logs/backend.log',
      );
      // `setsid` makes the group a moment after Process.start returns (the shell has to exec it
      // first), so wait for the group to exist instead of racing it: signalling at once lost
      // that race on a loaded CI runner.
      var groupExists = false;
      for (var i = 0; i < 100 && !groupExists; i++) {
        final probe = await Process.run('kill', ['-0', '--', '-${proc.pid}']);
        groupExists = probe.exitCode == 0;
        if (!groupExists) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(groupExists, isTrue, reason: 'the process group never appeared');
      final r = await Process.run('kill', ['-TERM', '--', '-${proc.pid}']);
      expect(r.exitCode, 0);
      await proc.exitCode.timeout(const Duration(seconds: 5));
    },
    skip: Platform.isLinux ? false : 'needs setsid',
  );

  group('BootScreen', () {
    Future<void> pump(WidgetTester t, LaunchFailed? failure) =>
        t.pumpWidget(MaterialApp(home: BootScreen(failure: failure)));

    testWidgets('already running offers Try again and Quit', (t) async {
      var quit = 0;
      var retry = 0;
      await t.pumpWidget(
        MaterialApp(
          home: BootScreen(
            alreadyRunning: true,
            onQuit: () => quit++,
            onRetry: () => retry++,
          ),
        ),
      );
      expect(find.text('HARO IS ALREADY RUNNING'), findsOneWidget);
      expect(find.textContaining('still shutting down'), findsOneWidget);
      await t.tap(find.byKey(const Key('boot-retry')));
      await t.tap(find.byKey(const Key('boot-quit')));
      expect((retry, quit), (1, 1));
    });

    testWidgets('error screen names the failure and the log path', (t) async {
      await pump(
        t,
        const LaunchFailed('It broke.', logPath: '/home/u/.haro/backend.log'),
      );
      expect(find.text('BACKEND FAILED'), findsOneWidget);
      expect(find.text('It broke.'), findsOneWidget);
      expect(find.textContaining('/home/u/.haro/backend.log'), findsOneWidget);
    });
  });

  group('BootGate', () {
    group('quit confirm', () {
      Future<(_SequenceLauncher, List<int>)> ready(
        WidgetTester t,
        List<BusyWorkspace> busy,
      ) async {
        final exits = <int>[];
        final launcher = _SequenceLauncher([
          LaunchReady(
            const BackendConfig(baseUrl: 'http://127.0.0.1:41417'),
            spawned: false,
          ),
        ]);
        await t.pumpWidget(
          BootGate(
            launcher: launcher,
            hookWindowClose: false,
            busyCheck: (_) async => busy,
            exitApp: exits.add,
            appBuilder: (_) => const Text('app'),
          ),
        );
        await t.pump();
        await t.pump();
        return (launcher, exits);
      }

      testWidgets('nothing running: closes without asking', (t) async {
        final (_, exits) = await ready(t, const []);
        final state =
            t.state<State<BootGate>>(find.byType(BootGate)) as dynamic;
        await state.closeRequested();
        await t.pump();
        expect(find.byKey(const Key('quit-confirm')), findsNothing);
        expect(exits, [0]);
      });

      testWidgets('while the backend stops the window says Closing', (t) async {
        final launcher = _SlowStopLauncher();
        final exits = <int>[];
        await t.pumpWidget(
          BootGate(
            launcher: launcher,
            hookWindowClose: false,
            busyCheck: (_) async => const [],
            exitApp: exits.add,
            appBuilder: (_) => const Text('app'),
          ),
        );
        await t.pump();
        await t.pump();
        final state =
            t.state<State<BootGate>>(find.byType(BootGate)) as dynamic;
        unawaited(state.closeRequested());
        await t.pump();
        await t.pump();
        expect(find.text('CLOSING'), findsOneWidget);
        expect(find.text('app'), findsNothing);
        expect(exits, isEmpty);
        launcher.stopped.complete();
        await t.pump();
        await t.pump();
        expect(exits, [0]);
      });

      testWidgets('Cmd+Q takes the same path as closing the window', (t) async {
        final (_, exits) = await ready(t, const []);
        final state =
            t.state<State<BootGate>>(find.byType(BootGate)) as dynamic;
        final response = await state.exitRequested();
        await t.pump();
        await t.pump();
        expect(response, AppExitResponse.cancel);
        expect(exits, [0]);
      });

      testWidgets('Cmd+Q with an agent running asks first', (t) async {
        final (_, exits) = await ready(t, const [
          BusyWorkspace('streak', 'agent'),
        ]);
        final state =
            t.state<State<BootGate>>(find.byType(BootGate)) as dynamic;
        await state.exitRequested();
        await t.pump();
        await t.pump();
        expect(find.text('An agent is still working'), findsOneWidget);
        expect(exits, isEmpty);
      });

      testWidgets('a running agent asks; Keep leaves the app as it was', (
        t,
      ) async {
        final (_, exits) = await ready(t, const [
          BusyWorkspace('streak', 'agent'),
        ]);
        final state =
            t.state<State<BootGate>>(find.byType(BootGate)) as dynamic;
        await state.closeRequested();
        await t.pump();
        expect(find.text('An agent is still working'), findsOneWidget);
        expect(find.text('streak · agent running'), findsOneWidget);
        await t.tap(find.byKey(const Key('quit-keep')));
        await t.pump();
        expect(find.byKey(const Key('quit-confirm')), findsNothing);
        expect(find.text('app'), findsOneWidget);
        expect(exits, isEmpty);
      });

      testWidgets('Quit anyway quits', (t) async {
        final (_, exits) = await ready(t, const [
          BusyWorkspace('streak', 'gate'),
        ]);
        final state =
            t.state<State<BootGate>>(find.byType(BootGate)) as dynamic;
        await state.closeRequested();
        await t.pump();
        expect(find.text('A gate is still running'), findsOneWidget);
        await t.tap(find.byKey(const Key('quit-anyway')));
        await t.pump();
        expect(exits, [0]);
      });
    });

    testWidgets('Try again launches again once the old instance is gone', (
      t,
    ) async {
      final launcher = _SequenceLauncher([
        const LaunchAlreadyRunning(),
        LaunchReady(
          const BackendConfig(baseUrl: 'http://127.0.0.1:41417'),
          spawned: false,
        ),
      ]);
      await t.pumpWidget(
        BootGate(
          launcher: launcher,
          hookWindowClose: false,
          appBuilder: (_) =>
              const Text('app', textDirection: TextDirection.ltr),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.text('HARO IS ALREADY RUNNING'), findsOneWidget);
      await t.tap(find.byKey(const Key('boot-retry')));
      await t.pump();
      await t.pump();
      expect(find.text('app'), findsOneWidget);
      expect(launcher.calls, 2);
    });

    testWidgets('a start() that throws becomes the error screen', (t) async {
      final launcher = _ThrowingLauncher();
      await t.pumpWidget(
        BootGate(
          launcher: launcher,
          hookWindowClose: false,
          appBuilder: (_) => const SizedBox(),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.text('BACKEND FAILED'), findsOneWidget);
    });

    testWidgets('builds the app right away for a connect plan', (t) async {
      final launcher = BackendLauncher(
        env: {'HARO_BACKEND': 'http://127.0.0.1:1234'},
        appExecutable: '/x/haro_app',
        define: '',
      );
      BackendConfig? seen;
      await t.pumpWidget(
        BootGate(
          launcher: launcher,
          hookWindowClose: false,
          appBuilder: (c) {
            seen = c;
            return const SizedBox();
          },
        ),
      );
      await t.pump();
      expect(seen?.baseUrl, 'http://127.0.0.1:1234');
    });
  });
}
