import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/diff_view.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/features/workspace/steps/code/editor/code_editor_area.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_gutter.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/proof_marks.dart';
import 'package:haro_app/features/workspace/terminal/bottom_panel_provider.dart';
import 'package:haro_app/features/workspace/terminal/panel_model.dart';
import 'package:re_editor/re_editor.dart';

import '../../harness.dart';
import 'code_harness.dart';

const _ts = '''import { zone } from './zones';
const base = 2;
const surcharge = 3;
// note
export function rate() {
  return base;
}
''';

Map<String, FileContent> _files() => {
  'lib/rates.ts': const FileContent(path: 'lib/rates.ts', content: _ts),
  'lib/old.ts': const FileContent(path: 'lib/old.ts', content: 'x\n'),
};

CodeRig _rig({List<ProblemRow> eyes = const []}) {
  final r = CodeRig(proof: verified(), files: _files());
  if (eyes.isNotEmpty) {
    r.extra.add(
      codeProblemsProvider.overrideWith((ref, id) => ProblemsView(eyes: eyes)),
    );
  }
  return r;
}

ProviderContainer _container(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CodeEditorArea)));

EditorTabsState _tabs(WidgetTester t) =>
    _container(t).read(editorTabsProvider(id));

/// 1-based line the cursor sits on: a jump is consumed once the editor has revealed it.
int _cursorLine(WidgetTester t) =>
    t
        .widget<CodeEditor>(find.byType(CodeEditor).first)
        .controller!
        .selection
        .extentIndex +
    1;

EditorGutter _gutter(WidgetTester t) =>
    t.widget<EditorGutter>(find.byType(EditorGutter));

Future<TestGesture> _mouse(WidgetTester t) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: const Offset(1, 1));
  addTearDown(g.removePointer);
  return g;
}

final _flagged = ProblemRow(
  key: 'untested:lib/rates.ts:2',
  label: 'NO TEST RAN',
  title: 'rates.ts:2',
  detail: '1 line',
  path: 'lib/rates.ts',
  line: 2,
);

