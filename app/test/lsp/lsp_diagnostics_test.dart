import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/code/proof_marks.dart';
import 'package:haro_app/features/workspace/terminal/panel_model.dart';
import 'package:haro_app/lsp/lsp_client.dart';
import 'package:haro_app/lsp/lsp_diagnostics.dart';

import 'fake_lsp.dart';

const _root = '/work/tree';
const _a = 'file:///work/tree/src/a.ts';
const _b = 'file:///work/tree/src/b.ts';

const _ts2322 =
    "Type 'string' is not assignable to type 'number'.\n  more detail";

Map<String, Object?> _diag({
  int line = 0,
  int character = 6,
  int? severity = 1,
  String message = _ts2322,
  Object? code = 2322,
  String? source = 'typescript',
}) => {
  'range': {
    'start': {'line': line, 'character': character},
    'end': {'line': line, 'character': character + 1},
  },
  'severity': ?severity,
  'code': ?code,
  'source': ?source,
  'message': message,
};

Map<String, Object?> _publish(
  String uri,
  List<Map<String, Object?>> items, {
  int? version,
}) => {
  'jsonrpc': '2.0',
  'method': 'textDocument/publishDiagnostics',
  'params': {'uri': uri, 'version': ?version, 'diagnostics': items},
};

Future<void> _flush() => pumpEventQueue(times: 50);

Future<void> _debounce() => Future<void>.delayed(
  DiagnosticsFeed.delay + const Duration(milliseconds: 60),
);

Future<(LspClient, FakeLspServer)> _ready({
  List<String> open = const [_a],
}) async {
  final s = FakeLspServer();
  final c = LspClient(connect: () => s, rootPath: _root);
  addTearDown(c.dispose);
  for (final u in open) {
    c.openDocument(u, 'typescript', 'const x: number = "a";');
  }
  await _flush();
  return (c, s);
}

