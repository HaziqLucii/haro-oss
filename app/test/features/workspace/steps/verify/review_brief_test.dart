import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/verify/review_brief.dart'
    show reviewMeterHelp, reviewStudyFact;

import '../../../../state/builders.dart';
import '../../harness.dart';
import '../agent/agent_events.dart';
import 'verify_harness.dart';

String unified(Map<String, int> adds) {
  final b = StringBuffer();
  adds.forEach((path, n) {
    b.writeln('diff --git a/$path b/$path');
    b.writeln('--- a/$path');
    b.writeln('+++ b/$path');
    b.writeln('@@ -1,1 +1,${n + 1} @@');
    b.writeln(' keep');
    for (var i = 0; i < n; i++) {
      b.writeln('+line $i');
    }
  });
  return b.toString();
}

Future<VerifyRig> pump(
  WidgetTester tester, {
  Map<String, int>? files,
  List<AgentEvent> events = const [],
  ReceiptScope? scope,
  List<ReceiptNewDependency> deps = const [],
}) async {
  var d = verifyDetail(
    WorkspaceStatus.gateGreen,
    run: greenRun(),
    cells: cells(594),
  ).copyWith(events: events);
  if (files != null) {
    d = d.copyWith(
      diff: DiffResponse(
        baseRef: 'origin/main',
        diff: unified(files),
        filesChanged: files.length,
      ),
    );
  }
  final rig = VerifyRig(
    Preview.green,
    state: d,
    receipt: scope == null && deps.isEmpty
        ? null
        : ReceiptResponse(
            receipt: Receipt(
              workspaceId: id,
              scope: scope ?? const ReceiptScope(),
              newDependencies: deps,
            ),
            markdown: '',
          ),
  );
  rig.router = await rig.pump(tester);
  return rig;
}

Finder key(String k) => find.byKey(ValueKey(k));

String text(WidgetTester t, String k) => t.widget<Text>(key(k)).data!;

