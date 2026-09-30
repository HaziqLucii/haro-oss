import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/workspace/steps/code/run_on_save.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../../../state/builders.dart' as builders;
import '../../harness.dart';

class _Actions extends WorkspaceActions {
  _Actions(super.ref, super.workspaceId, this.runs, {this.fail});

  final List<bool> runs;
  final HaroApiException? fail;

  @override
  Future<TestRun> runGate({
    bool impacted = false,
    bool failedOnly = false,
  }) async {
    runs.add(impacted);
    if (fail != null) throw fail!;
    return builders.run();
  }
}

class _Rig {
  _Rig({
    Preview preview = Preview.green,
    this.live,
    GateConfig? loaded,
    bool getFails = false,
    HaroApiException? fail,
  }) {
    final detail = detailFor(preview)
        .copyWith(gateConfig: loaded ?? const GateConfig());
    container = ProviderContainer(
      overrides: [
        workspaceDetailProvider.overrideWith2(
          (wsId) => FixedDetail(wsId, detail),
        ),
        workspaceActionsProvider.overrideWith(
          (ref, wsId) => _Actions(ref, wsId, runs, fail: fail),
        ),
        haroApiProvider.overrideWithValue(
          HaroApi(
            Uri.parse('http://127.0.0.1:8000'),
            client: MockClient((http.Request r) async {
              gets++;
              if (getFails || live == null) {
                return http.Response('{"detail":"down"}', 500);
              }
              return http.Response(
                jsonEncode(live!.toJson()),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        ),
      ],
    );
  }

  final GateConfig? live;
  late final ProviderContainer container;
  final runs = <bool>[];
  int gets = 0;

  Future<String?> save() => container.read(runOnSaveProvider(id)).run();
}

void main() {
  test('off by default: a save starts nothing', () async {
    final r = _Rig(live: const GateConfig());
    addTearDown(r.container.dispose);
    expect(r.container.read(runOnSaveEnabledProvider(id)), isFalse);
    expect(await r.save(), isNull);
    expect(r.runs, isEmpty);
  });

  test('on: a save runs the gate, full scope by default', () async {
    final r = _Rig(
      loaded: const GateConfig(runOnSave: true),
      live: const GateConfig(runOnSave: true),
    );
    addTearDown(r.container.dispose);
    expect(r.container.read(runOnSaveEnabledProvider(id)), isTrue);
    expect(await r.save(), isNull);
    expect(r.runs, [false]);
  });

  test('on with an impacted default scope runs the impacted gate', () async {
    final cfg = const GateConfig(runOnSave: true, defaultScope: 'impacted');
    final r = _Rig(loaded: cfg, live: cfg);
    addTearDown(r.container.dispose);
    await r.save();
    expect(r.runs, [true]);
  });

  test('the live setting wins over the value the workspace loaded', () async {
    final turnedOn = _Rig(live: const GateConfig(runOnSave: true));
    addTearDown(turnedOn.container.dispose);
    await turnedOn.save();
    expect(turnedOn.runs, [
      false,
    ], reason: 'switched on in Settings since load');

    final turnedOff = _Rig(
      loaded: const GateConfig(runOnSave: true),
      live: const GateConfig(),
    );
    addTearDown(turnedOff.container.dispose);
    await turnedOff.save();
    expect(turnedOff.runs, isEmpty, reason: 'switched off in Settings');
  });

  test('an unreachable config falls back to the loaded value', () async {
    final r = _Rig(loaded: const GateConfig(runOnSave: true), getFails: true);
    addTearDown(r.container.dispose);
    await r.save();
    expect(r.runs, [false]);
  });

  test('skips while a gate or an agent is already running', () async {
    for (final p in [Preview.running]) {
      final r = _Rig(preview: p, live: const GateConfig(runOnSave: true));
      addTearDown(r.container.dispose);
      expect(await r.save(), isNull);
      expect(r.runs, isEmpty);
      expect(r.gets, 0, reason: 'no request when there is nothing to do');
    }
  });

  test('skips a merged workspace', () async {
    final r = _Rig(
      preview: Preview.merged,
      live: const GateConfig(runOnSave: true),
    );
    addTearDown(r.container.dispose);
    expect(await r.save(), isNull);
    expect(r.runs, isEmpty);
  });

  test('a failed run comes back as a message for the caller', () async {
    final r = _Rig(
      live: const GateConfig(runOnSave: true),
      fail: HaroApiException(409, 'an agent is running'),
    );
    addTearDown(r.container.dispose);
    expect(await r.save(), 'an agent is running');
  });
}
