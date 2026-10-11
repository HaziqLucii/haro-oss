import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../data/workspace_store.dart' show workspaceStoreProvider;
import '../../../../settings/device_prefs.dart';
import '../workbench/workbench_state.dart';
import 'editor_sticky.dart';
import 'editor_tabs.dart';

const _debounce = Duration(milliseconds: 500);

/// The saved sticky state for a workspace (null when there is none), read once; while it is
/// watched it also writes the live tabs and side panel back, 500 ms after the last change and
/// once more as it goes away (leaving the step), so the last edit is never lost.
///
/// Listening starts only after the read, so a change made while the file is being read cannot
/// overwrite what is about to be restored.
final editorStickyProvider = FutureProvider.autoDispose
    .family<StickyEditorState?, String>((ref, id) async {
      final store = ref.read(devicePrefsStoreProvider);
      StickyEditorState? saved;
      try {
        saved = parseStickyMap((await store.read())['code_sticky'])[id];
      } catch (_) {}
      if (!ref.mounted) return saved;

      var written = saved?.contentKey ?? '';
      var hasEntry = saved != null;
      Timer? timer;
      StickyEditorState? pending;
      Set<String>? pendingKnown;

      Future<void> flush() async {
        final next = pending;
        if (next == null) return;
        final known = pendingKnown;
        pending = null;
        written = next.contentKey;
        try {
          await store.update(
            (file) => mergeSticky(file, id, next, knownIds: known),
          );
        } catch (_) {}
      }

      void changed(_, _) {
        final next = StickyEditorState.fromLive(
          tabs: ref.read(editorTabsProvider(id)),
          workbench: ref.read(workbenchProvider(id)),
          savedAt: DateTime.now().millisecondsSinceEpoch,
        );
        if (next.contentKey == written || (!next.hasTabs && !hasEntry)) {
          pending = null;
          timer?.cancel();
          return;
        }
        final snap = ref.read(workspaceStoreProvider);
        hasEntry = next.hasTabs;
        pending = next;
        pendingKnown = snap.loaded ? {for (final w in snap.all) w.id} : null;
        timer?.cancel();
        timer = Timer(_debounce, flush);
      }

      ref.listen(editorTabsProvider(id), changed);
      ref.listen(workbenchProvider(id), changed);
      ref.onDispose(() {
        timer?.cancel();
        flush();
      });
      return saved;
    });
