import '../../api/haro_api.dart';

const editorsRestartHint = 'Open in… needs a backend restart';

/// The backend answers a route it does not have with a bare `Not Found`, which is what a
/// backend started before `/editors` existed says. A real "workspace not found" carries its
/// own words.
bool _routeMissing(HaroApiException e) =>
    e.status == 404 && e.message.trim().toLowerCase() == 'not found';

/// One mono line for a failed `GET /editors`.
String editorsLoadError(Object e) {
  if (e is HaroApiException) {
    if (_routeMissing(e)) return editorsRestartHint;
    return e.status == 0 ? 'Backend not reachable' : e.message;
  }
  return '$e';
}

/// One mono line for a failed `POST /workspaces/{id}/open`.
String openInError(Object e) {
  if (e is HaroApiException) {
    if (_routeMissing(e)) return editorsRestartHint;
    return e.status == 0 ? 'Backend not reachable' : e.message;
  }
  return '$e';
}
