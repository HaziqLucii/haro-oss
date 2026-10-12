import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'editor_sticky.dart';

/// Open editor tabs for one workspace, split into up to two panes.
///
/// The shared contract of the code step: the explorer, search, changes, ⌘P and the bottom panel
/// all open files through [EditorTabsNotifier.open]; the editor renders [EditorTabsState].

/// Which body a tab shows: the file's diff against the base, or the editor.
enum CodeMode { diff, edit }

class EditorTab {
  const EditorTab({
    required this.path,
    this.preview = true,
    this.dirty = false,
    this.mode,
  });

  final String path;

  /// Italic in the tab strip; the next preview open replaces it. Pinned by a double-click or an edit.
  final bool preview;
  final bool dirty;

  /// A body this tab was opened with (Show diff, or a jump to a line), or null to follow the
  /// editor's Diff | Edit choice ([EditorTabsState.viewMode]).
  final CodeMode? mode;

  EditorTab copyWith({bool? preview, bool? dirty, CodeMode? mode}) => EditorTab(
    path: path,
    preview: preview ?? this.preview,
    dirty: dirty ?? this.dirty,
    mode: mode ?? this.mode,
  );

  EditorTab withoutMode() =>
      EditorTab(path: path, preview: preview, dirty: dirty);

  /// What to show: this tab's own body if it has one, else [viewMode] for a file the workspace
  /// changed. A file without changes has no diff to show, so it is always the editor.
  CodeMode resolveMode({
    required bool changed,
    CodeMode viewMode = CodeMode.diff,
  }) => mode ?? (changed ? viewMode : CodeMode.edit);
}

class EditorPane {
  const EditorPane({this.tabs = const [], this.activePath});

  final List<EditorTab> tabs;
  final String? activePath;

  EditorTab? get active {
    for (final t in tabs) {
      if (t.path == activePath) return t;
    }
    return null;
  }

  bool has(String path) => tabs.any((t) => t.path == path);
}

/// A line to reveal once the file at [path] is shown; [serial] makes repeat jumps to the same line fire.
/// [col] is 1-based and puts the cursor on the symbol a go-to-definition lands on.
class EditorJump {
  const EditorJump(this.path, this.line, this.serial, {this.col = 1});

  final String path;
  final int line;
  final int serial;
  final int col;
}

/// Where the cursor and the scroll were when an editor was last closed over [path]: coming back
/// (leaving the step, or restarting the app) puts both back. [line] and [col] are 1-based.
class EditorPlace {
  const EditorPlace({required this.line, required this.col, this.scroll = 0});

  final int line;
  final int col;
  final double scroll;

  @override
  bool operator ==(Object other) =>
      other is EditorPlace &&
      other.line == line &&
      other.col == col &&
      other.scroll == scroll;

  @override
  int get hashCode => Object.hash(line, col, scroll);

  @override
  String toString() => 'EditorPlace($line:$col @ $scroll)';
}

class EditorTabsState {
  const EditorTabsState({
    this.panes = const [EditorPane()],
    this.focusedPane = 0,
    this.jump,
    this.viewMode = CodeMode.diff,
    this.places = const {},
  });

  /// Cursor and scroll per open file, kept here (not on the buffer) so they outlive the buffers
  /// and can be saved with the rest of the sticky state.
  final Map<String, EditorPlace> places;

  /// The Diff | Edit choice, shared by every tab and pane (the toggle in a tab strip sets it).
  final CodeMode viewMode;

  /// One pane, or two after "split right" / "open to the side".
  final List<EditorPane> panes;
  final int focusedPane;
  final EditorJump? jump;

  EditorPane get focused => panes[focusedPane];
  String? get activePath => focused.activePath;

  bool get split => panes.length > 1;

  /// Every open path, once, across both panes.
  Set<String> get openPaths => {
    for (final p in panes)
      for (final t in p.tabs) t.path,
  };

  Set<String> get dirtyPaths => {
    for (final p in panes)
      for (final t in p.tabs)
        if (t.dirty) t.path,
  };

  EditorTabsState copyWith({
    List<EditorPane>? panes,
    int? focusedPane,
    EditorJump? jump,
    CodeMode? viewMode,
    Map<String, EditorPlace>? places,
  }) => EditorTabsState(
    panes: panes ?? this.panes,
    focusedPane: focusedPane ?? this.focusedPane,
    jump: jump ?? this.jump,
    viewMode: viewMode ?? this.viewMode,
    places: places ?? this.places,
  );
}

