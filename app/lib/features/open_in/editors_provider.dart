import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../settings/device_prefs.dart';
import '../settings/display_prefs_provider.dart';

/// The detected editors, fetched once and kept. The backend caches its own probe; [refresh]
/// asks it to look again (an editor installed since haro started).
class EditorsNotifier extends AsyncNotifier<List<EditorInfo>> {
  @override
  Future<List<EditorInfo>> build() => ref.watch(haroApiProvider).listEditors();

  Future<void> refresh() async {
    final api = ref.read(haroApiProvider);
    state = await AsyncValue.guard(() => api.listEditors(refresh: true));
  }
}

// The default retry would hammer a backend that has no such route; the menu retries on use.
final editorsProvider =
    AsyncNotifierProvider<EditorsNotifier, List<EditorInfo>>(
      EditorsNotifier.new,
      retry: (_, _) => null,
    );

/// The editor last picked from the menu this session (not persisted).
class LastEditorNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String id) => state = id;
}

final lastEditorProvider = NotifierProvider<LastEditorNotifier, String?>(
  LastEditorNotifier.new,
);

List<EditorInfo> availableEditors(Iterable<EditorInfo> all) => [
  for (final e in all)
    if (e.available) e,
];

/// What a plain click opens. Null means ask: either the preference says so or the chosen
/// editor is not installed. With a preference set, the last editor picked from the menu
/// this session wins over it.
EditorInfo? resolveDefaultEditor(
  Iterable<EditorInfo> editors, {
  required String preferred,
  String? lastUsed,
}) {
  if (preferred == DisplayPrefs.askEditor) return null;
  final available = availableEditors(editors);
  for (final id in [?lastUsed, preferred]) {
    for (final e in available) {
      if (e.id == id) return e;
    }
  }
  return null;
}

final defaultEditorProvider = Provider<EditorInfo?>((ref) {
  final editors = ref.watch(editorsProvider).value;
  if (editors == null) return null;
  return resolveDefaultEditor(
    editors,
    preferred: ref.watch(displayPrefsProvider.select((p) => p.preferredEditor)),
    lastUsed: ref.watch(lastEditorProvider),
  );
});
