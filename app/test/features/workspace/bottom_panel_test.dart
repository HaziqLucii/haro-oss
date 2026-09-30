import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_detail_lazy.dart';
import 'package:haro_app/data/workspace_detail_models.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/terminal/bottom_panel.dart';
import 'package:haro_app/features/workspace/terminal/bottom_panel_provider.dart';
import 'package:haro_app/features/workspace/workspace_ui.dart';
import 'package:haro_app/main.dart' show HaroApp;

import 'harness.dart';

Finder key(String k) => find.byKey(ValueKey(k));

/// Text inside the panel only: the verify step behind it repeats the verdict copy.
Finder inPanel(String text) =>
    find.descendant(of: find.byType(BottomPanel), matching: find.text(text));

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HaroApp)));

const proofFile = VerifiedFile(
  path: 'lib/rates.ts',
  inMap: true,
  added: 6,
  executed: 4,
  unexecuted: 2,
  lines: {4: 1, 5: 0, 6: 0, 7: 2},
);

Rig rig({
  Preview preview = Preview.green,
  WorkspaceDetail? detail,
  List<VerifiedFile> files = const [proofFile],
}) {
  final r = Rig(preview, detail: detail);
  r.extra.addAll([
    workspaceVerifiedHunksProvider.overrideWith(
      (ref, id) async =>
          VerifiedHunksResponse(baseRef: 'main', supported: true, files: files),
    ),
    workspaceImpactProvider.overrideWith(
      (ref, id) async => const ImpactResponse(
        baseRef: 'main',
        supported: true,
        changedFiles: [ChangedFile(path: 'lib/rates.ts')],
        impactedTests: [
          ImpactTest(file: 'lib/rates.test.ts', name: 'a'),
          ImpactTest(file: 'lib/rates.test.ts', name: 'b'),
        ],
        impactedFiles: ['lib/rates.test.ts'],
      ),
    ),
    workspaceReceiptProvider.overrideWith((ref, id) async => null),
  ]);
  return r;
}

WorkspaceDetail withSurvivors(Preview p, List<MutationSurvivor> survivors) =>
    detailFor(p).copyWith(
      analysis: WorkspaceAnalysis(
        mutation: MutationResponse(
          baseRef: 'main',
          supported: true,
          score: 60,
          killed: 3,
          survived: survivors.length,
          survivors: survivors,
        ),
      ),
    );

