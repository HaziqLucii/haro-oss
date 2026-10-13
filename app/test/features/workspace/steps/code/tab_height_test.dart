import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart'
    show codeEditorHighlighting;
import 'package:haro_app/features/workspace/steps/code/editor/tab_strip.dart';

import 'code_harness.dart';

void main() {
  setUpAll(() => codeEditorHighlighting = false);

  testWidgets('a file tab fills the strip, border to border', (tester) async {
    final rig = CodeRig(
      tree: [file('lib/rates.ts'), file('README.md')],
      files: {
        'lib/rates.ts': const FileContent(
          path: 'lib/rates.ts',
          content: 'export const rate = 1;\n',
        ),
      },
    );
    await rig.pump(tester, step: 'code');
    await tester.tap(find.byKey(const ValueKey('tree-row:lib/rates.ts')));
    await tester.pumpAndSettle();
    final strip = tester.getRect(find.byType(TabStrip));
    final tab = tester.getRect(find.byKey(const ValueKey('tab:lib/rates.ts')));
    expect(tab.top, strip.top);
    // the strip draws a 1px rule under itself; the tab stops at it
    expect(tab.bottom, strip.bottom - 1);
  });

  testWidgets('several tabs all take the full strip height', (tester) async {
    final rig = CodeRig(
      tree: [file('lib/rates.ts'), file('README.md')],
      files: {
        'lib/rates.ts': const FileContent(path: 'lib/rates.ts', content: 'a\n'),
        'README.md': const FileContent(path: 'README.md', content: '# haro\n'),
      },
    );
    await rig.pump(tester, step: 'code');
    await tester.tap(find.byKey(const ValueKey('tree-row:lib/rates.ts')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tree-row:README.md')));
    await tester.pumpAndSettle();
    final strip = tester.getRect(find.byType(TabStrip));
    for (final t in tester.widgetList(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey &&
            '${(w.key as ValueKey).value}'.startsWith('tab:'),
      ),
    )) {
      final r = tester.getRect(find.byWidget(t));
      expect(r.height, strip.height - 1);
    }
  });
}
