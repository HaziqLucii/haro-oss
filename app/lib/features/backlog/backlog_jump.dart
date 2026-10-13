import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the Backlog should land when it opens or is already open: a note, a todo (its file and
/// position) or a GitHub issue. The quick switcher, the review and a note's `[[todo:...]]` link set
/// it; the page consumes it and clears it.
class BacklogJump {
  const BacklogJump({
    required this.projectId,
    required this.kind,
    this.path,
    this.file,
    this.index,
    this.number,
    this.text,
  });

  final String projectId;

  /// `note`, `todo` or `issue`.
  final String kind;
  final String? path;
  final String? file;
  final int? index;
  final int? number;

  /// A todo named by its text (a note's link): the page finds its position in [file].
  final String? text;
}

class BacklogJumpNotifier extends Notifier<BacklogJump?> {
  @override
  BacklogJump? build() => null;

  void jump(BacklogJump j) => state = j;

  void clear() => state = null;
}

final backlogJumpProvider = NotifierProvider<BacklogJumpNotifier, BacklogJump?>(
  BacklogJumpNotifier.new,
);
