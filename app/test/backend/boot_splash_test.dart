import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/backend/backend_config.dart';
import 'package:haro_app/backend/backend_launcher.dart';
import 'package:haro_app/backend/boot_gate.dart';
import 'package:haro_app/backend/boot_splash.dart';
import 'package:haro_app/backend/quit_check.dart';
import 'package:haro_app/widgets/check_mark.dart';
import 'package:haro_app/widgets/haro_mark_motion.dart';
import 'package:haro_app/widgets/haro_skeleton.dart';

class FakeLauncher extends BackendLauncher {
  FakeLauncher({this.stages = const [], this.gate})
    : super(
        env: const {},
        appExecutable: '/x/haro_app',
        define: '',
        acquireLock: () => null,
      );

  final List<BootStage> stages;
  final Completer<void>? gate;
  final stopped = Completer<void>();

  @override
  LaunchReady? get immediate => null;

  @override
  Future<LaunchOutcome> start() async {
    for (final s in stages) {
      onStage?.call(s);
    }
    await gate?.future;
    return LaunchReady(
      const BackendConfig(baseUrl: 'http://127.0.0.1:41417'),
      spawned: true,
    );
  }

  @override
  Future<void> stop() => stopped.future;
}

Widget gate(FakeLauncher l, List<int> exits, {List<BusyWorkspace>? busy}) =>
    BootGate(
      launcher: l,
      hookWindowClose: false,
      busyCheck: (_) async => busy ?? const [],
      exitApp: exits.add,
      appBuilder: (_) => const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('app'),
      ),
    );

Finder k(String key) => find.byKey(Key(key));

