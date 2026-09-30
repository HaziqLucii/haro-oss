import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/workspace_flow.dart' show StepKey;

/// The bottom panel's tabs. [devLog] only shows once a dev server has run in the workspace.
enum BottomTab { terminal, gate, problems, devLog }

/// `/w/<id>/<step>`.
String workspaceStepPath(String workspaceId, StepKey step) =>
    '/w/$workspaceId/${step.name}';

/// 1-based, as ⌘1 to ⌘4 number them. Null outside 1 to 4.
StepKey? stepFromNumber(int n) =>
    n >= 1 && n <= StepKey.values.length ? StepKey.values[n - 1] : null;

StepKey stepFromName(String? name) {
  for (final s in StepKey.values) {
    if (s.name == name) return s;
  }
  return StepKey.agent;
}

@immutable
class WorkspaceUi {
  const WorkspaceUi({
    this.activeWorkspaceId,
    this.terminalOpen = false,
    this.bottomTab = BottomTab.terminal,
    this.composerFocusRequest = 0,
  });

  /// The workspace whose page is mounted, so global shortcuts know what ⌘1-4 or ⌘G target.
  final String? activeWorkspaceId;
  final bool terminalOpen;
  final BottomTab bottomTab;

  /// Bumped by [WorkspaceUiNotifier.requestComposerFocus]; the composer listens and focuses
  /// itself on every change.
  final int composerFocusRequest;

  WorkspaceUi copyWith({
    Object? activeWorkspaceId = _keep,
    bool? terminalOpen,
    BottomTab? bottomTab,
    int? composerFocusRequest,
  }) => WorkspaceUi(
    activeWorkspaceId: identical(activeWorkspaceId, _keep)
        ? this.activeWorkspaceId
        : activeWorkspaceId as String?,
    terminalOpen: terminalOpen ?? this.terminalOpen,
    bottomTab: bottomTab ?? this.bottomTab,
    composerFocusRequest: composerFocusRequest ?? this.composerFocusRequest,
  );
}

const Object _keep = Object();

class WorkspaceUiNotifier extends Notifier<WorkspaceUi> {
  @override
  WorkspaceUi build() => const WorkspaceUi();

  void setActive(String? workspaceId) {
    if (state.activeWorkspaceId == workspaceId) return;
    state = state.copyWith(activeWorkspaceId: workspaceId);
  }

  /// Only clears when [workspaceId] is still the active one, so a page that unmounts after
  /// its replacement mounted does not wipe the new page's registration.
  void clearActive(String workspaceId) {
    if (state.activeWorkspaceId == workspaceId) {
      state = state.copyWith(activeWorkspaceId: null);
    }
  }

  void toggleTerminal() =>
      state = state.copyWith(terminalOpen: !state.terminalOpen);

  void setTerminalOpen(bool open) => state = state.copyWith(terminalOpen: open);

  void selectBottomTab(BottomTab tab) => state = state.copyWith(bottomTab: tab);

  /// Opens the bottom panel on the Terminal tab.
  void showShell() =>
      state = state.copyWith(terminalOpen: true, bottomTab: BottomTab.terminal);

  void requestComposerFocus() => state = state.copyWith(
    composerFocusRequest: state.composerFocusRequest + 1,
  );
}

final workspaceUiProvider = NotifierProvider<WorkspaceUiNotifier, WorkspaceUi>(
  WorkspaceUiNotifier.new,
);
