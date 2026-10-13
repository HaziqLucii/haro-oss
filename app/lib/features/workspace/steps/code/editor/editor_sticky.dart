import 'dart:convert';

import '../../../../../api/models/json_util.dart';
import '../workbench/workbench_state.dart';
import 'editor_tabs.dart';

/// What the code step remembers per workspace between visits and app restarts: which files are
/// open in which pane, the active tab, the Diff | Edit choice, each open file's cursor and scroll,
/// and the side panel. Never buffer contents (they are re-read from disk), never a dirty flag
/// and never a pending jump: this is where you were, not unsaved work.
///
/// Port of `frontend/src/codeSticky.ts`. Stored in the device prefs file under `code_sticky`,
/// keyed by workspace id.
class StickyTab {
  const StickyTab({required this.path, this.preview = true, this.mode});

  final String path;
  final bool preview;
  final CodeMode? mode;

  StickyTab copy() => StickyTab(path: path, preview: preview, mode: mode);
}

class StickyPane {
  const StickyPane({this.tabs = const [], this.active});

  final List<StickyTab> tabs;
  final String? active;
}

class StickySide {
  const StickySide({
    this.view = WorkbenchView.files,
    this.open = true,
    this.width = WorkbenchState.defaultSideWidth,
    this.scope = ExplorerScope.all,
  });

  final WorkbenchView view;
  final bool open;
  final double width;
  final ExplorerScope scope;
}

class StickyEditorState {
  const StickyEditorState({
    this.panes = const [],
    this.focused = 0,
    this.viewMode = CodeMode.diff,
    this.places = const {},
    this.side = const StickySide(),
    this.savedAt = 0,
  });

  /// Entries kept in the file, newest first by [savedAt].
  static const maxEntries = 40;

  final List<StickyPane> panes;
  final int focused;
  final CodeMode viewMode;
  final Map<String, EditorPlace> places;
  final StickySide side;

  /// Milliseconds since the epoch, for the least-recently-used cut.
  final int savedAt;

  /// Every open path, once, across both panes.
  List<String> get paths => [
    for (final p in panes)
      for (final t in p.tabs) t.path,
  ];

  bool get hasTabs => panes.any((p) => p.tabs.isNotEmpty);

  /// The live tabs and side panel as a snapshot. Places are kept for open files only.
  factory StickyEditorState.fromLive({
    required EditorTabsState tabs,
    required WorkbenchState workbench,
    required int savedAt,
  }) {
    final open = tabs.openPaths;
    return StickyEditorState(
      panes: [
        for (final p in tabs.panes)
          StickyPane(
            tabs: [
              for (final t in p.tabs)
                StickyTab(path: t.path, preview: t.preview, mode: t.mode),
            ],
            active: p.activePath,
          ),
      ],
      focused: tabs.focusedPane,
      viewMode: tabs.viewMode,
      places: {
        for (final e in tabs.places.entries)
          if (open.contains(e.key)) e.key: e.value,
      },
      side: StickySide(
        view: workbench.view,
        open: workbench.sideOpen,
        width: workbench.sideWidth,
        scope: workbench.scope,
      ),
      savedAt: savedAt,
    );
  }

  Json toJson() => {
    'panes': [
      for (final p in panes)
        {
          'tabs': [
            for (final t in p.tabs)
              {
                'path': t.path,
                'preview': t.preview,
                if (t.mode != null) 'mode': t.mode!.name,
              },
          ],
          'active': p.active,
        },
    ],
    'focused': focused,
    'view_mode': viewMode.name,
    'places': {
      for (final e in places.entries)
        e.key: {
          'line': e.value.line,
          'col': e.value.col,
          'scroll': e.value.scroll,
        },
    },
    'side': {
      'view': side.view.name,
      'open': side.open,
      'width': side.width,
      'scope': side.scope.name,
    },
    'saved_at': savedAt,
  };

  /// Everything but [savedAt]: two snapshots with the same key need no second write.
  String get contentKey => jsonEncode(toJson()..remove('saved_at'));

  /// A stored snapshot, or null when it is not one: not a map, no `panes` list (the older
  /// shape has `tabs` instead), or a pane that is not a map. Single bad tabs and places are
  /// skipped rather than failing the whole entry.
  static StickyEditorState? parse(Object? raw) {
    if (raw is! Map) return null;
    return fromJson(asJson(raw));
  }