ProblemRow _row(
  String label, {
  String? path = 'lib/a.ts',
  int? line = 4,
  bool blocking = false,
  String detail = '',
}) => ProblemRow(
  key: '$label:$path:$line',
  label: label,
  title: 't',
  detail: detail,
  path: path,
  line: line,
  blocking: blocking,
);

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  group('proofMarksFromRows', () {
    test('groups eyes by file then line', () {
      final marks = proofMarksFromRows(
        ProblemsView(
          eyes: [
            _row('NO TEST RAN', detail: '3 lines'),
            _row('FAILED', line: 4, blocking: true),
            _row('NO TEST RAN', line: 8),
            _row('NO TEST RAN', path: 'lib/b.ts', line: 9, detail: 'x'),
          ],
        ),
      );
      expect(marks.keys, unorderedEquals(['lib/a.ts', 'lib/b.ts']));
      expect(marks['lib/a.ts']!.keys, unorderedEquals([4, 8]));
      expect(marks['lib/a.ts']![4], hasLength(2));
      final m = marks['lib/b.ts']![9]!.single;
      expect(m.kind, ProofMarkKind.eyes);
      expect(m.text, 'NO TEST RAN · x');
      expect(m.blocking, isFalse);
    });

    test('rows without a file or a line have nowhere to sit', () {
      final marks = proofMarksFromRows(
        ProblemsView(
          eyes: [
            _row('COVERAGE', path: null, line: null),
            _row('NO TEST RAN', line: null),
            _row('NO TEST RAN', line: 0),
          ],
        ),
      );
      expect(marks, isEmpty);
    });

    test('the blocking flag follows the row', () {
      final marks = proofMarksFromRows(
        ProblemsView(
          eyes: [_row('FAILED', blocking: true), _row('NO TEST RAN', line: 7)],
        ),
      )['lib/a.ts']!;
      expect(lineBlocks(marks[4]!), isTrue);
      expect(lineBlocks(marks[7]!), isFalse);
    });

    test('a mark without detail reads as its label alone', () {
      expect(
        const ProofMark(kind: ProofMarkKind.eyes, label: 'NO TEST RAN').text,
        'NO TEST RAN',
      );
    });
  });

  group('diff: Edit here', () {
    Finder numbers(String n) =>
        find.descendant(of: find.byType(DiffView), matching: find.text(n));
    Finder number(String n) => numbers(n).last;

    Future<void> hoverRow(WidgetTester t, String n) async {
      final g = await _mouse(t);
      await g.moveTo(t.getCenter(number(n)) + const Offset(120, 0));
      await t.pump();
    }

    testWidgets('a click on the line number opens the editor on that line', (
      tester,
    ) async {
      await _rig().pump(tester, step: 'code');
      expect(find.byType(DiffView), findsOneWidget);
      await tester.tap(number('3'));
      await tester.pumpAndSettle();
      expect(find.byType(DiffView), findsNothing);
      expect(find.byType(EditPane), findsOneWidget);
      expect(_tabs(tester).activePath, 'lib/rates.ts');
      expect(_cursorLine(tester), 3);
    });

    testWidgets('a deleted row opens on the next line that still exists', (
      tester,
    ) async {
      await _rig().pump(tester, step: 'code');
      await tester.tap(numbers('2').first);
      await tester.pumpAndSettle();
      expect(_cursorLine(tester), 2);
    });

    testWidgets('a double click on the code opens the editor too', (
      tester,
    ) async {
      await _rig().pump(tester, step: 'code');
      final at = tester.getCenter(number('3')) + const Offset(200, 0);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(find.byType(DiffView), findsNothing);
      expect(_cursorLine(tester), 3);
    });

    testWidgets('a single click on the code leaves the diff alone', (
      tester,
    ) async {
      await _rig().pump(tester, step: 'code');
      await tester.tapAt(tester.getCenter(number('3')) + const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(find.byType(DiffView), findsOneWidget);
      expect(_tabs(tester).jump, isNull);
    });

    testWidgets('hovering a row that ran says Edit here', (tester) async {
      await _rig().pump(tester, step: 'code');
      await hoverRow(tester, '2');
      expect(find.text('Edit here'), findsOneWidget);
    });

    testWidgets('hovering a line that never ran says so', (tester) async {
      await _rig().pump(tester, step: 'code');
      await hoverRow(tester, '3');
      expect(find.text('never ran · Edit here'), findsOneWidget);
    });

    testWidgets('the label goes when the pointer leaves the row', (
      tester,
    ) async {
      await _rig().pump(tester, step: 'code');
      final g = await _mouse(tester);
      await g.moveTo(tester.getCenter(number('3')) + const Offset(120, 0));
      await tester.pump();
      expect(find.byKey(const ValueKey('diff-edit-hint')), findsOneWidget);
      await g.moveTo(const Offset(1, 1));
      await tester.pump();
      expect(find.byKey(const ValueKey('diff-edit-hint')), findsNothing);
    });

    testWidgets('a deleted file has no handler and no label', (tester) async {
      await _rig().pump(tester, step: 'code');
      _container(tester)
          .read(editorTabsProvider(id).notifier)
          .open('lib/old.ts', preview: false);
      await tester.pumpAndSettle();
      final view = tester.widget<DiffView>(find.byType(DiffView));
      expect(view.file.path, 'lib/old.ts');
      expect(view.onEdit, isNull);
      await hoverRow(tester, '1');
      expect(find.byKey(const ValueKey('diff-edit-hint')), findsNothing);
      await tester.tap(number('1'));
      await tester.pumpAndSettle();
      expect(find.byType(DiffView), findsOneWidget);
      expect(_tabs(tester).jump, isNull);
    });
  });

  group('gutter proof marks', () {
    Future<CodeRig> openEdit(WidgetTester tester, CodeRig rig) async {
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      return rig;
    }

    testWidgets('a flagged row at a path and line reaches the gutter', (
      tester,
    ) async {
      await openEdit(tester, _rig(eyes: [_flagged]));
      final marks = _gutter(tester).proof;
      expect(marks.keys, [2]);
      expect(marks[2]!.single.kind, ProofMarkKind.eyes);
      expect(marks[2]!.single.text, 'NO TEST RAN · 1 line');
    });

    testWidgets('no marks without findings', (tester) async {
      await openEdit(tester, _rig());
      expect(_gutter(tester).proof, isEmpty);
    });

    testWidgets('marks are hidden while the buffer has unsaved edits', (
      tester,
    ) async {
      await openEdit(tester, _rig(eyes: [_flagged]));
      expect(_gutter(tester).proof, isNotEmpty);
      tester.widget<EditPane>(find.byType(EditPane)).buffer.controller!.text =
          'edited\n';
      await tester.pump();
      expect(_gutter(tester).proof, isEmpty);
    });

    testWidgets('a flagged row in another file does not mark this one', (
      tester,
    ) async {
      await openEdit(
        tester,
        _rig(eyes: [_row('NO TEST RAN', path: 'lib/zones.ts', line: 2)]),
      );
      expect(_gutter(tester).proof, isEmpty);
    });

    testWidgets('hovering the mark names the finding, a click opens Problems', (
      tester,
    ) async {
      await openEdit(tester, _rig(eyes: [_flagged]));
      final box = tester.getTopLeft(find.byType(EditorGutter));
      final g = await _mouse(tester);
      Offset? hit;
      for (var dy = 4.0; dy < 120 && hit == null; dy += 4) {
        final p = box + Offset(GutterMetrics.bar + 4, dy);
        await g.moveTo(p);
        await tester.pump();
        if (find
            .byKey(const ValueKey('gutter-proof-label'))
            .evaluate()
            .isNotEmpty) {
          hit = p;
        }
      }
      expect(hit, isNotNull, reason: 'a row of the gutter shows the label');
      expect(find.text('NO TEST RAN · 1 line'), findsOneWidget);
      await tester.tapAt(hit!);
      await tester.pumpAndSettle();
      expect(
        _container(tester)
            .read(bottomPanelProvider(id))
            .showing(BottomTab.problems),
        isTrue,
      );
    });
  });
}
