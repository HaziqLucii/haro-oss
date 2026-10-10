import '../../../../api/models/models.dart';
import 'ship_model.dart';

const _maxIntent = 400;

/// A pasteable PR description block: intent, constraints, evidence, decision. The intent and
/// the reason are the developer's own words, never drafted, and an empty field says so instead
/// of being filled in. Evidence is the receipt rows as they stand, bounded the same way.
String prBlock(
  Receipt r, {
  String? intent,
  String? reason,
  VerifiedHunksResponse? hunks,
  String? writtenBy,
}) {
  final asked = collapseSpace(intent ?? '');
  final why = normalizeReason(reason ?? '');
  final fenced = r.scope.patterns.isNotEmpty;
  final evidence = [
    for (final row in receiptRows(
      r,
      hunks: hunks,
      writtenBy: writtenBy,
      reason: '',
    ))
      if (row.label != 'Scope') '- ${row.label}: ${row.value}',
  ];
  final b = StringBuffer()
    ..writeln('## Intent')
    ..writeln(
      asked.isEmpty
          ? 'Not applicable: no prompt was given in haro.'
          : '${asked.length > _maxIntent ? '${asked.substring(0, _maxIntent).trimRight()}…' : asked}'
                ' (first prompt, as typed)',
    )
    ..writeln()
    ..writeln('## Constraints')
    ..writeln(
      fenced
          ? 'Agent fenced to: ${scopeText(r)}. The fence covers files; commands and network are not restricted.'
          : 'Not applicable: no fence was set, the agent could change any file.',
    )
    ..writeln()
    ..writeln('## Evidence')
    ..writeAll(evidence, '\n')
    ..writeln()
    ..writeln()
    ..writeln('## Decision')
    ..write(
      why.isEmpty
          ? 'Not applicable: no reason was written at ship time.'
          : '$why (typed by the developer)',
    );
  return b.toString();
}