  static StickyEditorState? fromJson(Json j) {
    final rawPanes = j['panes'];
    if (rawPanes is! List || rawPanes.isEmpty) return null;
    final seen = <String>{};
    final panes = <StickyPane>[];
    for (final rp in rawPanes.take(2)) {
      if (rp is! Map) return null;
      final pj = asJson(rp);
      final rawTabs = pj['tabs'];
      if (rawTabs is! List) return null;
      final tabs = <StickyTab>[];
      for (final rt in rawTabs) {
        if (rt is! Map) continue;
        final tj = asJson(rt);
        final path = jStr(tj, 'path');
        if (path.isEmpty || !seen.add(path)) continue;
        tabs.add(
          StickyTab(
            path: path,
            preview: jBool(tj, 'preview', true),
            mode: _modeOf(tj['mode']),
          ),
        );
      }
      final active = jStrN(pj, 'active');
      panes.add(
        StickyPane(
          tabs: tabs,
          active: tabs.any((t) => t.path == active)
              ? active
              : (tabs.isEmpty ? null : tabs.last.path),
        ),
      );
    }
    final places = <String, EditorPlace>{};
    final rawPlaces = j['places'];
    if (rawPlaces is Map) {
      for (final e in rawPlaces.entries) {
        final key = e.key;
        if (key is! String || key.isEmpty || e.value is! Map) continue;
        final pj = asJson(e.value);
        final line = jIntN(pj, 'line');
        final col = jIntN(pj, 'col');
        final scroll = jDoubleN(pj, 'scroll') ?? 0;
        if (line == null || col == null || line < 1 || col < 1) continue;
        if (!scroll.isFinite || scroll < 0) continue;
        places[key] = EditorPlace(line: line, col: col, scroll: scroll);
      }
    }
    final sj = asJson(j['side']);
    final width = jDoubleN(sj, 'width');
    return StickyEditorState(
      panes: panes,
      focused: jInt(j, 'focused').clamp(0, panes.length - 1),
      viewMode: _modeOf(j['view_mode']) ?? CodeMode.diff,
      places: places,
      side: StickySide(
        view:
            WorkbenchView.values.asNameMap()[jStr(sj, 'view')] ??
            WorkbenchView.files,
        open: jBool(sj, 'open', true),
        width: width != null && width.isFinite
            ? clampSideWidth(width)
            : WorkbenchState.defaultSideWidth,
        scope:
            ExplorerScope.values.asNameMap()[jStr(sj, 'scope')] ??
            ExplorerScope.all,
      ),
      savedAt: jInt(j, 'saved_at'),
    );
  }

  static CodeMode? _modeOf(Object? v) =>
      v is String ? CodeMode.values.asNameMap()[v] : null;

  /// This snapshot cut down to the files that still exist: tabs for other paths are dropped,
  /// panes left empty are dropped, the active tab moves to a neighbour. Null when no tab is left.
  StickyEditorState? keeping(Set<String> exists) {
    final kept = <StickyPane>[];
    int? focusedAt;
    for (var i = 0; i < panes.length; i++) {
      final p = panes[i];
      final tabs = [
        for (final t in p.tabs)
          if (exists.contains(t.path)) t.copy(),
      ];
      if (tabs.isEmpty) continue;
      if (i == focused) focusedAt = kept.length;
      final at = p.tabs.indexWhere((t) => t.path == p.active);
      var active = p.active;
      if (active == null || !exists.contains(active)) {
        final neighbour = tabs.indexWhere(
          (t) => p.tabs.indexWhere((o) => o.path == t.path) >= at,
        );
        active = tabs[neighbour < 0 ? tabs.length - 1 : neighbour].path;
      }
      kept.add(StickyPane(tabs: tabs, active: active));
    }
    if (kept.isEmpty) return null;
    final open = {
      for (final p in kept)
        for (final t in p.tabs) t.path,
    };
    return StickyEditorState(
      panes: kept,
      focused: focusedAt ?? 0,
      viewMode: viewMode,
      places: {
        for (final e in places.entries)
          if (open.contains(e.key)) e.key: e.value,
      },
      side: side,
      savedAt: savedAt,
    );
  }
}

/// Every parseable entry of the stored `code_sticky` object, by workspace id.
Map<String, StickyEditorState> parseStickyMap(Object? raw) {
  final out = <String, StickyEditorState>{};
  if (raw is! Map) return out;
  for (final e in raw.entries) {
    final key = e.key;
    if (key is! String) continue;
    final s = StickyEditorState.parse(e.value);
    if (s != null) out[key] = s;
  }
  return out;
}

/// [all] without workspaces that no longer exist (when [knownIds] is given) and cut to the
/// [max] most recently saved.
Map<String, StickyEditorState> pruneSticky(
  Map<String, StickyEditorState> all, {
  Set<String>? knownIds,
  int max = StickyEditorState.maxEntries,
}) {
  final live = [
    for (final e in all.entries)
      if (knownIds == null || knownIds.contains(e.key)) e,
  ]..sort((a, b) => b.value.savedAt.compareTo(a.value.savedAt));
  return {for (final e in live.take(max)) e.key: e.value};
}

/// The device prefs file with workspace [id]'s entry set to [state] (removed when it has no tab
/// left, as the React editor did) and the rest pruned. Keys other than `code_sticky` pass
/// through untouched. [id] itself is never pruned as unknown: the workspace list may be stale.
Json mergeSticky(
  Json file,
  String id,
  StickyEditorState state, {
  Set<String>? knownIds,
}) {
  final all = parseStickyMap(file['code_sticky']);
  if (state.hasTabs) {
    all[id] = state;
  } else {
    all.remove(id);
  }
  final pruned = pruneSticky(
    all,
    knownIds: knownIds == null ? null : {...knownIds, id},
  );
  return {
    ...file,
    'code_sticky': {for (final e in pruned.entries) e.key: e.value.toJson()},
  };
}
