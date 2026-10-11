import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_sticky.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_tabs.dart';

void main() {
  late ProviderContainer c;
  EditorTabsNotifier n() => c.read(editorTabsProvider('w').notifier);
  EditorTabsState s() => c.read(editorTabsProvider('w'));

  setUp(() => c = ProviderContainer());
  tearDown(() => c.dispose());

  test('a preview open replaces the previous preview', () {
    n().open('a.dart');
    n().open('b.dart');
    expect(s().focused.tabs.map((t) => t.path), ['b.dart']);
    expect(s().activePath, 'b.dart');
  });

  test('a pinned or dirty tab is never replaced by a preview', () {
    n().open('a.dart', preview: false);
    n().open('b.dart');
    n().setDirty('b.dart', true);
    n().open('c.dart');
    expect(s().focused.tabs.map((t) => t.path), ['a.dart', 'b.dart', 'c.dart']);
    expect(s().focused.tabs[1].preview, isFalse);
  });

  test(
    'editing a file keeps its tab on Edit after the save makes it changed',
    () {
      n().open('a.dart', preview: false);
      final before = s().focused.tabs.single;
      expect(before.resolveMode(changed: false), CodeMode.edit);
      n().setDirty('a.dart', true);
      n().setDirty('a.dart', false);
      final after = s().focused.tabs.single;
      expect(
        after.resolveMode(changed: true, viewMode: s().viewMode),
        CodeMode.edit,
      );
    },
  );

  test('the Diff | Edit toggle still wins after an edit', () {
    n().open('a.dart', preview: false);
    n().setDirty('a.dart', true);
    n().setDirty('a.dart', false);
    n().setMode(CodeMode.diff);
    expect(
      s().focused.tabs.single.resolveMode(
        changed: true,
        viewMode: s().viewMode,
      ),
      CodeMode.diff,
    );
  });

  test('opening at a line records a fresh jump each time', () {
    n().open('a.dart', line: 3);
    final first = s().jump!;
    n().open('a.dart', line: 3);
    expect(s().jump!.serial, greaterThan(first.serial));
    expect(s().jump!.line, 3);
  });

  test('open to the side splits, closing the last side tab collapses it', () {
    n().open('a.dart');
    n().open('b.dart', toSide: true);
    expect(s().panes, hasLength(2));
    expect(s().focusedPane, 1);
    n().close('b.dart');
    expect(s().panes, hasLength(1));
    expect(s().activePath, 'a.dart');
  });

  test('closing the active tab activates its neighbour', () {
    n().open('a.dart', preview: false);
    n().open('b.dart', preview: false);
    n().open('c.dart', preview: false);
    n().activate('b.dart');
    n().close('b.dart');
    expect(s().activePath, 'c.dart');
  });

  group('view mode', () {
    test('a changed file opens on its diff, any other on the editor', () {
      n().open('a.dart');
      final tab = s().focused.active!;
      expect(tab.mode, isNull);
      expect(s().viewMode, CodeMode.diff);
      expect(tab.resolveMode(changed: true), CodeMode.diff);
      expect(tab.resolveMode(changed: false), CodeMode.edit);
    });

    test('the Diff | Edit pick is shared by every tab and pane', () {
      n().open('a.dart', preview: false);
      n().open('b.dart', toSide: true);
      n().setMode(CodeMode.edit);
      expect(s().viewMode, CodeMode.edit);
      for (final p in s().panes) {
        expect(
          p.active!.resolveMode(changed: true, viewMode: s().viewMode),
          CodeMode.edit,
        );
      }
      n().setMode(CodeMode.diff);
      expect(
        s().panes[1].active!.resolveMode(changed: true, viewMode: s().viewMode),
        CodeMode.diff,
      );
    });

    test('a file with no changes is the editor even in Diff', () {
      n().open('a.dart');
      expect(
        s().focused.active!.resolveMode(
          changed: false,
          viewMode: CodeMode.diff,
        ),
        CodeMode.edit,
      );
    });

    test('the pick survives opening and closing files', () {
      n().setMode(CodeMode.edit);
      n().open('a.dart');
      n().close('a.dart');
      n().open('b.dart', toSide: true);
      expect(s().viewMode, CodeMode.edit);
    });

    test('opening at a line switches that tab to the editor only', () {
      n().open('a.dart', preview: false);
      n().open('b.dart', preview: false);
      n().open('a.dart', line: 12);
      expect(s().focused.active!.mode, CodeMode.edit);
      expect(s().focused.tabs.last.mode, isNull);
      expect(s().viewMode, CodeMode.diff);
    });

    test('Show diff opens one tab on the diff while the pick is Edit', () {
      n().setMode(CodeMode.edit);
      n().open('a.dart', preview: false, mode: CodeMode.diff);
      expect(
        s().focused.active!.resolveMode(changed: true, viewMode: s().viewMode),
        CodeMode.diff,
      );
      n().open('b.dart', preview: false);
      expect(
        s().focused.active!.resolveMode(changed: true, viewMode: s().viewMode),
        CodeMode.edit,
      );
    });

    test('picking Diff | Edit clears the bodies tabs were opened with', () {
      n().open('a.dart', preview: false, mode: CodeMode.diff);
      n().open('b.dart', line: 3);
      n().setMode(CodeMode.edit);
      expect(s().focused.tabs.map((t) => t.mode), [null, null]);
    });

    test('a plain re-open leaves a tab\'s own body alone', () {
      n().open('a.dart', preview: false, mode: CodeMode.diff);
      n().open('a.dart');
      expect(s().focused.active!.mode, CodeMode.diff);
    });
  });

  group('split', () {
    test('toggling with nothing open does nothing', () {
      n().toggleSplit();
      expect(s().split, isFalse);
    });

    test('opens an empty second pane and focuses it', () {
      n().open('a.dart', preview: false);
      n().toggleSplit();
      expect(s().split, isTrue);
      expect(s().focusedPane, 1);
      expect(s().panes[1].tabs, isEmpty);
      expect(s().panes[0].tabs.map((t) => t.path), ['a.dart']);
    });

    test('the next open lands in the new pane', () {
      n().open('a.dart', preview: false);
      n().toggleSplit();
      n().open('b.dart', preview: false);
      expect(s().panes[0].tabs.map((t) => t.path), ['a.dart']);
      expect(s().panes[1].tabs.map((t) => t.path), ['b.dart']);
    });

    test('toggling again folds the side tabs back into the first pane', () {
      n().open('a.dart', preview: false);
      n().toggleSplit();
      n().open('c.dart', preview: false);
      n().toggleSplit();
      expect(s().split, isFalse);
      expect(s().focusedPane, 0);
      expect(s().panes.single.tabs.map((t) => t.path), ['a.dart', 'c.dart']);
      expect(s().activePath, 'c.dart');
    });

    test('each pane has its own tabs and active file', () {
      n().open('a.dart', preview: false);
      n().open('x.dart', preview: false);
      n().toggleSplit();
      n().open('b.dart', preview: false);
      n().activate('a.dart', pane: 0);
      expect(s().panes[0].activePath, 'a.dart');
      expect(s().panes[1].activePath, 'b.dart');
      expect(s().openPaths, {'a.dart', 'x.dart', 'b.dart'});
    });

    test("a preview open replaces only the focused pane's preview", () {
      n().open('a.dart', preview: false);
      n().toggleSplit();
      n().open('b.dart');
      n().open('c.dart');
      expect(s().panes[0].tabs.map((t) => t.path), ['a.dart']);
      expect(s().panes[1].tabs.map((t) => t.path), ['c.dart']);
    });

    test('a file already open in the other pane is activated there', () {
      n().open('a.dart', preview: false);
      n().toggleSplit();
      n().open('b.dart', preview: false);
      n().open('a.dart');
      expect(s().panes[1].tabs.map((t) => t.path), ['b.dart']);
      expect(s().panes[0].tabs.map((t) => t.path), ['a.dart']);
      expect(s().focusedPane, 0);
      expect(s().activePath, 'a.dart');
    });

    test('open to the side moves the tab across, mode and dirty intact', () {
      n().open('a.dart', preview: false);
      n().open('b.dart', preview: false, mode: CodeMode.edit);
      n().setDirty('b.dart', true);
      n().open('b.dart', toSide: true);
      expect(s().panes[0].tabs.map((t) => t.path), ['a.dart']);
      expect(s().panes[1].tabs.map((t) => t.path), ['b.dart']);
      expect(s().panes[1].tabs.single.mode, CodeMode.edit);
      expect(s().panes[1].tabs.single.dirty, isTrue);
      expect(s().panes[0].activePath, 'a.dart');
      expect(s().focusedPane, 1);
    });

    test(
      'moving the only tab to the side leaves one pane, not an empty one',
      () {
        n().open('a.dart', preview: false);
        n().open('a.dart', toSide: true);
        expect(s().split, isFalse);
        expect(s().panes.single.tabs.map((t) => t.path), ['a.dart']);
      },
    );
  });

  group('dirty and closing', () {
    test('dirtyPaths collects across panes and setDirty pins', () {
      n().open('a.dart');
      n().setDirty('a.dart', true);
      expect(s().dirtyPaths, {'a.dart'});
      expect(s().focused.active!.preview, isFalse);
      n().setDirty('a.dart', false);
      expect(s().dirtyPaths, isEmpty);
    });

    test('closeEverywhere removes the file and collapses an emptied pane', () {
      n().open('a.dart', preview: false);
      n().open('b.dart', toSide: true);
      n().closeEverywhere('b.dart');
      expect(s().openPaths, {'a.dart'});
      expect(s().split, isFalse);
    });

    test('closing an unknown path changes nothing', () {
      n().open('a.dart');
      n().close('nope.dart');
      expect(s().activePath, 'a.dart');
    });
  });

  group('places and restore', () {
    const place = EditorPlace(line: 4, col: 2, scroll: 90);

    test('rememberPlace keeps the place of an open file only', () {
      n().open('a.dart', preview: false);
      n().rememberPlace('a.dart', place);
      n().rememberPlace('closed.dart', place);
      expect(s().places, {'a.dart': place});
    });

    test('a closed tab\'s late report does not come back', () {
      n().open('a.dart', preview: false);
      n().close('a.dart');
      n().rememberPlace('a.dart', place);
      expect(s().places, isEmpty);
    });

    test('movePath follows a rename, a folder rename and drops nothing', () {
      n().open('lib/a.dart', preview: false);
      n().open('lib/b.dart', preview: false);
      n().rememberPlace('lib/a.dart', place);
      n().rememberPlace('lib/b.dart', const EditorPlace(line: 1, col: 1));
      n().movePath('lib', 'src');
      expect(s().places.keys.toSet(), {'src/a.dart', 'src/b.dart'});
      expect(s().places['src/a.dart'], place);
    });

    test('closeUnder drops the places below a deleted folder', () {
      n().open('lib/a.dart', preview: false);
      n().open('keep.dart', preview: false);
      n().rememberPlace('lib/a.dart', place);
      n().rememberPlace('keep.dart', place);
      n().closeUnder('lib');
      expect(s().places.keys, ['keep.dart']);
    });

    test('closeEverywhere drops the place', () {
      n().open('a.dart', preview: false);
      n().rememberPlace('a.dart', place);
      n().closeEverywhere('a.dart');
      expect(s().places, isEmpty);
    });

    StickyEditorState saved() => const StickyEditorState(
      panes: [
        StickyPane(
          tabs: [
            StickyTab(path: 'a.dart', preview: false),
            StickyTab(path: 'b.dart', mode: CodeMode.diff),
          ],
          active: 'b.dart',
        ),
        StickyPane(
          tabs: [StickyTab(path: 'c.dart', preview: false)],
          active: 'c.dart',
        ),
      ],
      focused: 1,
      viewMode: CodeMode.edit,
      places: {'a.dart': EditorPlace(line: 4, col: 2, scroll: 90)},
    );

    test('restore puts back panes, tabs, active, focus, mode and places', () {
      expect(n().restore(saved()), isTrue);
      expect(s().panes, hasLength(2));
      expect(s().panes[0].tabs.map((t) => t.path), ['a.dart', 'b.dart']);
      expect(s().panes[0].activePath, 'b.dart');
      expect(s().panes[0].tabs[0].preview, isFalse);
      expect(s().panes[0].tabs[1].mode, CodeMode.diff);
      expect(s().focusedPane, 1);
      expect(s().activePath, 'c.dart');
      expect(s().viewMode, CodeMode.edit);
      expect(s().places['a.dart'], place);
      expect(s().dirtyPaths, isEmpty);
      expect(s().jump, isNull);
    });

    test('an open before the restore wins', () {
      n().open('x.dart');
      expect(n().restore(saved()), isFalse);
      expect(s().openPaths, {'x.dart'});
    });

    test('a restore is refused once tabs exist, and after one restore', () {
      expect(n().restore(saved()), isTrue);
      n().close('c.dart');
      n().close('a.dart', pane: 0);
      n().close('b.dart', pane: 0);
      expect(s().openPaths, isEmpty);
      expect(n().restore(saved()), isFalse);
    });

    test('a saved state with no tab restores nothing', () {
      expect(
        n().restore(const StickyEditorState(panes: [StickyPane()])),
        isFalse,
      );
    });
  });
}
