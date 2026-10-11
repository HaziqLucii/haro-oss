/// Branch and workspace naming for New workspace (§6.4). Ports `slugify` (mirrors the
/// backend's `git_ops.slugify`) and the branch-prefix handling of `NewWorkspaceModal.tsx`.
library;

const branchPrefixes = [
  'feat/',
  'fix/',
  'chore/',
  'docs/',
  'refactor/',
  'test/',
];

const defaultBranchPrefix = 'feat/';

final _fixWord = RegExp(r'\b(fix|bug|bugfix|hotfix)\b', caseSensitive: false);

/// `fix/` when the task says it is a fix (a whole word fix, bug, bugfix or hotfix anywhere in
/// it), else `feat/`. Same for both modes: who writes the code says nothing about what kind
/// of change it is.
String branchPrefixForTask(String task) =>
    _fixWord.hasMatch(task) ? 'fix/' : defaultBranchPrefix;

/// Lowercase, runs of non-alphanumerics become `-`, trimmed. An empty result is `task` so a
/// blank name still yields a valid branch.
String slugify(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'task' : slug;
}

/// Compact workspace name from a longer title: markdown marks stripped, the lead phrase
/// before a spaced dash, cut at a word boundary (never mid-word) past 48 characters.
String slugTitle(String title) {
  final lead = title
      .replaceAll(RegExp(r'[`*]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  var name = lead.split(RegExp(r'\s+[\u2014\u2013-]\s+')).first;
  if (name.isEmpty) name = lead;
  if (name.length > 48) {
    final cut = name.substring(0, 48);
    final space = cut.lastIndexOf(' ');
    name = (space > 16 ? cut.substring(0, space) : cut).trim();
  }
  return name;
}

/// Workspace name for the task text: short single-line text is used as typed, anything
/// longer or multi-line is compacted with [slugTitle].
String workspaceNameFor(String task) {
  final t = task.trim();
  return t.length <= 48 && !t.contains('\n') ? t : slugTitle(t);
}

/// Swaps the leading `<word>/` of [branch] for [prefix], keeping what follows, or falls
/// back to [fallback] when there is nothing to keep.
String withPrefix(String branch, String prefix, String fallback) {
  final slash = branch.indexOf('/');
  final rest = slash == -1 ? branch : branch.substring(slash + 1);
  return '$prefix${rest.isEmpty ? fallback : rest}';
}

/// The branch field: derived from the task until the user edits it by hand, after which it
/// stays theirs, even if they clear it (the form then refuses to submit). The prefix follows
/// the task text until a chip is clicked.
class BranchDraft {
  const BranchDraft({this.prefix, this.manual});

  /// Null while the prefix follows the task ([branchPrefixForTask]).
  final String? prefix;

  /// Null while the branch follows the task.
  final String? manual;

  bool get auto => manual == null;

  String branchFor(String task) {
    final m = manual;
    if (m != null) return m;
    final trimmed = task.trim();
    final lead = prefix ?? branchPrefixForTask(trimmed);
    return '$lead${trimmed.isEmpty ? 'task-name' : slugify(workspaceNameFor(trimmed))}';
  }

  /// Chip click. A hand-edited branch keeps its own tail and only swaps the prefix.
  BranchDraft withChip(String next, String task) {
    final m = manual;
    if (m == null) return BranchDraft(prefix: next);
    return BranchDraft(
      prefix: next,
      manual: withPrefix(m, next, slugify(workspaceNameFor(task))),
    );
  }

  BranchDraft edited(String value) =>
      BranchDraft(prefix: prefix, manual: value);
}
