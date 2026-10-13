import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/json_util.dart' show asJson;
import 'device_prefs.dart';

/// App-wide notification prefs the UI reads live (today: when to warn that the context is
/// filling). Same shape as the Display and XP prefs: the defaults until the device file is read,
/// and Settings pushes the saved value through [set].
class NotificationPrefsNotifier extends Notifier<NotificationPrefs> {
  bool _touched = false;

  @override
  NotificationPrefs build() {
    _load();
    return const NotificationPrefs();
  }

  Future<void> _load() async {
    try {
      final file = await ref.read(devicePrefsStoreProvider).read();
      if (!_touched) {
        state = NotificationPrefs.fromJson(asJson(file['notifications']));
      }
    } catch (_) {}
  }

  void set(NotificationPrefs prefs) {
    _touched = true;
    state = prefs;
  }
}

final notificationPrefsProvider =
    NotifierProvider<NotificationPrefsNotifier, NotificationPrefs>(
      NotificationPrefsNotifier.new,
    );
