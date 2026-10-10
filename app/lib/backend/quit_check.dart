import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A workspace whose agent or gate a quit would stop.
class BusyWorkspace {
  const BusyWorkspace(this.name, this.what);

  final String name;

  /// `agent` or `gate`.
  final String what;
}

/// Which workspaces have an agent or a gate running right now, asked straight from the
/// backend (the close hook sits above the app's own state). Best-effort: a slow or failed
/// read returns nothing, so a broken backend can never trap the user in the app.
Future<List<BusyWorkspace>> busyWorkspaces(
  Uri base, {
  http.Client? client,
  Duration budget = const Duration(milliseconds: 1500),
}) async {
  final c = client ?? http.Client();
  try {
    return await _read(c, base).timeout(budget);
  } catch (_) {
    return const [];
  } finally {
    if (client == null) c.close();
  }
}

Future<List<BusyWorkspace>> _read(http.Client c, Uri base) async {
  final projects = jsonDecode((await c.get(base.resolve('/projects'))).body);
  if (projects is! List) return const [];
  final lists = await Future.wait([
    for (final p in projects)
      if (p is Map && p['id'] is String)
        c.get(base.resolve('/projects/${p['id']}/workspaces')),
  ]);
  final busy = <BusyWorkspace>[];
  for (final res in lists) {
    final ws = jsonDecode(res.body);
    if (ws is! List) continue;
    for (final w in ws) {
      if (w is! Map) continue;
      final what = switch (w['status']) {
        'agent_running' => 'agent',
        'tests_running' => 'gate',
        _ => null,
      };
      if (what != null) busy.add(BusyWorkspace('${w['name']}', what));
    }
  }
  return busy;
}
