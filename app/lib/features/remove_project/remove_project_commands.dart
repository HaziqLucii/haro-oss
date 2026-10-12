import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shortcuts/app_commands.dart';
import 'remove_project_overlay.dart';

/// Registers the real `removeProject` (⌘K "Remove project", the sidebar right-click menu) on
/// [appCommandsProvider]. Call once from a post-frame callback of a widget under the router.
void registerRemoveProjectCommands(
  WidgetRef ref,
  BuildContext Function() context,
) {
  ref
      .read(appCommandsProvider.notifier)
      .register(
        (c) => c.copyWith(
          removeProject: (projectId) {
            final ctx = context();
            if (!ctx.mounted) return;
            showRemoveProject(ctx, projectId: projectId);
          },
        ),
      );
}
