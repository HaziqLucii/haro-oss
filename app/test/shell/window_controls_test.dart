import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/shell/focus_bar.dart';
import 'package:haro_app/shell/shell_models.dart';
import 'package:haro_app/shell/top_bar.dart';
import 'package:haro_app/shell/window_controls.dart';
import 'package:haro_app/theme/haro_theme.dart';

import '../features/creation_harness.dart' show loadBrandFonts;

class _FakeWindow extends WindowActions {
  _FakeWindow({this.maximized = false});

  bool maximized;
  final calls = <String>[];
  ValueChanged<bool>? _onChange;
  var cancelled = false;

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<void> minimize() async => calls.add('minimize');

  @override
  Future<void> toggleMaximize() async => calls.add('toggleMaximize');

  @override
  Future<void> close() async => calls.add('close');

  @override
  VoidCallback listen(ValueChanged<bool> onChange) {
    _onChange = onChange;
    return () => cancelled = true;
  }

  void setMaximized(bool v) {
    maximized = v;
    _onChange?.call(v);
  }
}

Widget _host(Widget child, {double width = 1200}) => MaterialApp(
  theme: buildHaroTheme(),
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(width: width, child: child),
  ),
);

void main() {
  setUpAll(loadBrandFonts);

  group('WindowControls', () {
    testWidgets('each button does its one thing', (tester) async {
      final w = _FakeWindow();
      await tester.pumpWidget(_host(WindowControls(actions: w)));
      await tester.tap(find.byKey(const ValueKey('window-minimize')));
      await tester.tap(find.byKey(const ValueKey('window-maximize')));
      await tester.tap(find.byKey(const ValueKey('window-close')));
      expect(w.calls, ['minimize', 'toggleMaximize', 'close']);
    });

    testWidgets(
      'the middle button says Restore while the window is maximized',
      (tester) async {
        final w = _FakeWindow(maximized: true);
        await tester.pumpWidget(_host(WindowControls(actions: w)));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Restore'), findsOneWidget);
        expect(find.byTooltip('Maximize'), findsNothing);
        w.setMaximized(false);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Maximize'), findsOneWidget);
      },
    );

    testWidgets('stops listening when it leaves the tree', (tester) async {
      final w = _FakeWindow();
      await tester.pumpWidget(_host(WindowControls(actions: w)));
      await tester.pumpWidget(_host(const SizedBox()));
      expect(w.cancelled, isTrue);
    });

    test(
      'the controls are off by default in tests and elsewhere than Linux',
      () {
        expect(useWindowControls, isFalse);
      },
    );
  });

  group('the bars', () {
    testWidgets('the top bar draws the controls only when asked', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const TopBar(
            crumb1: 'haro',
            needYouCount: 0,
            actions: ShellActions(),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('window-close')), findsNothing);
      await tester.pumpWidget(
        _host(
          const TopBar(
            crumb1: 'haro',
            needYouCount: 0,
            actions: ShellActions(),
            windowControls: true,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('window-close')), findsOneWidget);
    });

    testWidgets('the top bar with the controls fits the narrowest window', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(960, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          const TopBar(
            crumb1: 'shelf-demo',
            crumb2: 'reject dates that do not exist in logSession',
            needYouCount: 12,
            actions: ShellActions(),
            windowControls: true,
          ),
          width: 960,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the focus bar draws the controls too, and fits', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(960, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          FocusBar(
            title: 'REJECT DATES THAT DO NOT EXIST · 02 CODE · FOCUS',
            gate: null,
            onExit: () {},
            windowControls: true,
          ),
          width: 960,
        ),
      );
      expect(find.byKey(const ValueKey('window-close')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
