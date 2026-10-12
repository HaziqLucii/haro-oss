import '../../api/models/models.dart';
import '../new_workspace/branch_naming.dart';
import '../new_workspace/prefill.dart';
import 'inline_markdown.dart';

/// A todo file's lifecycle bucket: what's underway, what's untouched, what's shipped.
enum TodoCategory {
  active('In progress'),
  todo('Not started'),
  done('Done');

  const TodoCategory(this.label);
  final String label;
}

int itemsDone(TodoFile f) => f.items.where((i) => i.done).length;

TodoCategory categoryOf(TodoFile f) {
  final total = f.items.length;
  final done = itemsDone(f);
  if (total > 0 && done >= total) return TodoCategory.done;
  if (done > 0) return TodoCategory.active;
  return TodoCategory.todo;
}

/// 0..1, zero for a file without tasks.
double progressOf(TodoFile f) =>
    f.items.isEmpty ? 0 : itemsDone(f) / f.items.length;

class TodoGroup {
  const TodoGroup(this.category, this.files);
  final TodoCategory category;
  final List<TodoFile> files;
}

/// In progress, Not started, Done: empty groups are left out, file order is kept.
List<TodoGroup> groupTodoFiles(List<TodoFile> files) => [
  for (final c in TodoCategory.values)
    if (files.any((f) => categoryOf(f) == c))
      TodoGroup(c, [
        for (final f in files)
          if (categoryOf(f) == c) f,
      ]),
];

bool isStartable(TodoItem i) =>
    !i.done && i.seededWorkspace == null && i.seedKey != null;

/// The item "Start as workspace" acts on when none is picked: the first open one.
TodoItem? nextStartable(TodoFile f) {
  for (final i in f.items) {
    if (isStartable(i)) return i;
  }
  return null;
}

final _h1 = RegExp(r'^#\s+(.*)$');
final _todoLead = RegExp(r'^TODO\s*[\u2014\u2013:-]?\s*', caseSensitive: false);

Iterable<String> _noteLines(TodoFile f) sync* {
  for (final b in f.blocks) {
    if (b is TodoNote) yield* b.md.split('\n');
  }
}

/// The first `# ` heading without a leading "TODO -", else the file name.
String fileTitle(TodoFile f) {
  for (final line in _noteLines(f)) {
    final m = _h1.firstMatch(line.trim());
    if (m == null) continue;
    final t = stripInlineMarkdown(m.group(1)!.replaceFirst(_todoLead, ''))
        .trim();
    if (t.isNotEmpty) return t;
  }
  return f.label.replaceFirst(RegExp(r'\.md$'), '');
}

/// The first paragraph after the heading, block-quote marks removed, capped for the pane.
String fileSummary(TodoFile f, {int maxChars = 360}) {
  var seenHeading = false;
  final para = <String>[];
  for (final raw in _noteLines(f)) {
    final line = raw.trim();
    if (!seenHeading) {
      if (_h1.hasMatch(line)) seenHeading = true;
      continue;
    }
    if (line.isEmpty) {
      if (para.isNotEmpty) break;
      continue;
    }
    if (line.startsWith('#') ||
        line.startsWith('- ') ||
        line.startsWith('```')) {
      if (para.isNotEmpty) break;
      continue;
    }
    para.add(line.replaceFirst(RegExp(r'^>\s?'), ''));
  }
  final text = para.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= maxChars) return text;
  final cut = text.substring(0, maxChars);
  final space = cut.lastIndexOf(' ');
  var head = (space > maxChars ~/ 2 ? cut.substring(0, space) : cut).trim();
  // A cut inside **bold** or `code` would leave a dangling mark that prints literally.
  for (final mark in ['**', '`']) {
    if (mark.allMatches(head).length.isOdd) {
      head = head.substring(0, head.lastIndexOf(mark)).trim();
    }
  }
  return '$head…';
}

/// Todo item to a New workspace pre-fill: the full item (code included) is the agent brief,
/// a pointer to the source file lets the agent read the surrounding notes.
NewWorkspacePrefill todoPrefill(TodoItem item, String path) =>
    NewWorkspacePrefill(
      title: slugTitle(item.text),
      task: '${item.body.isEmpty ? item.text : item.body}\n\nReference: $path',
      seedKey: item.seedKey,
    );

/// Strips a leading `[TAG] -` project tag so the workspace name is the descriptive part.
String issueSeedName(String title) {
  final stripped = title
      .replaceFirst(RegExp(r'^\s*\[[^\]]*\]\s*[-\u2013\u2014]?\s*'), '')
      .trim();
  return stripped.isEmpty ? title : stripped;
}

NewWorkspacePrefill issuePrefill(IssueItem issue) => NewWorkspacePrefill(
  title: slugTitle(issueSeedName(issue.title)),
  task:
      '${issue.body.isEmpty ? issue.title : issue.body}\n\nReference: #${issue.number}',
  seedKey: issue.seedKey,
);

/// Free-text match over `#number`, title and label. [q] must be lowercased and trimmed.
bool issueMatchesQuery(IssueItem it, String q) {
  if (q.isEmpty) return true;
  return it.title.toLowerCase().contains(q) ||
      '${it.number}'.contains(q) ||
      it.labels.any((l) => l.toLowerCase().contains(q));
}

/// Distinct labels with their issue counts, count descending then name.
List<(String, int)> labelCountsOf(List<IssueItem> issues) {
  final counts = <String, int>{};
  for (final it in issues) {
    for (final l in it.labels) {
      counts[l] = (counts[l] ?? 0) + 1;
    }
  }
  return counts.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) {
    final byCount = b.$2.compareTo(a.$2);
    return byCount != 0 ? byCount : a.$1.compareTo(b.$1);
  });
}

/// Search then label narrowing over the fetched issues.
List<IssueItem> filterIssues(
  List<IssueItem> issues, {
  String query = '',
  String? label,
}) {
  final q = query.trim().toLowerCase();
  return [
    for (final it in issues)
      if (issueMatchesQuery(it, q) &&
          (label == null || it.labels.contains(label)))
        it,
  ];
}

enum IssueStateFilter {
  open('Open', 'open'),
  closed('Closed', 'closed'),
  all('All', 'all');

  const IssueStateFilter(this.label, this.wire);
  final String label;
  final String wire;
}
