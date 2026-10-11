import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/models/models.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_store.dart';
import '../../../../state/workspace_flow.dart' show AgentPhase;
import 'composer_logic.dart';

/// What the composer holds for one workspace. Lives in a provider, not in the widget, so the
/// draft survives hopping to another step and back, and so the empty state can fill it.
@immutable
class ComposerDraft {
  const ComposerDraft({
    this.text = '',
    this.planFirst = false,
    this.testFirst = false,
    this.model,
    this.effort,
    this.attachments = const [],
    this.fillRevision = 0,
    this.scope = '',
    this.scopeInput = '',
  });

  final String text;
  final bool planFirst;

  /// Draft only a failing acceptance test first. Exclusive with [planFirst].
  final bool testFirst;

  /// Picker overrides, used only when `[roles]` is off.
  final String? model;
  final String? effort;
  final List<Attachment> attachments;

  /// Bumped when something other than the field itself sets the text (a suggestion), so the
  /// field knows to take it and move the caret to the end.
  final int fillRevision;

  /// The scope field as typed. Sticky for the session: a send does not clear it.
  final String scope;

  /// Text typed in the scope box that is not a chip yet. A run takes it too, so what the box
  /// shows is what is sent.
  final String scopeInput;

  /// The fence a run starts with: the chips plus whatever is still being typed.
  List<String> get fence => parseScope(addScopeEntry(scope, scopeInput));

  bool get isEmpty => text.trim().isEmpty && attachments.isEmpty;

  ComposerDraft copyWith({
    String? text,
    bool? planFirst,
    bool? testFirst,
    Object? model = _keep,
    Object? effort = _keep,
    List<Attachment>? attachments,
    int? fillRevision,
    String? scope,
    String? scopeInput,
  }) => ComposerDraft(
    text: text ?? this.text,
    planFirst: planFirst ?? this.planFirst,
    testFirst: testFirst ?? this.testFirst,
    model: identical(model, _keep) ? this.model : model as String?,
    effort: identical(effort, _keep) ? this.effort : effort as String?,
    attachments: attachments ?? this.attachments,
    fillRevision: fillRevision ?? this.fillRevision,
    scope: scope ?? this.scope,
    scopeInput: scopeInput ?? this.scopeInput,
  );
}

const Object _keep = Object();

class ComposerDraftNotifier extends Notifier<ComposerDraft> {
  ComposerDraftNotifier(this.workspaceId);

  final String workspaceId;

  @override
  ComposerDraft build() => const ComposerDraft();

  void setText(String text) {
    if (text != state.text) state = state.copyWith(text: text);
  }

  /// Replaces the text from outside the field.
  void fill(String text) =>
      state = state.copyWith(text: text, fillRevision: state.fillRevision + 1);

  void setPlanFirst(bool on) =>
      state = state.copyWith(planFirst: on, testFirst: on ? false : null);
  void setTestFirst(bool on) =>
      state = state.copyWith(testFirst: on, planFirst: on ? false : null);
  void setScope(String scope) {
    if (scope != state.scope) state = state.copyWith(scope: scope);
  }

  void setScopeInput(String text) {
    if (text != state.scopeInput) state = state.copyWith(scopeInput: text);
  }

  void setModel(String? model) => state = state.copyWith(model: model);
  void setEffort(String? effort) => state = state.copyWith(effort: effort);

  void addAttachment(Attachment a) =>
      state = state.copyWith(attachments: [...state.attachments, a]);

  void removeAttachment(String path) => state = state.copyWith(
    attachments: [
      for (final a in state.attachments)
        if (a.path != path) a,
    ],
  );

  /// After a successful send: text and attachments go, the toggle and picks stay.
  void clearSent() => state = state.copyWith(
    text: '',
    attachments: const [],
    fillRevision: state.fillRevision + 1,
  );
}

final composerDraftProvider =
    NotifierProvider.family<ComposerDraftNotifier, ComposerDraft, String>(
      ComposerDraftNotifier.new,
    );

/// A failed load must not block the composer: it falls back to plain defaults.
final agentRolesProvider = FutureProvider.autoDispose
    .family<RolesConfig?, String>((ref, projectId) async {
      try {
        return await ref.watch(haroApiProvider).getRoles(projectId);
      } catch (_) {
        return null;
      }
    });

final agentConfigProvider = FutureProvider.autoDispose
    .family<AgentConfig?, String>((ref, projectId) async {
      try {
        return await ref.watch(haroApiProvider).getAgent(projectId);
      } catch (_) {
        return null;
      }
    });

/// Worktree file paths for `@` completion and the Scope box's path suggestions. Only read once
/// one of them is in use.
final worktreeFilesProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, workspaceId) async {
      // The tree is walked server-side; keep it for a while so each `@` does not refetch.
      final link = ref.keepAlive();
      final timer = Timer(const Duration(seconds: 60), link.close);
      ref.onDispose(timer.cancel);
      try {
        return flattenFiles(
          await ref.watch(haroApiProvider).listFiles(workspaceId),
        );
      } catch (_) {
        return const [];
      }
    });

@immutable
class TaskSuggestion {
  const TaskSuggestion({required this.text, required this.source});

  final String text;

  /// The backlog file it came from.
  final String source;
}

/// Open backlog items that no workspace has picked up, files with progress first (the
/// backlog view's "In progress" group leads), at most [limit].
List<TaskSuggestion> pickSuggestions(TodoResponse todo, {int limit = 3}) {
  final started = <TodoFile>[];
  final fresh = <TodoFile>[];
  for (final f in todo.files) {
    final done = f.items.where((i) => i.done).length;
    (done > 0 ? started : fresh).add(f);
  }
  final out = <TaskSuggestion>[];
  for (final f in [...started, ...fresh]) {
    for (final i in f.items) {
      if (i.done || i.seededWorkspace != null || i.text.trim().isEmpty) {
        continue;
      }
      out.add(TaskSuggestion(text: i.text.trim(), source: f.label));
      if (out.length >= limit) return out;
    }
  }
  return out;
}

final taskSuggestionsProvider = FutureProvider.autoDispose
    .family<List<TaskSuggestion>, String>((ref, projectId) async {
      try {
        return pickSuggestions(
          await ref.watch(haroApiProvider).getTodo(projectId),
        );
      } catch (_) {
        return const [];
      }
    });

/// Injected so tests can pin "14m ago".
final agentClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Model, effort and adapter the composer would start a run with right now. Shared by
/// `Run agent` and `Approve plan`, which the React client feeds the same `runArgs`.
RunArgs currentRunArgs(WidgetRef ref, String workspaceId) {
  final projectId = ref
      .read(workspaceDetailProvider(workspaceId))
      .workspace
      ?.projectId;
  final roles = projectId == null
      ? null
      : ref.read(agentRolesProvider(projectId)).value;
  final agent = projectId == null
      ? null
      : ref.read(agentConfigProvider(projectId)).value;
  final draft = ref.read(composerDraftProvider(workspaceId));
  return resolveRunArgs(
    rolesEnabled: roles?.enabled ?? false,
    adapter: agent?.adapter,
    localModel: agent?.localModel,
    model: draft.model,
    effort: draft.effort,
  );
}

/// Whether a new run may start. `Run agent` and the ⌘↵ shortcut both ask this, so the key
/// cannot start a second run the button would refuse.
bool canStartRun({
  required WorkspaceStatus? status,
  required AgentPhase phase,
  required bool sending,
}) =>
    !sending &&
    (status == null || !isAgentBusy(status)) &&
    phase != AgentPhase.running &&
    phase != AgentPhase.queued;
