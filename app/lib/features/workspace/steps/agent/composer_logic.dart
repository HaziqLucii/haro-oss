import 'package:flutter/services.dart';

import '../../../../api/models/models.dart';

/// Pure composer logic, ported from the React client's `composerAutocomplete.ts`,
/// `attachments.ts`, `roles.ts` and `composerButton.ts`.

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
