import 'package:flutter/widgets.dart';

import '../../shortcuts/app_commands.dart';
import 'settings_scope.dart';

/// One `label + help | control` row (§6.1). The control is built lazily so a tab that has not
/// loaded yet can still be searched by its labels.
class SettingRowSpec {
  const SettingRowSpec({
    required this.id,
    required this.label,
    required this.control,
    this.help = '',
    this.section,
    this.stacked = false,
    this.visible,
    this.dimmed = false,
  });

  final String id;
  final String label;
  final String help;

  /// Mono uppercase subhead drawn above this row (and any rows after it until the next).
  final String? section;

  /// Control under the label at full width (editors) instead of beside it.
  final bool stacked;

  /// Hides the row for the current data (for example Command only shows for the command
  /// runner). Ignored while searching a tab that has not loaded.
  final bool Function()? visible;

  /// Faded, still interactive: the setting exists but the current choice ignores it.
  final bool dimmed;
  final Widget Function(BuildContext context) control;
}

class SettingsTabSpec {
  const SettingsTabSpec({
    required this.tab,
    required this.title,
    required this.intro,
    required this.scope,
    this.rows = const [],
    this.summary,
    this.banner,
    this.footer,
  });

  final SettingsTab tab;
  final String title;
  final String intro;
  final SettingsScope scope;
  final List<SettingRowSpec> rows;

  /// Boxed line above the rows (the Gate sentence).
  final Widget? summary;

  /// Notice replacing the rows' place when there is nothing to list (Usage unavailable).
  final Widget? banner;
  final Widget? footer;
}

bool _hit(String haystack, String q) => haystack.toLowerCase().contains(q);

bool rowMatches(SettingRowSpec r, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return _hit(r.label, q) || _hit(r.help, q) || _hit(r.section ?? '', q);
}

/// Rows of [spec] that match [query]. A query that names the tab itself keeps every row.
List<SettingRowSpec> filterRows(SettingsTabSpec spec, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty || _hit(spec.title, q)) return spec.rows;
  return [
    for (final r in spec.rows)
      if (rowMatches(r, q)) r,
  ];
}

bool tabMatches(SettingsTabSpec spec, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return _hit(spec.title, q) || spec.rows.any((r) => rowMatches(r, q));
}
