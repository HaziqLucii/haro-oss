import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../workspace/harness.dart';

Map<String, dynamic> editor(
  String id,
  String label,
  String kind, {
  bool available = true,
}) => {'id': id, 'label': label, 'kind': kind, 'available': available};

List<Map<String, dynamic>> sampleEditors() => [
  editor('vscode', 'VS Code', 'gui', available: false),
  editor('zed', 'Zed', 'gui'),
  editor('neovim', 'Neovim', 'terminal'),
  editor('file_manager', 'Files', 'file_manager'),
];

class Recorded {
  Recorded(this.method, this.path, this.query, this.body);

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic>? body;
}

/// `GET /editors` and `POST /workspaces/ws_1/open`, recorded. Everything else 404s the way a
/// route the backend does not have does.
class OpenInBackend {
  OpenInBackend({List<Map<String, dynamic>>? editors})
    : editors = editors ?? sampleEditors();

  final List<Map<String, dynamic>> editors;
  final calls = <Recorded>[];

  /// When set, `/editors` answers with this status and `{"detail": editorsDetail}`.
  int? editorsStatus;
  String editorsDetail = 'Not Found';

  int? openStatus;
  String openDetail = 'file not found';
  Map<String, dynamic> Function(Map<String, dynamic> body)? reply;

  Iterable<Recorded> get opens => calls.where(
    (c) => c.method == 'POST' && c.path == '/workspaces/$id/open',
  );

  int get editorGets => calls.where((c) => c.path == '/editors').length;

  http.Response _json(Object? v, [int status = 200]) => http.Response(
    jsonEncode(v),
    status,
    headers: {'content-type': 'application/json'},
  );

  Future<http.Response> _handle(http.Request r) async {
    final body = r.body.isEmpty
        ? null
        : Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    calls.add(Recorded(r.method, r.url.path, r.url.queryParameters, body));
    if (r.method == 'GET' && r.url.path == '/editors') {
      final s = editorsStatus;
      return s == null ? _json(editors) : _json({'detail': editorsDetail}, s);
    }
    if (r.method == 'POST' && r.url.path == '/workspaces/$id/open') {
      final s = openStatus;
      if (s != null) return _json({'detail': openDetail}, s);
      return _json(reply?.call(body!) ?? {'mode': 'spawned', 'command': null});
    }
    return _json({'detail': 'Not Found'}, 404);
  }

  HaroApi api() =>
      HaroApi(Uri.parse('http://127.0.0.1:8000'), client: MockClient(_handle));
}

/// Adds the backend and the stored Display prefs to any [Rig].
void withOpenIn(Rig rig, OpenInBackend backend, {String? preferred}) {
  rig.extra.add(haroApiProvider.overrideWithValue(backend.api()));
  rig.prefs = MemoryDevicePrefsStore({
    'display': {'preferred_editor': ?preferred},
  });
}

Finder byText(String t) => find.text(t);

/// The shell socket the workspace page opened, if any.
List<Map<String, dynamic>> shellSent(Rig rig) {
  final i = rig.net.uris.indexWhere((u) => u.path.contains('/terminal/'));
  if (i < 0) return const [];
  return [
    for (final m in rig.net.channels[i].sent)
      Map<String, dynamic>.from(jsonDecode(m as String) as Map),
  ];
}

Future<void> settleOpen(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}