class EditorTabsNotifier extends Notifier<EditorTabsState> {
  EditorTabsNotifier(this.workspaceId);

  final String workspaceId;
  int _jumps = 0;

  /// Set by the first [open] or [restore]: a restore that arrives after the user already
  /// opened something must not replace it.
  bool _touched = false;

  @override
  EditorTabsState build() => const EditorTabsState();

  /// Opens [path] in the focused pane (or the side pane when [toSide]), optionally at [line] and
  /// [col] (both 1-based)
  /// and with a fixed body [mode] (Show diff).
  /// A preview open replaces the pane's existing preview tab; an already-open tab is just activated
  /// (and pinned when [preview] is false).
  ///
  /// A file lives in one pane: opening one that another pane holds activates it there, and
  /// opening it to the side moves its tab across. Two live editors cannot share one buffer.
  void open(
    String path, {
    int? line,
    bool preview = true,
    bool toSide = false,
    CodeMode? mode,
    int col = 1,
  }) {
    _touched = true;
    var panes = [...state.panes];
    var target = state.focusedPane;
    final holder = panes.indexWhere((p) => p.has(path));
    EditorTab? carried;
    if (toSide) {
      if (panes.length == 1) panes.add(const EditorPane());
      target = 1;
      if (holder == 0) {
        final from = panes[0];
        carried = from.tabs.firstWhere((t) => t.path == path);
        final rest = [...from.tabs]..removeWhere((t) => t.path == path);
        final wasActive = from.activePath == path;
        panes[0] = EditorPane(
          tabs: rest,
          activePath: wasActive
              ? (rest.isEmpty ? null : rest.last.path)
              : from.activePath,
        );
        if (rest.isEmpty) {
          panes.removeAt(0);
          target = 0;
        }
      }
    } else if (holder >= 0 && holder != target) {
      target = holder;
    }
    final pane = panes[target];
    final tabs = [...pane.tabs];
    final existing = tabs.indexWhere((t) => t.path == path);
    if (existing >= 0) {
      if (!preview) tabs[existing] = tabs[existing].copyWith(preview: false);
    } else if (carried != null) {
      tabs.add(carried.copyWith(preview: false));
    } else {
      final previewAt = tabs.indexWhere((t) => t.preview && !t.dirty);
      final tab = EditorTab(path: path, preview: preview);
      if (preview && previewAt >= 0) {
        tabs[previewAt] = tab;
      } else {
        tabs.add(tab);
      }
    }
    // Only the editor can reveal a line, so a jump switches the tab to it; Show diff asks for
    // the other body. Either way it is this tab only, the Diff | Edit choice is untouched.
    final wanted = line != null ? CodeMode.edit : mode;
    if (wanted != null) {
      final at = tabs.indexWhere((t) => t.path == path);
      tabs[at] = tabs[at].copyWith(mode: wanted);
    }
    panes[target] = EditorPane(tabs: tabs, activePath: path);
    state = EditorTabsState(
      panes: panes,
      focusedPane: target,
      jump: line != null
          ? EditorJump(path, line, ++_jumps, col: col)
          : (state.jump?.path == path ? state.jump : null),
      viewMode: state.viewMode,
      places: state.places,
    );
  }

  /// The editor that revealed the line calls this: a jump fires once, then is gone, so a
  /// remounted editor (leaving the step and coming back) never replays it.
  void consumeJump(int serial) {
    if (state.jump?.serial != serial) return;
    state = EditorTabsState(
      panes: state.panes,
      focusedPane: state.focusedPane,
      viewMode: state.viewMode,
      places: state.places,
    );
  }

  void pin(String path) => _mapTab(path, (t) => t.copyWith(preview: false));

  /// The Diff | Edit toggle: one choice for every tab and both panes, and it clears any body a
  /// tab was opened with, so what you just picked is what you see.
  void setMode(CodeMode mode) {
    state = state.copyWith(
      viewMode: mode,
      panes: [
        for (final p in state.panes)
          EditorPane(
            tabs: [for (final t in p.tabs) t.withoutMode()],
            activePath: p.activePath,
          ),
      ],
    );
  }

