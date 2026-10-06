import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/shell/notifier.dart';

GateResultNotify gate({
  bool green = true,
  WorkspaceKind kind = WorkspaceKind.managed,
  WorkspaceMode mode = WorkspaceMode.agent,
}) => GateResultNotify(
  workspaceId: 'w1',
  workspaceName: 'rates',
  green: green,
  workspaceKind: kind,
  workspaceMode: mode,
  passed: green ? 12 : 9,
  failed: green ? 0 : 3,
  total: 12,
);

class _Store extends WorkspaceStore {
  @override
  WorkspaceSnapshot build() => const WorkspaceSnapshot();
}

void main() {
  const prefs = NotificationPrefs(desktop: true);

  group('planNotification', () {
    test('a manual workspace gate verdict plays a tone and notifies when unfocused', () {
      final p = planNotification(
        gate(mode: WorkspaceMode.manual),
        prefs,
        focused: false,
      )!;
      expect(p.sound, isTrue);
      expect(p.desktop, isTrue);
      expect(p.title, 'rates');
      expect(p.body, 'Gate green: 12 of 12 tests pass');
    });

    test('a focused window gets the tone but no OS notification', () {
      final p = planNotification(
        gate(mode: WorkspaceMode.manual),
        prefs,
        focused: true,
      )!;
      expect(p.sound, isTrue);
      expect(p.desktop, isFalse);
    });

    test(
      'a managed agent workspace gate stays silent: agent done already beeped',
      () {
        final p = planNotification(gate(), prefs, focused: false)!;
        expect(p.sound, isFalse);
        expect(p.desktop, isTrue);
      },
    );

    test('an adopted worktree gate plays a tone', () {
      final p = planNotification(
        gate(kind: WorkspaceKind.adopted),
        prefs,
        focused: true,
      )!;
      expect(p.sound, isTrue);
    });

    test('red reads the failure count', () {
      final p = planNotification(
        gate(green: false, mode: WorkspaceMode.manual),
        prefs,
        focused: false,
      )!;
      expect(p.body, 'Gate red: 3 of 12 tests fail');
    });

    test('a red gate with no tests reads as an error, not 0 of 0', () {
      final p = planNotification(
        GateResultNotify(workspaceId: 'w1', green: false, workspaceName: 'x'),
        prefs,
        focused: false,
      )!;
      expect(p.body, 'Gate errored: no tests ran');
    });

    test('stay quiet on green drops green but keeps red', () {
      const quiet = NotificationPrefs(desktop: true, quietOnGreen: true);
      expect(
        planNotification(
          gate(mode: WorkspaceMode.manual),
          quiet,
          focused: false,
        ),
        isNull,
      );
      expect(
        planNotification(
          gate(green: false, mode: WorkspaceMode.manual),
          quiet,
          focused: false,
        ),
        isNotNull,
      );
    });

    test('agent done follows the sound and desktop toggles', () {
      const e = AgentDoneNotify(workspaceId: 'w1', workspaceName: 'rates');
      final on = planNotification(e, prefs, focused: false)!;
      expect(on.sound, isTrue);
      expect(on.desktop, isTrue);
      final off = planNotification(
        e,
        const NotificationPrefs(soundOnFinish: false),
        focused: false,
      )!;
      expect(off.sound, isFalse);
      expect(off.desktop, isFalse);
    });

    test('other events earn nothing', () {
      expect(
        planNotification(
          const RungNotify(workspaceId: 'w1'),
          prefs,
          focused: false,
        ),
        isNull,
      );
    });
  });

  group('DesktopNotifier', () {
    test('macOS uses afplay and osascript, escaping quotes', () async {
      final calls = <List<String>>[];
      final n = DesktopNotifier(
        isMac: true,
        native: (_, _) async => false,
        run: (exe, args) async => calls.add([exe, ...args]),
      );
      await n.playSound('glass');
      await n.show('say "hi"', r'a\b');
      expect(calls[0], ['afplay', '/System/Library/Sounds/Glass.aiff']);
      expect(calls[1][0], 'osascript');
      expect(
        calls[1][2],
        r'display notification "a\\b" with title "say \"hi\""',
      );
    });

    test(
      'macOS prefers the app notification and skips osascript when it posts',
      () async {
        final calls = <List<String>>[];
        final native = <(String, String)>[];
        final n = DesktopNotifier(
          isMac: true,
          native: (t, b) async {
            native.add((t, b));
            return true;
          },
          run: (exe, args) async => calls.add([exe, ...args]),
        );
        await n.show('rates', 'Gate red');
        expect(native, [('rates', 'Gate red')]);
        expect(calls, isEmpty);
      },
    );

    test('Linux uses canberra and notify-send', () async {
      final calls = <List<String>>[];
      final n = DesktopNotifier(
        isMac: false,
        icon: () => '/app/icon.png',
        run: (exe, args) async => calls.add([exe, ...args]),
      );
      await n.playSound('chime');
      await n.show('rates', 'Gate red');
      expect(calls[0], ['canberra-gtk-play', '-i', 'complete']);
      expect(calls[1], [
        'notify-send',
        '--app-name=haro',
        '--icon=/app/icon.png',
        '--',
        'rates',
        'Gate red',
      ]);
    });

    test('Linux names the app even with no bundled icon', () async {
      final calls = <List<String>>[];
      final n = DesktopNotifier(
        isMac: false,
        icon: () => null,
        run: (exe, args) async => calls.add([exe, ...args]),
      );
      await n.show('rates', 'Gate green');
      expect(calls.single, [
        'notify-send',
        '--app-name=haro',
        '--',
        'rates',
        'Gate green',
      ]);
    });
  });

  testWidgets(
    'NotifierHost turns a feed event into a tone and a notification',
    (tester) async {
      final calls = <List<String>>[];
      final store = _Store();
      final container = ProviderContainer(
        overrides: [
          workspaceStoreProvider.overrideWith(() => store),
          devicePrefsStoreProvider.overrideWithValue(
            MemoryDevicePrefsStore({
              'notifications': {'desktop': true, 'sound': 'glass'},
            }),
          ),
          desktopNotifierProvider.overrideWithValue(
            DesktopNotifier(
              isMac: true,
              native: (_, _) async => false,
              run: (exe, args) async => calls.add([exe, ...args]),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: NotifierHost(
              isFocused: () async => false,
              child: const SizedBox(),
            ),
          ),
        ),
      );
      container
          .read(workspaceStoreProvider.notifier)
          .emitNotify(gate(mode: WorkspaceMode.manual));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(calls.map((c) => c.first), containsAll(['afplay', 'osascript']));
    },
  );
}
