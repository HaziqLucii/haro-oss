import '../../../../../api/models/models.dart';
import '../diff_model.dart';
import 'explorer_model.dart' show ChangeLetter, letterOf;

/// One row of the Changes panel: a file git sees as changed since the last commit, with the
/// checkbox state of "is it in the index".
class ChangeEntry {
  const ChangeEntry({
    required this.path,
    required this.staged,
    required this.letter,
    this.partial = false,
    this.conflict = false,
    this.additions = 0,
    this.deletions = 0,
  });

  final String path;
  final bool staged;

  /// In the index, but the worktree has more edits on top: clicking stages the rest.
  final bool partial;

  /// Unmerged: no checkbox, and "Stage all" leaves it out.
  final bool conflict;
  final ChangeLetter letter;
  final int additions;
  final int deletions;

  /// An untracked folder git reports whole (`dir/`): stageable, but not a file to open.
  bool get isDirectory => path.endsWith('/');

  String get name {
    final bare = isDirectory ? path.substring(0, path.length - 1) : path;
    return '${basenameOf(bare)}${isDirectory ? '/' : ''}';
  }

  String get dir {
    final bare = isDirectory ? path.substring(0, path.length - 1) : path;
    return dirnameOf(bare);
  }
}

ChangeLetter _letterFor(GitFileStatus f, DiffFile? diff) {
  final words = '${f.index} ${f.work}';
  if (words.contains('deleted')) return ChangeLetter.deleted;
  if (words.contains('renamed')) return ChangeLetter.renamed;
  if (words.contains('added') || words.contains('untracked')) {
    return ChangeLetter.added;
  }
  return diff == null ? ChangeLetter.modified : letterOf(diff);
}

/// The Changes panel list: `git status` files by path, with line counts from the branch diff
/// where it has the file.
List<ChangeEntry> changeEntries(
  GitStatusResponse? status,
  List<DiffFile> diffFiles,
) {
  if (status == null) return const [];
  final byPath = {for (final f in diffFiles) f.path: f};
  final out = [
    for (final f in status.files)
      ChangeEntry(
        path: f.path,
        staged: f.staged,
        partial: f.partial,
        conflict: f.conflict,
        letter: _letterFor(f, byPath[f.path]),
        additions: byPath[f.path]?.additions ?? 0,
        deletions: byPath[f.path]?.deletions ?? 0,
      ),
  ]..sort((a, b) => a.path.compareTo(b.path));
  return out;
}

/// Every entry is in the index with nothing left over: the state "Stage all" flips from.
bool allFullyStaged(List<ChangeEntry> entries) {
  final stageable = entries.where((e) => !e.conflict);
  return stageable.isNotEmpty && stageable.every((e) => e.staged && !e.partial);
}

int stagedCount(List<ChangeEntry> entries) =>
    entries.where((e) => e.staged).length;

/// Commit needs a message and something in the index.
bool canCommit(List<ChangeEntry> entries, String message) =>
    message.trim().isNotEmpty && stagedCount(entries) > 0;
