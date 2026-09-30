import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/json_util.dart' show asJson;
import 'device_prefs.dart';

/// App-wide Display prefs. Starts on the defaults (the shipped look) and swaps in the stored
/// value once the file is read; Settings pushes the saved value through [set] so a change
/// shows up without a restart. Storage stays in [DevicePrefsStore].
class DisplayPrefsNotifier extends Notifier<DisplayPrefs> {
  bool _touched = false;

  @override
  DisplayPrefs build() {
    _load();
    return const DisplayPrefs();
  }

  Future<void> _load() async {
    try {
      final file = await ref.read(devicePrefsStoreProvider).read();
      // A save that lands before the first read finishes must not be overwritten by it.
      if (!_touched) state = DisplayPrefs.fromJson(asJson(file['display']));
    } catch (_) {}
  }

  void set(DisplayPrefs prefs) {
    _touched = true;
    state = prefs;
  }
}

final displayPrefsProvider =
    NotifierProvider<DisplayPrefsNotifier, DisplayPrefs>(
      DisplayPrefsNotifier.new,
    );
