import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_sticky.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/workbench_state.dart';

StickyEditorState sample({int savedAt = 5}) => StickyEditorState(
  panes: const [
    StickyPane(
      tabs: [
        StickyTab(path: 'a.ts', preview: false),
        StickyTab(path: 'b.md', mode: CodeMode.edit),
      ],
      active: 'b.md',
    ),
    StickyPane(
      tabs: [StickyTab(path: 'c.ts', preview: false)],
      active: 'c.ts',
    ),
  ],
  focused: 1,
  viewMode: CodeMode.edit,
  places: const {'a.ts': EditorPlace(line: 12, col: 4, scroll: 240.5)},
  side: const StickySide(
    view: WorkbenchView.search,
    open: false,
    width: 300,
    scope: ExplorerScope.changes,
  ),
  savedAt: savedAt,
);

void main() {
  test('round trips through JSON text', () {
    final back = StickyEditorState.parse(
      jsonDecode(jsonEncode(sample().toJson())),
    )!;
    expect(back.toJson(), sample().toJson());
    expect(back.panes[0].tabs[1].mode, CodeMode.edit);
    expect(back.panes[0].tabs[0].preview, isFalse);
    expect(
      back.places['a.ts'],
      const EditorPlace(line: 12, col: 4, scroll: 240.5),
    );
    expect(back.side.view, WorkbenchView.search);
    expect(back.side.open, isFalse);
    expect(back.focused, 1);
  });

  group('defensive parse', () {
    test('garbage and the older shape are null', () {
      for (final bad in <Object?>[
        null,
        'x',
        3,
        <Object?>[],
        <String, Object?>{},
        {'panes': 'no'},
        {'panes': <Object?>[]},
        {
          'panes': [3],
        },
        {
          'panes': [
            {'tabs': 'no'},
          ],
        },
        // frontend/src/codeSticky.ts shape
        {
          'tabs': [
            {'path': 'a.ts'},
          ],
          'active': 'a.ts',
        },
      ]) {
        expect(StickyEditorState.parse(bad), isNull, reason: '$bad');
      }
    });

    test('bad tabs, places and side values are skipped, not fatal', () {
      final s = StickyEditorState.parse({
        'panes': [
          {
            'tabs': [
              3,
              {'path': ''},
              {'path': 'a.ts', 'preview': 'yes', 'mode': 'bogus'},
              {'path': 'a.ts'},
              {'path': 'b.ts', 'mode': 'diff'},
            ],
            'active': 'gone.ts',
          },
        ],
        'focused': 9,
        'view_mode': 'nope',
        'places': {
          'a.ts': {'line': 0, 'col': 1, 'scroll': 0},
          'b.ts': {'line': 3, 'col': 2, 'scroll': -1},
          'c.ts': {'line': 'x', 'col': 1},
          'd.ts': {'line': 3, 'col': 2},
          7: {'line': 3, 'col': 2},
        },
        'side': {'view': 'zzz', 'width': 9999, 'scope': 1, 'open': 'no'},
      })!;
      expect(s.panes.single.tabs.map((t) => t.path), ['a.ts', 'b.ts']);
      expect(s.panes.single.tabs[0].preview, isTrue);
      expect(s.panes.single.tabs[0].mode, isNull);
      expect(s.panes.single.tabs[1].mode, CodeMode.diff);
      expect(s.panes.single.active, 'b.ts');
      expect(s.focused, 0);
      expect(s.viewMode, CodeMode.diff);
      expect(s.places.keys, ['d.ts']);
      expect(s.side.view, WorkbenchView.files);
      expect(s.side.open, isTrue);
      expect(s.side.width, WorkbenchState.maxSideWidth);
      expect(s.side.scope, ExplorerScope.all);
      expect(s.savedAt, 0);
    });

    test('a path held by two panes stays in the first', () {
      final s = StickyEditorState.parse({
        'panes': [
          {
            'tabs': [
              {'path': 'a.ts'},
            ],
          },
          {
            'tabs': [
              {'path': 'a.ts'},
              {'path': 'b.ts'},
            ],
          },
        ],
      })!;
      expect(s.panes[0].tabs.map((t) => t.path), ['a.ts']);
      expect(s.panes[1].tabs.map((t) => t.path), ['b.ts']);
    });
  });

  test('keeping drops missing files, empty panes and their places', () {
    final k = sample().keeping({'a.ts', 'c.ts'})!;
    expect(k.panes[0].tabs.map((t) => t.path), ['a.ts']);
    expect(k.panes[0].active, 'a.ts', reason: 'b.md was active and is gone');
    expect(k.panes[1].tabs.single.path, 'c.ts');
    expect(k.focused, 1);
    expect(k.places.keys, ['a.ts']);

    final one = sample().keeping({'a.ts', 'b.md'})!;
    expect(one.panes, hasLength(1), reason: 'the side pane lost its only tab');
    expect(one.focused, 0);
    expect(one.panes.single.active, 'b.md');

    expect(sample().keeping({'zzz'}), isNull);
    expect(sample().keeping({}), isNull);
  });

  test('fromLive keeps places for open tabs only and never the dirty flag', () {
    final tabs = EditorTabsState(
      panes: const [
        EditorPane(
          tabs: [
            EditorTab(path: 'a.ts', preview: false, dirty: true),
            EditorTab(path: 'b.ts', mode: CodeMode.diff),
          ],
          activePath: 'a.ts',
        ),
      ],
      jump: const EditorJump('a.ts', 3, 1),
      places: const {
        'a.ts': EditorPlace(line: 2, col: 1),
        'closed.ts': EditorPlace(line: 9, col: 9),
      },
    );
    final s = StickyEditorState.fromLive(
      tabs: tabs,
      workbench: const WorkbenchState(sideOpen: false),
      savedAt: 7,
    );
    expect(s.places.keys, ['a.ts']);
    expect(s.side.open, isFalse);
    expect(s.savedAt, 7);
    final json = jsonEncode(s.toJson());
    expect(json, isNot(contains('dirty')));
    expect(json, isNot(contains('jump')));
    expect(s.contentKey, isNot(contains('saved_at')));
  });

  group('storage', () {
    test('mergeSticky writes one workspace and keeps unrelated keys', () {
      final file = mergeSticky(
        {
          'display': {'density': 'compact'},
        },
        'w1',
        sample(),
      );
      expect(file['display'], {'density': 'compact'});
      final stored = parseStickyMap(file['code_sticky']);
      expect(stored.keys, ['w1']);
      expect(stored['w1']!.toJson(), sample().toJson());
    });

    test('a workspace with no tab left is removed', () {
      final file = mergeSticky(
        {
          'code_sticky': {'w1': sample().toJson()},
        },
        'w1',
        const StickyEditorState(panes: [StickyPane()], savedAt: 9),
      );
      expect(file['code_sticky'], isEmpty);
    });

    test('unknown workspace ids are dropped, the one being written is not', () {
      final file = mergeSticky(
        {
          'code_sticky': {
            'old': sample().toJson(),
            'live': sample().toJson(),
            'bad': 'garbage',
          },
        },
        'new',
        sample(),
        knownIds: {'live'},
      );
      expect(parseStickyMap(file['code_sticky']).keys.toSet(), {'live', 'new'});
    });

    test('keeps the 40 most recently saved', () {
      final all = {for (var i = 0; i < 45; i++) 'w$i': sample(savedAt: i)};
      final pruned = pruneSticky(all);
      expect(pruned, hasLength(40));
      expect(pruned.containsKey('w44'), isTrue);
      expect(pruned.containsKey('w5'), isTrue);
      expect(pruned.containsKey('w4'), isFalse);
      expect(pruned.containsKey('w0'), isFalse);

      final file = mergeSticky(
        {
          'code_sticky': {for (final e in all.entries) e.key: e.value.toJson()},
        },
        'fresh',
        sample(savedAt: 100),
      );
      final stored = parseStickyMap(file['code_sticky']);
      expect(stored, hasLength(40));
      expect(stored.containsKey('fresh'), isTrue);
      expect(stored.containsKey('w5'), isFalse);
    });
  });
}
