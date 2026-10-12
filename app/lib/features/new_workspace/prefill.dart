/// Pre-filled New workspace, from a backlog item or issue (§6.6).
class NewWorkspacePrefill {
  const NewWorkspacePrefill({required this.task, this.title, this.seedKey});

  /// The full brief handed to the agent.
  final String task;

  /// Short text for the task input and the workspace name. Defaults to [task].
  final String? title;

  /// Links the workspace back to the backlog item so it is marked in progress.
  final String? seedKey;

  String get inputText => title ?? task;
}
