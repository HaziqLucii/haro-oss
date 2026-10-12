import '../../../api/haro_api.dart';

/// Plain words for a refused "run the tests touching this file": 409 is another run in
/// flight, 400 a runner (or path) the backend will not do this for.
String relatedRunMessage(int status, String detail) => switch (status) {
  409 => 'The gate is busy. Try again once it finishes.',
  400 =>
    detail.trim().isEmpty
        ? 'This runner cannot run the tests for one file.'
        : detail.trim(),
  0 => 'Could not reach haro.',
  _ => detail.trim().isEmpty ? 'Could not start the run.' : detail.trim(),
};

/// Starts the advisory run. Null when it started, else the line to show.
Future<String?> startRelatedRun(HaroApi api, String wsId, String path) async {
  try {
    await api.runRelated(wsId, path);
    return null;
  } on HaroApiException catch (e) {
    return relatedRunMessage(e.status, e.message);
  }
}
