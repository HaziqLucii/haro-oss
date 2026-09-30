import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/json_util.dart' show asJson, jStrN;
import 'device_prefs.dart';

/// App-wide XP prefs (Show XP, Streak reminder). Same shape as the Display and Editor prefs:
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

/// The local day (`yyyy-mm-dd`) the streak nudge was dismissed on, or null. Kept under its own
/// device-file key so saving the XP settings tab never overwrites it with a stale draft.
class XpNudgeDismissed extends Notifier<String?> {
  static const _key = 'xp_nudge';

  @override
  String? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    try {
      final file = await ref.read(devicePrefsStoreProvider).read();
      final day = jStrN(asJson(file[_key]), 'dismissed_on');
      if (state == null && day != null) state = day;
    } catch (_) {}
  }

  Future<void> dismiss(String day) async {
    state = day;
    try {
      await ref
          .read(devicePrefsStoreProvider)
          .update(
            (file) => {
              ...file,
              _key: {'dismissed_on': day},
            },
          );
    } catch (_) {}
  }
}

final xpNudgeDismissedProvider = NotifierProvider<XpNudgeDismissed, String?>(
  XpNudgeDismissed.new,
);
