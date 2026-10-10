import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/check_mark.dart';
import '../widgets/haro_mark_motion.dart';
import '../widgets/haro_skeleton.dart';

/// Motion is off in tests (the skeleton switch) and under the OS reduce-motion setting: the
/// screens then show their end state at once and nothing is held back.
bool get bootMotionOn =>
    HaroSkeleton.animate &&
    !PlatformDispatcher.instance.accessibilityFeatures.disableAnimations;

/// How long the splash's sequence runs, on its own clock: the glyph assembling, then the word and
/// the tagline (done by 2.55 s).
const Duration bootSequence = Duration(milliseconds: 2600);

/// How long the finished sequence and READY show before the splash starts to fade.
const Duration bootReadyHold = Duration(milliseconds: 500);

/// The splash fading off the app that has already loaded beneath it.
const Duration bootFade = Duration(milliseconds: 350);

/// After the backend is stopped: the glyph comes apart and the word fades (done by 1.7 s), then
/// the app exits.
const Duration closingTail = Duration(milliseconds: 1800);

const int _wordAt = 1950;
const int _taglineAt = 2150;
const int _stillMs = 100000;

class BootLine {
  const BootLine(this.label, [this.result]);

  final String label;

  /// Null while it is still going.
  final String? result;
}

/// Ticks [ms] milliseconds since it started, or stands at [_stillMs] when motion is off so every
/// fade reads as finished.
mixin _SplashClock<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T> {
  final ValueNotifier<int> ms = ValueNotifier(0);
  Ticker? _ticker;

  void startClock() {
    if (!bootMotionOn) {
      ms.value = _stillMs;
      return;
    }
    _ticker = createTicker((d) => ms.value = d.inMilliseconds)..start();
  }

  void disposeClock() {
    _ticker?.dispose();
    ms.dispose();
  }
}

class _Lines extends StatelessWidget {
  const _Lines({required this.lines, required this.opacity});

