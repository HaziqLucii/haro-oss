/// Tolerant JSON readers. The backend is pydantic, so keys are usually present, but older
/// persisted rows and newer backend builds both happen: a missing or oddly typed key must
/// degrade to a default instead of throwing inside a WebSocket handler.
typedef Json = Map<String, dynamic>;

Json asJson(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return Map<String, dynamic>.from(v);
  return <String, dynamic>{};
}

String jStr(Json j, String k, [String def = '']) {
  final v = j[k];
  return v is String ? v : def;
}

String? jStrN(Json j, String k) {
  final v = j[k];
  return v is String ? v : null;
}

int jInt(Json j, String k, [int def = 0]) => jIntN(j, k) ?? def;

int? jIntN(Json j, String k) {
  final v = j[k];
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}

double jDouble(Json j, String k, [double def = 0]) => jDoubleN(j, k) ?? def;

double? jDoubleN(Json j, String k) {
  final v = j[k];
  return v is num ? v.toDouble() : null;
}

bool jBool(Json j, String k, [bool def = false]) {
  final v = j[k];
  return v is bool ? v : def;
}

bool? jBoolN(Json j, String k) {
  final v = j[k];
  return v is bool ? v : null;
}

List<T> jList<T>(Json j, String k, T Function(Json) parse) {
  final v = j[k];
  if (v is! List) return <T>[];
  return [
    for (final e in v)
      if (e is Map) parse(asJson(e)),
  ];
}

/// Like [jList] but keeps `null` distinct from an empty list. Several gate fields are
/// tri-state on purpose ("never measured" is not "measured clean").
List<T>? jListN<T>(Json j, String k, T Function(Json) parse) {
  if (j[k] is! List) return null;
  return jList(j, k, parse);
}

List<String> jStrList(Json j, String k) {
  final v = j[k];
  if (v is! List) return <String>[];
  return [
    for (final e in v)
      if (e is String) e,
  ];
}

List<int> jIntList(Json j, String k) {
  final v = j[k];
  if (v is! List) return <int>[];
  return [
    for (final e in v)
      if (e is num) e.toInt(),
  ];
}

/// Parses [raw] against each enum's `wire` string, falling back to [fallback] (always the
/// enum's `unknown`) so a backend that grows a new state never crashes the client.
T enumFromWire<T extends Enum>(
  List<T> values,
  String Function(T) wire,
  Object? raw,
  T fallback,
) {
  if (raw is String) {
    for (final v in values) {
      if (wire(v) == raw) return v;
    }
  }
  return fallback;
}
