import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/shell/shell_layout.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('haro-prefs-test');
    file = File('${dir.path}/flutter-client.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('FileDevicePrefsStore', () {
    test('interleaved read-modify-write from two writers keeps every key', () {
      final a = FileDevicePrefsStore(file: file);
      final b = FileDevicePrefsStore(file: file);
      return Future.wait([
        for (var i = 0; i < 25; i++) ...[
          a.update((f) => {...f, 'settings_$i': i}),
          b.update((f) => {...f, 'shell_$i': i}),
        ],
      ]).then((_) async {
        final data = await a.read();
        expect(data.keys, hasLength(50));
        expect(data['settings_24'], 24);
        expect(data['shell_24'], 24);
      });
    });

    test('a reader never sees a truncated file while writers run', () async {
      final store = FileDevicePrefsStore(file: file);
      await store.write({'display': 'x' * 2000, 'keep': true});
      var writing = true;
      final writers = Future.wait([
        for (var i = 0; i < 40; i++)
          store.update((f) => {...f, 'n': i, 'pad': 'y' * 4000}),
      ]).whenComplete(() => writing = false);
      var reads = 0;
      while (writing) {
        final seen = await store.read();
        expect(seen['keep'], isTrue, reason: 'read $reads lost keys');
        reads++;
      }
      await writers;
      expect((await store.read())['n'], 39);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('write goes through the same lock as update', () async {
      final store = FileDevicePrefsStore(file: file);
      await Future.wait([
        store.update((f) => {...f, 'a': 1}),
        store.write({'b': 2}),
        store.update((f) => {...f, 'c': 3}),
      ]);
      expect(await store.read(), {'b': 2, 'c': 3});
    });

    test('a failing update does not wedge the queue', () async {
      final store = FileDevicePrefsStore(file: file);
      await expectLater(
        store.update((f) => throw StateError('nope')),
        throwsStateError,
      );
      await store.update((f) => {...f, 'ok': true});
      expect(await store.read(), {'ok': true});
    });
  });

  group('MemoryDevicePrefsStore', () {
    test('updates are serial', () async {
      final store = MemoryDevicePrefsStore();
      await Future.wait([
        for (var i = 0; i < 10; i++)
          store.update((f) async {
            await Future<void>.delayed(Duration.zero);
            return {...f, 'k$i': i};
          }),
      ]);
      expect(store.data.keys, hasLength(10));
    });
  });

  group('shell layout beside Settings', () {
    test('shell flags and a Settings save both land', () async {
      final store = FileDevicePrefsStore(file: file);
      final c = ProviderContainer(
        overrides: [devicePrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(shellLayoutProvider.notifier);
      n.toggleSidebar();
      final settings = store.update(
        (f) => {
          ...f,
          'display': {'density': 'x'},
        },
      );
      n.toggleRail();
      await settings;
      await n.writesSettled;
      final data = await store.read();
      expect(data['display'], {'density': 'x'});
      expect(data['shell'], {'sidebar_open': false, 'rail_open': false});
    });
  });
}
