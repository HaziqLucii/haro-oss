import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/features/workspace/rail/phone_shot.dart';

import '../harness.dart';

void main() {
  ProviderContainer containerWith(
    List<String> calls, {
    HaroApiException? fail,
  }) {
    final c = ProviderContainer(
      overrides: [
        workspaceActionsProvider.overrideWith(
          (ref, id) => RecordingActions(ref, id, calls, failWith: fail),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.listen(phoneShotProvider('w1'), (_, _) {});
    return c;
  }

  test('a picture bumps the revision so the image is read again', () async {
    final calls = <String>[];
    final c = containerWith(calls);
    final before = c.read(phoneShotProvider('w1')).revision;
    await c.read(phoneShotProvider('w1').notifier).take();
    expect(calls, ['tool:screenshot']);
    expect(c.read(phoneShotProvider('w1')).revision, before + 1);
    expect(c.read(phoneShotProvider('w1')).busy, isFalse);
  });

  test('takeSoon waits, then takes one picture', () async {
    final calls = <String>[];
    final c = containerWith(calls);
    final n = c.read(phoneShotProvider('w1').notifier);
    n.takeSoon(const Duration(milliseconds: 30));
    n.takeSoon(const Duration(milliseconds: 30));
    expect(calls, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(calls, ['tool:screenshot']);
  });

  test(
    'a quiet picture that fails says nothing; a manual one says why',
    () async {
      final calls = <String>[];
      final c = containerWith(
        calls,
        fail: const HaroApiException(404, 'no tool'),
      );
      final n = c.read(phoneShotProvider('w1').notifier);
      await n.take(quiet: true);
      expect(c.read(phoneShotProvider('w1')).error, isNull);
      await n.take();
      expect(
        c.read(phoneShotProvider('w1')).error,
        'No screenshot tool: declare [scripts.tools.screenshot] in .haro/settings.toml',
      );
    },
  );

  test(
    'a picture asked for while one is being taken is taken right after',
    () async {
      final calls = <String>[];
      final c = containerWith(calls);
      final n = c.read(phoneShotProvider('w1').notifier);
      final first = n.take();
      await n.take(quiet: true);
      await first;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, ['tool:screenshot', 'tool:screenshot']);
      expect(c.read(phoneShotProvider('w1')).busy, isFalse);
    },
  );

  test('a reopened card does not repeat an image-cache number', () {
    final a = containerWith(<String>[]).read(phoneShotProvider('w1')).revision;
    expect(a, greaterThan(1000000000000));
  });
}
