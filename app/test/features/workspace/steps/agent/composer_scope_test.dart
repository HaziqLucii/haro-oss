import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/agent/composer_state.dart';
import 'package:haro_app/theme/tokens.dart';

import 'agent_harness.dart';

Finder scope() => find.byKey(const ValueKey('composer-scope'));
Finder run() => find.byKey(const ValueKey('composer-run'));
Finder menu() => find.byKey(const ValueKey('completion-menu'));
Finder row(String t) => find.descendant(of: menu(), matching: find.text(t));
Finder chip(String entry) => find.byKey(ValueKey('scope-chip-$entry'));
Finder chipX(String entry) => find.byKey(ValueKey('scope-chip-remove-$entry'));

String input(WidgetTester t) => t.widget<TextField>(scope()).controller!.text;

String drafted(WidgetTester t) =>
    ProviderScope.containerOf(t.element(scope()))
        .read(composerDraftProvider(id))
        .scope;

Future<void> typeScope(WidgetTester tester, String text) async {
  await tester.enterText(scope(), text);
  await tester.pumpAndSettle();
}

Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pumpAndSettle();
}

Future<void> focusBox(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('scope-box')));
  await tester.pumpAndSettle();
}

Future<void> sendWithCtrlEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadBrandFonts);

  testWidgets(
    'the row reads as an input: a rule, a label, a plain placeholder',
    (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      expect(find.byKey(const ValueKey('scope-box')), findsOneWidget);
      expect(find.byKey(const ValueKey('scope-divider')), findsOneWidget);
      expect(find.text('SCOPE'), findsOneWidget);
      final hint = tester.widget<TextField>(scope()).decoration!.hintText!;
      expect(hint, contains('all files'));
      expect(hint, contains('pick folders or files'));
    },
  );

  testWidgets('hovering the label says a folder covers everything inside it', (
    tester,
  ) async {
    final rig = AgentRig(Preview.idle);
    await rig.pump(tester, step: 'agent');
    final tip = tester.widget<Tooltip>(
      find.ancestor(of: find.text('SCOPE'), matching: find.byType(Tooltip)),
    );
    expect(tip.message, contains('A folder covers everything inside it'));
    expect(tip.message, contains('put back when the run ends'));
    expect(tip.message, contains('Empty means all files'));
  });

  group('picking', () {
    testWidgets(
      'focusing the empty box lists the root with nothing highlighted, folders first',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await focusBox(tester);
        expect(menu(), findsOneWidget);
        expect(
          tester.getTopLeft(row('src/')).dy,
          lessThan(tester.getTopLeft(row('README.md')).dy),
        );
        await key(tester, LogicalKeyboardKey.tab);
        expect(drafted(tester), '');
        await key(tester, LogicalKeyboardKey.enter);
        expect(drafted(tester), '');
      },
    );

    testWidgets(
      'a click on a file row makes a chip, clears the input and keeps the focus',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await focusBox(tester);
        await tester.tap(row('README.md'));
        await tester.pumpAndSettle();
        expect(chip('README.md'), findsOneWidget);
        expect(drafted(tester), 'README.md');
        expect(input(tester), '');
        expect(tester.widget<TextField>(scope()).focusNode!.hasFocus, isTrue);
      },
    );

    testWidgets(
      'a click on a folder row adds the whole folder with its file count',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await focusBox(tester);
        await tester.tap(row('src/'));
        await tester.pumpAndSettle();
        expect(chip('src/'), findsOneWidget);
        expect(
          find.descendant(of: chip('src/'), matching: find.text('2')),
          findsOneWidget,
        );
        final tip = tester.widget<Tooltip>(
          find
              .ancestor(
                of: find.text('src/').first,
                matching: find.byType(Tooltip),
              )
              .first,
        );
        expect(tip.message, 'Everything inside src/ (2 files)');
      },
    );

    testWidgets(
      'a real mouse press on a row picks it on Linux, after hovering it',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          final rig = AgentRig(Preview.idle);
          await rig.pump(tester, step: 'agent');
          await focusBox(tester);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(row('README.md')));
          await tester.pump();
          await mouse.down(tester.getCenter(row('README.md')));
          await mouse.up();
          await tester.pumpAndSettle();
          expect(chip('README.md'), findsOneWidget);
          expect(drafted(tester), 'README.md');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('the chevron on a folder steps into it without adding it', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await focusBox(tester);
      await tester.tap(find.byKey(const ValueKey('completion-drill-src/')));
      await tester.pumpAndSettle();
      expect(input(tester), 'src/');
      expect(drafted(tester), '');
      expect(row('src/lib/'), findsOneWidget);
      expect(row('src/App.tsx'), findsOneWidget);
      expect(row('add the whole folder · 2 files'), findsOneWidget);
      expect(tester.widget<TextField>(scope()).focusNode!.hasFocus, isTrue);
    });

    testWidgets('after adding a chip the next one is one click away', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await focusBox(tester);
      await tester.tap(row('README.md'));
      await tester.pumpAndSettle();
      expect(menu(), findsOneWidget);
      await tester.tap(row('src/'));
      await tester.pumpAndSettle();
      expect(drafted(tester), 'README.md, src/');
      expect(chip('README.md'), findsOneWidget);
      expect(chip('src/'), findsOneWidget);
    });
  });

  group('menu rows', () {
    testWidgets(
      'a folder row has a labelled Open button and the menu says what a click does',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await focusBox(tester);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('completion-drill-src/')),
            matching: find.text('Open \u203a'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('completion-drill-README.md')),
          findsNothing,
        );
        expect(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byKey(const ValueKey('completion-footer')),
                  matching: find.byType(Text),
                ),
              )
              .data,
          contains('click adds a folder or file'),
        );
      },
    );

    testWidgets(
      'Open shows what is inside, with a back row that goes up one level',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await focusBox(tester);
        await tester.tap(find.byKey(const ValueKey('completion-drill-src/')));
        await tester.pumpAndSettle();
        expect(input(tester), 'src/');
        expect(row('\u2039 back'), findsOneWidget);
        expect(row('to all files'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('completion-drill-src/lib/')),
        );
        await tester.pumpAndSettle();
        expect(input(tester), 'src/lib/');
        expect(row('to src/'), findsOneWidget);
        await tester.tap(row('\u2039 back'));
        await tester.pumpAndSettle();
        expect(input(tester), 'src/');
        expect(drafted(tester), '');
        await tester.tap(row('\u2039 back'));
        await tester.pumpAndSettle();
        expect(input(tester), '');
        expect(row('src/'), findsOneWidget);
      },
    );

    testWidgets('Enter inside a folder adds the folder, not the back row', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'src/');
      expect(row('\u2039 back'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.enter);
      expect(drafted(tester), 'src/');
    });
  });

  group('typing', () {
    testWidgets(
      'a bare name finds folders and files anywhere; Enter adds the best match',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await typeScope(tester, 'lib');
        expect(row('src/lib/'), findsOneWidget);
        await key(tester, LogicalKeyboardKey.enter);
        expect(drafted(tester), 'src/lib/');
        expect(input(tester), '');
      },
    );

    testWidgets('Tab steps into a folder and adds a file', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'sr');
      await key(tester, LogicalKeyboardKey.tab);
      expect(input(tester), 'src/');
      expect(drafted(tester), '');
      expect(row('src/App.tsx'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.tab);
      expect(drafted(tester), 'src/App.tsx');
    });

    testWidgets('the folder itself leads once you are inside it', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'src/');
      await key(tester, LogicalKeyboardKey.enter);
      expect(drafted(tester), 'src/');
    });

    testWidgets('src/** is offered as the folder it means and needs no glob', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'src/**');
      expect(row('src/'), findsOneWidget);
      expect(find.textContaining('add the whole folder'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.enter);
      expect(drafted(tester), 'src/');
      expect(chip('src/'), findsOneWidget);
    });

    testWidgets('a real pattern becomes a pattern chip', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, '*.ts');
      expect(find.textContaining('a pattern'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.enter);
      expect(drafted(tester), '*.ts');
      final tip = tester.widget<Tooltip>(
        find
            .ancestor(of: find.text('*.ts'), matching: find.byType(Tooltip))
            .first,
      );
      expect(tip.message, 'Files matching this pattern');
    });

    testWidgets(
      'a path that does not exist yet shows no menu and Enter commits it',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await typeScope(tester, 'src/new/file.ts');
        expect(menu(), findsNothing);
        await key(tester, LogicalKeyboardKey.enter);
        expect(drafted(tester), 'src/new/file.ts');
        final tip = tester.widget<Tooltip>(
          find
              .ancestor(
                of: find.text('src/new/file.ts'),
                matching: find.byType(Tooltip),
              )
              .first,
        );
        expect(tip.message, 'A new file: it does not exist yet');
      },
    );

    testWidgets('a comma turns the finished entries into chips', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, './README.md, src/**, src/lib/rat');
      expect(drafted(tester), 'README.md, src/');
      expect(input(tester), 'src/lib/rat');
      expect(chip('README.md'), findsOneWidget);
      expect(chip('src/'), findsOneWidget);
    });

    testWidgets('pasting a list, one path per line, makes one chip per line', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': 'src/App.tsx\nREADME.md\r\nsrc/lib/rat'}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await focusBox(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(drafted(tester), 'src/App.tsx, README.md');
      expect(input(tester), 'src/lib/rat');
    });

    testWidgets('repeats are ignored', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'README.md, ./README.md, ');
      expect(drafted(tester), 'README.md');
    });

    testWidgets('Esc closes the menu until the next keystroke', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'sr');
      await key(tester, LogicalKeyboardKey.escape);
      expect(menu(), findsNothing);
      expect(input(tester), 'sr');
      await typeScope(tester, 'src');
      expect(menu(), findsOneWidget);
    });

    testWidgets(
      'leaving the box closes the menu, and the prompt menu is unaffected',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await typeScope(tester, 'sr');
        expect(menu(), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('composer-field')));
        await tester.pumpAndSettle();
        expect(menu(), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('composer-field')),
          '@rat',
        );
        await tester.pumpAndSettle();
        expect(row('src/lib/rates.ts'), findsOneWidget);
      },
    );
  });

  group('review fixes', () {
    testWidgets('what is typed and not yet a chip is part of the draft fence', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'src/, docs/new.md');
      final draft = ProviderScope.containerOf(tester.element(scope()))
          .read(composerDraftProvider(id));
      expect(draft.scope, 'src/');
      expect(draft.scopeInput, 'docs/new.md');
      expect(draft.fence, ['src/', 'docs/new.md']);
    });

    testWidgets(
      'Enter adds a file name as typed even when a longer name starts with it',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await typeScope(tester, 'src/App.ts');
        expect(row('src/App.tsx'), findsOneWidget);
        await key(tester, LogicalKeyboardKey.enter);
        expect(drafted(tester), 'src/App.ts');
      },
    );

    testWidgets('Enter on a bare word still takes the best match', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'sr');
      await key(tester, LogicalKeyboardKey.enter);
      expect(drafted(tester), 'src/');
    });

    testWidgets(
      'a pattern with a glob in front of /** is not rewritten to a wider one',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await typeScope(tester, 'src*/**');
        expect(find.textContaining('a pattern'), findsOneWidget);
        await key(tester, LogicalKeyboardKey.enter);
        expect(drafted(tester), 'src*/**');
      },
    );

    testWidgets(
      'sending with text left in the box adds it without taking the focus',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await typeScope(tester, 'docs/new.md');
        await tester.tap(find.byKey(const ValueKey('composer-field')));
        await tester.enterText(
          find.byKey(const ValueKey('composer-field')),
          'go',
        );
        await tester.pumpAndSettle();
        await sendWithCtrlEnter(tester);
        expect(rig.agent.starts.single.scope, ['docs/new.md']);
        expect(tester.widget<TextField>(scope()).focusNode!.hasFocus, isFalse);
      },
    );

    testWidgets('a send with nothing to send leaves the scope box alone', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'docs/new.md');
      await tester.tap(run());
      await tester.pumpAndSettle();
      expect(rig.agent.starts, isEmpty);
      expect(drafted(tester), '');
      expect(input(tester), 'docs/new.md');
    });

    testWidgets('a right click on a row does not pick it', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await focusBox(tester);
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await mouse.addPointer(location: tester.getCenter(row('README.md')));
        await mouse.down(tester.getCenter(row('README.md')));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(chip('README.md'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'after Esc, typing and deleting back to empty reopens the root list',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await focusBox(tester);
        await key(tester, LogicalKeyboardKey.escape);
        expect(menu(), findsNothing);
        await typeScope(tester, 's');
        expect(menu(), findsOneWidget);
        await typeScope(tester, '');
        expect(menu(), findsOneWidget);
      },
    );

    testWidgets(
      'a folder typed in the wrong case is added in the case it has on disk',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await typeScope(tester, 'SRC/');
        await key(tester, LogicalKeyboardKey.enter);
        expect(drafted(tester), 'src/');
      },
    );
  });

  group('chips', () {
    testWidgets(
      'the cross removes one, and Backspace in an empty input removes the last',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await typeScope(tester, 'README.md, src/, ');
        await tester.tap(chipX('README.md'));
        await tester.pumpAndSettle();
        expect(drafted(tester), 'src/');
        await tester.tap(find.byKey(const ValueKey('scope-box')));
        await tester.pumpAndSettle();
        await key(tester, LogicalKeyboardKey.backspace);
        expect(drafted(tester), '');
        expect(chip('src/'), findsNothing);
      },
    );

    testWidgets('the placeholder changes once there is a chip', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'README.md, ');
      expect(
        tester.widget<TextField>(scope()).decoration!.hintText,
        contains('add another'),
      );
    });

    testWidgets('past six chips the list folds, and the input stays in view', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent', size: HaroTokens.minWindow);
      await typeScope(
        tester,
        '${[for (var i = 0; i < 9; i++) 'some/long/path/file$i.ts'].join(', ')}, ',
      );
      expect(tester.takeException(), isNull);
      expect(chip('some/long/path/file4.ts'), findsOneWidget);
      expect(chip('some/long/path/file5.ts'), findsNothing);
      expect(find.text('+4 more'), findsOneWidget);
      final frame = tester.getRect(find.byKey(const ValueKey('scope-frame')));
      expect(frame.contains(tester.getCenter(scope())), isTrue);
      await tester.tap(find.byKey(const ValueKey('scope-more')));
      await tester.pumpAndSettle();
      expect(chip('some/long/path/file8.ts'), findsOneWidget);
      expect(find.text('fewer'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a short window with the terminal open and a fence set does not overflow',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent', size: HaroTokens.minWindow);
        await typeScope(tester, 'src/a.ts, docs/, ');
        await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
        await tester.pumpAndSettle();
        expect(scope(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the box lights up while a fence is set and dims when it is cleared',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        Color border() {
          final box = tester.widget<AnimatedContainer>(
            find.byKey(const ValueKey('scope-frame')),
          );
          return ((box.decoration! as BoxDecoration).border! as Border)
              .top
              .color;
        }

        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(border(), HaroTokens.line14);
        await typeScope(tester, 'src/a.ts, ');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(border(), HaroTokens.line30);
        await tester.tap(chipX('src/a.ts'));
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(border(), HaroTokens.line14);
      },
    );
  });

  group('sending', () {
    testWidgets(
      'the chips are the fence, sent on every run and kept after a send',
      (tester) async {
        final rig = AgentRig(Preview.idle);
        await rig.pump(tester, step: 'agent');
        await typeScope(tester, './src/a.ts, src/**, src/a.ts, ');
        await tester.enterText(
          find.byKey(const ValueKey('composer-field')),
          'first',
        );
        await tester.pumpAndSettle();
        await tester.tap(run());
        await tester.pumpAndSettle();
        expect(rig.agent.starts.single.scope, ['src/a.ts', 'src/']);
        expect(chip('src/a.ts'), findsOneWidget);

        await tester.enterText(
          find.byKey(const ValueKey('composer-field')),
          'second',
        );
        await tester.pumpAndSettle();
        await tester.tap(run());
        await tester.pumpAndSettle();
        expect(rig.agent.starts.last.scope, ['src/a.ts', 'src/']);
      },
    );

    testWidgets('text still typed in the box is included when you send', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'src/new.ts');
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'go',
      );
      await tester.pumpAndSettle();
      await tester.tap(run());
      await tester.pumpAndSettle();
      expect(rig.agent.starts.single.scope, ['src/new.ts']);
      expect(chip('src/new.ts'), findsOneWidget);
    });

    testWidgets('Ctrl+Enter sends while focus is in the scope input', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'go',
      );
      await tester.pumpAndSettle();
      await typeScope(tester, 'src/a.ts');
      expect(tester.widget<TextField>(scope()).focusNode!.hasFocus, isTrue);
      await sendWithCtrlEnter(tester);
      expect(rig.agent.starts.map((s) => s.task), ['go']);
      expect(rig.agent.starts.single.scope, ['src/a.ts']);
    });

    testWidgets('no chips sends no fence', (tester) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'do it',
      );
      await tester.pumpAndSettle();
      await tester.tap(run());
      await tester.pumpAndSettle();
      expect(rig.agent.starts.single.scope, isEmpty);
    });

    testWidgets('a plan run does not carry the fence, and the box stays', (
      tester,
    ) async {
      final rig = AgentRig(Preview.idle);
      await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'src/, ');
      await tester.tap(find.byKey(const ValueKey('plan-first')));
      await tester.pumpAndSettle();
      expect(scope(), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'plan it',
      );
      await tester.pumpAndSettle();
      await tester.tap(run());
      await tester.pumpAndSettle();
      expect(rig.agent.starts.single.plan, isTrue);
      expect(rig.agent.starts.single.scope, isEmpty);
    });

    testWidgets('the chips survive a trip to another step', (tester) async {
      final rig = AgentRig(Preview.idle);
      final router = await rig.pump(tester, step: 'agent');
      await typeScope(tester, 'src/, ');
      router.go('/w/$id/verify');
      await tester.pumpAndSettle();
      router.go('/w/$id/agent');
      await tester.pumpAndSettle();
      expect(chip('src/'), findsOneWidget);
    });
  });
}