  /// ⌘\: with one pane, opens an empty second pane on the right and focuses it (the next file
  /// opened lands there); with two, folds the second pane's tabs back into the first.
  void toggleSplit() {
    if (state.split) {
      closeSplit();
      return;
    }
    if (state.focused.tabs.isEmpty) return;
    state = EditorTabsState(
      panes: [state.panes.first, const EditorPane()],
      focusedPane: 1,
      jump: state.jump,
      viewMode: state.viewMode,
      places: state.places,
    );
  }

  /// Merges the side pane's tabs into the first pane and drops the split. A tab the first
  /// pane already has keeps its place; the side pane's dirty flag wins.
  void closeSplit() {
    if (!state.split) return;
    final first = [...state.panes.first.tabs];
    for (final t in state.panes[1].tabs) {
      if (!first.any((f) => f.path == t.path)) first.add(t);
    }
    final side = state.panes[1].activePath;
    state = EditorTabsState(
      panes: [
        EditorPane(
          tabs: first,
          activePath: side ?? state.panes.first.activePath,
        ),
      ],
      jump: state.jump,
      viewMode: state.viewMode,
      places: state.places,
    );
  }

  /// Removes [path] from every pane (the file was deleted or renamed).
  void closeEverywhere(String path) {
    for (var p = state.panes.length - 1; p >= 0; p--) {
      if (p < state.panes.length && state.panes[p].has(path)) {
        close(path, pane: p);
      }
    }
    if (state.places.containsKey(path)) {
      state = state.copyWith(places: _placesWithout(path));
    }
  }

  static bool _under(String prefix, String path) =>
      path == prefix || path.startsWith('$prefix/');

  Map<String, EditorPlace> _placesWithout(String path) => {
    for (final e in state.places.entries)
      if (!_under(path, e.key)) e.key: e.value,
  };

  /// Removes [path], and everything below it when it is a folder, from every pane in one
  /// update (a file or folder was deleted). Closing tab by tab against a stale pane list
  /// used to index a pane that had just collapsed.
  void closeUnder(String path) {
    final kept = <EditorPane>[];
    var focused = state.panes[state.focusedPane];
    EditorPane? focusedNow;
    for (final pane in state.panes) {
      final tabs = [
        for (final t in pane.tabs)
          if (!_under(path, t.path)) t,
      ];
      if (tabs.length == pane.tabs.length) {
        kept.add(pane);
        if (identical(pane, focused)) focusedNow = pane;
        continue;
      }
      final active = pane.activePath;
      String? nextActive = active;
      if (active != null && _under(path, active)) {
        final at = pane.tabs.indexWhere((t) => t.path == active);
        nextActive = tabs.isEmpty
            ? null
            : tabs[at.clamp(0, tabs.length - 1)].path;
      }
      final next = EditorPane(tabs: tabs, activePath: nextActive);
      kept.add(next);
      if (identical(pane, focused)) focusedNow = next;
    }
    if (kept.length == 2) {
      final live = [
        for (final p in kept)
          if (p.tabs.isNotEmpty) p,
      ];
      if (live.length < 2) {
        final only = live.isEmpty ? const EditorPane() : live.first;
        focusedNow = only;
        kept
          ..clear()
          ..add(only);
      }
    }
    final jump = state.jump;
    state = EditorTabsState(
      panes: kept,
      focusedPane: focusedNow == null ? 0 : kept.indexOf(focusedNow),
      jump: jump != null && !_under(path, jump.path) ? jump : null,
      viewMode: state.viewMode,
      places: _placesWithout(path),
    );
  }

  /// A file (or a folder, and so every tab below it) was renamed: the tabs follow it with
  /// their place, pin, unsaved mark and body. A tab that would land on a path another tab in
  /// the same pane already holds is dropped.
  void movePath(String from, String to) {
    String moved(String p) => p == from
        ? to
        : (p.startsWith('$from/') ? '$to${p.substring(from.length)}' : p);
    EditorPane remap(EditorPane pane) {
      final seen = <String>{};
      final tabs = <EditorTab>[];
      for (final t in pane.tabs) {
        final path = moved(t.path);
        if (!seen.add(path)) continue;
        tabs.add(
          path == t.path
              ? t
              : EditorTab(
                  path: path,
                  preview: t.preview,
                  dirty: t.dirty,
                  mode: t.mode,
                ),
        );
      }
      final active = pane.activePath;
      return EditorPane(
        tabs: tabs,
        activePath: active == null ? null : moved(active),
      );
    }

    final jump = state.jump;
    state = EditorTabsState(
      panes: [for (final p in state.panes) remap(p)],
      focusedPane: state.focusedPane,
      jump: jump == null || moved(jump.path) == jump.path
          ? jump
          : EditorJump(moved(jump.path), jump.line, jump.serial, col: jump.col),
      viewMode: state.viewMode,
      places: {for (final e in state.places.entries) moved(e.key): e.value},
    );
  }