void main() {
  tearDown(() => HaroSkeleton.animate = false);

  group('the glyph', () {
    double opacityOf(List<MarkFrame> f, MarkKind kind, int index) {
      final i = markPieces.indexWhere(
        (p) => p.kind == kind && p.index == index,
      );
      return f[i].opacity;
    }

    test('assembles dots, then cells, then the green cell, then the bar', () {
      expect(
        markFrames(MarkMotion.assemble, 0).every((f) => f.opacity == 0),
        isTrue,
      );
      final early = markFrames(MarkMotion.assemble, 400);
      expect(opacityOf(early, MarkKind.dot, 0), greaterThan(0));
      expect(opacityOf(early, MarkKind.cell, 0), 0);
      final mid = markFrames(MarkMotion.assemble, 1000);
      expect(opacityOf(mid, MarkKind.dot, 0), 1);
      expect(opacityOf(mid, MarkKind.cell, 0), greaterThan(0));
      expect(opacityOf(mid, MarkKind.cell, 5), 0);
      expect(opacityOf(mid, MarkKind.bar, 0), 0);
      expect(opacityOf(mid, MarkKind.gate, 0), 0);
      final late = markFrames(MarkMotion.assemble, 1560);
      expect(opacityOf(late, MarkKind.gate, 0), 1);
      expect(opacityOf(late, MarkKind.bar, 0), 0);
      final done = markFrames(
        MarkMotion.assemble,
        markAssembleDuration.inMilliseconds,
      );
      expect(done.every((f) => f.opacity == 1), isTrue);
      final bar = markPieces.indexWhere((p) => p.kind == MarkKind.bar);
      expect(done[bar].rect.width, markPieces[bar].rect.width);
    });

    test('the bar grows to its width instead of fading', () {
      final bar = markPieces.indexWhere((p) => p.kind == MarkKind.bar);
      final w = markPieces[bar].rect.width;
      final a = markFrames(MarkMotion.assemble, 1700)[bar].rect.width;
      expect(a, inExclusiveRange(0, w));
      expect(markFrames(MarkMotion.assemble, 1700)[bar].opacity, 1);
    });

    test('comes apart in reverse: bar, green, cells, dots', () {
      expect(
        markFrames(MarkMotion.disassemble, 0).every((f) => f.opacity == 1),
        isTrue,
      );
      final a = markFrames(MarkMotion.disassemble, 300);
      expect(opacityOf(a, MarkKind.bar, 0), 1);
      expect(opacityOf(a, MarkKind.gate, 0), lessThan(1));
      expect(opacityOf(a, MarkKind.cell, 0), 1);
      final b = markFrames(MarkMotion.disassemble, 700);
      expect(opacityOf(b, MarkKind.bar, 0), 0);
      expect(opacityOf(b, MarkKind.gate, 0), 0);
      expect(opacityOf(b, MarkKind.cell, 5), lessThan(1));
      expect(opacityOf(b, MarkKind.dot, 0), 1);
      final end = markFrames(
        MarkMotion.disassemble,
        markDisassembleDuration.inMilliseconds,
      );
      expect(end.every((f) => f.opacity == 0), isTrue);
    });

    test('only the gate cell is green', () {
      expect(
        markFrames(MarkMotion.assemble, 3000).where((f) => f.gate),
        hasLength(1),
      );
    });
  });

  group('the opening splash', () {
    testWidgets('shows the lockup, our line and what has happened', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: BootSplash(
            ready: false,
            lines: [
              BootLine('running haro', 'none'),
              BootLine('bundled backend'),
            ],
          ),
        ),
      );
      expect(find.text('haro.'), findsOneWidget);
      expect(find.text('YOU STAY THE AUTHOR'), findsOneWidget);
      expect(find.text('STARTING BACKEND'), findsOneWidget);
      expect(find.text('none'), findsOneWidget);
      expect(find.text('…'), findsOneWidget);
      expect(find.byType(CheckMark), findsOneWidget);
      expect(find.text('NOTHING SHIPS UNTIL IT’S GREEN'), findsNothing);
    });

    testWidgets('without motion the lines are plainly visible', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: BootSplash(
            ready: true,
            lines: [
              BootLine('running haro', 'none'),
              BootLine('bundled backend', 'ready'),
            ],
          ),
        ),
      );
      for (final i in [0, 1]) {
        final o = t.widget<Opacity>(
          find
              .ancestor(of: k('boot-line-$i'), matching: find.byType(Opacity))
              .first,
        );
        expect(o.opacity, 1);
      }
    });

    testWidgets('ready completes the bar and says so', (t) async {
      await t.pumpWidget(
        const MaterialApp(home: BootSplash(ready: true, lines: [])),
      );
      expect(find.text('READY'), findsOneWidget);
      final bar = t.widget<FractionallySizedBox>(
        find.descendant(
          of: k('boot-bar'),
          matching: find.byType(FractionallySizedBox),
        ),
      );
      expect(bar.widthFactor, 1);
    });

    testWidgets('with motion on the word and line arrive after the glyph', (
      t,
    ) async {
      HaroSkeleton.animate = true;
      await t.pumpWidget(
        const MaterialApp(home: BootSplash(ready: false, lines: [])),
      );
      double wordOpacity() => t
          .widget<Opacity>(
            find
                .ancestor(
                  of: k('boot-wordmark'),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      await t.pump(const Duration(milliseconds: 100));
      expect(wordOpacity(), 0);
      await t.pump(const Duration(milliseconds: 2400));
      expect(wordOpacity(), 1);
      final bar = t
          .widget<FractionallySizedBox>(
            find.descendant(
              of: k('boot-bar'),
              matching: find.byType(FractionallySizedBox),
            ),
          )
          .widthFactor!;
      expect(bar, inExclusiveRange(0, .92));
      await t.pumpWidget(const SizedBox());
    });
  });

  group('the gate', () {
    testWidgets('lists the stages as they really happen', (t) async {
      final gateOpen = Completer<void>();
      final l = FakeLauncher(
        stages: const [BootStage.probing, BootStage.spawning],
        gate: gateOpen,
      );
      await t.pumpWidget(gate(l, []));
      await t.pump();
      expect(find.text('running haro'), findsOneWidget);
      expect(find.text('none'), findsOneWidget);
      expect(find.text('bundled backend'), findsOneWidget);
      expect(find.text('app'), findsNothing);
      gateOpen.complete();
      await t.pump();
      await t.pump();
      expect(find.text('app'), findsOneWidget);
    });

    double splashOpacity(WidgetTester t) =>
        t.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

    // The splash's clock starts at its first frame, so step in small frames.
    Future<void> run(WidgetTester t, int ms) async {
      for (var i = 0; i < ms ~/ 50; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets(
      'a quick backend: the sequence plays out, the app loads beneath, a beat, then the fade',
      (t) async {
        HaroSkeleton.animate = true;
        final l = FakeLauncher(
          stages: const [BootStage.probing, BootStage.found],
        );
        await t.pumpWidget(gate(l, []));
        await t.pump(const Duration(milliseconds: 16));
        await run(t, 500);
        expect(
          find.text('app'),
          findsNothing,
          reason: 'not built while the glyph is still assembling',
        );
        expect(find.byType(BootSplash), findsOneWidget);
        expect(find.text('READY'), findsOneWidget);
        await run(t, 1900);
        expect(splashOpacity(t), 1, reason: 'the sequence is still playing');
        expect(find.text('app'), findsNothing);
        await run(t, 500);
        expect(
          find.text('app'),
          findsOneWidget,
          reason: 'built under the splash once the sequence has played',
        );
        expect(splashOpacity(t), 1, reason: 'a beat on the finished sequence');
        await run(t, 400);
        expect(splashOpacity(t), 0);
        expect(find.byType(BootSplash), findsOneWidget, reason: 'still fading');
        await run(t, 400);
        expect(find.byType(BootSplash), findsNothing);
        expect(find.text('app'), findsOneWidget);
      },
    );

    testWidgets(
      'a click skips the sequence and its beat; the splash ignores clicks while it fades',
      (t) async {
        HaroSkeleton.animate = true;
        final l = FakeLauncher();
        await t.pumpWidget(gate(l, []));
        await t.pump(const Duration(milliseconds: 16));
        await run(t, 600);
        expect(splashOpacity(t), 1);
        await t.tapAt(const Offset(20, 20));
        await t.pump(const Duration(milliseconds: 100));
        await t.pump(const Duration(milliseconds: 100));
        expect(splashOpacity(t), 0);
        final ignore = t.widget<IgnorePointer>(
          find
              .descendant(
                of: find.byKey(const ValueKey('boot-splash')),
                matching: find.byType(IgnorePointer),
              )
              .first,
        );
        expect(ignore.ignoring, isTrue);
        await run(t, 500);
        expect(find.byType(BootSplash), findsNothing);
      },
    );

    testWidgets(
      'a slow backend: no app until it answers, then READY for a beat and the fade',
      (t) async {
        HaroSkeleton.animate = true;
        final open = Completer<void>();
        final l = FakeLauncher(gate: open);
        await t.pumpWidget(gate(l, []));
        await t.pump(const Duration(milliseconds: 16));
        await run(t, 4000);
        expect(find.text('app'), findsNothing);
        expect(find.byType(BootSplash), findsOneWidget);
        open.complete();
        await t.pump();
        await run(t, 100);
        expect(find.text('app'), findsOneWidget);
        expect(splashOpacity(t), 1, reason: 'the beat on READY');
        await run(t, 500);
        expect(splashOpacity(t), 0);
        await run(t, 400);
        expect(find.byType(BootSplash), findsNothing);
      },
    );
  });

  group('the closing splash', () {
    testWidgets(
      'says what is stopping, then the glyph comes apart before the exit',
      (t) async {
        HaroSkeleton.animate = true;
        final l = FakeLauncher();
        final exits = <int>[];
        await t.pumpWidget(
          gate(
            l,
            exits,
            busy: const [
              BusyWorkspace('a', 'agent'),
              BusyWorkspace('b', 'agent'),
              BusyWorkspace('c', 'gate'),
            ],
          ),
        );
        await t.pump(const Duration(milliseconds: 16));
        for (var i = 0; i < 90; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
        final state =
            t.state<State<BootGate>>(find.byType(BootGate)) as dynamic;
        await state.closeRequested();
        await t.pump();
        // The window asks first: Quit anyway.
        await t.tap(find.text('Quit anyway'));
        await t.pump(const Duration(milliseconds: 600));
        expect(find.text('CLOSING'), findsOneWidget);
        expect(find.text('stopping 2 agents and 1 gate'), findsOneWidget);
        expect(find.text('stopping backend'), findsOneWidget);
        expect(find.byType(CheckMark), findsNothing);
        l.stopped.complete();
        await t.pump(const Duration(milliseconds: 100));
        expect(find.text('done'), findsNWidgets(2));
        expect(find.byType(CheckMark), findsNWidgets(2));
        expect(exits, isEmpty);
        await t.pump(const Duration(milliseconds: 1000));
        expect(exits, isEmpty);
        await t.pump(const Duration(milliseconds: 900));
        expect(exits, [0]);
      },
    );

    testWidgets('a signal during the animation exits at once', (t) async {
      HaroSkeleton.animate = true;
      final l = FakeLauncher();
      final exits = <int>[];
      await t.pumpWidget(gate(l, exits));
      await t.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 90; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      final state = t.state<State<BootGate>>(find.byType(BootGate)) as dynamic;
      unawaited(state.closeRequested());
      await t.pump();
      l.stopped.complete();
      await t.pump(const Duration(milliseconds: 300));
      expect(exits, isEmpty);
      unawaited(state.quitForSignal());
      await t.pump();
      expect(exits, [0]);
    });

    testWidgets('a signal does not wait for the animation', (t) async {
      final l = FakeLauncher();
      final exits = <int>[];
      HaroSkeleton.animate = true;
      await t.pumpWidget(gate(l, exits));
      await t.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 90; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      final state = t.state<State<BootGate>>(find.byType(BootGate)) as dynamic;
      unawaited(state.quitForSignal());
      await t.pump();
      l.stopped.complete();
      await t.pump();
      await t.pump();
      expect(exits, [0]);
    });

    testWidgets('Cmd+Q still takes the close path', (t) async {
      final l = FakeLauncher();
      await t.pumpWidget(gate(l, []));
      await t.pump();
      await t.pump();
      final state = t.state<State<BootGate>>(find.byType(BootGate)) as dynamic;
      expect(await state.exitRequested(), AppExitResponse.cancel);
    });
  });
}
