import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'boot_splash.dart' show BootLine;

/// One finished step the backend printed to its own log, `[boot] db.init 12ms` while it starts
/// and `[shutdown] snapshot 8ms` while it stops (`main.lifespan`). The boot and closing screens
/// list these, so they show what the backend really did, not a guess.
class BackendStep {
  const BackendStep(this.phase, this.key, this.ms, [this.detail = '']);

  /// `boot` or `shutdown`.
  final String phase;
  final String key;
  final int ms;

  /// What the step reported (`17 workspaces`, `none`), empty when it had nothing to say.
  final String detail;

  @override
  String toString() => '[$phase] $key ${ms}ms $detail';
}

final _stepLine = RegExp(r'^\[(boot|shutdown)\] (\S+) (\d+)ms(?: (.+))?$');

BackendStep? parseBackendStep(String line) {
  final m = _stepLine.firstMatch(line.trimRight());
  if (m == null) return null;
  return BackendStep(
    m.group(1)!,
    m.group(2)!,
    int.parse(m.group(3)!),
    m.group(4) ?? '',
  );
}

/// Reads new lines from the backend's log as it writes them. The log is a plain file the shell
/// redirects stdout into, so this polls its length; a shorter file means a new launch truncated it.
class BackendLogTail {
  BackendLogTail(
    this.path,
    this.onStep, {
    this.fromEnd = false,
    this.every = const Duration(milliseconds: 100),
  });

  final String path;
  final void Function(BackendStep step) onStep;

  /// Skip what is already in the file (the quit starts after a whole session of log).
  final bool fromEnd;
  final Duration every;

  int? _offset;
  String _partial = '';
  Timer? _timer;

  void start() {
    if (fromEnd) {
      try {
        _offset = File(path).lengthSync();
      } catch (_) {
        _offset = 0;
      }
    }
    _timer = Timer.periodic(every, (_) => poll());
  }

  void poll() {
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final length = file.lengthSync();
      var offset = _offset ?? 0;
      if (length < offset) {
        offset = 0;
        _partial = '';
      }
      if (length == offset) return;
      final raf = file.openSync();
      List<int> bytes;
      try {
        raf.setPositionSync(offset);
        bytes = raf.readSync(length - offset);
      } finally {
        raf.closeSync();
      }
      _offset = length;
      final text = _partial + utf8.decode(bytes, allowMalformed: true);
      final lines = text.split('\n');
      _partial = lines.removeLast();
      for (final line in lines) {
        final step = parseBackendStep(line);
        if (step != null) onStep(step);
      }
    } catch (_) {
      // A log that cannot be read just shows fewer lines.
    }
  }

  /// One last read, so a step printed just before the process answered is not lost.
  void stop() {
    poll();
    _timer?.cancel();
    _timer = null;
  }
}

String formatStepMs(int ms) =>
    ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)} s' : '$ms ms';

typedef _Group = ({
  String label,
  List<String> keys,
  String Function(Map<String, BackendStep> seen)? extra,
});

String _suffix(Map<String, BackendStep> seen, String key) {
  final d = seen[key]?.detail ?? '';
  return d.isEmpty ? '' : ', $d';
}

/// The backend's startup steps folded into a few readable lines. A line is printed when the last
/// of its steps has finished, and shows their summed time; a group with a step missing (an older
/// backend) is left out, never invented.
final List<_Group> _bootGroups = [
  (label: 'claude skills', keys: ['install_haro_skill'], extra: null),
  (
    label: 'database',
    keys: ['db.init', 'db.load_into'],
    extra: (seen) => _suffix(seen, 'db.load_into'),
  ),
  (
    label: 'worktrees vs git',
    keys: ['db.reconcile', 'db.mark_broken'],
    extra: null,
  ),
  (
    label: 'project baselines',
    keys: ['baseline_sweep', 'reconcile_adoptable'],
    extra: null,
  ),
  (
    label: 'stray dev servers',
    keys: ['sweep_orphan_runs'],
    extra: (seen) => _suffix(seen, 'sweep_orphan_runs'),
  ),
];

List<BootLine> bootStepLines(Iterable<BackendStep> steps) {
  final seen = <String, BackendStep>{
    for (final s in steps)
      if (s.phase == 'boot') s.key: s,
  };
  return [
    for (final g in _bootGroups)
      if (g.keys.every(seen.containsKey))
        BootLine(
          '${g.label}${g.extra?.call(seen) ?? ''}',
          formatStepMs(g.keys.fold(0, (sum, k) => sum + seen[k]!.ms)),
        ),
  ];
}

/// What the backend reported doing while it stopped, in the order it did it. Only steps that ran:
/// no dev servers running means no dev-server line.
List<String> closingStepLines(Iterable<BackendStep> steps) => [
  for (final s in steps)
    if (s.phase == 'shutdown')
      switch (s.key) {
        'dev_servers' =>
          'stopped ${s.detail.isEmpty ? '' : '${s.detail} '}dev server${s.detail == '1' ? '' : 's'}',
        'browser' =>
          s.detail == '1'
              ? 'closed the shared browser'
              : 'closed ${s.detail} shared browsers',
        'snapshot' => 'saved state',
        'database' => 'closed database',
        _ => null,
      },
].whereType<String>().toList();
