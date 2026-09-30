import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart' show TextLineBreak;

import '../edit_buffer.dart';
import '../syntax.dart';
import 'editor_data.dart';
import 'editor_marks.dart';
import 'editor_tabs.dart';

enum EditorSave { saved, unsaved, saving }

/// What the status bar shows about the file in the editor. Read-only: derived from the
/// buffer, never written back.
@immutable
class EditorStatus {
  const EditorStatus({
    required this.line,
    required this.column,
    required this.spaces,
    required this.language,
    required this.eol,
    required this.save,
  });

  final int line;
  final int column;

  /// The file's indent step (2 when it has no indented lines).
  final int spaces;
  final String language;

  /// `LF` or `CRLF`.
  final String eol;
  final EditorSave save;

  String get position => 'Ln $line, Col $column';
  String get encoding => 'UTF-8 · $eol';

  @override
  bool operator ==(Object other) =>
      other is EditorStatus &&
      other.line == line &&
      other.column == column &&
      other.spaces == spaces &&
      other.language == language &&
      other.eol == eol &&
      other.save == save;

  @override
  int get hashCode => Object.hash(line, column, spaces, language, eol, save);
}

/// The status of [buffer], or null while it has no editor (loading, guarded, failed).
EditorStatus? editorStatusOf(EditBuffer? buffer) {
  final controller = buffer?.controller;
  if (buffer == null ||
      controller == null ||
      buffer.phase != BufferPhase.ready) {
    return null;
  }
  final sel = controller.selection;
  final lines = controller.codeLines;
  return EditorStatus(
    line: sel.extentIndex + 1,
    column: sel.extentOffset + 1,
    spaces: indentUnit([
      for (var i = 0; i < lines.length && i < 400; i++) lines[i].text,
    ]),
    language: languageLabel(languageForPath(buffer.path)),
    eol: controller.options.lineBreak == TextLineBreak.crlf ? 'CRLF' : 'LF',
    save: buffer.saving
        ? EditorSave.saving
        : buffer.dirty
        ? EditorSave.unsaved
        : EditorSave.saved,
  );
}

/// The path shown in the focused editor pane when that pane is on the Edit body (a diff has
/// no cursor), else null.
String? focusedEditPath(WidgetRef ref, String workspaceId) {
  final tabs = ref.watch(editorTabsProvider(workspaceId));
  final tab = tabs.focused.active;
  if (tab == null) return null;
  final parsed = ref.watch(parsedDiffProvider(workspaceId));
  final mode = tab.resolveMode(
    changed: parsed.byPath.containsKey(tab.path),
    viewMode: tabs.viewMode,
  );
  return mode == CodeMode.edit ? tab.path : null;
}
