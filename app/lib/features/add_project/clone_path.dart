/// Thrown with a message that is safe to show inline.
class ClonePathException implements Exception {
  const ClonePathException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The directory git will create: `<parent>/<folder>`, normalised the way the backend does
/// before it registers a project (`Path(p).expanduser().resolve()`), so the folder git
/// clones into and the path handed to `POST /projects` are the same string.
///
/// A leading `~` expands to [home]; the result must be absolute; `.` and `..` are folded.
String resolveCloneTarget({
  required String parent,
  required String folder,
  String? home,
}) {
  if (folder.isEmpty ||
      folder == '.' ||
      folder == '..' ||
      folder.contains('/')) {
    throw const ClonePathException(
      'Could not work out a folder name from the URL.',
    );
  }
  var p = parent.trim();
  if (p.isEmpty) throw const ClonePathException('Pick a folder to clone into.');
  if (p == '~' || p.startsWith('~/')) {
    if (home == null || home.isEmpty) {
      throw const ClonePathException('Cannot expand ~ here. Use a full path.');
    }
    p = '$home${p.substring(1)}';
  }
  if (!p.startsWith('/')) {
    throw const ClonePathException(
      'Enter a full folder path (starting with / or ~).',
    );
  }
  final parts = <String>[];
  for (final seg in '$p/$folder'.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return '/${parts.join('/')}';
}
