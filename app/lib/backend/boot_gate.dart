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

/// Sits above the app's `ProviderScope`. Builds the app straight away when there is nothing
/// to start (dev, `HARO_BACKEND`, no bundled backend); otherwise shows the splash until the
/// backend answers `/health`, or an error screen pointing at the log.
class BootGate extends StatefulWidget {
  const BootGate({
    super.key,
    required this.launcher,
    required this.appBuilder,
    this.hookWindowClose = true,
  });

  final BackendLauncher launcher;
  final Widget Function(BackendConfig config) appBuilder;
  final bool hookWindowClose;

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

  Future<void> _quit() async {
    await widget.launcher.stop();
    exit(0);
  }

  @override
  void onWindowClose() => _quit();

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
    if (outcome is LaunchReady) return widget.appBuilder(outcome.config);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'haro',
      theme: buildHaroTheme(),
      home: BootScreen(
        failure: outcome is LaunchFailed ? outcome : null,
        alreadyRunning: outcome is LaunchAlreadyRunning,
        onQuit: () => exit(0),
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
  });

  final LaunchFailed? failure;
  final bool alreadyRunning;
  final VoidCallback? onQuit;

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
                  'Switch to the open window, or quit this one.',
                  style: HaroText.mono(color: HaroTokens.ink42, tracking: .04),
                ),
                const SizedBox(height: 16),
                HaroButton(
                  key: const Key('boot-quit'),
                  label: 'Quit',
                  variant: HaroButtonVariant.primary,
                  onPressed: widget.onQuit,
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
