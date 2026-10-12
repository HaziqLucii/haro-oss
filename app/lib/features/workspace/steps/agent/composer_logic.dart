import 'package:flutter/services.dart';

import '../../../../api/models/models.dart';

/// Pure composer logic, ported from the React client's `composerAutocomplete.ts`,
/// `attachments.ts`, `roles.ts` and `composerButton.ts`.

// ---- scope fence ----

/// The composer's scope field as the request's `scope` list: split on commas or newlines
/// (a path may contain a space), each entry trimmed, a leading `./` dropped, blanks and
/// repeats removed. Empty means no fence.
List<String> parseScope(String text) {
  final out = <String>[];
  for (final raw in text.split(RegExp(r'[,\n]'))) {
    var p = raw.trim();
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    if (p.isNotEmpty && !out.contains(p)) out.add(p);
  }
  return out;
}

bool _hasGlob(String s) =>
    s.contains('*') || s.contains('?') || s.contains('[');

/// One entry the way the chips hold it: trimmed, a leading `./` dropped, and a trailing `/**`
/// written as the folder it means (`src/**` is `src/`: a folder already covers everything
/// inside it, so nobody needs to know the glob).
String normalizeScopeEntry(String raw) {
  var p = raw.trim();
  while (p.startsWith('./')) {
    p = p.substring(2);
  }
  if (p.endsWith('/**') && !_hasGlob(p.substring(0, p.length - 3))) {
    p = p.substring(0, p.length - 2);
  }
  return p;
}

enum ScopeKind { folder, file, pattern }

/// What a chip stands for. A name with no slash that has files under it is a folder too,
/// because the fence reads a plain path as itself and everything beneath it.
ScopeKind scopeKind(String entry, List<String> files) {
  if (_hasGlob(entry)) return ScopeKind.pattern;
  if (entry.endsWith('/')) return ScopeKind.folder;
  final prefix = '$entry/';
  return files.any((f) => f.startsWith(prefix))
      ? ScopeKind.folder
      : ScopeKind.file;
}

/// How many files an entry covers right now: the files under a folder, 1 or 0 for a file (0
/// is fine, the agent may create it), null for a pattern (matched by the backend).
int? scopeFileCount(String entry, List<String> files) {
  switch (scopeKind(entry, files)) {
    case ScopeKind.pattern:
      return null;
    case ScopeKind.folder:
      final prefix = entry.endsWith('/') ? entry : '$entry/';
      return files.where((f) => f.startsWith(prefix)).length;
    case ScopeKind.file:
      return files.contains(entry) ? 1 : 0;
  }
}

/// [scope] with [entry] added (normalized; nothing changes for a blank or repeated entry).
String addScopeEntry(String scope, String entry) {
  final e = normalizeScopeEntry(entry);
  final all = parseScope(scope);
  if (e.isEmpty || all.contains(e)) return scope;
  return [...all, e].join(', ');
}

String removeScopeEntry(String scope, String entry) =>
    parseScope(scope).where((e) => e != entry).join(', ');

/// Text typed or pasted into the scope input, cut at each comma or newline: the complete
/// entries (to become chips) and what is left after the last separator (still being typed).
({List<String> done, String rest}) splitScopeInput(String text) {
  final parts = text.split(RegExp(r'[,\n]'));
  final rest = parts.removeLast();
  return (
    done: [
      for (final p in parts)
        if (normalizeScopeEntry(p).isNotEmpty) normalizeScopeEntry(p),
    ],
    rest: rest,
  );
}

class ScopeSuggestion {
  const ScopeSuggestion(
    this.path, {
    required this.dir,
    this.all = false,
    this.pattern = false,
    this.up = false,
  });

  /// Relative path; a directory ends with `/`.
  final String path;
  final bool dir;

  /// The folder the typed path is inside, offered first: "the whole of this folder".
  final bool all;

  /// A typed glob offered as it is, because it cannot be completed.
  final bool pattern;

  /// "Back": the folder above the one being listed (empty path is the top).
  final bool up;
}

/// The folder above `src/lib/`: `src/`. The top is the empty string.
String scopeParent(String dir) {
  final t = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  final i = t.lastIndexOf('/');
  return i == -1 ? '' : t.substring(0, i + 1);
}

final _dirsMemo = Expando<List<String>>('scopeDirs');

