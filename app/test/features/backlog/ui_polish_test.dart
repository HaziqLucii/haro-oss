import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/overlays/confirm_overlay.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_button.dart';
import 'package:haro_app/widgets/haro_pressable.dart';

import '../creation_harness.dart';
import 'backlog_test.dart' show backend, fileJson, itemJson, open, pumpShell;

final _palettes = <String, HaroPalette>{
  'haro': HaroPalette.haro,
  'material3': HaroPalette.material3,
  'paper': HaroPalette.paper,
};

Map<String, dynamic> _many() => {
  'files': [
    fileJson('backlog/big.md', [
      for (var i = 0; i < 30; i++) itemJson('Card number $i'),
    ], title: 'Big'),
  ],
  'orphaned': <Object>[],
};

MockBackend _b({Map<String, dynamic>? todo}) =>
    backend(todo: todo)
      ..routes['GET /projects/p1/notes'] = ((_) =>
          jsonRes({'notes': <Object>[]}));

Future<void> _chord(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await t.sendKeyDownEvent(LogicalKeyboardKey.shift);
  await t.sendKeyDownEvent(key);
  await t.sendKeyUpEvent(key);
  await t.sendKeyUpEvent(LogicalKeyboardKey.shift);
  await t.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadBrandFonts);

  for (final entry in _palettes.entries) {
    group('in the ${entry.key} theme', () {
      setUp(() => HaroTokens.apply(entry.value));
      tearDown(() => HaroTokens.apply(HaroPalette.haro));

      testWidgets(
        'every card of a column is as wide as the column, left-aligned',
        (tester) async {
          final todo = {
            'files': [
              fileJson('backlog/a.md', [
                itemJson('Short'),
                itemJson(
                  'A much longer card title that wraps onto a second line',
                ),
                itemJson('Mid length card'),
              ], title: 'A'),
            ],
            'orphaned': <Object>[],
          };
          await open(tester, _b(todo: todo));
          await tester.tap(find.byKey(const Key('bl-layout-board')));
          await tester.pumpAndSettle();
          final head = tester.getTopLeft(find.byKey(const Key('bl-col-ready')));
          for (var i = 0; i < 3; i++) {
            final card = find.byKey(Key('bl-card-backlog/a.md#$i'));
            expect(
              tester.getSize(card).width,
              236,
              reason: 'card $i fills the column',
            );
            expect(
              tester.getTopLeft(card).dx,
              head.dx,
              reason: 'card $i lines up with the title',
            );
          }
        },
      );

      testWidgets('the whole board scrolls under sticky column titles', (
        tester,
      ) async {
        await open(tester, _b(todo: _many()));
        await tester.tap(find.byKey(const Key('bl-layout-board')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final head = find.byKey(const Key('bl-col-ready'));
        final blocked = find.byKey(const Key('bl-col-blocked'));
        final top = tester.getTopLeft(head).dy;
        final first = find.byKey(const Key('bl-card-backlog/big.md#0'));
        expect(
          find.descendant(of: first, matching: find.byType(HaroButton)),
          findsOneWidget,
        );
        final last = find.byKey(const Key('bl-card-backlog/big.md#29'));
        final viewport = tester.view.physicalSize.height;
        expect(tester.getTopLeft(last).dy, greaterThan(viewport));
        // Dragging an EMPTY column's area scrolls the board too: it is one scroll view.
        await tester.dragFrom(
          tester.getCenter(blocked) + const Offset(0, 300),
          const Offset(0, -3000),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('bl-card-backlog/big.md#29')),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(last).dy,
          lessThan(tester.view.physicalSize.height),
          reason: 'the last card scrolled into view',
        );
        expect(tester.getTopLeft(head).dy, top, reason: 'the title stays put');
        expect(blocked, findsOneWidget);
      });

      testWidgets(
        'the filter has a search icon, a plain hint and a word menu',
        (tester) async {
          await open(tester, _b());
          expect(find.text('Filter todos'), findsOneWidget);
          expect(
            find.byIcon(Icons.search),
            findsNothing,
            reason: 'Lucide, not Material',
          );
          await tester.tap(find.byKey(const Key('bl-find-help')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('tag:'));
          await tester.pumpAndSettle();
          final field = tester.widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('bl-find')),
              matching: find.byType(EditableText),
            ),
          );
          expect(field.controller.text, 'tag:');
        },
      );

      testWidgets('the row and note menus are icon buttons, not three dots', (
        tester,
      ) async {
        await open(tester, _b());
        await tester.tap(find.text('live-gate.md').first);
        await tester.pumpAndSettle();
        expect(find.text('\u00b7\u00b7\u00b7'), findsNothing);
        expect(find.byKey(const Key('bl-menu-0')), findsOneWidget);
        expect(find.byKey(const Key('bl-new-file')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('bl-new-file')),
            matching: find.byType(Icon),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('bl-tab-notes')));
        await tester.pumpAndSettle();
        for (final k in [
          'notes-new',
          'notes-template',
          'notes-today',
          'notes-tasks',
        ]) {
          expect(
            find.descendant(
              of: find.byKey(Key(k)),
              matching: find.byType(Icon),
            ),
            findsOneWidget,
            reason: k,
          );
        }
      });
    });
  }

  group('ripples', () {
    setUp(() => HaroTokens.apply(HaroPalette.material3));
    tearDown(() => HaroTokens.apply(HaroPalette.haro));

    testWidgets('the checkbox ripples inside a circle around the box', (
      tester,
    ) async {
      await open(tester, _b());
      await tester.tap(find.text('live-gate.md').first);
      await tester.pumpAndSettle();
      final box = find.byKey(const Key('bl-toggle-1'));
      final size = tester.getSize(box);
      expect(size, const Size(24, 24));
      final press = await tester.startGesture(tester.getCenter(box));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      final clip = rippleClipBounds(
        tester
            .widget<CustomPaint>(
              find.descendant(
                of: box,
                matching: find.byKey(const ValueKey('ripple')),
              ),
            )
            .painter,
      )!.single;
      expect(
        clip,
        rectMoreOrLessEquals(const Rect.fromLTWH(0, 0, 24, 24), epsilon: .01),
      );
      await press.cancel();
    });

    testWidgets(
      'pressing the checkbox ripples the checkbox only, not the row',
      (tester) async {
        await open(tester, _b());
        await tester.tap(find.text('live-gate.md').first);
        await tester.pumpAndSettle();
        final box = find.byKey(const Key('bl-toggle-2'));
        final press = await tester.startGesture(tester.getCenter(box));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 80));
        expect(find.byKey(const ValueKey('ripple')), findsOneWidget);
        expect(
          find.descendant(
            of: box,
            matching: find.byKey(const ValueKey('ripple')),
          ),
          findsOneWidget,
          reason: 'the one ripple is the checkbox\'s',
        );
        await press.cancel();
      },
    );

    testWidgets('the menu button ripples inside its own square', (
      tester,
    ) async {
      await open(tester, _b());
      await tester.tap(find.text('live-gate.md').first);
      await tester.pumpAndSettle();
      final btn = find.byKey(const Key('bl-menu-0'));
      final press = await tester.startGesture(tester.getCenter(btn));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      final clip = rippleClipBounds(
        tester
            .widget<CustomPaint>(
              find.descendant(
                of: btn,
                matching: find.byKey(const ValueKey('ripple')),
              ),
            )
            .painter,
      )!.single;
      expect(clip.size, const Size(28, 28));
      await press.cancel();
    });
  });

  group('full screen', () {
    testWidgets('the button, the chord and Esc, in every theme', (
      tester,
    ) async {
      for (final p in _palettes.values) {
        HaroTokens.apply(p);
        await pumpShell(tester, _b(), [
          project('p1', 'haro'),
        ], location: '/backlog?project=p1');
        expect(find.byKey(const ValueKey('focus-bar')), findsNothing);
        await tester.tap(find.byKey(const Key('bl-fullscreen')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('focus-bar')), findsOneWidget);
        expect(find.text('FOCUS'), findsOneWidget);
        expect(find.byKey(const Key('bl-fullscreen')), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('focus-bar')), findsNothing);
        await _chord(tester, LogicalKeyboardKey.enter);
        expect(find.byKey(const ValueKey('focus-bar')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('focus-exit')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('focus-bar')), findsNothing);
      }
      HaroTokens.apply(HaroPalette.haro);
    });
  });

  for (final entry in _palettes.entries) {
    group('compact layout in the ${entry.key} theme', () {
      setUp(() => HaroTokens.apply(entry.value));
      tearDown(() => HaroTokens.apply(HaroPalette.haro));

      testWidgets('buttons are as wide as their content', (tester) async {
        await open(tester, _b());
        await tester.tap(find.text('live-gate.md').first);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const Key('bl-new-file'))).width,
          lessThan(160),
        );
        final edit = tester.getTopLeft(find.byKey(const Key('bl-edit-link')));
        final rename = tester.getTopLeft(find.byKey(const Key('bl-rename')));
        expect(rename.dy, edit.dy, reason: 'side by side, not stacked');
        expect(
          tester.getSize(find.byKey(const Key('bl-rename'))).width,
          lessThan(140),
        );
      });

      testWidgets('the notes actions share one row', (tester) async {
        await open(tester, _b());
        await tester.tap(find.byKey(const Key('bl-tab-notes')));
        await tester.pumpAndSettle();
        final ys = {
          for (final k in [
            'notes-new',
            'notes-template',
            'notes-today',
            'notes-tasks',
          ])
            tester.getTopLeft(find.byKey(Key(k))).dy,
        };
        expect(ys, hasLength(1));
      });
    });
  }

  group('the label popover', () {
    MockBackend withLabels() => backend(
      issues: (_) => {
        'available': true,
        'issues': [
          for (var i = 0; i < 40; i++)
            {
              'number': i + 1,
              'title': 'Issue $i',
              'body': '',
              'state': 'open',
              'labels': [
                'label-$i',
                if (i.isEven) 'even',
                if (i % 3 == 0) 'three',
              ],
              'url': 'https://github.com/o/r/issues/${i + 1}',
              'seed_key': 'issue-${i + 1}',
              'seeded_workspace': null,
              'stage': null,
            },
        ],
      },
    );

    Future<void> openIssues(WidgetTester tester) async {
      await open(tester, withLabels());
      await tester.tap(find.byKey(const Key('bl-tab-issues')));
      await tester.pumpAndSettle();
    }

    testWidgets('stays open for several picks, with no dimmed backdrop', (
      tester,
    ) async {
      await openIssues(tester);
      expect(
        find.byKey(const Key('bl-label-even')),
        findsNothing,
        reason: 'no chip wall',
      );
      await tester.tap(find.byKey(const Key('bl-labels')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('haro-popover')), findsOneWidget);
      final size = tester.getSize(find.byKey(const Key('haro-popover')));
      expect(size.width, lessThanOrEqualTo(300));
      expect(size.height, lessThanOrEqualTo(360));
      // The page behind is not covered by a scrim.
      expect(
        find.byWidgetPredicate(
          (w) => w is ModalBarrier && w.color != null && w.color!.a > 0,
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('bl-label-even')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bl-label-three')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('haro-popover')),
        findsOneWidget,
        reason: 'still open',
      );
      expect(find.text('2 SELECTED'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('bl-labels')),
          matching: find.text('2 labels'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an issue must carry every picked label', (tester) async {
      await openIssues(tester);
      await tester.tap(find.byKey(const Key('bl-labels')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bl-label-even')));
      await tester.tap(find.byKey(const Key('bl-label-three')));
      await tester.pumpAndSettle();
      // even AND divisible by 3: 0, 6, 12, 18, 24, 30, 36 (7 issues, numbers 1, 7, ...).
      await tester.tap(find.byKey(const Key('label-popover-close')));
      await tester.pumpAndSettle();
      expect(find.text('Issue 0'), findsWidgets);
      expect(find.text('Issue 6'), findsWidgets);
      expect(find.text('Issue 2'), findsNothing);
      expect(find.text('Issue 3'), findsNothing);
    });

    testWidgets(
      'filters its list, closes with the button and by clicking outside',
      (tester) async {
        await openIssues(tester);
        await tester.tap(find.byKey(const Key('bl-labels')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('label-filter')),
          'label-3',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('bl-label-label-30')), findsOneWidget);
        expect(find.byKey(const Key('bl-label-label-7')), findsNothing);
        await tester.tap(find.byKey(const Key('label-popover-close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('haro-popover')), findsNothing);
        await tester.tap(find.byKey(const Key('bl-labels')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('haro-popover')), findsOneWidget);
        await tester.tapAt(const Offset(1200, 700));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('haro-popover')), findsNothing);
      },
    );
  });

  group('right-click opens the menu', () {
    Future<void> rightClick(WidgetTester tester, Finder f) async {
      await tester.tapAt(tester.getCenter(f), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
    }

    testWidgets('on a todo row and on a file row', (tester) async {
      await open(tester, _b());
      await tester.tap(find.text('live-gate.md').first);
      await tester.pumpAndSettle();
      // a todo row
      await rightClick(tester, find.text('Second open item'));
      expect(find.text('Move up'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      // a file row
      await rightClick(tester, find.text('desktop.md').first);
      expect(
        find.text('Rename'),
        findsNWidgets(2),
        reason: 'the menu and the pane button',
      );
      expect(find.text('Edit in editor'), findsNWidgets(2));
    });
  });

  group('renaming happens in the row itself', () {
    testWidgets(
      'a file: the row becomes the name field; Enter renames, Esc keeps the name',
      (tester) async {
        final b = _b()
          ..routes['POST /projects/p1/todo/rename'] = ((_) =>
              jsonRes({'ok': true}));
        await open(tester, b);
        final label = find.text('desktop.md');
        expect(label, findsOneWidget);
        await tester.tapAt(
          tester.getCenter(label),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename').last);
        await tester.pumpAndSettle();
        // The field replaced that file's row: no field at the top of the list, no label left.
        expect(find.byKey(const Key('bl-name')), findsOneWidget);
        expect(label, findsNothing);
        final field = tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(const Key('bl-name')),
            matching: find.byType(EditableText),
          ),
        );
        expect(field.controller.text, 'backlog/desktop.md');
        // Esc ends it without renaming
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('bl-name')), findsNothing);
        expect(find.text('desktop.md'), findsOneWidget);
        expect(b.where('POST', '/projects/p1/todo/rename'), isEmpty);
        // and again, this time confirmed
        await tester.tapAt(
          tester.getCenter(find.text('desktop.md')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('bl-name')),
          'backlog/shell.md',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(b.where('POST', '/projects/p1/todo/rename').single.body, {
          'path': 'backlog/desktop.md',
          'new_path': 'backlog/shell.md',
        });
      },
    );

    testWidgets('a note: the row becomes the name field', (tester) async {
      final b = _b()
        ..routes['GET /projects/p1/notes'] = ((_) => jsonRes({
          'notes': [
            {
              'path': 'ideas.md',
              'title': 'Ideas',
              'modified': DateTime.now().millisecondsSinceEpoch / 1000,
              'size': 10,
              'snippets': <String>[],
            },
          ],
        }))
        ..routes['GET /projects/p1/notes/file'] = ((_) =>
            jsonRes({'path': 'ideas.md', 'content': '# Ideas\n', 'etag': 'e1'}))
        ..routes['GET /projects/p1/notes/links'] = ((_) => jsonRes({
          'path': 'ideas.md',
          'tags': <String>[],
          'outgoing': <Object>[],
          'backlinks': <Object>[],
          'mentions': <Object>[],
        }))
        ..routes['POST /projects/p1/notes/rename'] = ((_) =>
            jsonRes({'ok': true}));
      await open(tester, b);
      await tester.tap(find.byKey(const Key('bl-tab-notes')));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('note-ideas.md'))),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes-name')), findsOneWidget);
      expect(
        find.byKey(const Key('note-ideas.md')),
        findsNothing,
        reason: 'the row is the field',
      );
      await tester.enterText(find.byKey(const Key('notes-name')), 'brainstorm');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(b.where('POST', '/projects/p1/notes/rename').single.body, {
        'path': 'ideas.md',
        'new_path': 'brainstorm.md',
      });
    });
  });

  for (final entry in _palettes.entries) {
    testWidgets(
      'the confirm modal is a dialog with Cancel focused (${entry.key})',
      (tester) async {
        HaroTokens.apply(entry.value);
        addTearDown(() => HaroTokens.apply(HaroPalette.haro));
        bool? answer;
        await pumpCreation(
          tester,
          backend: _b(),
          projects: [project('p1', 'haro')],
          open: (c) async => answer = await showConfirm(
            c,
            title: 'Delete this note?',
            body: 'ideas.md is removed from the project.',
          ),
        );
        expect(find.byKey(const Key('confirm-title')), findsOneWidget);
        expect(find.byKey(const Key('confirm-body')), findsOneWidget);
        // Enter by reflex answers Cancel, never Delete.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          answer,
          isNull,
          reason: 'the dialog is still open: Enter on a focused button is not wired',
        );
        await tester.tap(find.byKey(const Key('confirm-cancel')));
        await tester.pumpAndSettle();
        expect(answer, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
