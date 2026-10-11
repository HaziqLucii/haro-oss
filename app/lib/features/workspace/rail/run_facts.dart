import 'package:flutter/foundation.dart';

import '../../../api/models/models.dart';

const _defaultWindow = 200000;
const _longWindow = 1000000;

/// What the rail's Run section shows, read off the transcript. Every field is null when the
/// transcript has nothing for it, and the rail omits that row.
@immutable
class RunFacts {
  const RunFacts({
    this.model,
    this.effort,
    this.spentUsd,
    this.duration,
    this.contextFraction,
  });

  static const none = RunFacts();

  /// `fable-5-1`: the adapter's model id without the `claude-` prefix.
  final String? model;
  final String? effort;

  /// Summed over every finished run in the workspace.
  final double? spentUsd;

  /// Live elapsed while a run is going, else the last finished run's duration.
  final Duration? duration;

  /// 0 to 1: how full the model's context window was at the end of the last run.
  final double? contextFraction;

  bool get isEmpty =>
      model == null &&
      spentUsd == null &&
      duration == null &&
      contextFraction == null;

  String? get modelLine {
    final m = model;
    if (m == null) return null;
    return effort == null || effort!.isEmpty ? m : '$m · $effort';
  }

  @override
  bool operator ==(Object other) =>
      other is RunFacts &&
      other.model == model &&
      other.effort == effort &&
      other.spentUsd == spentUsd &&
      other.duration == duration &&
      other.contextFraction == contextFraction;

  @override
  int get hashCode =>
      Object.hash(model, effort, spentUsd, duration, contextFraction);
}

String shortModel(String id) => id.startsWith('claude-') ? id.substring(7) : id;

RunFacts deriveRunFacts(List<AgentEvent> events, {Duration? elapsed}) {
  String? model;
  String? effort;
  double? spent;
  AgentEvent? snapshot;

  for (var i = events.length - 1; i >= 0; i--) {
    final e = events[i];
    if (model == null && e.type == AgentEventType.token) {
      final m = e.payload['model'];
      if (m is String && m.isNotEmpty) {
        model = m;
        final ef = e.payload['effort'];
        if (ef is String && ef.isNotEmpty) effort = ef;
      }
    }
    if (snapshot == null &&
        (e.type == AgentEventType.done || e.type == AgentEventType.error) &&
        e.payload['context_tokens'] is num) {
      snapshot = e;
    }
    if (model != null && snapshot != null) break;
  }

  double? context;
  if (snapshot != null) {
    final used = snapshot.payload['context_tokens'] as num;
    final w = snapshot.payload['context_window'];
    final window = w is num && w > 0
        ? w.toDouble()
        : (RegExp('1m', caseSensitive: false).hasMatch(model ?? '')
                  ? _longWindow
                  : _defaultWindow)
              .toDouble();
    context = (used / window).clamp(0.0, 1.0).toDouble();
  }

  for (final e in events) {
    if (e.type != AgentEventType.done) continue;
    final c = e.payload['cost_usd'];
    if (c is num) spent = (spent ?? 0) + c;
  }

  return RunFacts(
    model: model == null ? null : shortModel(model),
    effort: effort,
    spentUsd: spent,
    duration: elapsed,
    contextFraction: context,
  );
}
