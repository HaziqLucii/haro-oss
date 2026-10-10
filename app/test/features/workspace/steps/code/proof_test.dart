import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/diff_model.dart';
import 'package:haro_app/features/workspace/steps/code/proof.dart';

import 'code_harness.dart';

VerifiedFile vf(
  Map<int, int?> lines, {
  bool inMap = true,
  bool stale = false,
}) => VerifiedFile(path: 'f.ts', inMap: inMap, stale: stale, lines: lines);

void main() {
  group('lineDot', () {
    final file = vf({2: 3, 3: 0, 4: null});

    test('ran, never ran, and no claim', () {
      expect(lineDot(file, 2), LineDot.hit);
      expect(lineDot(file, 3), LineDot.cold);
      expect(lineDot(file, 4), LineDot.none);
      expect(lineDot(file, 99), LineDot.none);
    });

    test('no proof, a stale file or a deleted line says nothing', () {
      expect(lineDot(null, 2), LineDot.none);
      expect(lineDot(vf({2: 3}, stale: true), 2), LineDot.none);
      expect(lineDot(file, null), LineDot.none);
    });
  });

  group('hunkProof', () {
    test('every coverable line ran', () {
      final p = hunkProof(vf({1: 2, 2: 1, 3: null}), [1, 2, 3])!;
      expect(p.kind, HunkKind.executed);
      expect((p.executed, p.unexecuted, p.noncoverable), (2, 0, 1));
    });

    test('some never ran', () {
      final p = hunkProof(vf({1: 2, 2: 0}), [1, 2])!;
      expect(p.kind, HunkKind.partial);
      expect(hunkBadgeLabel(p), '1 of 2 added lines never ran');
    });

    test('nothing executable was added', () {
      final p = hunkProof(vf({1: null, 2: null}), [1, 2])!;
      expect(p.kind, HunkKind.nonexec);
    });

    test('a file no test imports counts every added line as never run', () {
      final p = hunkProof(vf({}, inMap: false), [1, 2, 3])!;
      expect(p.kind, HunkKind.unmapped);
      expect(p.unexecuted, 3);
    });

    test('stale wins, and nothing to say for a hunk with no additions', () {
      expect(hunkProof(vf({1: 1}, stale: true), [1])!.kind, HunkKind.stale);
      expect(hunkProof(vf({1: 1}), []), isNull);
      expect(hunkProof(null, [1]), isNull);
    });

    test('labels never claim more than "ran"', () {
      for (final k in HunkKind.values) {
        final label = hunkBadgeLabel(
          HunkProof(
            kind: k,
            added: 2,
            executed: 1,
            unexecuted: 1,
            noncoverable: 0,
          ),
        )!;
        expect(label, isNot(contains('verified')));
        expect(label, isNot(contains('proven')));
        expect(label, isNot(contains('correct')));
      }
    });
  });

  group('mergeProof', () {
    HunkProof p(HunkKind k, int e, int u) => HunkProof(
      kind: k,
      added: e + u,
      executed: e,
      unexecuted: u,
      noncoverable: 0,
    );

    test('one cold hunk makes the file partial', () {
      final m = mergeProof([
        p(HunkKind.executed, 2, 0),
        p(HunkKind.partial, 1, 1),
      ])!;
      expect(m.kind, HunkKind.partial);
      expect((m.executed, m.unexecuted), (3, 1));
    });

    test('all unmapped stays unmapped; stale poisons the rest', () {
      expect(
        mergeProof([p(HunkKind.unmapped, 0, 2), p(HunkKind.unmapped, 0, 1)])!
            .kind,
        HunkKind.unmapped,
      );
      expect(
        mergeProof([p(HunkKind.executed, 2, 0), p(HunkKind.stale, 0, 0)])!.kind,
        HunkKind.stale,
      );
      expect(mergeProof([null, null]), isNull);
    });
  });

  group('indexProof', () {
    test('unsupported or empty runners give no index', () {
      expect(indexProof(null), isNull);
      expect(indexProof(verified(supported: false)), isNull);
      expect(
        indexProof(const VerifiedHunksResponse(baseRef: 'b', supported: true)),
        isNull,
      );
      expect(indexProof(verified())!.keys, contains('lib/rates.ts'));
    });
  });

  group('proofSquareFor', () {
    final files = {for (final f in parseUnifiedDiff(rates)) f.path: f};
    final proof = indexProof(verified());

    test('green when every added line ran', () {
      expect(proofSquareFor(files['lib/zones.ts']!, proof), ProofSquare.ran);
    });

    test('hollow when some added lines never ran', () {
      expect(
        proofSquareFor(files['lib/rates.ts']!, proof),
        ProofSquare.partial,
      );
    });

    test('a file no test imports is hollow too', () {
      expect(proofSquareFor(files['README.md']!, proof), ProofSquare.partial);
    });

    test('dim without data, without a map, or with nothing coverable', () {
      expect(proofSquareFor(files['lib/old.ts']!, proof), ProofSquare.none);
      expect(proofSquareFor(files['lib/rates.ts']!, null), ProofSquare.none);
      final comments = indexProof(
        VerifiedHunksResponse(
          baseRef: 'b',
          supported: true,
          files: [
            const VerifiedFile(
              path: 'lib/zones.ts',
              inMap: true,
              lines: {2: null},
            ),
          ],
        ),
      );
      expect(
        proofSquareFor(files['lib/zones.ts']!, comments),
        ProofSquare.none,
      );
    });
  });
}
