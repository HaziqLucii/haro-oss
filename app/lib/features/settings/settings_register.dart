import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/workspace_store.dart';
import '../../shortcuts/app_commands.dart';
import 'device_prefs.dart';
import 'display_prefs_provider.dart';
import 'editor_prefs_provider.dart';
import 'settings_layers.dart';
import 'settings_overlay.dart';
import 'xp_prefs_provider.dart';

/// The project the user is looking at: the project of the open `/w/:id/...` workspace, else
/// `null` (the overlay then falls back to the first project).
String? currentProjectId(BuildContext context, WorkspaceSnapshot snapshot) {
  final router = GoRouter.maybeOf(context);
  if (router == null) return null;
  final uri = router.routerDelegate.currentConfiguration.uri;
  final segments = uri.pathSegments;
  if (segments.firstOrNull == 'first-run') {
    return uri.queryParameters['project'];
  }
  if (segments.length < 2 || segments.first != 'w') return null;
  for (final e in snapshot.workspaces.entries) {
    if (e.value.any((w) => w.id == segments[1])) return e.key;
  }
  return null;
}

/// Registers `openSettings` on [appCommandsProvider]. Call it once from `initState` or a
/// post-frame callback of a widget that sits under the app's Navigator (ShellHost), passing
/// a getter for a context the overlay can be shown from.
///
/// ```dart
/// registerSettingsCommands(ref, () => context);
/// ```
void registerSettingsCommands(WidgetRef ref, BuildContext Function() context) {
  ref
      .read(appCommandsProvider.notifier)
      .register(
        (c) => c.copyWith(
          openSettings: (tab) {
            final ctx = context();
            if (!ctx.mounted) return;
            openSettingsFor(ref, ctx, tab: tab);
          },
        ),
      );
}

/// Opens Settings on [tab] for [projectId], or for the project of the current route when null.
void openSettingsFor(
  WidgetRef ref,
  BuildContext context, {
  SettingsTab? tab,
  String? projectId,
}) {
  final snapshot = ref.read(workspaceStoreProvider);
  showSettingsOverlay(
    context,
    api: ref.read(haroApiProvider),
    devicePrefs: ref.read(devicePrefsStoreProvider),
    layers: ref.read(settingsLayersProvider),
    projects: snapshot.projects,
    projectId: projectId ?? currentProjectId(context, snapshot),
    tab: tab,
    onDisplaySaved: ref.read(displayPrefsProvider.notifier).set,
    onEditorSaved: ref.read(editorPrefsProvider.notifier).set,
    onXpSaved: ref.read(xpPrefsProvider.notifier).set,
  );
}