/// Every folder that holds a file, as `a/` and `a/b/`, once each.
List<String> scopeFolders(List<String> files) {
  final cached = _dirsMemo[files];
  if (cached != null) return cached;
  final seen = <String>{};
  for (final f in files) {
    var i = f.indexOf('/');
    while (i != -1) {
      seen.add(f.substring(0, i + 1));
      i = f.indexOf('/', i + 1);
    }
  }
  return _dirsMemo[files] = seen.toList();
}

String _baseName(String path) {
  final t = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  return t.substring(t.lastIndexOf('/') + 1);
}

/// Paths to offer for what is typed in the scope input.
///
/// A bare name searches the whole project: folders and files whose name starts with it, then
/// contains it, so `comp` finds `app/components/`. Once there is a slash it lists what is
/// inside that folder one level at a time, with the folder itself first ("everything in it").
/// Folders come before files at the same rank. A pattern is left to the caller.
List<ScopeSuggestion> scopeSuggestions(
  List<String> files,
  String query, {
  int limit = 8,
}) {
  final q = normalizeScopeEntry(query);
  if (_hasGlob(q)) return const [];
  final slash = q.lastIndexOf('/');
  if (slash == -1 && q.isNotEmpty) return _searchEverywhere(files, q, limit);
  final dirPart = slash == -1 ? '' : q.substring(0, slash + 1);
  final name = q.substring(slash + 1).toLowerCase();
  final dirLower = dirPart.toLowerCase();

  final seen = <String>{};
  final entries = <ScopeSuggestion>[];
  for (final p in files) {
    if (p.length < dirPart.length ||
        p.substring(0, dirPart.length).toLowerCase() != dirLower) {
      continue;
    }
    final rest = p.substring(dirPart.length);
    final cut = rest.indexOf('/');
    final dir = cut != -1;
    final seg = dir ? rest.substring(0, cut) : rest;
    if (seg.isEmpty) continue;
    final path = '${p.substring(0, dirPart.length)}$seg${dir ? '/' : ''}';
    if (seen.add(path)) entries.add(ScopeSuggestion(path, dir: dir));
  }
  String segOf(ScopeSuggestion s) => _baseName(s.path).toLowerCase();
  var hits = [
    for (final e in entries)
      if (segOf(e).startsWith(name)) e,
  ];
  if (hits.isEmpty && name.isNotEmpty) {
    hits = [
      for (final e in entries)
        if (segOf(e).contains(name)) e,
    ];
  }
  hits.sort((a, b) {
    if (a.dir != b.dir) return a.dir ? -1 : 1;
    return a.path.toLowerCase().compareTo(b.path.toLowerCase());
  });
  final out = <ScopeSuggestion>[
    if (dirPart.isNotEmpty && name.isEmpty && entries.isNotEmpty)
      ScopeSuggestion(
        entries.first.path.substring(0, dirPart.length),
        dir: true,
        all: true,
      ),
    for (final h in hits)
      if (h.path != q) h,
  ];
  return out.take(limit).toList();
}

List<ScopeSuggestion> _searchEverywhere(
  List<String> files,
  String q,
  int limit,
) {
  final needle = q.toLowerCase();
  final scored = <(int, ScopeSuggestion)>[];
  final inPath = <ScopeSuggestion>[];
  void consider(String path, bool dir) {
    final base = _baseName(path).toLowerCase();
    int? rank;
    if (base == needle) {
      rank = dir ? 0 : 2;
    } else if (base.startsWith(needle)) {
      rank = dir ? 1 : 3;
    } else if (base.contains(needle)) {
      rank = dir ? 4 : 5;
    } else if (path.toLowerCase().contains(needle)) {
      inPath.add(ScopeSuggestion(path, dir: dir));
    }
    if (rank != null) scored.add((rank, ScopeSuggestion(path, dir: dir)));
  }

  for (final d in scopeFolders(files)) {
    consider(d, true);
  }
  for (final f in files) {
    consider(f, false);
  }
  // A name that is only somewhere in the path (a file under a matching folder) is a last
  // resort, so `src` does not also list every file inside src/.
  if (scored.isEmpty) {
    for (final e in inPath) {
      scored.add((6, e));
    }
  }
  scored.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (a.$2.path.length != b.$2.path.length) {
      return a.$2.path.length.compareTo(b.$2.path.length);
    }
    return a.$2.path.compareTo(b.$2.path);
  });
  return [
    for (final e in scored)
      if (e.$2.path != q) e.$2,
  ].take(limit).toList();
}