void main() {
  group('bottomPanelProvider', () {
    testWidgets('show opens on the tab, toggleTab hides on the same tab', (
      tester,
    ) async {
      final r = rig();
      await r.pump(tester);
      final c = containerOf(tester);
      BottomPanelState state() => c.read(bottomPanelProvider(id));
      BottomPanelNotifier panel() => c.read(bottomPanelProvider(id).notifier);

      expect(state().open, isFalse);
      expect(key('term-tab-gate'), findsNothing);

      panel().show(BottomTab.gate);
      await tester.pumpAndSettle();
      expect(state().showing(BottomTab.gate), isTrue);
      expect(key('panel-gate'), findsOneWidget);
      expect(c.read(workspaceUiProvider).terminalOpen, isTrue);

      panel().toggleTab(BottomTab.gate);
      await tester.pumpAndSettle();
      expect(state().open, isFalse);
      expect(key('panel-gate'), findsNothing);

      panel().toggleTab(BottomTab.problems);
      await tester.pumpAndSettle();
      expect(state().showing(BottomTab.problems), isTrue);
      panel().toggleTab(BottomTab.gate);
      await tester.pumpAndSettle();
      expect(state().showing(BottomTab.gate), isTrue);

      panel().toggle();
      await tester.pumpAndSettle();
      expect(state().open, isFalse, reason: 'the ⌃` path shares the flag');
      panel().toggle();
      await tester.pumpAndSettle();
      expect(state().showing(BottomTab.gate), isTrue, reason: 'last tab kept');
    });

    testWidgets('the rail toggle and hide drive the same state', (
      tester,
    ) async {
      final r = rig();
      await r.pump(tester);
      final c = containerOf(tester);
      await tester.tap(key('rail-terminal-toggle'));
      await tester.pumpAndSettle();
      expect(
        c.read(bottomPanelProvider(id)).showing(BottomTab.terminal),
        isTrue,
      );
      await tester.tap(key('term-hide'));
      await tester.pumpAndSettle();
      expect(c.read(bottomPanelProvider(id)).open, isFalse);
    });
  });

  group('tabs', () {
    testWidgets('Dev log shows once a dev server is running', (tester) async {
      final r = rig(
        detail: detailFor(
          Preview.green,
          runs: const {'app': DevRun(running: true)},
        ),
      );
      await r.pump(tester);
      final c = containerOf(tester);
      c.read(bottomPanelProvider(id).notifier).show(BottomTab.devLog);
      await tester.pumpAndSettle();
      expect(key('term-tab-devlog'), findsOneWidget);
      expect(key('devlog-view'), findsOneWidget);
    });

    testWidgets('a Dev log pick with no dev server falls back to Terminal', (
      tester,
    ) async {
      final r = rig();
      await r.pump(tester);
      final c = containerOf(tester);
      c.read(bottomPanelProvider(id).notifier).show(BottomTab.devLog);
      await tester.pumpAndSettle();
      expect(key('term-tab-devlog'), findsNothing);
      expect(key('shell-view'), findsOneWidget);
    });

    testWidgets('Gate tab: verdict, this file, run on save and impact', (
      tester,
    ) async {
      final r = rig();
      await r.pump(tester);
      final c = containerOf(tester);
      c.read(bottomPanelProvider(id).notifier).show(BottomTab.gate);
      await tester.pumpAndSettle();

      expect(inPanel('GREEN'), findsOneWidget);
      expect(key('panel-gate-line'), findsOneWidget);
      expect(inPanel('This file: no file open'), findsOneWidget);
      expect(inPanel('Run on save is off (Settings, Gate).'), findsOneWidget);

      c.read(editorTabsProvider(id).notifier).open('lib/rates.ts');
      await tester.pumpAndSettle();
      expect(inPanel('This file: 2 added lines never ran'), findsOneWidget);
      expect(
        inPanel(
          'Run on save is off (Settings, Gate). Tests touching this change: 2.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Gate tab: a never-run line opens the file at that line', (
      tester,
    ) async {
      final r = rig(
        detail: detailFor(Preview.green).copyWith(
          diff: const DiffResponse(
            baseRef: 'main',
            filesChanged: 1,
            diff:
                'diff --git a/lib/rates.ts b/lib/rates.ts\n--- a/lib/rates.ts\n'
                '+++ b/lib/rates.ts\n@@ -3,0 +4,4 @@\n+ok\n+cold one\n+cold two\n+ok\n',
          ),
        ),
      );
      final router = await r.pump(tester);
      final c = containerOf(tester);
      c.read(bottomPanelProvider(id).notifier).show(BottomTab.gate);
      await tester.pumpAndSettle();

      final row = key('panel-spot-lib/rates.ts:5');
      expect(row, findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      final tabs = c.read(editorTabsProvider(id));
      expect(tabs.activePath, 'lib/rates.ts');
      expect(tabs.jump?.line, 5);
      expect(pathOf(router), '/w/$id/code');
    });

    testWidgets(
      'Problems: surviving mutants and needs-your-eyes rows open files',
      (tester) async {
        final r = rig(
          detail: withSurvivors(Preview.green, const [
            MutationSurvivor(
              path: 'lib/zones.ts',
              line: 22,
              operator: '>= to >',
            ),
          ]),
        );
        final router = await r.pump(tester);
        final c = containerOf(tester);
        c.read(bottomPanelProvider(id).notifier).show(BottomTab.problems);
        await tester.pumpAndSettle();

        expect(inPanel('SURVIVING MUTANTS · 1'), findsOneWidget);
        expect(inPanel('NEEDS YOUR EYES · 2'), findsOneWidget);
        expect(inPanel('zones.ts:22'), findsOneWidget);
        expect(inPanel('>= to >'), findsOneWidget);

        await tester.tap(key('problem-mutation:lib/zones.ts:22'));
        await tester.pumpAndSettle();
        final tabs = c.read(editorTabsProvider(id));
        expect(tabs.activePath, 'lib/zones.ts');
        expect(tabs.jump?.line, 22);
        expect(pathOf(router), '/w/$id/code');
      },
    );

    testWidgets('Problems: empty state is plain words, no lint or type lines', (
      tester,
    ) async {
      final r = rig(preview: Preview.idle);
      await r.pump(tester);
      final c = containerOf(tester);
      c.read(bottomPanelProvider(id).notifier).show(BottomTab.problems);
      await tester.pumpAndSettle();

      expect(key('panel-problems-empty'), findsOneWidget);
      expect(
        inPanel('Nothing to review until the gate has run.'),
        findsOneWidget,
      );
      expect(find.textContaining('mutation run'), findsOneWidget);
      expect(find.textContaining('lint'), findsNothing);
      expect(find.textContaining('type error'), findsNothing);
    });
  });
}
