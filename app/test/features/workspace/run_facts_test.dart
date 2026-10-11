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
    expect(f.modelLine, 'sonnet-5 · high');
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
}
