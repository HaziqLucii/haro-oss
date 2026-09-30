import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_button.dart';
import '../widgets/haro_mark.dart';
import 'backend_config.dart';
import 'backend_launcher.dart';
import 'quit_check.dart';

Future<void> _hideWindow() => windowManager.hide();

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
    this.hideWindow = _hideWindow,
  });

  final BackendLauncher launcher;
  final Widget Function(BackendConfig config) appBuilder;
  final bool hookWindowClose;

  /// What a quit would stop; asked when the window is closed, never on a signal.
  final Future<List<BusyWorkspace>> Function(Uri base) busyCheck;
  final void Function(int code) exitApp;
  final Future<void> Function() hideWindow;

  @override
  State<BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<BootGate> with WindowListener {
  late LaunchOutcome? _outcome = widget.launcher.immediate;
  StreamSubscription<ProcessSignal>? _term;
  StreamSubscription<ProcessSignal>? _int;

  @override
  void initState() {
    super.initState();
    if (widget.hookWindowClose && widget.launcher.willSpawn) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
      _term = ProcessSignal.sigterm.watch().listen((_) => _quit());
      _int = ProcessSignal.sigint.watch().listen((_) => _quit());
    }
    if (_outcome == null) unawaited(_boot());
  }

  Future<void> _boot() async {
    LaunchOutcome outcome;
    try {
      outcome = await widget.launcher.start();
    } catch (e) {
      outcome = LaunchFailed('The backend could not be started ($e).');
    }
    if (mounted) setState(() => _outcome = outcome);
  }

  bool _quitting = false;

  // The window goes first: stopping the backend can take seconds (graceful shutdown, then
  // the kill fallback), and nobody should watch a frozen window for that.
  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await widget.hideWindow();
    } catch (_) {
      // No window to hide (headless): stopping the backend still matters.
    }
    await widget.launcher.stop();
    widget.exitApp(0);
  }

  void _retry() {
    setState(() => _outcome = null);
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

  @override
  void dispose() {
    windowManager.removeListener(this);
    _term?.cancel();
    _int?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    if (outcome is LaunchReady) {
      // Always the same wrapper, so the app keeps its state when the confirm comes and goes.
      final busy = _busy;
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.appBuilder(outcome.config),
            if (busy != null)
              QuitConfirm(
                busy: busy,
                onKeep: () => setState(() => _busy = null),
                onQuit: _quit,
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
              Container(height: 1, color: HaroTokens.line20),
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
              ] else if (failure == null)
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: HaroTokens.fade,
                  curve: HaroTokens.curve,
                  builder: (context, v, child) =>
                      Opacity(opacity: v, child: child),
                  child: Text(
                    'STARTING BACKEND',
                    key: const Key('boot-status'),
                    style: HaroText.mono(color: HaroTokens.ink66),
                  ),
                )
              else ...[
                Text(
                  'BACKEND FAILED',
                  key: const Key('boot-status'),
                  style: HaroText.mono(color: HaroTokens.ink),
                ),
                const SizedBox(height: 12),
                Text(
                  failure.message,
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