void main() {
  group('client', () {
    test('parses and stores diagnostics per uri', () async {
      final (c, s) = await _ready(open: [_a, _b]);
      s.push(
        _publish(_a, [_diag(), _diag(line: 3, severity: 2, code: '6133')]),
      );
      s.push(_publish(_b, [_diag(message: 'other')]));
      await _flush();

      final a = c.diagnosticsOf(_a);
      expect(a, hasLength(2));
      expect(a.first.severity, DiagnosticSeverity.error);
      expect(a.first.line, 0);
      expect(a.first.character, 6);
      expect(a.first.codeLabel, 'TS2322');
      expect(
        a.first.headline,
        "Type 'string' is not assignable to type 'number'.",
      );
      expect(a.last.severity, DiagnosticSeverity.warning);
      expect(c.diagnosticsOf(_b).single.message, 'other');
      expect(c.diagnosticsOf('file:///work/tree/src/none.ts'), isEmpty);
    });

    test('an empty publish clears the file', () async {
      final (c, s) = await _ready();
      s.push(_publish(_a, [_diag()]));
      await _flush();
      expect(c.diagnosticsOf(_a), isNotEmpty);
      s.push(_publish(_a, const []));
      await _flush();
      expect(c.diagnosticsOf(_a), isEmpty);
    });

    test('a publish older than the buffer version is ignored', () async {
      final (c, s) = await _ready();
      c.changeDocument(_a, 'const x: number = 1;');
      c.changeDocument(_a, 'const x: number = 2;');
      expect(c.versionOf(_a), 3);
      s.push(_publish(_a, [_diag(message: 'stale')], version: 2));
      await _flush();
      expect(c.diagnosticsOf(_a), isEmpty);
      s.push(_publish(_a, [_diag(message: 'fresh')], version: 3));
      await _flush();
      expect(c.diagnosticsOf(_a).single.message, 'fresh');
    });

    test(
      'a publish without a version, or for an unopened file, is handled',
      () async {
        final (c, s) = await _ready();
        s.push(_publish(_a, [_diag()]));
        s.push(_publish(_b, [_diag()]));
        await _flush();
        expect(c.diagnosticsOf(_a), hasLength(1));
        expect(c.diagnosticsOf(_b), isEmpty);
      },
    );

    test('malformed entries are skipped', () async {
      final (c, s) = await _ready();
      s.push({
        'jsonrpc': '2.0',
        'method': 'textDocument/publishDiagnostics',
        'params': {
          'uri': _a,
          'diagnostics': [
            'junk',
            {'message': 'no range'},
            {
              'range': {
                'start': {'line': 1, 'character': 0},
              },
              'message': 'no severity means error',
            },
          ],
        },
      });
      await _flush();
      final d = c.diagnosticsOf(_a).single;
      expect(d.severity, DiagnosticSeverity.error);
      expect(d.line, 1);
    });

    test('closing the document clears it; a late publish is ignored', () async {
      final (c, s) = await _ready();
      s.push(_publish(_a, [_diag()]));
      await _flush();
      await _debounce();
      var fired = 0;
      c.diagnosticsFeed.addListener(() => fired++);
      c.closeDocument(_a);
      expect(c.diagnosticsOf(_a), isEmpty);
      expect(fired, 0);
      await _debounce();
      expect(fired, 1);
      s.push(_publish(_a, [_diag()]));
      await _flush();
      expect(c.diagnosticsOf(_a), isEmpty);
    });

    test(
      'a second editor on the same file keeps them until the last closes',
      () async {
        final (c, s) = await _ready();
        c.openDocument(_a, 'typescript', 'const x: number = "a";');
        s.push(_publish(_a, [_diag()]));
        await _flush();
        c.closeDocument(_a);
        expect(c.diagnosticsOf(_a), isNotEmpty);
        c.closeDocument(_a);
        expect(c.diagnosticsOf(_a), isEmpty);
      },
    );

    test('the server going away clears everything', () async {
      final (c, s) = await _ready(open: [_a, _b]);
      s.push(_publish(_a, [_diag()]));
      s.push(_publish(_b, [_diag()]));
      await _flush();
      s.push({'haro': 'lsp_exited', 'code': 1});
      await _flush();
      expect(c.status, LspStatus.unavailable);
      expect(c.diagnosticsOf(_a), isEmpty);
      expect(c.diagnosticsOf(_b), isEmpty);
      expect(c.diagnosticsByPath(), isEmpty);
    });

    test('a burst of publishes notifies once', () async {
      final (c, s) = await _ready();
      var fired = 0;
      c.diagnosticsFeed.addListener(() => fired++);
      for (var i = 0; i < 5; i++) {
        s.push(_publish(_a, [_diag(line: i)]));
      }
      await _flush();
      expect(fired, 0);
      await _debounce();
      expect(fired, 1);
      expect(c.diagnosticsOf(_a).single.line, 4);
    });

    test('an identical republish does not notify', () async {
      final (c, s) = await _ready();
      s.push(_publish(_a, [_diag()]));
      await _flush();
      await _debounce();
      var fired = 0;
      c.diagnosticsFeed.addListener(() => fired++);
      s.push(_publish(_a, [_diag()]));
      await _flush();
      await _debounce();
      expect(fired, 0);
    });

    test('dispose does not notify or throw', () async {
      final (c, s) = await _ready();
      s.push(_publish(_a, [_diag()]));
      await _flush();
      c.dispose();
      await _debounce();
      expect(c.diagnosticsOf(_a), isEmpty);
    });

    test('diagnosticsByPath is worktree-relative and decoded', () async {
      final (c, s) = await _ready(open: ['file:///work/tree/src/a%20b.ts']);
      s.push(_publish('file:///work/tree/src/a%20b.ts', [_diag()]));
      await _flush();
      final files = c.diagnosticsByPath();
      expect(files.single.path, 'src/a b.ts');
    });
  });

  group('derivations', () {
    LspDiagnostic d(int line, DiagnosticSeverity s, {String m = 'm'}) =>
        LspDiagnostic(
          line: line,
          character: 2,
          severity: s,
          message: m,
          source: 'typescript',
          code: '2322',
        );

    test('gutter marks are 1-based, worst first, hints left out', () {
      final marks = diagnosticMarks([
        d(4, DiagnosticSeverity.warning, m: 'w'),
        d(4, DiagnosticSeverity.error, m: 'e\nsecond line'),
        d(7, DiagnosticSeverity.hint),
      ]);
      expect(marks.keys, [5]);
      expect(marks[5]!.map((m) => m.text), [
        'ERROR TS2322 · e',
        'WARNING TS2322 · w',
      ]);
      expect(kindOfLine(marks[5]!), ProofMarkKind.error);
      expect(lineBlocks(marks[5]!), isFalse);
    });

    test('a diagnostic mark is never the failure red', () {
      for (final s in DiagnosticSeverity.values) {
        final marks = diagnosticMarks([d(0, s)]);
        if (marks.isEmpty) continue;
        expect(
          proofMarkColor(marks[1]!),
          isNot(equals(const Color.fromRGBO(224, 104, 94, 1))),
        );
      }
    });

    test('gate evidence keeps the mark when a line has both', () {
      final merged = mergeProofMarks({
        3: const [
          ProofMark(kind: ProofMarkKind.mutant, label: 'MUTANT SURVIVED'),
        ],
      }, diagnosticMarks([d(2, DiagnosticSeverity.error)]));
      expect(kindOfLine(merged[3]!), ProofMarkKind.mutant);
      expect(merged[3], hasLength(2));
    });

    test(
      'problem sections group by source, errors first, with file:line:col',
      () {
        final sections = deriveDiagnosticSections([
          FileDiagnostics('src/b.ts', [d(9, DiagnosticSeverity.warning)]),
          FileDiagnostics('src/a.ts', [
            d(1, DiagnosticSeverity.error),
            d(0, DiagnosticSeverity.hint),
          ]),
          const FileDiagnostics('src/c.js', [
            LspDiagnostic(
              line: 0,
              character: 0,
              severity: DiagnosticSeverity.error,
              message: 'x',
              source: 'eslint',
            ),
          ]),
        ]);
        expect([for (final s in sections) s.title], ['TYPESCRIPT', 'ESLINT']);
        final ts = sections.first;
        expect(ts.count, 2);
        expect(ts.rows.first.title, 'a.ts:2:3');
        expect(ts.rows.first.label, 'ERROR TS2322');
        expect(ts.rows.first.path, 'src/a.ts');
        expect(ts.rows.first.line, 2);
        expect(ts.rows.last.label, 'WARNING TS2322');
      },
    );
  });
}
