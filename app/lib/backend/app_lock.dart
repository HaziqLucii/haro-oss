import 'dart:io';

/// Exclusive, non-blocking lock on a file, held until the process exits (the OS then drops it,
/// even after a crash). One app instance at a time: a second backend booting against the same
/// `~/.haro/haro.db` runs its orphan sweep and kills the first one's dev servers.
class AppLock {
  AppLock._(this._file);

  final RandomAccessFile _file;

  /// Null when another process holds the lock.
  static AppLock? tryAcquire(String path) {
    final parent = File(path).parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final f = File(path).openSync(mode: FileMode.append);
    try {
      f.lockSync(FileLock.exclusive);
      return AppLock._(f);
    } on FileSystemException {
      f.closeSync();
      return null;
    }
  }

  void release() {
    try {
      _file.unlockSync();
    } on FileSystemException {
      // The close below drops it anyway.
    }
    _file.closeSync();
  }
}
