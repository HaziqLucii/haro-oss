import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/terminal/bottom_panel_provider.dart';
import 'package:haro_app/features/workspace/terminal/panel_model.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/state/look_at.dart';
import 'package:haro_app/state/review_items.dart';

VerifiedHunksResponse proof(List<VerifiedFile> files, {bool stale = false}) =>
    VerifiedHunksResponse(
      baseRef: 'main',
      supported: true,
      stale: stale,
      files: files,
    );

String line(
  String? path,
  VerifiedHunksResponse? p, {
  DisplayState state = DisplayState.green,
  Set<String> changed = const {'a.ts'},
}) => fileProofLine(path: path, state: state, proof: p, changed: changed);

void main() {
  group('fileProofLine', () {
    test('no open file and unchanged files say so', () {
      expect(line(null, null), 'no file open');
      expect(line('other.ts', null), 'unchanged');
    });

    test('every coverable added line ran only under a green gate', () {
      final p = proof([
        const VerifiedFile(
          path: 'a.ts',
          inMap: true,
          added: 3,
          executed: 3,
          lines: {1: 2, 2: 1, 3: 4},
        ),
      ]);
      expect(line('a.ts', p), 'every added line ran in the green suite');
      expect(
        line('a.ts', p, state: DisplayState.red),
        'the gate is red, no proof for this file yet',
      );
      expect(line('a.ts', p, state: DisplayState.gate), 'the gate is running');
      expect(
        line('a.ts', p, state: DisplayState.agent),
        'the gate has not run on this tree',
      );
    });

    test('never-run lines are counted, singular and plural', () {
      const f = VerifiedFile(
        path: 'a.ts',
        inMap: true,
        added: 4,
        executed: 3,
        unexecuted: 1,
        lines: {1: 0},
      );
      expect(line('a.ts', proof([f])), '1 added line never ran');
      const g = VerifiedFile(
        path: 'a.ts',
        inMap: true,
        added: 4,
        executed: 1,
        unexecuted: 3,
        lines: {1: 0, 2: 0, 3: 0},
      );
      expect(line('a.ts', proof([g])), '3 added lines never ran');
    });

    test('unmapped, stale, nothing coverable and unmeasured files', () {
      expect(
        line('a.ts', proof([const VerifiedFile(path: 'a.ts', added: 5)])),
        'no test imports this file, 5 added lines never ran',
      );
      expect(
        line(
          'a.ts',
          proof([const VerifiedFile(path: 'a.ts', stale: true, added: 1)]),
        ),
        'the gate ran on an older version of this file',
      );
      expect(
        line(
          'a.ts',
          proof([const VerifiedFile(path: 'a.ts', inMap: true, added: 1)]),
        ),
        'not executable, no proof needed',
      );
      expect(line('a.ts', null), 'not measured');
      expect(
        line('a.ts', const VerifiedHunksResponse(baseRef: 'main')),
        'not measured',
      );
    });
  });

  group('impactLine', () {
    ImpactResponse impact({bool supported = true, String? error}) =>
        ImpactResponse(
          baseRef: 'main',
          supported: supported,
          error: error,
          changedFiles: const [ChangedFile(path: 'src/a.ts')],
          impactedTests: const [
            ImpactTest(file: 'src/a.test.ts', name: 'one'),
            ImpactTest(file: 'src/a.test.ts', name: 'two'),
            ImpactTest(file: 'src/b.test.ts', name: 'three'),
          ],
          impactedFiles: const ['src/a.test.ts', 'src/b.test.ts'],
        );

    test('a source file gets the change count, a test file its own', () {
      expect(
        impactLine('src/a.ts', impact()),
        'Tests touching this change: 3.',
      );
      expect(impactLine('src/a.test.ts', impact()), 'Tests in this file: 2.');
    });

    test('says nothing for unrelated files or unusable data', () {
      expect(impactLine('README.md', impact()), isNull);
      expect(impactLine(null, impact()), isNull);
      expect(impactLine('src/a.ts', null), isNull);
      expect(impactLine('src/a.ts', impact(supported: false)), isNull);
      expect(impactLine('src/a.ts', impact(error: 'boom')), isNull);
    });
  });

  group('deriveProblems', () {
    LookAtItem item(LookAtKind kind, String key, {String? file, int? line}) =>
        LookAtItem(
          kind: kind,
          key: key,
          label: 'NO TEST RAN',
          title: file ?? key,
          file: file,
          line: line,
          review: const ReviewItem(target: 't', text: 'x'),
        );

    test('mutants come from survivors, eyes exclude look-at mutation rows', () {
      final v = deriveProblems(
        LookAt(
          pending: [
            item(LookAtKind.codeToCheck, 'c1', file: 'lib/a.ts', line: 4),
            item(LookAtKind.mutation, 'mutation:lib/b.ts:9', file: 'lib/b.ts'),
            item(LookAtKind.coverage, 'coverage'),
          ],
        ),
        const [
          MutationSurvivor(path: 'lib/b.ts', line: 9, operator: '== to !='),
        ],
      );
      expect(v.mutants, hasLength(1));
      expect(v.mutants.single.title, 'b.ts:9');
      expect(v.mutants.single.detail, '== to !=');
      expect(v.mutants.single.path, 'lib/b.ts');
      expect(v.mutants.single.line, 9);
      expect(v.eyes.map((r) => r.key), ['c1', 'coverage']);
      expect(v.eyes.last.path, isNull, reason: 'a coverage note has no file');
      expect(v.count, 3);
      expect(v.isEmpty, isFalse);
    });

    test('empty when nothing is flagged and no mutant survived', () {
      expect(deriveProblems(LookAt.empty, const []).isEmpty, isTrue);
    });

    test('the empty words never claim a clean run that nothing measured', () {
      expect(
        problemsEmptyLines(DisplayState.idle, mutationRan: false),
        hasLength(2),
      );
      expect(problemsEmptyLines(DisplayState.green, mutationRan: true), [
        'Nothing flagged on this run.',
      ]);
    });
  });

  test('changedPaths reads the new side of the diff', () {
    const diff =
        'diff --git a/x.ts b/x.ts\n--- a/x.ts\n+++ b/x.ts\n@@ -1 +1 @@\n-a\n+b\n'
        'diff --git a/gone.ts b/gone.ts\n--- a/gone.ts\n+++ /dev/null\n@@ -1 +0,0 @@\n-a\n';
    expect(changedPaths(diff), {'x.ts'});
  });

  test('the Dev log tab falls back to the terminal when unavailable', () {
    expect(devLogAvailable(running: false, hasOutput: false), isFalse);
    expect(devLogAvailable(running: true, hasOutput: false), isTrue);
    expect(devLogAvailable(running: false, hasOutput: true), isTrue);
    expect(
      effectiveBottomTab(BottomTab.devLog, devLog: false),
      BottomTab.terminal,
    );
    expect(
      effectiveBottomTab(BottomTab.devLog, devLog: true),
      BottomTab.devLog,
    );
    expect(effectiveBottomTab(BottomTab.gate, devLog: false), BottomTab.gate);
  });
}