// ---- autocomplete ----

enum TriggerKind { slash, at }

class Trigger {
  const Trigger({
    required this.kind,
    required this.query,
    required this.start,
    required this.end,
  });

  final TriggerKind kind;

  /// Text typed after the trigger char, up to the caret.
  final String query;

  /// Index of the `/` or `@`.
  final int start;

  /// Caret position: end of the token being completed.
  final int end;

  String get key => '${kind.name}:$start:$query';
}

class SlashCommand {
  const SlashCommand(this.name, this.description);

  final String name;
  final String description;
}

const slashCommands = [
  SlashCommand('/mcp', 'Manage MCP servers'),
  SlashCommand('/clear', 'Clear conversation history'),
  SlashCommand('/compact', 'Summarize & compact the conversation'),
  SlashCommand('/review', 'Review a pull request'),
  SlashCommand('/init', 'Generate a CLAUDE.md for the repo'),
  SlashCommand('/help', 'Show available commands'),
  SlashCommand('/model', 'Change the model'),
];

bool _isSpace(String? ch) =>
    ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';

/// The active `/` or `@` token at the caret, or null. `@` wins over `/`, because `/` only
/// triggers at the very start of the input while `@` paths may contain `/`.
Trigger? detectTrigger(String text, int caret) {
  final pos = caret.clamp(0, text.length);
  for (var i = pos - 1; i >= 0; i--) {
    final ch = text[i];
    if (_isSpace(ch)) break;
    if (ch == '@') {
      final before = i == 0 ? null : text[i - 1];
      if (i == 0 || _isSpace(before)) {
        return Trigger(
          kind: TriggerKind.at,
          query: text.substring(i + 1, pos),
          start: i,
          end: pos,
        );
      }
      break;
    }
  }
  if (text.isNotEmpty && text[0] == '/') {
    final head = text.substring(0, pos);
    if (!RegExp(r'\s').hasMatch(head)) {
      return Trigger(
        kind: TriggerKind.slash,
        query: text.substring(1, pos),
        start: 0,
        end: pos,
      );
    }
  }
  return null;
}

List<SlashCommand> filterSlashCommands(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return slashCommands;
  return [
    for (final c in slashCommands)
      if (c.name.substring(1).toLowerCase().contains(q)) c,
  ];
}

List<String> flattenFiles(List<FileNode> nodes) {
  final out = <String>[];
  void walk(List<FileNode> ns) {
    for (final n in ns) {
      if (n.dir) {
        walk(n.children);
      } else {
        out.add(n.path);
      }
    }
  }

  walk(nodes);
  return out;
}

String _basename(String p) {
  final i = p.lastIndexOf('/');
  return i == -1 ? p : p.substring(i + 1);
}

int _score(String path, String q) {
  final p = path.toLowerCase();
  final base = _basename(p);
  if (base == q) return 5;
  if (base.startsWith(q)) return 4;
  if (base.contains(q)) return 3;
  if (p.startsWith(q)) return 2;
  return 1;
}

/// Basename hits before deep-path hits, prefixes before mid-string matches. Empty query
/// returns the head of the list.
List<String> filterFiles(List<String> paths, String query, {int limit = 50}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return paths.take(limit).toList();
  final hits = [
    for (final p in paths)
      if (p.toLowerCase().contains(q)) p,
  ];
  // Stable: Dart's List.sort is not, so keep the original index as a tiebreaker.
  final indexed = [for (var i = 0; i < hits.length; i++) (i, hits[i])];
  indexed.sort((a, b) {
    final c = _score(b.$2, q).compareTo(_score(a.$2, q));
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed.take(limit)) e.$2];
}

/// Replaces the trigger token with [insert] plus a trailing space.
({String text, int caret}) applyCompletion(
  String text,
  Trigger trigger,
  String insert,
) {
  final before = text.substring(0, trigger.start);
  final after = text.substring(trigger.end);
  final insertion = '$insert ';
  return (
    text: before + insertion + after,
    caret: before.length + insertion.length,
  );
}

// ---- attachments ----

const pasteToFileLines = 20;
const pasteToFileChars = 2000;

bool shouldAttachPaste(String text) {
  if (text.isEmpty) return false;
  return '\n'.allMatches(text).length + 1 >= pasteToFileLines ||
      text.length >= pasteToFileChars;
}

