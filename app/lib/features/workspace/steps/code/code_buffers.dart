import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart';
import '../../../../data/workspace_actions.dart';
import 'edit_buffer.dart';

/// Open editor buffers for one workspace, keyed by path. The page swaps the step body when
/// the user goes to another step, which disposes the code step's widgets; a buffer with
/// unsaved edits must outlive that, so the store holds a keep-alive link for as long as any
/// buffer is dirty and lets everything go once they are saved or discarded.
final codeBuffersProvider = Provider.autoDispose
    .family<CodeBufferStore, String>((ref, id) {
      final store = CodeBufferStore(ref.keepAlive);
      ref.onDispose(store.dispose);
      return store;
    });

class CodeBufferStore extends ChangeNotifier {
  CodeBufferStore(this._keepAlive);

  final KeepAliveLink Function() _keepAlive;
  final _buffers = <String, EditBuffer>{};
  KeepAliveLink? _link;
  bool _disposed = false;

  EditBuffer? bufferFor(String path) => _buffers[path];

  Set<String> get dirtyPaths => {
    for (final e in _buffers.entries)
      if (e.value.dirty) e.key,
  };

  /// The buffer for [path], created and loaded from [read] only when there is none yet. Every
  /// open tab holds one, so switching tabs never drops or re-reads it.
  EditBuffer ensure(String path, Future<FileContent> Function() read) {
    final existing = _buffers[path];
    if (existing != null) return existing;
    final b = EditBuffer(path)..addListener(_onBufferChanged);
    _buffers[path] = b;
    b.load(read);
    _syncLink();
    return b;
  }

  /// Drops every buffer whose path is not in [keep] and has no unsaved edits. Dirty buffers of
  /// closed tabs are only dropped by an explicit [drop] (the user discarded them).
  void retainOnly(Set<String> keep) {
    final gone = [
      for (final e in _buffers.entries)
        if (!keep.contains(e.key) && !e.value.dirty) e.key,
    ];
    for (final path in gone) {
      drop(path);
    }
  }

  /// A fresh buffer for [path], loaded from [read]. A dirty one is kept and returned as is:
  /// unsaved edits are never replaced by a re-read.
  EditBuffer open(String path, Future<FileContent> Function() read) {
    final existing = _buffers[path];
    if (existing != null && existing.dirty) return existing;
    existing?.dispose();
    final b = EditBuffer(path)..addListener(_onBufferChanged);
    _buffers[path] = b;
    b.load(read);
    _syncLink();
    return b;
  }

  void drop(String path) {
    final b = _buffers.remove(path);
    if (b == null) return;
    b.removeListener(_onBufferChanged);
    b.dispose();
    _syncLink();
    notifyListeners();
  }

  static bool _under(String prefix, String path) =>
      path == prefix || path.startsWith('$prefix/');

  /// Buffers with unsaved edits at [path] or, for a folder, below it.
  Set<String> dirtyUnder(String path) => {
    for (final p in dirtyPaths)
      if (_under(path, p)) p,
  };

  /// Re-keys the buffer for [from] (and every one below it, for a folder) to [to]: the file
  /// was renamed, and its unsaved edits, scroll and cursor go with it.
  void moveUnder(String from, String to) {
    final moving = [
      for (final p in _buffers.keys)
        if (_under(from, p)) p,
    ];
    if (moving.isEmpty) return;
    final taken = {for (final p in moving) p: _buffers.remove(p)!};
    for (final e in taken.entries) {
      final next = '$to${e.key.substring(from.length)}';
      _buffers.remove(next)?.dispose();
      e.value.path = next;
      _buffers[next] = e.value;
    }
    notifyListeners();
  }

  /// Drops the buffers at [path] or below it, unsaved edits included (the file was deleted
  /// and the user was told).
  void dropUnder(String path) {
    for (final p in [
      for (final p in _buffers.keys)
        if (_under(path, p)) p,
    ]) {
      drop(p);
    }
  }

  /// Disposes every buffer without unsaved edits (the step is going away).
  void releaseClean() {
    for (final path in [
      for (final e in _buffers.entries)
        if (!e.value.dirty) e.key,
    ]) {
      final b = _buffers.remove(path)!;
      b.removeListener(_onBufferChanged);
      b.dispose();
    }
    _syncLink();
  }

  void _onBufferChanged() {
    _syncLink();
    if (!_disposed) notifyListeners();
  }

  void _syncLink() {
    final dirty = _buffers.values.any((b) => b.dirty);
    if (dirty && _link == null && !_disposed) {
      _link = _keepAlive();
    } else if (!dirty && _link != null) {
      final link = _link!;
      _link = null;
      link.close();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final b in _buffers.values) {
      b.removeListener(_onBufferChanged);
      b.dispose();
    }
    _buffers.clear();
    super.dispose();
  }
}

/// Writes every buffer with unsaved edits, in order. Stops and throws on the first that cannot
/// be saved, so a gate run never starts on a tree that is missing the user's last edits. A file
/// that changed on disk since it was opened is not overwritten silently: nothing is written
/// until each such file has been opened and answered (Overwrite or Reload).
Future<void> saveDirtyBuffers(
  CodeBufferStore store,
  WorkspaceActions actions,
) async {
  final paths = store.dirtyPaths;
  final changed = <String>[];
  for (final path in paths) {
    final b = store.bufferFor(path);
    if (b == null) continue;
    if (await b.changedOnDisk(() => actions.readFile(path))) {
      b.markDiskConflict(true);
      changed.add(path);
    }
  }
  if (changed.isNotEmpty) {
    throw HaroApiException(
      0,
      '${changed.join(', ')} changed on disk since you opened '
      '${changed.length == 1 ? 'it' : 'them'}: open the file to overwrite or reload.',
    );
  }
  for (final path in paths) {
    final b = store.bufferFor(path);
    // A save that was in flight during the disk check may already have written it.
    if (b == null || !b.dirty) continue;
    final ok = await b.save((content) => actions.saveFile(path, content));
    if (!ok) {
      throw HaroApiException(
        0,
        'Could not save $path: ${b.saveError ?? 'unknown error'}',
      );
    }
  }
}
