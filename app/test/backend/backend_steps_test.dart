import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/backend/backend_steps.dart';

void main() {
  group('parseBackendStep', () {
    test('reads a boot line with and without a detail', () {
      final a = parseBackendStep('[boot] db.load_into 40ms 17 workspaces')!;
      expect(
        (a.phase, a.key, a.ms, a.detail),
        ('boot', 'db.load_into', 40, '17 workspaces'),
      );
      expect(
        parseBackendStep('[boot] baseline_sweep 0ms')!.key,
        'baseline_sweep',
      );
      final c = parseBackendStep('[shutdown] snapshot 8ms')!;
      expect((c.phase, c.key, c.ms, c.detail), ('shutdown', 'snapshot', 8, ''));
    });

    test('ignores everything else in the log', () {
      expect(parseBackendStep('[reconcile] something'), isNull);
      expect(parseBackendStep('INFO: started'), isNull);
      expect(parseBackendStep(''), isNull);
    });
  });

  group('the lines', () {
    test('a group prints when its last step is in, with their summed time', () {
      final lines = bootStepLines(const [
        BackendStep('boot', 'install_haro_skill', 3),
        BackendStep('boot', 'db.init', 10),
      ]);
      expect(
        [for (final l in lines) (l.label, l.result)],
        [('claude skills', '3 ms')],
      );
      final more = bootStepLines(const [
        BackendStep('boot', 'db.init', 10),
        BackendStep('boot', 'db.load_into', 1500, '2 workspaces'),
        BackendStep('boot', 'sweep_orphan_runs', 4, 'none'),
      ]);
      expect(
        [for (final l in more) (l.label, l.result)],
        [
          ('database · 2 workspaces', '1.5 s'),
          ('stray dev servers · none', '4 ms'),
        ],
      );
    });

    test('shutdown lines only for steps that ran, in order', () {
      expect(
        closingStepLines(const [
          BackendStep('boot', 'db.init', 1),
          BackendStep('shutdown', 'dev_servers', 900, '1'),
          BackendStep('shutdown', 'snapshot', 8),
        ]),
        ['stopped 1 dev server', 'saved state'],
      );
      expect(
        closingStepLines(const [
          BackendStep('shutdown', 'browser', 120, '1'),
          BackendStep('shutdown', 'dev_servers', 50, '2'),
        ]),
        ['closed the shared browser', 'stopped 2 dev servers'],
      );
      expect(closingStepLines(const []), isEmpty);
    });
  });

  group('BackendLogTail', () {
    late Directory dir;
    late File log;
    final got = <BackendStep>[];

    setUp(() {
      dir = Directory.systemTemp.createTempSync('haro-tail');
      log = File('${dir.path}/backend.log');
      got.clear();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('reads lines as they are written, holding a half line back', () {
      final tail = BackendLogTail(log.path, got.add);
      tail.poll();
      expect(got, isEmpty);
      log.writeAsStringSync('noise\n[boot] db.init 5ms\n[boot] db.lo');
      tail.poll();
      expect(got.map((s) => s.key), ['db.init']);
      log.writeAsStringSync(
        'ad_into 7ms 3 workspaces\n',
        mode: FileMode.append,
      );
      tail.poll();
      expect(got.map((s) => s.key), ['db.init', 'db.load_into']);
      tail.poll();
      expect(got, hasLength(2));
    });

    test('fromEnd skips what was already there', () {
      log.writeAsStringSync('[boot] old 1ms\n');
      final tail = BackendLogTail(log.path, got.add, fromEnd: true)..start();
      log.writeAsStringSync('[shutdown] snapshot 2ms\n', mode: FileMode.append);
      tail.stop();
      expect(got.map((s) => s.key), ['snapshot']);
    });

    test('a truncated log (a new launch) is read from the top again', () {
      final tail = BackendLogTail(log.path, got.add);
      log.writeAsStringSync('[boot] a 1ms\n[boot] b 1ms\n');
      tail.poll();
      log.writeAsStringSync('[boot] c 1ms\n');
      tail.poll();
      expect(got.map((s) => s.key), ['a', 'b', 'c']);
    });
  });
}
