import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_button.dart';
import '../widgets/haro_mark.dart';
import 'backend_config.dart';
import 'backend_launcher.dart';
import 'boot_splash.dart';
import 'quit_check.dart';

/// Sits above the app's `ProviderScope`. Builds the app straight away when there is nothing
/// to start (dev, `HARO_BACKEND`, no bundled backend); otherwise shows the splash until the
/// backend answers `/health`, or an error screen pointing at the log.
class BootGate extends StatefulWidget {
  const BootGate({
    super.key,
    required this.launcher,
    required this.appBuilder,
    this.hookWindowClose = true,
    this.busyCheck = busyWorkspaces,
    this.exitApp = exit,
  });

  final BackendLauncher launcher;
  final Widget Function(BackendConfig config) appBuilder;
  final bool hookWindowClose;

  /// What a quit would stop; asked when the window is closed, never on a signal.
  final Future<List<BusyWorkspace>> Function(Uri base) busyCheck;
  final void Function(int code) exitApp;

  @override
  State<BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<BootGate> with WindowListener {
  late LaunchOutcome? _outcome = widget.launcher.immediate;
  StreamSubscription<ProcessSignal>? _term;
  StreamSubscription<ProcessSignal>? _int;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    if (widget.hookWindowClose && widget.launcher.willSpawn) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
      _term = ProcessSignal.sigterm.watch().listen((_) => quitForSignal());
      _int = ProcessSignal.sigint.watch().listen((_) => quitForSignal());
      _lifecycle = AppLifecycleListener(onExitRequested: exitRequested);
    }
    if (_outcome == null) unawaited(_boot());
  }

  BootStage? _stage;
  bool _ready = false;

  /// The splash covers the screen until the backend has answered and it has had its moment; the
  /// app is built underneath once the sequence has played (building it earlier is the heaviest
  /// frame of the launch and stalls the glyph mid-assembly), so it has loaded by the time the
  /// splash fades.
  late bool _splashUp = _outcome == null;
  bool _fading = false;

  /// Completes when the splash has played its whole sequence, or was skipped. Measured on the
  /// splash's own clock, which starts at its first frame, not when the launch began: a timer from
  /// the launch ran out before the first frames of the animation on a fast machine.
  Completer<void> _played = Completer<void>();
  bool _skipped = false;

  void _sequenceDone() {
    if (!_played.isCompleted) _played.complete();
  }

  void _skip() {
    _skipped = true;
    _sequenceDone();
  }

  /// Only what has really happened: whether a haro was already running, then the backend we start.
  List<BootLine> get _lines => switch (_stage) {
    null => const [],
    BootStage.probing => const [BootLine('running haro')],
    BootStage.found => const [
      BootLine('running haro', 'found'),
      BootLine('backend', 'ready'),
    ],
    BootStage.spawning => const [
      BootLine('running haro', 'none'),
      BootLine('bundled backend'),
    ],
    BootStage.ready => const [
      BootLine('running haro', 'none'),
      BootLine('bundled backend', 'ready'),
    ],
  };

  Future<void> _boot() async {
    widget.launcher.onStage = (s) {
      if (mounted) setState(() => _stage = s);
    };
    // A backend that answers sooner waits for the splash to finish its sequence (a click or key
    // skips). Motion off (tests, reduce motion): no wait at all.
    final waits = bootMotionOn;
    LaunchOutcome outcome;
    try {
      outcome = await widget.launcher.start();
    } catch (e) {
      outcome = LaunchFailed('The backend could not be started ($e).');
    }
    if (!mounted) return;
    if (outcome is LaunchReady && waits) {
      setState(() => _ready = true);
      await _played.future;
      if (!mounted) return;
      setState(() => _outcome = outcome);
      await WidgetsBinding.instance.endOfFrame;
      // A beat on the finished sequence and READY before it fades, unless it was skipped.
      if (!_skipped) await Future<void>.delayed(bootReadyHold);
      if (mounted) setState(() => _fading = true);
      return;
    }
    setState(() {
      _outcome = outcome;
      _splashUp = false;
    });
  }

  bool _quitting = false;
  bool _closing = false;
  bool _stopped = false;
  List<String> _closingLines = const [];

  List<String> _stoppingLines() {
    final agents = (_busy ?? const []).where((b) => b.what == 'agent').length;
    final gates = (_busy ?? const []).where((b) => b.what == 'gate').length;
    final parts = [
      if (agents > 0) '$agents ${agents == 1 ? 'agent' : 'agents'}',
      if (gates > 0) '$gates ${gates == 1 ? 'gate' : 'gates'}',
    ];
    return [
      if (parts.isNotEmpty) 'stopping ${parts.join(' and ')}',
      'stopping backend',
    ];
  }

  final Completer<void> _tail = Completer<void>();
  Timer? _tailTimer;

  void _endTail() {
    _tailTimer?.cancel();
    if (!_tail.isCompleted) _tail.complete();
  }

  /// A shutdown does not wait for the glyph to come apart, not even when a quit is already
  /// playing it.
  @visibleForTesting
  Future<void> quitForSignal() {
    if (_quitting) {
      _endTail();
      return Future<void>.value();
    }
    _hurry = true;
    return _quit();
  }

  bool _hurry = false;

  // Stopping the backend takes seconds (graceful shutdown, then the kill fallback). Hiding the
  // window for that left a black screen, worst in full screen, so the window stays up and says
  // what is happening until the backend is gone.
  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    if (mounted) {
      setState(() {
        _closingLines = _stoppingLines();
        _closing = true;
      });
    }
    await widget.launcher.stop();
    if (mounted) setState(() => _stopped = true);
    // The glyph comes apart once the backend is gone.
    if (!_hurry && bootMotionOn) {
      _tailTimer = Timer(closingTail, _endTail);
      await _tail.future;
    }
    widget.exitApp(0);
  }

  void _retry() {
    setState(() {
      _outcome = null;
      _stage = null;
      _ready = false;
      _splashUp = true;
      _fading = false;
      _skipped = false;
      _played = Completer<void>();
    });
    unawaited(_boot());
  }

  List<BusyWorkspace>? _busy;
  bool _checking = false;

  @override
  void onWindowClose() => unawaited(closeRequested());

  @visibleForTesting
  Future<void> closeRequested() async {
    if (_quitting || _checking || _busy != null) return;
    final ready = _outcome;
    _checking = true;
    final busy = ready is LaunchReady
        ? await widget.busyCheck(Uri.parse(ready.config.baseUrl))
        : const <BusyWorkspace>[];
    _checking = false;
    if (!mounted) return;
    if (busy.isEmpty) return _quit();
    setState(() => _busy = busy);
  }

  /// Cmd+Q (`terminate:`) does not close the window, so without this it ended the app and
  /// left the backend running. Cancel the exit and take the window-close path, which asks
  /// about running work and stops the backend before exiting.
  @visibleForTesting
  Future<AppExitResponse> exitRequested() async {
    unawaited(closeRequested());
    return AppExitResponse.cancel;
  }

  @override
  void dispose() {
    _tailTimer?.cancel();
    _lifecycle?.dispose();
    windowManager.removeListener(this);
    _term?.cancel();
    _int?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    if (_closing) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'haro',
        theme: buildHaroTheme(),
        home: ClosingSplash(lines: _closingLines, stopped: _stopped),
      );
    }
    if (outcome == null || outcome is LaunchReady) {
      // One wrapper for the splash and the app, keyed, so neither restarts when the other
      // arrives or goes: the app mounts under the splash, which then fades out of the way.
      final busy = _busy;
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (outcome is LaunchReady)
              KeyedSubtree(
                key: const ValueKey('boot-app'),
                child: widget.appBuilder(outcome.config),
              ),
            if (busy != null)
              QuitConfirm(
                key: const ValueKey('boot-quit-confirm'),
                busy: busy,
                onKeep: () => setState(() => _busy = null),
                onQuit: _quit,
              ),
            if (_splashUp)
              Positioned.fill(
                key: const ValueKey('boot-splash'),
                child: IgnorePointer(
                  ignoring: _fading,
                  child: AnimatedOpacity(
                    opacity: _fading ? 0 : 1,
                    duration: bootFade,
                    curve: HaroTokens.curve,
                    onEnd: () {
                      if (_fading && mounted) setState(() => _splashUp = false);
                    },
                    child: MaterialApp(
                      debugShowCheckedModeBanner: false,
                      title: 'haro',
                      theme: buildHaroTheme(),
                      home: BootSplash(
                        lines: _lines,
                        ready: _ready,
                        onSkip: _skip,
                        onSequenceDone: _sequenceDone,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'haro',
      theme: buildHaroTheme(),
      home: BootScreen(
        failure: outcome is LaunchFailed ? outcome : null,
        alreadyRunning: outcome is LaunchAlreadyRunning,
        onQuit: () => exit(0),
        onRetry: _retry,
      ),
    );
  }
}

class BootScreen extends StatefulWidget {
  const BootScreen({
    super.key,
    this.failure,
    this.alreadyRunning = false,
    this.onQuit,
    this.onRetry,
  });

  /// The two screens with something to read or press: a failed start, or another haro running.
  /// The start and the quit are [BootSplash] and [ClosingSplash].
  final LaunchFailed? failure;
  final bool alreadyRunning;
  final VoidCallback? onQuit;
  final VoidCallback? onRetry;

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> {
  @override
  Widget build(BuildContext context) {
    final failure = widget.failure;
    return Scaffold(
      backgroundColor: HaroTokens.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const HaroWordmark(fontSize: 44, textKey: Key('boot-wordmark')),
              const SizedBox(height: 20),
              const _BootRule(),
              const SizedBox(height: 16),
              if (widget.alreadyRunning) ...[
                Text(
                  'HARO IS ALREADY RUNNING',
                  key: const Key('boot-status'),
                  style: HaroText.mono(color: HaroTokens.ink),
                ),
                const SizedBox(height: 12),
                Text(
                  'Switch to the open window. If you just closed haro, it is still '
                  'shutting down: try again in a moment.',
                  style: HaroText.mono(color: HaroTokens.ink42, tracking: .04),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HaroButton(
                      key: const Key('boot-retry'),
                      label: 'Try again',
                      variant: HaroButtonVariant.primary,
                      onPressed: widget.onRetry,
                    ),
                    const SizedBox(width: 10),
                    HaroButton(
                      key: const Key('boot-quit'),
                      label: 'Quit',
                      onPressed: widget.onQuit,
                    ),
                  ],
                ),
              ] else ...[
                Text(
                  'BACKEND FAILED',
                  key: const Key('boot-status'),
                  style: HaroText.mono(color: HaroTokens.ink),
                ),
                const SizedBox(height: 12),
                Text(
                  failure!.message,
                  key: const Key('boot-message'),
                  style: HaroText.mono(
                    color: HaroTokens.ink66,
                    tracking: .04,
                    height: 1.5,
                  ),
                ),
                if (failure.logPath != null) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    'LOG  ${failure.logPath}',
                    key: const Key('boot-log-path'),
                    style: HaroText.mono(
                      color: HaroTokens.ink42,
                      tracking: .04,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'Check the log, then reopen haro.',
                  style: HaroText.mono(color: HaroTokens.ink42, tracking: .04),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The hairline under the wordmark, drawn from the left once when the screen appears. Whole at
/// once under the OS reduce-motion setting.
class _BootRule extends StatelessWidget {
  const _BootRule();

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    key: const Key('boot-rule'),
    tween: Tween(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : HaroTokens.draw,
    curve: Curves.easeOut,
    builder: (context, v, _) => Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: v,
        child: Container(height: 1, color: HaroTokens.line20),
      ),
    ),
  );
}

/// Asked on window close when a quit would stop an agent or a gate mid-run.
class QuitConfirm extends StatelessWidget {
  const QuitConfirm({
    super.key,
    required this.busy,
    required this.onKeep,
    required this.onQuit,
  });

  final List<BusyWorkspace> busy;
  final VoidCallback onKeep;
  final VoidCallback onQuit;

  @override
  Widget build(BuildContext context) {
    final agents = busy.where((b) => b.what == 'agent').length;
    final title = agents > 0
        ? (busy.length == 1
              ? 'An agent is still working'
              : 'Work is still running')
        : (busy.length == 1
              ? 'A gate is still running'
              : 'Gates are still running');
    return ColoredBox(
      key: const Key('quit-confirm'),
      color: HaroTokens.backdrop,
      child: Center(
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: HaroTokens.panel,
            border: Border.all(color: HaroTokens.line20),
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: HaroText.ui(size: 18, weight: FontWeight.w500),
              ),
              const SizedBox(height: 10),
              Text(
                'Quitting stops it now. The worktree and everything saved so far stay.',
                style: HaroText.ui(
                  size: 13.5,
                  color: HaroTokens.ink66,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              for (final b in busy)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${b.name} · ${b.what == 'agent' ? 'agent running' : 'gate running'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.mono(
                      size: 12,
                      tracking: 0,
                      color: HaroTokens.ink,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HaroButton(
                    key: const Key('quit-anyway'),
                    label: 'Quit anyway',
                    foreground: HaroTokens.fail,
                    onPressed: onQuit,
                  ),
                  const SizedBox(width: 10),
                  HaroButton(
                    key: const Key('quit-keep'),
                    label: 'Keep haro open',
                    variant: HaroButtonVariant.primary,
                    onPressed: onKeep,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
