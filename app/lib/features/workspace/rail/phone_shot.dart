import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api/haro_api.dart' show HaroApiException;
import '../../../data/workspace_actions.dart';

/// Where the project's `screenshot` tool writes its picture (the same file the agent opens
/// after `haro-app do screenshot`), relative to the worktree.
const phoneShotPath = '.haro/shots/screen.png';

/// How the card loads the picture; a test swaps it for one that needs no network.
ImageProvider Function(String url) phoneImageProvider = NetworkImage.new;

class PhoneShotState {
  const PhoneShotState({required this.revision, this.busy = false, this.error});

  /// Bumped on every new picture so the image is read again instead of served from cache. It
  /// starts from the clock, so a reopened workspace never repeats a number the image cache holds.
  final int revision;
  final bool busy;
  final String? error;

  PhoneShotState copyWith({int? revision, bool? busy, String? error}) =>
      PhoneShotState(
        revision: revision ?? this.revision,
        busy: busy ?? this.busy,
        error: error,
      );
}

/// The rail's phone card: runs the project's `screenshot` and `mirror` tools (declared under
/// `[scripts.tools]`, so haro itself knows nothing about adb) and says when a picture is new.
class PhoneShot extends Notifier<PhoneShotState> {
  PhoneShot(this.workspaceId);

  final String workspaceId;
  Timer? _later;
  bool _again = false;
  bool _mirroring = false;

  @override
  PhoneShotState build() {
    ref.onDispose(() => _later?.cancel());
    return PhoneShotState(revision: DateTime.now().millisecondsSinceEpoch);
  }

  WorkspaceActions get _actions =>
      ref.read(workspaceActionsProvider(workspaceId));

  /// A moment after something changed on the phone (a reload, the app coming up), take a
  /// picture of it. Quiet: a phone that is not there is not worth an error.
  void takeSoon([Duration after = const Duration(milliseconds: 1500)]) {
    _later?.cancel();
    _later = Timer(after, () => take(quiet: true));
  }

  Future<void> take({bool quiet = false}) async {
    if (state.busy) {
      // A picture is being taken: one more right after it, so the change is not missed.
      _again = true;
      return;
    }
    state = state.copyWith(busy: true);
    String? error;
    var fresh = false;
    try {
      final r = await _actions.runTool('screenshot');
      if (r.ok) {
        fresh = true;
      } else if (!quiet) {
        error = r.lastLine.isEmpty ? 'The screenshot failed' : r.lastLine;
      }
    } on HaroApiException catch (e) {
      if (!quiet) error = _problem(e, 'screenshot');
    } catch (_) {
      if (!quiet) error = 'The screenshot failed';
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      busy: false,
      revision: fresh ? state.revision + 1 : null,
      error: error,
    );
    if (_again) {
      _again = false;
      unawaited(take(quiet: true));
    }
  }

  Future<void> mirror() async {
    if (_mirroring) return;
    _mirroring = true;
    String? error;
    try {
      final r = await _actions.runTool('mirror');
      if (!r.ok) {
        error = r.lastLine.isEmpty ? 'The mirror did not start' : r.lastLine;
      }
    } on HaroApiException catch (e) {
      error = _problem(e, 'mirror');
    } catch (_) {
      error = 'The mirror did not start';
    } finally {
      _mirroring = false;
    }
    if (ref.mounted) state = state.copyWith(error: error);
  }

  String _problem(HaroApiException e, String tool) => e.status == 404
      ? 'No $tool tool: declare [scripts.tools.$tool] in .haro/settings.toml'
      : e.message;
}

final phoneShotProvider = NotifierProvider.autoDispose
    .family<PhoneShot, PhoneShotState, String>(PhoneShot.new);