  /// An editor over [path] reports where the cursor and scroll were as it closes. Only files that
  /// still have a tab are kept: a closed tab's place is forgotten, and a deleted file's editor
  /// disposing after the delete cannot bring its entry back.
  void rememberPlace(String path, EditorPlace place) {
    if (!state.openPaths.contains(path)) return;
    if (state.places[path] == place) return;
    state = state.copyWith(places: {...state.places, path: place});
  }

  /// Puts back the tabs, panes, active file and places saved by an earlier session. Refused
  /// (false) once anything was opened, so a restore that lands late never replaces what the user
  /// just did. Nothing restored is dirty or carries a jump.
  bool restore(StickyEditorState sticky) {
    if (_touched || state.openPaths.isNotEmpty) return false;
    final panes = [
      for (final p in sticky.panes)
        EditorPane(
          tabs: [
            for (final t in p.tabs)
              EditorTab(path: t.path, preview: t.preview, mode: t.mode),
          ],
          activePath: p.active,
        ),
    ];
    if (panes.every((p) => p.tabs.isEmpty)) return false;
    _touched = true;
    state = EditorTabsState(
      panes: panes,
      focusedPane: sticky.focused.clamp(0, panes.length - 1),
      viewMode: sticky.viewMode,
      places: sticky.places,
    );
    return true;
  }

  /// Marks a tab dirty (which also pins it: an edited preview must not be replaced). Editing
  /// also fixes the tab on the editor: a tab with no body of its own shows Edit only while the
  /// file is unchanged, so without this the first save made the file "changed" and flipped the
  /// tab to Diff under the cursor.
  void setDirty(String path, bool dirty) => _mapTab(
    path,
    (t) => t.copyWith(
      dirty: dirty,
      preview: dirty ? false : t.preview,
      mode: dirty && t.mode == null ? CodeMode.edit : null,
    ),
  );

  void activate(String path, {int? pane}) {
    final p = pane ?? state.focusedPane;
    final panes = [...state.panes];
    panes[p] = EditorPane(tabs: panes[p].tabs, activePath: path);
    state = state.copyWith(panes: panes, focusedPane: p);
  }

  void focusPane(int pane) {
    if (pane < state.panes.length) state = state.copyWith(focusedPane: pane);
  }

  /// Closes [path] in [pane] (default: the focused pane). Callers confirm a dirty close first.
  /// An emptied side pane collapses the split.
  void close(String path, {int? pane}) {
    final p = pane ?? state.focusedPane;
    final panes = [...state.panes];
    final tabs = [...panes[p].tabs];
    final i = tabs.indexWhere((t) => t.path == path);
    if (i < 0) return;
    tabs.removeAt(i);
    var active = panes[p].activePath;
    if (active == path) {
      active = tabs.isEmpty ? null : tabs[i.clamp(0, tabs.length - 1)].path;
    }
    panes[p] = EditorPane(tabs: tabs, activePath: active);
    final held = panes.any((pane) => pane.has(path));
    final jump = state.jump?.path == path && !held ? null : state.jump;
    if (panes.length == 2 && panes[p].tabs.isEmpty) {
      panes.removeAt(p);
      state = EditorTabsState(
        panes: panes,
        jump: jump,
        viewMode: state.viewMode,
        places: state.places,
      );
    } else {
      state = EditorTabsState(
        panes: panes,
        focusedPane: state.focusedPane,
        jump: jump,
        viewMode: state.viewMode,
        places: state.places,
      );
    }
  }

  void _mapTab(String path, EditorTab Function(EditorTab) f) {
    state = state.copyWith(
      panes: [
        for (final p in state.panes)
          EditorPane(
            tabs: [for (final t in p.tabs) t.path == path ? f(t) : t],
            activePath: p.activePath,
          ),
      ],
    );
  }
}

final editorTabsProvider =
    NotifierProvider.family<EditorTabsNotifier, EditorTabsState, String>(
      EditorTabsNotifier.new,
    );
