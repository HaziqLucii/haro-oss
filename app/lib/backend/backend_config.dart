/// Where the haro backend lives. The app never starts one in this phase: it only connects
/// to a backend that is already running (a second one would corrupt ~/.haro/haro.db).
class BackendConfig {
  const BackendConfig({required this.baseUrl});

  factory BackendConfig.fromEnvironment() =>
      const BackendConfig(baseUrl: _fromDefine);

  static const String _fromDefine = String.fromEnvironment(
    'HARO_BACKEND',
    defaultValue: 'http://127.0.0.1:8000',
  );

  final String baseUrl;

  Uri resolve(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base${path.startsWith('/') ? path : '/$path'}');
  }

  Uri get healthUri => resolve('/health');

  /// `host:port` for display.
  String get hostLabel => Uri.parse(baseUrl).authority;
}
