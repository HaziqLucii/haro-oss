/// Splits a `file::test name` id on the FIRST `::` only (a test name may contain `::`).
/// The file is null when the id carries none.
(String? file, String name) splitTestId(String id) {
  final i = id.indexOf('::');
  return i < 0 ? (null, id) : (id.substring(0, i), id.substring(i + 2));
}

/// `1240` -> `1,240`.
String groupThousands(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// Short duration for status lines: `45s`, `14m`, `1h 5m`.
String formatDuration(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '${s < 0 ? 0 : s}s';
  final m = d.inMinutes;
  if (m < 60) return '${m}m';
  final h = d.inHours;
  final rem = m - h * 60;
  return rem == 0 ? '${h}h' : '${h}h ${rem}m';
}

/// Milliseconds as seconds with one decimal under a minute (`2.0s`), else [formatDuration].
String formatMs(double ms) {
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  return formatDuration(Duration(milliseconds: ms.round()));
}

/// `now`, `2m`, `14m`, `1h`, `1d`: the relative-time column of a triage row.
String relativeAgo(double epochSeconds, DateTime now) {
  final then = DateTime.fromMillisecondsSinceEpoch(
    (epochSeconds * 1000).round(),
    isUtc: true,
  );
  final d = now.toUtc().difference(then);
  if (d.inSeconds < 45) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

String plural(int n, String singular, [String? pluralForm]) =>
    n == 1 ? singular : (pluralForm ?? '${singular}s');
