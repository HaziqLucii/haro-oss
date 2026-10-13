import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_markdown.dart';
import 'package:haro_app/theme/palette.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/shell_icons.dart';

const _md =
    'Run `npm test` first.\n\n```js\nconst a = 1;\nconsole.log(a);\n```\n';

final _palettes = <String, HaroPalette>{
  'haro': HaroPalette.haro,
  'material3': HaroPalette.material3,
  'paper': HaroPalette.paper,
};

void main() {
  for (final entry in _palettes.entries) {
    group('click to copy code in the ${entry.key} theme', () {
      final copied = <String>[];

      setUp(() {
        HaroTokens.apply(entry.value);
        copied.clear();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                copied.add((call.arguments as Map)['text'] as String);
              }
              return null;
            });
      });
      tearDown(() {
        HaroTokens.apply(HaroPalette.haro);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      Future<void> pump(WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SelectionArea(
                child: SingleChildScrollView(
                  child: SizedBox(width: 500, child: AgentProse(_md)),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      testWidgets('a click on inline code copies exactly that code', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.byKey(const ValueKey('agent-inline-code')));
        await tester.pump();
        expect(copied, ['npm test']);
        expect(find.text('Copied'), findsOneWidget);
        await tester.pumpAndSettle(const Duration(seconds: 3));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a click on a fenced block copies the whole block', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.byKey(const ValueKey('agent-code-block')));
        await tester.pump();
        expect(copied, ['const a = 1;\nconsole.log(a);']);
        ShellIcon iconNow() => tester
            .widget<ShellIconView>(
              find.byKey(const ValueKey('agent-code-copy-icon')),
            )
            .icon;
        expect(iconNow(), ShellIcon.check);
        await tester.pump(const Duration(seconds: 2));
        expect(iconNow(), ShellIcon.copy);
        await tester.pumpAndSettle(const Duration(seconds: 3));
        expect(tester.takeException(), isNull);
      });
    });
  }
}
