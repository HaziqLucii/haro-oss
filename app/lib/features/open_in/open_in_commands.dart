import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shortcuts/app_commands.dart';
import '../workspace/workspace_ui.dart';
import 'open_in_launcher.dart';

/// Registers `openWorktree` (⌘⇧O and the palette action): the open workspace's worktree in
/// the default editor, or the menu when the preference is "Ask every time".
void registerOpenInCommands(WidgetRef ref, BuildContext Function() context) {
  ref
      .read(appCommandsProvider.notifier)
      .register(
        (c) => c.copyWith(
          openWorktree: () {
            final id = ref.read(workspaceUiProvider).activeWorkspaceId;
            final ctx = context();
            if (id == null || !ctx.mounted) return;
            final size = MediaQuery.sizeOf(ctx);
            ref
                .read(openInLauncherProvider)
                .launch(
                  ctx,
                  workspaceId: id,
                  source: 'header',
                  position: Offset(size.width / 2 - 102, size.height / 4),
                );
          },
        ),
      );
}