  final List<BootLine> lines;
  final double Function(int index) opacity;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 360,
    child: Column(
      children: [
        for (final (i, l) in lines.indexed)
          Opacity(
            opacity: opacity(i),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    l.label,
                    key: ValueKey('boot-line-$i'),
                    style: HaroText.mono(
                      size: 11.5,
                      color: HaroTokens.ink66,
                      tracking: 0,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l.result ?? '…',
                        key: ValueKey('boot-line-result-$i'),
                        style: HaroText.mono(
                          size: 11.5,
                          color: l.result == null
                              ? HaroTokens.ink42
                              : HaroTokens.ink,
                          tracking: 0,
                        ),
                      ),
                      if (l.result != null) ...[
                        const SizedBox(width: 6),
                        CheckMark(
                          key: ValueKey('boot-line-check-$i'),
                          color: HaroTokens.ink,
                          size: 11,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class _Frame extends StatelessWidget {
  const _Frame({required this.center, required this.status, this.bar});

  final Widget center;
  final String status;
  final double? bar;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: HaroTokens.bg,
    body: Stack(
      children: [
        Positioned(
          left: 16,
          top: 0,
          bottom: 0,
          child: Center(
            child: RotatedBox(
              quarterTurns: 3,
              child: Text(
                '// haro · local first',
                style: HaroText.mono(
                  size: 9.5,
                  color: HaroTokens.ink.withValues(alpha: .18),
                  tracking: .3,
                ),
              ),
            ),
          ),
        ),
        Center(child: center),
        if (bar != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 2,
            child: Container(
              key: const Key('boot-bar'),
              color: HaroTokens.ink.withValues(alpha: .08),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: bar!.clamp(0.0, 1.0),
                child: Container(height: 2, color: HaroTokens.ink),
              ),
            ),
          ),
        Positioned(
          right: 24,
          bottom: 18,
          child: Text(
            status,
            key: const Key('boot-status'),
            style: HaroText.mono(
              size: 10,
              color: HaroTokens.ink.withValues(alpha: .3),
              tracking: .14,
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _word(double opacity) => Opacity(
  opacity: opacity,
  child: Text(
    'haro.',
    key: const Key('boot-wordmark'),
    style: HaroText.wordmark.copyWith(fontSize: 54, letterSpacing: -.54),
  ),
);

/// Shown while the backend starts.
class BootSplash extends StatefulWidget {
  const BootSplash({
    super.key,
    required this.lines,
    required this.ready,
    this.onSkip,
    this.onSequenceDone,
  });

  final List<BootLine> lines;

  /// The backend answered: the bar completes and the status reads READY.
  final bool ready;

  /// A click or a key: do not wait out the rest of the sequence.
  final VoidCallback? onSkip;

  /// The sequence has played in full ([bootSequence] after the first frame).
  final VoidCallback? onSequenceDone;

  @override
  State<BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<BootSplash>
    with SingleTickerProviderStateMixin, _SplashClock<BootSplash> {
  final Map<int, int> _seen = {};
  int? _readyAt;
  double _fillAtReady = 0;

  bool _announced = false;

  @override
  void initState() {
    super.initState();
    startClock();
    if (bootMotionOn) ms.addListener(_watch);
    _note();
  }

  void _watch() {
    if (_announced || ms.value < bootSequence.inMilliseconds) return;
    _announced = true;
    widget.onSequenceDone?.call();
  }

  @override
  void didUpdateWidget(BootSplash old) {
    super.didUpdateWidget(old);
    _note();
  }

  /// When each line first appeared and when the backend answered, so their fades start then.
  void _note() {
    final t = ms.value;
    for (var i = 0; i < widget.lines.length; i++) {
      // Without motion a line is simply there.
      _seen.putIfAbsent(i, () => bootMotionOn ? t : -_stillMs);
    }
    if (widget.ready && _readyAt == null) {
      _readyAt = t;
      _fillAtReady = _creep(t);
    }
  }

  @override
  void dispose() {
    disposeClock();
    super.dispose();
  }

  // An estimate: toward 92% while the backend starts, never full until it answers.
  double _creep(int t) => .92 * (1 - math.exp(-t / 2500));

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, e) {
      if (e is KeyDownEvent) widget.onSkip?.call();
      return KeyEventResult.ignored;
    },
    child: Listener(
      onPointerDown: (_) => widget.onSkip?.call(),
      child: ValueListenableBuilder<int>(
        valueListenable: ms,
        builder: (context, t, _) {
          final readyAt = _readyAt;
          final bar = !bootMotionOn
              ? (widget.ready ? 1.0 : _creep(t))
              : readyAt == null
              ? _creep(t)
              : _fillAtReady + (1 - _fillAtReady) * rampFade(t, readyAt, 250);
          return _Frame(
            status: widget.ready ? 'READY' : 'STARTING BACKEND',
            bar: bar,
            center: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                HaroMarkMotion(motion: MarkMotion.assemble, ms: t),
                const SizedBox(height: 26),
                _word(rampFade(t, _wordAt, 400)),
                const SizedBox(height: 10),
                Opacity(
                  opacity: rampFade(t, _taglineAt, 400),
                  child: Text(
                    'YOU STAY THE AUTHOR',
                    key: const Key('boot-tagline'),
                    style: HaroText.mono(
                      size: 10.5,
                      color: HaroTokens.ink42,
                      tracking: .22,
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                _Lines(
                  lines: widget.lines,
                  opacity: (i) => rampFade(t, _seen[i] ?? t, 200),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

/// Shown while the backend stops, then the glyph comes apart before the app exits.
class ClosingSplash extends StatefulWidget {
  const ClosingSplash({super.key, required this.lines, required this.stopped});

  /// Each reads done once [stopped].
  final List<String> lines;
  final bool stopped;

  @override
  State<ClosingSplash> createState() => _ClosingSplashState();
}

class _ClosingSplashState extends State<ClosingSplash>
    with SingleTickerProviderStateMixin, _SplashClock<ClosingSplash> {
  int? _stoppedAt;

  @override
  void initState() {
    super.initState();
    startClock();
    _note();
  }

  @override
  void didUpdateWidget(ClosingSplash old) {
    super.didUpdateWidget(old);
    _note();
  }

  void _note() {
    if (widget.stopped && _stoppedAt == null) _stoppedAt = ms.value;
  }

  @override
  void dispose() {
    disposeClock();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: ms,
    builder: (context, t, _) {
      // The glyph holds whole until the backend is gone, then comes apart.
      final stoppedAt = _stoppedAt;
      final moving = bootMotionOn && stoppedAt != null;
      final d0 = (stoppedAt ?? 0) + 200;
      final apart = moving ? math.max(0, t - d0) : 0;
      final linesOut = moving ? rampFade(t, d0 + 200, 400) : 0.0;
      final wordOut = moving ? rampFade(t, d0 + 1100, 400) : 0.0;
      return _Frame(
        status: 'CLOSING',
        center: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HaroMarkMotion(motion: MarkMotion.disassemble, ms: apart),
            const SizedBox(height: 26),
            _word(1 - wordOut),
            const SizedBox(height: 50),
            _Lines(
              lines: [
                for (final l in widget.lines)
                  BootLine(l, widget.stopped ? 'done' : null),
              ],
              opacity: (i) => rampFade(t, 150 + i * 260, 180) * (1 - linesOut),
            ),
          ],
        ),
      );
    },
  );
}
