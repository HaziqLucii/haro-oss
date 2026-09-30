import 'dart:io';

/// Port the packaged backend prefers, so a second app instance finds the first one's backend
/// instead of starting a rival against the same `~/.haro/haro.db`.
const int preferredBackendPort = 41417;
const String legacyBackendUrl = 'http://127.0.0.1:8000';

/// Where the frozen backend sits, relative to the app executable: the release bundle (and the
/// AppImage) ship it as `<bundle>/backend/haro-backend/haro-backend` (PyInstaller onedir).
const String frozenBackendRelPath = 'backend/haro-backend/haro-backend';

sealed class BackendPlan {
  const BackendPlan();
}

/// `HARO_BACKEND` is set, or no frozen binary ships with this build: connect, spawn nothing.
class ConnectPlan extends BackendPlan {
  const ConnectPlan(this.baseUrl);
  final String baseUrl;
}

/// A frozen backend ships next to the app: start it (unless one already answers).
class SpawnPlan extends BackendPlan {
  const SpawnPlan(this.executable);
  final String executable;
}

BackendPlan selectBackendPlan({
  required Map<String, String> env,
  required String appExecutable,
  String define = '',
  bool Function(String path)? fileExists,
}) {
  final override = (env['HARO_BACKEND'] ?? '').trim();
  if (override.isNotEmpty) return ConnectPlan(override);
  if (define.trim().isNotEmpty) return ConnectPlan(define.trim());
  final exists = fileExists ?? (path) => File(path).existsSync();
  final dir = appExecutable.substring(0, appExecutable.lastIndexOf('/'));
  final frozen = '$dir/$frozenBackendRelPath';
  if (exists(frozen)) return SpawnPlan(frozen);
  return const ConnectPlan(legacyBackendUrl);
}

/// The preferred port when it is free, else an OS-assigned one (bind :0). Stable across
/// launches when possible; never a port something else holds.
Future<int> pickBackendPort({
  int preferred = preferredBackendPort,
  Future<int?> Function(int port)? tryBind,
}) async {
  final bind = tryBind ?? _tryBind;
  return await bind(preferred) ??
      await bind(0) ??
      (throw StateError('no free loopback port'));
}

Future<int?> _tryBind(int port) async {
  try {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    final bound = s.port;
    await s.close();
    return bound;
  } on SocketException {
    return null;
  }
}
