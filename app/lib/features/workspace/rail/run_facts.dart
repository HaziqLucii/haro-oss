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
    this.tokensIn,
    this.tokensOut,
    this.duration,
    this.contextFraction,
  });

  static const none = RunFacts();

  /// `fable-5-1`: the adapter's model id without the `claude-` prefix.
  final String? model;
  final String? effort;

  /// Summed over every finished run in the workspace.
  final double? spentUsd;

  /// Tokens the finished runs used, fresh input and output (cached input is not counted, as in the
  /// provider's own usage). Null when no run reported any: a backend with no price still has tokens.
  final int? tokensIn;
  final int? tokensOut;

  /// Live elapsed while a run is going, else the last finished run's duration.
  final Duration? duration;

  /// 0 to 1: how full the model's context window was at the end of the last run.
  final double? contextFraction;

  bool get isEmpty =>
      model == null &&
      spentUsd == null &&
      tokensIn == null &&
      tokensOut == null &&
      duration == null &&
      contextFraction == null;

  String? get modelLine {
    final m = model;
    if (m == null) return null;
    return effort == null || effort!.isEmpty ? m : '$m, $effort';
  }

  @override
  bool operator ==(Object other) =>
      other is RunFacts &&
      other.model == model &&
      other.effort == effort &&
      other.spentUsd == spentUsd &&
      other.tokensIn == tokensIn &&
      other.tokensOut == tokensOut &&
      other.duration == duration &&
      other.contextFraction == contextFraction;

  @override
  int get hashCode => Object.hash(
    model,
    effort,
    spentUsd,
    tokensIn,
    tokensOut,
    duration,
    contextFraction,
  );
}

String shortModel(String id) => id.startsWith('claude-') ? id.substring(7) : id;

RunFacts deriveRunFacts(List<AgentEvent> events, {Duration? elapsed}) {
  String? model;
  String? effort;
  double? spent;
  AgentEvent? snapshot;
  var cleared = false;

  for (var i = events.length - 1; i >= 0; i--) {
    final e = events[i];
    if (e.type == AgentEventType.contextCleared) cleared = true;
    if (model == null && e.type == AgentEventType.token) {
      final m = e.payload['model'];
      if (m is String && m.isNotEmpty) {
        model = m;
        final ef = e.payload['effort'];
        if (ef is String && ef.isNotEmpty) effort = ef;
      }
    }
    if (snapshot == null &&
        !cleared &&
        (e.type == AgentEventType.done || e.type == AgentEventType.error) &&
        e.payload['context_tokens'] is num) {
      snapshot = e;
    }
    if (model != null && (snapshot != null || cleared)) break;
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

  int? tokensIn, tokensOut;
  for (final e in events) {
    if (e.type != AgentEventType.done) continue;
    final c = e.payload['cost_usd'];
    if (c is num) spent = (spent ?? 0) + c;
    final ti = e.payload['tokens_in'];
    final to = e.payload['tokens_out'];
    if (ti is num) tokensIn = (tokensIn ?? 0) + ti.round();
    if (to is num) tokensOut = (tokensOut ?? 0) + to.round();
  }
  if ((tokensIn ?? 0) == 0 && (tokensOut ?? 0) == 0) {
    tokensIn = null;
    tokensOut = null;
  }

  return RunFacts(
    model: model == null ? null : shortModel(model),
    effort: effort,
    spentUsd: spent,
    tokensIn: tokensIn,
    tokensOut: tokensOut,
    duration: elapsed,
    contextFraction: context,
  );
}

/// How much of the context window the session holds, for the "context is getting full" warning.
@immutable
class ContextUsage {
  const ContextUsage({required this.tokens, required this.window, this.ts = 0});

  final int tokens;
  final int window;

  /// When the run that reported it finished (epoch seconds).
  final double ts;

  double get fraction => (tokens / window).clamp(0.0, 1.0).toDouble();
  int get percent => (fraction * 100).round();
}

/// The newest run's occupancy of the context window, or null when there is none or the context
/// was cleared since. The window falls back to the model's size when the run did not report it.
ContextUsage? contextUsage(List<AgentEvent> events) {
  String? model;
  AgentEvent? snapshot;
  for (var i = events.length - 1; i >= 0; i--) {
    final e = events[i];
    if (e.type == AgentEventType.contextCleared) {
      if (snapshot == null) return null;
      break;
    }
    if (model == null && e.type == AgentEventType.token) {
      final m = e.payload['model'];
      if (m is String && m.isNotEmpty) model = m;
    }
    if (snapshot == null &&
        (e.type == AgentEventType.done || e.type == AgentEventType.error) &&
        e.payload['context_tokens'] is num) {
      snapshot = e;
    }
    if (snapshot != null && model != null) break;
  }
  if (snapshot == null) return null;
  final w = snapshot.payload['context_window'];
  final window = w is num && w > 0
      ? w.round()
      : RegExp('1m', caseSensitive: false).hasMatch(model ?? '')
      ? _longWindow
      : _defaultWindow;
  return ContextUsage(
    tokens: (snapshot.payload['context_tokens'] as num).round(),
    window: window,
    ts: snapshot.ts,
  );
}
