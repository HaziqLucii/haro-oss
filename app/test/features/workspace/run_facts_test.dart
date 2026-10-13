import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/rail/run_facts.dart';

AgentEvent ev(String type, Map<String, dynamic> payload) => AgentEvent(
  runId: 'r',
  workspaceId: 'w',
  ts: 1,
  type: AgentEventType.parse(type),
  payload: payload,
);

void main() {
  test('nothing in the transcript, nothing to show', () {
    expect(deriveRunFacts(const []).isEmpty, isTrue);
  });

  test('model, effort, summed spend, duration and context', () {
    final f = deriveRunFacts([
      ev('token', {
        'system': true,
        'model': 'claude-sonnet-5',
        'effort': 'high',
      }),
      ev('done', {
        'cost_usd': 4.5,
        'context_tokens': 20000,
        'context_window': 200000,
      }),
      ev('done', {
        'cost_usd': 5.39,
        'context_tokens': 42000,
        'context_window': 200000,
      }),
    ], elapsed: const Duration(minutes: 14));
    expect(f.modelLine, 'sonnet-5, high');
    expect(f.spentUsd, closeTo(9.89, 1e-9));
    expect(f.duration, const Duration(minutes: 14));
    expect(f.contextFraction, closeTo(.21, 1e-9));
  });

  test('a 1m model without a reported window uses the long window', () {
    final f = deriveRunFacts([
      ev('token', {'model': 'claude-x[1m]'}),
      ev('done', {'context_tokens': 100000}),
    ]);
    expect(f.contextFraction, closeTo(.1, 1e-9));
  });

  group('contextUsage', () {
    test('the newest run, with the window the run reported', () {
      final u = contextUsage([
        ev('done', {'context_tokens': 100000, 'context_window': 200000}),
        ev('done', {'context_tokens': 170000, 'context_window': 200000}),
      ])!;
      expect((u.tokens, u.window, u.percent), (170000, 200000, 85));
    });

    test('a 1m model without a reported window falls back to 1M', () {
      final u = contextUsage([
        ev('token', {'system': true, 'model': 'claude-sonnet-5[1m]'}),
        ev('done', {'context_tokens': 500000}),
      ])!;
      expect(u.window, 1000000);
    });

    test('a clear after the run empties it, the next run counts again', () {
      final cleared = [
        ev('done', {'context_tokens': 190000, 'context_window': 200000}),
        ev('context_cleared', const {}),
      ];
      expect(contextUsage(cleared), isNull);
      expect(deriveRunFacts(cleared).contextFraction, isNull);
      final after = [
        ...cleared,
        ev('done', {'context_tokens': 20000, 'context_window': 200000}),
      ];
      expect(contextUsage(after)!.percent, 10);
    });
  });

  group('tokens', () {
    test('summed over the finished runs, even when nothing was priced', () {
      final f = deriveRunFacts([
        ev('done', {'tokens_in': 1200, 'tokens_out': 300, 'cost_usd': null}),
        ev('done', {'tokens_in': 800, 'tokens_out': 200}),
      ]);
      expect((f.tokensIn, f.tokensOut), (2000, 500));
      expect(f.spentUsd, isNull);
      expect(f.isEmpty, isFalse);
    });

    test('none reported, or all zero, shows no row', () {
      expect(deriveRunFacts([ev('done', {})]).tokensIn, isNull);
      final zero = deriveRunFacts([
        ev('done', {'tokens_in': 0, 'tokens_out': 0}),
      ]);
      expect((zero.tokensIn, zero.tokensOut), (null, null));
    });
  });
}
