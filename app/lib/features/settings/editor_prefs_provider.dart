import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/json_util.dart' show asJson;
import 'device_prefs.dart';

/// App-wide Editor prefs (font size, minimap). Same shape as the Display prefs: defaults until
/// the device file is read, and Settings pushes the saved value through [set].
class EditorPrefsNotifier extends Notifier<EditorPrefs> {
  bool _touched = false;

  @override
  EditorPrefs build() {
    _load();
    return const EditorPrefs();
  }

  Future<void> _load() async {
    try {
      final file = await ref.read(devicePrefsStoreProvider).read();
      if (!_touched) state = EditorPrefs.fromJson(asJson(file['editor']));
    } catch (_) {}
  }

  void set(EditorPrefs prefs) {
    _touched = true;
    state = prefs;
  }
}

final editorPrefsProvider = NotifierProvider<EditorPrefsNotifier, EditorPrefs>(
  EditorPrefsNotifier.new,
);
