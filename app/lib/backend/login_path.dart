import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _start = '__HARO_PATH__';
const _end = '__HARO_END__';

/// Pulls PATH out of a login shell's output. The rc may print a banner, so the value is
/// bracketed in sentinels.
String? parseShellPath(String stdout) {
  final m = RegExp('$_start([\\s\\S]*?)$_end').firstMatch(stdout);
  final v = m?.group(1);
  return v == null || v.isEmpty ? null : v;
}

/// Prepends the dirs the backend needs to find `claude`, `npx` and friends. Idempotent: dirs
/// already present are skipped, so a good login PATH is left untouched.
String withToolDirs(String? path, {required String home, String? fallback}) {
  final base = path ?? fallback ?? '';
  final have = base.split(':').toSet();
  final extra = <String>[
    if (home.isNotEmpty) '$home/.local/bin',
    '/usr/local/bin',
    '/opt/homebrew/bin',
    '/opt/homebrew/sbin',
    '/home/linuxbrew/.linuxbrew/bin',
  ].where((d) => !have.contains(d)).toList();
  if (extra.isEmpty) return base;
  return base.isEmpty ? extra.join(':') : '${extra.join(':')}:$base';
}

typedef ShellRunner = Future<String?> Function(
  String shell,
  List<String> args,
  Duration timeout,
);

Future<String?> _runShell(
  String shell,
  List<String> args,
  Duration timeout,
) async {
  final proc = await Process.start(shell, args);
  await proc.stdin.close();
  final out = proc.stdout.transform(utf8.decoder).join();
  proc.stderr.drain<void>();
  try {
    final text = await out.timeout(timeout);
    return await proc.exitCode.timeout(timeout) == 0 ? text : null;
  } on TimeoutException {
    proc.kill(ProcessSignal.sigkill);
    return null;
  }
}

/// The user's real login-shell PATH (a GUI launch inherits a minimal one), with tool dirs
/// guaranteed. Falls back to our own PATH when the shell is slow (5s), broken or absent.
Future<String> resolveLoginPath({
  Map<String, String>? env,
  ShellRunner? run,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final e = env ?? Platform.environment;
  final shell = e['SHELL'] ?? '/bin/sh';
  String? scraped;
  try {
    final out = await (run ?? _runShell)(shell, [
      '-ilc',
      'printf "$_start%s$_end" "\$PATH"',
    ], timeout);
    if (out != null) scraped = parseShellPath(out);
  } catch (_) {}
  return withToolDirs(scraped, home: e['HOME'] ?? '', fallback: e['PATH']);
}
