import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/json_util.dart' show asJson;
import 'device_prefs.dart';

/// App-wide XP prefs (Show XP). Same shape as the Display and Editor prefs:
/// the defaults until the device file is read, and Settings pushes the saved value through [set].
class XpPrefsNotifier extends Notifier<XpPrefs> {
  bool _touched = false;

  @override
  XpPrefs build() {
    _load();
    return const XpPrefs();
  }

  Future<void> _load() async {
    try {
      final file = await ref.read(devicePrefsStoreProvider).read();
      if (!_touched) state = XpPrefs.fromJson(asJson(file['xp']));
    } catch (_) {}
  }

  void set(XpPrefs prefs) {
    _touched = true;
    state = prefs;
  }
}

final xpPrefsProvider = NotifierProvider<XpPrefsNotifier, XpPrefs>(
  XpPrefsNotifier.new,
);
