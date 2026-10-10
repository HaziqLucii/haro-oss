import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/xp_store.dart';
import 'package:haro_app/features/workspace/steps/code/diff_model.dart';
import 'package:haro_app/features/workspace/steps/code/diff_view.dart';
import 'package:haro_app/features/workspace/steps/verify/files_viewed.dart';
import 'package:haro_app/features/workspace/steps/verify/review_record.dart';
import 'package:haro_app/widgets/haro_button.dart';

import '../../../../state/builders.dart';
import '../../harness.dart';
import 'verify_harness.dart';

const mainJs = 'desktop/main.js';
const stream = 'frontend/src/components/AgentStream.tsx';

class _Xp extends XpReporter {
  _Xp() : super(() => throw StateError('no backend in this test'));

  final reported = <List<String>>[];

  @override
  void diffReviewed(String workspaceId, Iterable<String> paths) =>
      reported.add(paths.toList()..sort());
}

class RecReporter extends ReviewRecordReporter {
  RecReporter() : super(() => throw StateError('no backend in this test'));

  final sent = <List<({String path, double seconds})>>[];

  @override
  void report(
    String workspaceId,
    List<DiffFile> files,
    Map<String, String> marks,
    double? Function(String path) secondsFor,
  ) => sent.add(viewedRecord(files, marks, secondsFor));
}

late RecReporter rec;

Future<(VerifyRig, _Xp)> pump(
  WidgetTester tester, {
  Map<String, String>? marks,
}) async {
  final d = verifyDetail(
    WorkspaceStatus.gateGreen,
    run: greenRun(),
    cells: cells(594),
  );
  final rig = VerifyRig(Preview.green, state: d, hunks: sampleHunks());
  if (marks != null) {
    rig.prefs.data = {
      'files_viewed': {
        id: {'at': 1, 'marks': marks},
      },
    };
  }
  final xp = _Xp();
  rig.extra.add(xpReporterProvider.overrideWithValue(xp));
  rec = RecReporter();
  rig.extra.add(reviewRecordReporterProvider.overrideWithValue(rec));
  rig.router = await rig.pump(tester);
  return (rig, xp);
}

Map<String, String> signatures() => {
  for (final f in parseUnifiedDiff(sampleDiff)) f.path: fileSignature(f),
};

