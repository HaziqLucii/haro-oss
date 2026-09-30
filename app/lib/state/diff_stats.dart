/// File and line counts from a unified diff (`DiffResponse.diff`), for the step bar's
/// `21 files · +367 −130`. Only counts lines inside hunks, so a removed line that happens
/// to start with `--` is not mistaken for a file header.
class DiffStats {
  const DiffStats({this.files = 0, this.added = 0, this.removed = 0});

  static const empty = DiffStats();

  final int files;
  final int added;
  final int removed;

  bool get isEmpty => files == 0;
}

DiffStats parseDiffStats(String diff) {
  var files = 0;
  var added = 0;
  var removed = 0;
  var inHunk = false;
  for (final line in diff.split('\n')) {
    if (line.startsWith('diff --git ')) {
      files++;
      inHunk = false;
    } else if (line.startsWith('@@')) {
      inHunk = true;
    } else if (inHunk) {
      if (line.startsWith('+')) {
        added++;
      } else if (line.startsWith('-')) {
        removed++;
      }
    }
  }
  return DiffStats(files: files, added: added, removed: removed);
}
