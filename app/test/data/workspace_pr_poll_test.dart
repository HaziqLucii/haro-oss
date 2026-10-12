import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_detail_lazy.dart';
import 'package:haro_app/data/workspace_store.dart';

import '../features/workspace/harness.dart' show FixedDetail;
import 'pr_poll_api.dart';

const _ws = 'ws_1';
const _interval = Duration(seconds: 5);

PrStatusResponse _pr({String state = 'OPEN', bool merged = false}) =>
    PrStatusResponse(
      supported: true,
      exists: true,
      number: 7,
      state: state,
      workspaceMerged: merged,
    );

class _Rig {
  _Rig(List<Object> replies) : api = PrPollApi(replies) {
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        haroApiProvider.overrideWithValue(api),
        prPollIntervalProvider.overrideWithValue(_interval),
        appInForegroundProvider.overrideWithValue(() => foreground),
        workspaceDetailProvider.overrideWith2(
          (id) => FixedDetail(id, WorkspaceDetail(id: id)),
        ),
      ],
    );
  }

  final PrPollApi api;
  late final ProviderContainer container;
  bool foreground = true;
  ProviderSubscription<AsyncValue<PrStatusResponse>>? _sub;

  AsyncValue<PrStatusResponse> get value =>
      container.read(workspacePrProvider(_ws));

  Future<void> watch(WidgetTester tester) async {
    _sub = container.listen(workspacePrProvider(_ws), (_, _) {});
    await tester.pump();
  }

  Future<void> leave(WidgetTester tester) async {
    _sub?.close();
    _sub = null;
    await tester.pump();
  }

  Future<void> elapse(WidgetTester tester, Duration d) => tester.pump(d);

  Future<void> close(WidgetTester tester) async {
    await leave(tester);
    container.dispose();
  }
}

void main() {
  testWidgets('an open PR is re-read every interval until it is merged', (
    tester,
  ) async {
    final rig = _Rig([_pr(), _pr(), _pr(state: 'MERGED', merged: true)]);
    await rig.watch(tester);
    expect(rig.api.calls, 1);
    expect(rig.value.value!.workspaceMerged, isFalse);

    await rig.elapse(tester, _interval);
    expect(rig.api.calls, 2);
    expect(rig.value.value!.workspaceMerged, isFalse);

    await rig.elapse(tester, _interval);
    expect(rig.api.calls, 3);
    expect(rig.value.value!.workspaceMerged, isTrue);

    await rig.elapse(tester, _interval * 4);
    expect(rig.api.calls, 3);
    await rig.close(tester);
  });

  testWidgets('the previous value stays visible while a poll is in flight', (
    tester,
  ) async {
    final rig = _Rig([_pr(), _pr()]);
    await rig.watch(tester);
    rig.container.invalidate(workspacePrProvider(_ws));
    final during = rig.value;
    expect(during.isLoading, isTrue);
    expect(during.value?.number, 7);
    await tester.pump();
    await rig.close(tester);
  });

  for (final c in <String, PrStatusResponse>{
    'no PR': const PrStatusResponse(supported: true),
    'unsupported': const PrStatusResponse(),
    'merged': _pr(state: 'MERGED', merged: true),
    'merged state without a workspace verdict': _pr(state: 'MERGED'),
    'closed': _pr(state: 'CLOSED'),
  }.entries) {
    testWidgets('no poll when there is ${c.key}', (tester) async {
      final rig = _Rig([c.value]);
      await rig.watch(tester);
      await rig.elapse(tester, _interval * 5);
      expect(rig.api.calls, 1);
      await rig.close(tester);
    });
  }

  testWidgets('no poll after a failed load, and no retry loop', (tester) async {
    final rig = _Rig([const HaroApiException(500, 'boom')]);
    await rig.watch(tester);
    expect(rig.value.hasError, isTrue);
    await rig.elapse(tester, _interval * 5);
    expect(rig.api.calls, 1);
    await rig.close(tester);
  });

  testWidgets('a failed re-read keeps the last good value and stops polling', (
    tester,
  ) async {
    final rig = _Rig([_pr(), const HaroApiException(500, 'boom')]);
    await rig.watch(tester);
    await rig.elapse(tester, _interval);
    expect(rig.api.calls, 2);
    expect(rig.value.hasError, isTrue);
    expect(rig.value.value?.number, 7);
    expect(rig.value.value?.workspaceMerged, isFalse);

    await rig.elapse(tester, _interval * 4);
    expect(rig.api.calls, 2);
    await rig.close(tester);
  });

  testWidgets('leaving the step cancels the timer', (tester) async {
    final rig = _Rig([_pr()]);
    await rig.watch(tester);
    await rig.leave(tester);
    await rig.elapse(tester, _interval * 4);
    expect(rig.api.calls, 1);
    rig.container.dispose();
  });

  testWidgets('a tick is skipped while backgrounded and resumes after', (
    tester,
  ) async {
    final rig = _Rig([_pr(), _pr()]);
    await rig.watch(tester);
    rig.foreground = false;
    await rig.elapse(tester, _interval * 3);
    expect(rig.api.calls, 1);

    rig.foreground = true;
    await rig.elapse(tester, _interval);
    expect(rig.api.calls, 2);
    await rig.close(tester);
  });

  testWidgets('foreground check reads the app lifecycle', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final inForeground = container.read(appInForegroundProvider);
    for (final s in [
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
      expect(inForeground(), isFalse, reason: '$s');
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(inForeground(), isTrue);
  });
}