HaroButtonVariant proceedVariant(WidgetTester tester) => tester
    .widget<HaroButton>(find.byKey(const ValueKey('next-action')))
    .variant;

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists every changed file collapsed, none viewed', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('file-card-$mainJs')), findsOneWidget);
    expect(find.byKey(const ValueKey('file-card-$stream')), findsOneWidget);
    expect(find.byType(DiffView), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('files-progress'))).data,
      '0 / 2 viewed',
    );
  });

  testWidgets('files with lines that never ran come first, then by path', (
    tester,
  ) async {
    await pump(tester);
    final a = tester.getTopLeft(
      find.byKey(const ValueKey('file-card-$mainJs')),
    );
    final b = tester.getTopLeft(
      find.byKey(const ValueKey('file-card-$stream')),
    );
    expect(a.dy, lessThan(b.dy));
  });

  testWidgets('a file opens on its head, and Expand all opens the rest', (
    tester,
  ) async {
    await pump(tester);
    await tapKey(tester, 'file-head-$mainJs');
    expect(find.byType(DiffView), findsOneWidget);
    await tapKey(tester, 'files-expand-all');
    expect(find.byType(DiffView), findsNWidgets(2));
    await tapKey(tester, 'files-expand-all');
    expect(find.byType(DiffView), findsNothing);
  });

  testWidgets('Viewed folds the file and is stored on the device', (
    tester,
  ) async {
    final (rig, _) = await pump(tester);
    await tapKey(tester, 'file-head-$mainJs');
    await tapKey(tester, 'viewed-$mainJs');
    expect(find.byType(DiffView), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('files-progress'))).data,
      '1 / 2 viewed',
    );
    final stored = rig.prefs.data['files_viewed'] as Map;
    expect(((stored[id] as Map)['marks'] as Map).keys, [mainJs]);
    await tapKey(tester, 'viewed-$mainJs');
    expect(rig.prefs.data['files_viewed'], isEmpty);
  });

  testWidgets('Proceed to ship waits for every file, then reports the review', (
    tester,
  ) async {
    final (_, xp) = await pump(tester);
    expect(proceedVariant(tester), HaroButtonVariant.tertiary);
    await tapKey(tester, 'viewed-$mainJs');
    expect(proceedVariant(tester), HaroButtonVariant.tertiary);
    expect(xp.reported, isEmpty);
    await tapKey(tester, 'viewed-$stream');
    expect(proceedVariant(tester), HaroButtonVariant.primary);
    expect(xp.reported, [
      [mainJs, stream],
    ]);
  });

  testWidgets('marks saved earlier count when the file is unchanged', (
    tester,
  ) async {
    await pump(tester, marks: signatures());
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('files-progress'))).data,
      '2 / 2 viewed',
    );
    expect(proceedVariant(tester), HaroButtonVariant.primary);
  });

  testWidgets('a file that changed since it was viewed is not viewed', (
    tester,
  ) async {
    await pump(tester, marks: {...signatures(), mainJs: 'stale'});
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('files-progress'))).data,
      '1 / 2 viewed',
    );
    expect(proceedVariant(tester), HaroButtonVariant.tertiary);
  });

  testWidgets('marks restored from the device report the review too', (
    tester,
  ) async {
    final (_, xp) = await pump(tester, marks: signatures());
    expect(xp.reported, [
      [mainJs, stream],
    ]);
  });

  testWidgets('a mark added keeps the ones already saved', (tester) async {
    final sigs = signatures();
    final (rig, _) = await pump(
      tester,
      marks: {'gone.ts': 'x', mainJs: sigs[mainJs]!},
    );
    await tapKey(tester, 'viewed-$stream');
    final stored = rig.prefs.data['files_viewed'] as Map;
    expect(((stored[id] as Map)['marks'] as Map).keys.toSet(), {
      'gone.ts',
      mainJs,
      stream,
    });
  });

  testWidgets('ticking Viewed reports the file with how long it was open', (
    tester,
  ) async {
    final (rig, _) = await pump(tester);
    await tapKey(tester, 'file-head-$mainJs');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    await tapKey(tester, 'viewed-$mainJs');
    await tapKey(tester, 'viewed-$stream');
    expect(rec.sent, hasLength(2));
    expect(rec.sent.first.single.path, mainJs);
    expect(rec.sent.first.single.seconds, greaterThanOrEqualTo(1));
    final both = {for (final v in rec.sent.last) v.path: v.seconds};
    expect(both.keys.toSet(), {mainJs, stream});
    expect(both[stream], 0);
    final stored = ((rig.prefs.data['files_viewed'] as Map)[id] as Map);
    expect((stored['seconds'] as Map).keys.toSet(), {mainJs, stream});
  });

  testWidgets('a mark from before seconds were kept is not reported', (
    tester,
  ) async {
    final sigs = signatures();
    await pump(tester, marks: {mainJs: sigs[mainJs]!});
    await tapKey(tester, 'viewed-$stream');
    expect(rec.sent.first, isEmpty);
    expect(rec.sent.last.map((v) => v.path), [stream]);
  });

  testWidgets('marks restored from disk are reported without a tap', (
    tester,
  ) async {
    final sigs = signatures();
    final d = verifyDetail(
      WorkspaceStatus.gateGreen,
      run: greenRun(),
      cells: cells(594),
    );
    final r = VerifyRig(Preview.green, state: d, hunks: sampleHunks());
    r.prefs.data = {
      'files_viewed': {
        id: {
          'at': 1,
          'marks': {mainJs: sigs[mainJs]!},
          'seconds': {mainJs: 42.0},
        },
      },
    };
    rec = RecReporter();
    r.extra.add(reviewRecordReporterProvider.overrideWithValue(rec));
    r.extra.add(xpReporterProvider.overrideWithValue(_Xp()));
    r.router = await r.pump(tester);
    await tester.pumpAndSettle();
    expect(rec.sent, hasLength(1));
    expect(rec.sent.single.single.path, mainJs);
    expect(rec.sent.single.single.seconds, 42);
  });
}
