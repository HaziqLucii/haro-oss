import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/overlays/palette_model.dart';
import 'package:haro_app/overlays/shortcuts_overlay.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:haro_app/shortcuts/platform_keys.dart';

import '../shell/fake_shell_data.dart';

List<PaletteItem> _items(
  AppCommands c, {
  required bool code,
  bool definition = false,
}) => buildPaletteItems(
  data: fakeShellData,
  commands: () => c,
  openWorkspace: (_, _) {},
  modifier: PrimaryModifier.meta,
  codeAvailable: code,
  definitionAvailable: definition,
);

void main() {
  group('palette', () {
    test('go to line and related tests are offered on the code step only', () {
      final off = _items(const AppCommands(), code: false).map((i) => i.id);
      expect(off, isNot(contains('action:go-to-line')));
      expect(off, isNot(contains('action:run-related')));

      final on = _items(const AppCommands(), code: true).map((i) => i.id);
      expect(on, containsAll(['action:go-to-line', 'action:run-related']));
    });

    test('go to definition is offered only when an editor registered it', () {
      final none = _items(const AppCommands(), code: true).map((i) => i.id);
      expect(none, isNot(contains('action:go-to-definition')));
      final off = _items(const AppCommands(), code: false, definition: true);
      expect(off.map((i) => i.id), isNot(contains('action:go-to-definition')));

      var n = 0;
      final c = AppCommands(goToDefinition: () => n++);
      final item = _items(
        c,
        code: true,
        definition: true,
      ).singleWhere((i) => i.id == 'action:go-to-definition');
      expect((item.label, item.meta), ('Go to definition', 'F12'));
      item.run();
      expect(n, 1);
    });

    test('each item calls the command registered at run time', () {
      var go = 0;
      var related = 0;
      final c = AppCommands(
        goToLine: () => go++,
        runRelatedTests: () => related++,
      );
      final items = {for (final i in _items(c, code: true)) i.id: i};
      items['action:go-to-line']!.run();
      items['action:run-related']!.run();
      expect((go, related), (1, 1));
      expect(items['action:go-to-line']!.label, 'Go to line');
      expect(
        items['action:run-related']!.label,
        'Run the tests touching this file',
      );
    });

    test('the defaults do nothing and copyWith keeps the rest', () {
      const AppCommands().goToLine();
      const AppCommands().runRelatedTests();
      const AppCommands().goToDefinition();
      var go = 0;
      final c = const AppCommands().copyWith(goToLine: () => go++);
      c.runRelatedTests();
      c.goToLine();
      expect(go, 1);
    });
  });

  group('shortcuts sheet', () {
    test('lists replace, comment toggle and go to line', () {
      final mac = shortcutEntries(modifier: PrimaryModifier.meta);
      expect(mac, contains(('Replace in the file', '⌘⌥F')));
      expect(mac, contains(('Toggle line comment', '⌘/')));
      expect(mac, contains(('Go to definition (TS/JS)', 'F12')));
      expect(
        mac.any((e) => e.$1 == 'Go to line' && e.$2.contains(':42')),
        isTrue,
      );

      final linux = shortcutEntries(modifier: PrimaryModifier.control);
      expect(linux, contains(('Replace in the file', 'Ctrl+Alt+F')));
      expect(linux, contains(('Toggle line comment', 'Ctrl+/')));
    });

    test('the right-click row stays last', () {
      expect(shortcutEntries().last.$2, 'Right-click');
    });
  });
}