/// The text a single edit put in, or null when the edit only removed text. A paste over a
/// selection counts: the common prefix and suffix are peeled off and what is left in [after]
/// is the insertion.
String? insertedText(String before, String after) {
  var prefix = 0;
  final shorter = before.length < after.length ? before.length : after.length;
  while (prefix < shorter && before[prefix] == after[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < shorter - prefix &&
      before[before.length - 1 - suffix] == after[after.length - 1 - suffix]) {
    suffix++;
  }
  final inserted = after.substring(prefix, after.length - suffix);
  final removed = before.length - prefix - suffix;
  return inserted.length > removed ? inserted : null;
}

/// Diverts a big paste out of the field: the paste is rejected and handed to [onPaste]
/// instead, which promotes it to a `.context/` file.
class LargePasteFormatter extends TextInputFormatter {
  LargePasteFormatter(this.onPaste);

  final void Function(String text) onPaste;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final ins = insertedText(oldValue.text, newValue.text);
    if (ins == null || !shouldAttachPaste(ins)) return newValue;
    onPaste(ins);
    return oldValue;
  }
}

class Attachment {
  const Attachment({
    required this.path,
    required this.name,
    this.kind = 'text',
    this.lines,
    this.size,
  });

  factory Attachment.from(ContextAttachment c) => Attachment(
    path: c.path,
    name: c.name.isEmpty ? _basename(c.path) : c.name,
    kind: c.kind,
    lines: c.lines,
    size: c.size,
  );

  final String path;
  final String name;
  final String kind;
  final int? lines;
  final int? size;

  /// Chip stat: line count for text, byte size for images and files.
  String get stat {
    if (kind == 'image' || kind == 'file') {
      return size != null ? formatBytes(size!) : kind;
    }
    final n = lines ?? 0;
    return '$n ${n == 1 ? 'line' : 'lines'}';
  }
}

String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).round()} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Folds attachments into the task as `@path` mentions so the agent reads them. Attachments
/// alone (no typed prose) still produce a valid task.
String composeWithAttachments(String task, List<Attachment> attachments) {
  final mentions = attachments.map((a) => '@${a.path}').join(' ');
  final trimmed = task.trim();
  if (mentions.isEmpty) return trimmed;
  return trimmed.isEmpty ? mentions : '$trimmed\n\n$mentions';
}

// ---- roles and run arguments ----

/// The step a submit runs, given the "plan first" toggle.
String nextRole({required bool planFirst}) => planFirst ? 'plan' : 'build';

/// `fable:xhigh` -> `fable · xhigh`; `haiku` -> `haiku`; empty -> `not set`.
String roleLabel(String shorthand) {
  if (shorthand.isEmpty) return 'not set';
  final i = shorthand.indexOf(':');
  if (i == -1) return shorthand;
  final model = shorthand.substring(0, i);
  final effort = shorthand.substring(i + 1);
  return effort.isEmpty ? model : '$model · $effort';
}

/// `(model, effort)` from a `model:effort` shorthand.
(String, String?) splitRole(String shorthand) {
  final i = shorthand.indexOf(':');
  if (i == -1) return (shorthand, null);
  final effort = shorthand.substring(i + 1);
  return (shorthand.substring(0, i), effort.isEmpty ? null : effort);
}

class RunArgs {
  const RunArgs({this.adapter, this.model, this.effort});

  final String? adapter;
  final String? model;
  final String? effort;
}

/// Model, effort and adapter for `startAgent`. With `[roles]` on, model and effort are left
/// out: a stale picker value would win over the role server-side and reopen the "approve a
/// plan, build at the plan's model" trap roles exist to close.
RunArgs resolveRunArgs({
  required bool rolesEnabled,
  String? adapter,
  String? localModel,
  String? model,
  String? effort,
}) {
  if (rolesEnabled) return const RunArgs(adapter: 'claude-code');
  if (adapter == 'local') {
    return RunArgs(
      adapter: 'local',
      model: (localModel == null || localModel.isEmpty) ? null : localModel,
    );
  }
  return RunArgs(
    adapter: 'claude-code',
    model: (model == null || model.isEmpty || model == 'default')
        ? null
        : model,
    effort: (effort == null || effort.isEmpty || effort == 'default')
        ? null
        : effort,
  );
}

/// True only when an agent or test run occupies the worktree.
bool isAgentBusy(WorkspaceStatus s) =>
    s == WorkspaceStatus.agentRunning || s == WorkspaceStatus.testsRunning;
