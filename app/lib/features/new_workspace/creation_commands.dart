import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/workspace_store.dart';
import '../../shortcuts/app_commands.dart';
import '../add_project/add_project_overlay.dart';
import '../backlog/capture_todo_overlay.dart';
import 'new_workspace_overlay.dart';

/// Registers the real `openNewWorkspace` (⌘N, the sidebar `+`), `openAddProject` and
/// `openBacklog` implementations on [appCommandsProvider].
///
/// Call once from `ShellHost` inside a post-frame callback: Riverpod rejects provider writes
/// during `initState` and `build` alike. [context] is read when a command fires, so pass a closure
/// returning a context that sits under the router, such as the host's own `context`.
///
/// `openNewWorkspace(null)` picks the project of the open workspace, else the first one.
/// Every flow ends by reloading the workspace store and navigating: New workspace to
/// `/w/<id>/agent`, Add project to `/first-run?project=<id>`.
void registerCreationCommands(WidgetRef ref, BuildContext Function() context) {
  ref
      .read(appCommandsProvider.notifier)
      .register(
        (c) => c.copyWith(
          openNewWorkspace: (projectId) =>
              showNewWorkspace(context(), projectId: projectId),
          openAddProject: () => showAddProject(context()),
          captureTodo: () => showCaptureTodo(context()),
          openBacklog: () {
            final ctx = context();
            final project = openWorkspaceProjectId(
              ctx,
              ref.read(workspaceStoreProvider),
            );
            GoRouter.of(ctx)
                .go(project == null ? '/backlog' : '/backlog?project=$project');
          },
        ),
      );
}
