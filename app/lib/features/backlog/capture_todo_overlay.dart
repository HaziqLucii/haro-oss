import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/haro_api.dart';
import '../../data/workspace_store.dart';
import '../../overlays/overlay.dart';
import '../../overlays/toast.dart';
import '../../theme/haro_theme.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_text_field.dart';
import '../new_workspace/creation_widgets.dart';
import '../new_workspace/new_workspace_overlay.dart'
    show defaultProjectId, openWorkspaceProjectId;

/// The project the open Backlog page is showing. The URL keeps the project the page was opened
/// with, so picking another one inside the page is only visible here.
final backlogProjectId = ValueNotifier<String?>(null);

/// The project the page in front of the user belongs to: the Backlog's `?project=`, else the
/// open workspace's, else the first one.
String? captureProjectId(BuildContext context, WorkspaceSnapshot store) {
  String? given;
  try {
    final uri = GoRouter.of(context).routerDelegate.currentConfiguration.uri;
    if (uri.path == '/backlog') {
      given = backlogProjectId.value ?? uri.queryParameters['project'];
    }
  } catch (_) {
    given = null;
  }
  return defaultProjectId(
    projects: store.projects,
    given: given,
    openWorkspaceProjectId: openWorkspaceProjectId(context, store),
  );
}

Future<void> showCaptureTodo(BuildContext context) {
  final container = ProviderScope.containerOf(context);
  final id = captureProjectId(context, container.read(workspaceStoreProvider));
  if (id == null) {
    showHaroToast(context, 'Add a project first.');
    return Future.value();
  }
  return showHaroOverlay<void>(
    context,
    width: 520,
    child: CaptureTodoOverlay(projectId: id),
  );
}

/// One line, Enter, and it is a `- [ ]` in the project's `inbox.md`. No picking a file or a
/// section: the point is to get the thought down without leaving the step you are on.
class CaptureTodoOverlay extends ConsumerStatefulWidget {
  const CaptureTodoOverlay({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<CaptureTodoOverlay> createState() => _CaptureTodoOverlayState();
}

class _CaptureTodoOverlayState extends ConsumerState<CaptureTodoOverlay> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save(String raw) async {
    final title = raw.trim();
    if (title.isEmpty || _busy) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(haroApiProvider)
          .addTodoItem(widget.projectId, title, inbox: true);
    } on HaroApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
      return;
    }
    if (!mounted) return;
    navigator.pop();
    // The root navigator outlives this overlay, so its context is still good here.
    // ignore: use_build_context_synchronously
    showHaroToast(navigator.context, 'Added to the inbox');
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(workspaceStoreProvider).projects;
    final name = projects
        .where((p) => p.id == widget.projectId)
        .map((p) => p.name)
        .firstOrNull;
    return PopScope(
      canPop: !_busy,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Capture a todo',
              style: HaroText.ui(size: 20, weight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            MonoCaption('${name ?? 'project'} · inbox'),
            const SizedBox(height: 16),
            HaroTextField(
              key: const Key('capture-text'),
              controller: _text,
              autofocus: true,
              enabled: !_busy,
              hintText: 'What needs doing? Enter to save',
              onSubmitted: _save,
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              ErrorLine(_error!),
            ],
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                HaroButton(
                  label: 'Cancel',
                  onPressed: _busy ? null : () => closeHaroOverlay(context),
                ),
                const SizedBox(width: 8),
                HaroButton(
                  key: const Key('capture-save'),
                  label: _busy ? 'Saving…' : 'Add',
                  variant: HaroButtonVariant.primary,
                  onPressed: _busy ? null : () => _save(_text.text),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
