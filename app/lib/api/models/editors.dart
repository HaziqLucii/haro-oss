import 'json_util.dart';

enum EditorKind {
  gui('gui'),
  terminal('terminal'),
  fileManager('file_manager');

  const EditorKind(this.wire);

  final String wire;

  static EditorKind parse(String v) =>
      values.firstWhere((k) => k.wire == v, orElse: () => gui);
}

/// One "Open in..." target from `GET /editors`.
class EditorInfo {
  const EditorInfo({
    required this.id,
    required this.label,
    this.kind = EditorKind.gui,
    this.available = false,
  });

  final String id;
  final String label;
  final EditorKind kind;
  final bool available;

  factory EditorInfo.fromJson(Json j) => EditorInfo(
    id: jStr(j, 'id'),
    label: jStr(j, 'label'),
    kind: EditorKind.parse(jStr(j, 'kind')),
    available: jBool(j, 'available'),
  );
}

enum OpenInMode { spawned, shell }

/// `spawned`: the backend launched the editor. `shell`: a terminal editor, so the client
/// types [command] into the Shell tab (nothing was launched).
class OpenInResult {
  const OpenInResult({required this.mode, this.command});

  final OpenInMode mode;
  final String? command;

  factory OpenInResult.fromJson(Json j) => OpenInResult(
    mode: jStr(j, 'mode') == 'shell' ? OpenInMode.shell : OpenInMode.spawned,
    command: jStrN(j, 'command'),
  );
}
