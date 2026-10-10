import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/models/json_util.dart';
import '../../../../data/workspace_detail.dart';
import '../../../settings/device_prefs.dart';
import '../code/diff_model.dart';
import '../code/editor/editor_data.dart';

/// Which changed files the reviewer has marked Viewed, per workspace. A mark is the file's path
/// plus a signature of its diff, so a file the agent or you touched again after viewing it
/// reads as not viewed: the mark vouches for the text you saw, not for the path.
///
/// Kept in the device prefs file under `files_viewed`, never on the backend: it is the
/// reviewer's own progress, and the gate's `checked_rows` are pruned on every run.

const _prefsKey = 'files_viewed';
const _maxWorkspaces = 40;

/// FNV-1a over the file's paths, hunk headers and every line. Stable across runs (Dart's
/// `hashCode` is not promised to be), which a mark stored on disk needs.
String fileSignature(DiffFile f) => _signatures[f] ??= _hash(f);

/// A parsed diff is rebuilt on every fetch, so a file's signature is computed once per parse.
final _signatures = Expando<String>('fileSignature');

String _hash(DiffFile f) {
  var h = 0x811c9dc5;
  void feed(String s) {
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    h = ((h ^ 0x0a) * 0x01000193) & 0xffffffff;
  }

  feed(f.oldPath);
  feed(f.newPath);
  for (final hunk in f.hunks) {
    feed(hunk.header);
    for (final l in hunk.lines) {
      feed('${l.kind.index}${l.text}');
    }
  }
  return h.toRadixString(16);
}

class FilesViewedNotifier extends Notifier<Map<String, String>> {
  FilesViewedNotifier(this.id);

  final String id;

  /// Seconds the file's diff was open when it was marked Viewed, saved beside the mark. A mark
  /// saved before this was recorded has no entry.
  final Map<String, double> _seconds = {};

  double? secondsFor(String path) => _seconds[path];

  @override
  Map<String, String> build() {
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    try {
      final file = await ref.read(devicePrefsStoreProvider).read();
      final entry = asJson(asJson(file[_prefsKey])[id]);
      final marks = asJson(entry['marks']);
      if (!ref.mounted) return;
      for (final e in asJson(entry['seconds']).entries) {
        if (e.value is num) {
          _seconds.putIfAbsent(e.key, () => (e.value as num).toDouble());
        }
      }
      state = {
        ...state,
        for (final e in marks.entries)
          if (e.value is String) e.key: e.value as String,
      };
    } catch (_) {}
  }

  /// [seconds] is how long the file's diff was open; it is kept with the mark it belongs to.
  void toggle(DiffFile f, {double seconds = 0}) {
    final next = {...state};
    final sig = fileSignature(f);
    if (next[f.path] == sig) {
      next.remove(f.path);
      _seconds.remove(f.path);
    } else {
      next[f.path] = sig;
      _seconds[f.path] = seconds;
    }
    state = next;
    unawaited(_save(f.path, next[f.path], _seconds[f.path]));
  }

  /// Applies one change to what is on disk rather than writing [state], so a mark made before
  /// the first read finished cannot drop the marks saved earlier.
  Future<void> _save(String path, String? sig, double? seconds) async {
    try {
      await ref.read(devicePrefsStoreProvider).update((file) {
        final all = {...asJson(file[_prefsKey])};
        final marks = <String, dynamic>{...asJson(asJson(all[id])['marks'])};
        final secs = <String, dynamic>{...asJson(asJson(all[id])['seconds'])};
        if (sig == null) {
          marks.remove(path);
          secs.remove(path);
        } else {
          marks[path] = sig;
          secs[path] = seconds ?? 0;
        }
        if (marks.isEmpty) {
          all.remove(id);
        } else {
          all[id] = {
            'at': DateTime.now().millisecondsSinceEpoch,
            'marks': marks,
            'seconds': secs,
          };
        }
        if (all.length > _maxWorkspaces) {
          final byAge = all.keys.toList()
            ..sort(
              (a, b) => ((asJson(all[b])['at'] as num?) ?? 0).compareTo(
                (asJson(all[a])['at'] as num?) ?? 0,
              ),
            );
          for (final k in byAge.skip(_maxWorkspaces)) {
            all.remove(k);
          }
        }
        return {...file, _prefsKey: all};
      });
    } catch (_) {}
  }
}

final filesViewedProvider =
    NotifierProvider.family<FilesViewedNotifier, Map<String, String>, String>(
      FilesViewedNotifier.new,
    );

/// The changed files whose current diff is marked Viewed.
Set<String> viewedPaths(Iterable<DiffFile> files, Map<String, String> marks) =>
    {
      for (final f in files)
        if (marks[f.path] == fileSignature(f)) f.path,
    };

/// A fingerprint of the whole parsed diff: it changes when any changed file does. Empty until
/// the diff has loaded.
final diffSignatureProvider = Provider.autoDispose.family<String, String>((
  ref,
  id,
) {
  final files = ref.watch(parsedDiffProvider(id)).files;
  return files.isEmpty ? '' : files.map(fileSignature).join(',');
});

/// True when every changed file is marked Viewed (and trivially when nothing changed). False
/// until the diff has loaded: an unloaded diff has no files, which is not a finished review.
final reviewCompleteProvider = Provider.autoDispose.family<bool, String>((
  ref,
  id,
) {
  if (ref.watch(workspaceDetailProvider(id).select((d) => d.diff == null))) {
    return false;
  }
  final files = ref.watch(parsedDiffProvider(id)).files;
  final marks = ref.watch(filesViewedProvider(id));
  return viewedPaths(files, marks).length == files.length;
});
