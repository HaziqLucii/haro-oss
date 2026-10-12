/// How long each changed file's diff stayed open in the review step. The receipt reports it as a
/// plain fact ("median 12 s per file"); it is never a gate and never says the file was read.
class ReviewDwell {
  final Map<String, DateTime> _openSince = {};
  final Map<String, double> _closed = {};

  /// [openPaths] is every path whose diff is expanded right now.
  void update(Set<String> openPaths, DateTime now) {
    for (final p in _openSince.keys.toList()) {
      if (!openPaths.contains(p)) {
        final since = _openSince.remove(p)!;
        _closed[p] = (_closed[p] ?? 0) + _span(since, now);
      }
    }
    for (final p in openPaths) {
      _openSince.putIfAbsent(p, () => now);
    }
  }

  /// Seconds [path] has been open this session, counting a stretch still in progress.
  double seconds(String path, DateTime now) {
    final since = _openSince[path];
    return (_closed[path] ?? 0) + (since == null ? 0 : _span(since, now));
  }

  void reset(String path, DateTime now) {
    _closed.remove(path);
    if (_openSince.containsKey(path)) _openSince[path] = now;
  }

  static double _span(DateTime a, DateTime b) =>
      b.difference(a).inMilliseconds / 1000;
}