void main() {
  testWidgets(
    'the overview shows the task, follow-ups, the fence and the size',
    (tester) async {
      await pump(
        tester,
        events: [
          userEv('Add a maxWords option to slugify and tests for it.'),
          userEv('also the route', turn: 2),
          userEv('and the readme', turn: 3),
        ],
        scope: const ReceiptScope(
          patterns: ['lib/', 'app/api/'],
          fencedRuns: 2,
          editingRuns: 3,
          blocked: ['docs/b.md'],
          reverted: ['x.ts', 'y.ts'],
        ),
      );
      expect(key('review-brief'), findsOneWidget);
      expect(find.text('OVERVIEW'), findsOneWidget);
      expect(
        text(tester, 'brief-intent'),
        'Add a maxWords option to slugify and tests for it.',
      );
      expect(text(tester, 'brief-followups'), '+2 follow-ups');
      expect(text(tester, 'brief-fence-paths'), 'lib/  ·  app/api/');
      expect(
        text(tester, 'brief-fence-facts'),
        '2 of 3 runs fenced · 1 edit refused before the write · 2 reverted after the run',
      );
      expect(
        text(tester, 'brief-fence-bound'),
        'The fence covers files. Commands and network are not restricted.',
      );
      expect(
        text(tester, 'brief-size'),
        startsWith('3 changed lines in 2 files'),
      );
      expect(key('brief-meter'), findsOneWidget);
    },
  );

  testWidgets('an unfenced run says so, with the same bound', (tester) async {
    await pump(
      tester,
      events: [userEv('do it')],
      scope: const ReceiptScope(editingRuns: 1),
    );
    expect(
      text(tester, 'brief-fence-none'),
      'Not fenced: the agent could change any file.',
    );
    expect(key('brief-fence-bound'), findsOneWidget);
    expect(key('brief-fence-facts'), findsNothing);
  });

  testWidgets('a workspace nobody ran an agent in has no intent or fence row', (
    tester,
  ) async {
    await pump(tester);
    expect(key('review-brief'), findsOneWidget);
    expect(key('brief-intent'), findsNothing);
    expect(key('brief-fence-bound'), findsNothing);
    expect(key('brief-size'), findsOneWidget);
  });

  testWidgets('past 400 lines the size row suggests fencing the next run', (
    tester,
  ) async {
    await pump(
      tester,
      files: {'lib/big.ts': 450, 'yarn.lock': 900},
      events: [userEv('rewrite it')],
      scope: const ReceiptScope(editingRuns: 1),
    );
    expect(
      text(tester, 'brief-size'),
      '450 changed lines in 1 file \u00b7 1 file not counted (generated, lock, binary or renamed)',
    );
    expect(
      text(tester, 'brief-size-time'),
      'About 1.2 h if you read 400 lines an hour.',
    );
    expect(text(tester, 'brief-size-fact'), reviewStudyFact);
    expect(text(tester, 'brief-size-fact-tag'), 'FUN FACT');
    expect(key('brief-size-nudge'), findsOneWidget);
  });

  testWidgets('a small diff has no nudge', (tester) async {
    await pump(tester, files: {'lib/small.ts': 20});
    expect(key('brief-size-nudge'), findsNothing);
    expect(text(tester, 'brief-size-time'), startsWith('About 5 min'));
  });

  testWidgets(
    'the study is named, dated and bounded, and says nothing about this diff',
    (tester) async {
      await pump(tester, files: {'lib/small.ts': 20});
      final fact = text(tester, 'brief-size-fact');
      expect(fact, contains('Cisco'));
      expect(fact, contains('2,500'));
      expect(fact, contains('2006'));
      expect(fact, contains('before AI wrote code'));
      expect(fact, contains('rule of thumb'));
      expect(fact, contains("one team's data"));
      for (final word in ['proves', 'safe', 'verified', 'good']) {
        expect(fact.toLowerCase(), isNot(contains(word)));
      }
    },
  );

  testWidgets('nothing to read, no fact', (tester) async {
    await pump(tester, files: {'yarn.lock': 900});
    expect(text(tester, 'brief-size-time'), 'Nothing to read.');
    expect(key('brief-size-fact'), findsNothing);
    expect(key('brief-size-fact-tag'), findsNothing);
  });

  testWidgets(
    'files are listed boundary first and generated last, with their badges',
    (tester) async {
      await pump(
        tester,
        files: {
          'yarn.lock': 5,
          'lib/a.ts': 5,
          'package.json': 2,
          'lib/a.test.ts': 4,
          '.github/workflows/ci.yml': 1,
        },
      );
      double y(String p) => tester.getTopLeft(key('file-card-$p')).dy;
      expect(y('.github/workflows/ci.yml'), lessThan(y('package.json')));
      expect(y('package.json'), lessThan(y('lib/a.test.ts')));
      expect(y('lib/a.test.ts'), lessThan(y('lib/a.ts')));
      expect(y('lib/a.ts'), lessThan(y('yarn.lock')));
      expect(key('file-badge-package.json-DEPENDENCIES'), findsOneWidget);
      expect(key('file-badge-.github/workflows/ci.yml-CI'), findsOneWidget);
      expect(key('file-badge-yarn.lock-GENERATED'), findsOneWidget);
      expect(key('file-badge-lib/a.test.ts-TEST'), findsOneWidget);
      expect(key('file-badge-lib/a.ts-TEST'), findsNothing);
    },
  );

  testWidgets('partly fenced work says so, above the paths', (tester) async {
    await pump(
      tester,
      events: [userEv('x')],
      scope: const ReceiptScope(
        patterns: ['src/a.ts'],
        fencedRuns: 1,
        editingRuns: 3,
      ),
    );
    expect(
      text(tester, 'brief-fence-partial'),
      'Only part of this work was fenced: 2 runs had no fence.',
    );
    expect(text(tester, 'brief-fence-paths'), 'src/a.ts');
  });

  testWidgets(
    'no editing run means no fence row and no fence advice, even with a long diff',
    (tester) async {
      await pump(
        tester,
        files: {'lib/big.ts': 600},
        events: [userEv('what would you change?')],
        scope: const ReceiptScope(),
      );
      expect(key('brief-fence-bound'), findsNothing);
      expect(key('brief-fence-none'), findsNothing);
      expect(key('brief-size-nudge'), findsNothing);
      expect(key('brief-size'), findsOneWidget);
    },
  );

  testWidgets(
    'a receipt that did not load shows an unknown fence, not a missing one',
    (tester) async {
      await pump(tester, events: [userEv('x')]);
      expect(
        text(tester, 'brief-fence-unknown'),
        'Unknown: the receipt did not load.',
      );
    },
  );

  testWidgets('a single changed line reads as one line', (tester) async {
    await pump(tester, files: {'lib/a.ts': 1});
    expect(text(tester, 'brief-size'), '1 changed line in 1 file');
  });

  testWidgets('new manifest names are listed with what was not checked', (
    tester,
  ) async {
    await pump(
      tester,
      deps: const [
        ReceiptNewDependency(
          path: 'package.json',
          names: ['left-padd', 'tinycolor3'],
        ),
      ],
    );
    expect(
      text(tester, 'brief-deps-package.json'),
      'package.json: left-padd, tinycolor3',
    );
    final bound = text(tester, 'brief-deps-bound');
    expect(bound, contains('No registry was checked'));
    for (final word in ['malicious', 'hallucinated', 'safe']) {
      expect(bound.toLowerCase(), isNot(contains(word)));
    }
  });

  testWidgets('no new names, no row', (tester) async {
    await pump(tester);
    expect(key('brief-deps-bound'), findsNothing);
    expect(find.text('NEW DEPS'), findsNothing);
  });

  testWidgets('hovering the meter explains it in plain words', (tester) async {
    await pump(tester, files: {'lib/small.ts': 20});
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(key('brief-meter')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(reviewMeterHelp), findsOneWidget);
    expect(reviewMeterHelp, contains('full is 1,000 lines'));
    expect(reviewMeterHelp, contains('100 and 400 lines'));
    expect(reviewMeterHelp, contains("doesn't mean the code is bad"));
    expect(reviewMeterHelp, isNot(contains('—')));
  });
}
