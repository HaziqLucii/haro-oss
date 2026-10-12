import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/backend/backend_steps.dart';
import 'package:haro_app/backend/boot_splash.dart';
import 'package:haro_app/backend/boot_themes.dart' show m3ClosingNeeds;
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_skeleton.dart';

const _lines = [BootLine('running haro', 'none'), BootLine('bundled backend')];

Widget _app(Widget home) => MaterialApp(theme: buildHaroTheme(), home: home);

Finder _key(String k) => find.byKey(Key(k));

void main() {
  tearDown(() {
    HaroSkeleton.animate = false;
    HaroTokens.apply(HaroPalette.haro);
  });

  test('the Expressive quit fits the time the quit screen stays', () {
    HaroTokens.apply(HaroPalette.material3);
    expect(closingTail, greaterThanOrEqualTo(m3ClosingNeeds));
  });

  test('each theme has its own sequence length', () {
    HaroTokens.apply(HaroPalette.haro);
    final haro = (bootSequence, closingTail);
    HaroTokens.apply(HaroPalette.material3);
    final m3 = (bootSequence, closingTail);
    HaroTokens.apply(HaroPalette.paper);
    final paper = (bootSequence, closingTail);
    expect({haro, m3, paper}.length, 3);
    expect(m3.$1, greaterThan(haro.$1));
    expect(paper.$2, greaterThan(const Duration(milliseconds: 1200)));
  });

  for (final (name, palette) in [
    ('Classic', HaroPalette.haro),
    ('Material 3', HaroPalette.material3),
    ('Paper', HaroPalette.paper),
  ]) {
    testWidgets('$name: the full list of real steps fits a small window', (
      tester,
    ) async {
      HaroTokens.apply(palette);
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boot = [
        const BootLine('running haro', 'none'),
        const BootLine('bundled backend', 'ready'),
        ...bootStepLines(const [
          BackendStep('boot', 'install_haro_skill', 3),
          BackendStep('boot', 'db.init', 3),
          BackendStep('boot', 'db.load_into', 40, '120 workspaces'),
          BackendStep('boot', 'db.reconcile', 5),
          BackendStep('boot', 'db.mark_broken', 90),
          BackendStep('boot', 'baseline_sweep', 2),
          BackendStep('boot', 'reconcile_adoptable', 60),
          BackendStep('boot', 'sweep_orphan_runs', 4, '2 stopped'),
        ]),
      ];
      await tester.pumpWidget(_app(BootSplash(ready: true, lines: boot)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final closing = [
        'stopping 2 agents and 1 gate',
        'stopping backend',
        ...closingStepLines(const [
          BackendStep('shutdown', 'dev_servers', 1000, '3'),
          BackendStep('shutdown', 'snapshot', 8),
          BackendStep('shutdown', 'database', 2),
        ]),
      ];
      await tester.pumpWidget(
        _app(ClosingSplash(lines: closing, stopped: true)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, palette, style) in [
    ('Material 3', HaroPalette.material3, BootStyle.expressive),
    ('Paper', HaroPalette.paper, BootStyle.paper),
  ]) {
    group('$name boot screens', () {
      setUp(() => HaroTokens.apply(palette));

      testWidgets('the opening shows the word, the real lines and the status', (
        tester,
      ) async {
        expect(HaroTokens.palette.boot, style);
        await tester.pumpWidget(
          _app(const BootSplash(ready: false, lines: _lines)),
        );
        expect(tester.widget<Text>(_key('boot-wordmark')).data, 'haro.');
        expect(tester.widget<Text>(_key('boot-line-0')).data, 'running haro');
        expect(tester.widget<Text>(_key('boot-line-result-0')).data, 'none');
        expect(tester.widget<Text>(_key('boot-line-result-1')).data, '…');
        expect(
          tester.widget<Text>(_key('boot-status')).data,
          'STARTING BACKEND',
        );
        await tester.pumpWidget(
          _app(const BootSplash(ready: true, lines: _lines)),
        );
        expect(tester.widget<Text>(_key('boot-status')).data, 'READY');
      });

      testWidgets('the quit lists what is stopping and says when it is done', (
        tester,
      ) async {
        const lines = ['stopping 2 agents', 'stopping backend'];
        await tester.pumpWidget(
          _app(const ClosingSplash(lines: lines, stopped: false)),
        );
        expect(tester.widget<Text>(_key('boot-line-0')).data, lines[0]);
        expect(find.text('done'), findsNothing);
        await tester.pumpWidget(
          _app(const ClosingSplash(lines: lines, stopped: true)),
        );
        await tester.pump();
        expect(tester.widget<Text>(_key('boot-line-1')).data, lines[1]);
      });
    });
  }

  testWidgets('Paper prints the stopping steps as a dated receipt', (
    tester,
  ) async {
    HaroTokens.apply(HaroPalette.paper);
    const lines = ['stopping backend'];
    await tester.pumpWidget(
      _app(const ClosingSplash(lines: lines, stopped: false)),
    );
    expect(find.textContaining('session receipt ·'), findsOneWidget);
    expect(find.text('…'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('boot-status')).data,
      'Printing session receipt…',
    );
    await tester.pumpWidget(
      _app(const ClosingSplash(lines: lines, stopped: true)),
    );
    expect(find.text('done'), findsOneWidget);
    expect(find.textContaining('see you next time'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('boot-status')).data,
      'Stopped. Closing haro.',
    );
  });

  testWidgets('with motion, Material 3 shows the word only after the mark', (
    tester,
  ) async {
    HaroTokens.apply(HaroPalette.material3);
    HaroSkeleton.animate = true;
    await tester.pumpWidget(
      _app(const BootSplash(ready: false, lines: _lines)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    double wordOpacity() => tester
        .widget<Opacity>(
          find
              .ancestor(
                of: _key('boot-wordmark'),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    await tester.pump(const Duration(milliseconds: 1000));
    expect(wordOpacity(), 0);
    await tester.pump(const Duration(milliseconds: 2200));
    expect(wordOpacity(), 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with motion, Paper types the word out letter by letter', (
    tester,
  ) async {
    HaroTokens.apply(HaroPalette.paper);
    HaroSkeleton.animate = true;
    await tester.pumpWidget(
      _app(const BootSplash(ready: false, lines: _lines)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.widget<Text>(_key('boot-wordmark')).data, '');
    await tester.pump(const Duration(milliseconds: 950));
    expect(tester.widget<Text>(_key('boot-wordmark')).data, 'h');
    await tester.pump(const Duration(milliseconds: 1200));
    expect(tester.widget<Text>(_key('boot-wordmark')).data, 'haro.');
    await tester.pumpWidget(const SizedBox());
  });

  for (final (name, palette) in [
    ('Material 3', HaroPalette.material3),
    ('Paper', HaroPalette.paper),
  ]) {
    testWidgets('$name plays both screens through without a paint error', (
      tester,
    ) async {
      HaroTokens.apply(palette);
      HaroSkeleton.animate = true;
      await tester.pumpWidget(
        _app(const BootSplash(ready: false, lines: _lines)),
      );
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 37));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      const lines = ['stopping backend'];
      await tester.pumpWidget(
        _app(const ClosingSplash(lines: lines, stopped: false)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 37));
      }
      await tester.pumpWidget(
        _app(const ClosingSplash(lines: lines, stopped: true)),
      );
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 37));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
