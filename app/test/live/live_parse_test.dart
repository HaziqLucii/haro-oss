@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/workspace_flow.dart';

Future<Object?> _get(String path) async {
  final c = HttpClient();
  final req = await c.getUrl(Uri.parse('http://127.0.0.1:8000$path'));
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  c.close();
  return jsonDecode(body);
}

void main() {
  test('parses every project and workspace from a live backend', () async {
    final projects = (await _get('/projects') as List)
        .map((j) => Project.fromJson(j as Map<String, dynamic>))
        .toList();
    for (final p in projects) {
      final list = await _get('/projects/${p.id}/workspaces') as List;
      for (final j in list) {
        final w = Workspace.fromJson(j as Map<String, dynamic>);
        final f = deriveWorkspaceFlow(FlowInput.fromWorkspace(w));
        // ignore: avoid_print
        print(
          '${p.name} | ${w.name} | ${w.statusRaw} -> ${f.displayState.word} / ${f.triageGroup.name} / ${f.nextAction.label}',
        );
      }
    }
  });
}
