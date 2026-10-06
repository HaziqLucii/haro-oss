import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart';
import '../../../../data/workspace_actions.dart';

/// The Review with AI result for one workspace. Held outside the ship step so it survives
/// switching steps; an explicit click is the only thing that ever starts a run.
class AiReviewState {
  const AiReviewState({this.busy = false, this.review, this.failure});

  final bool busy;
  final AiReview? review;

  /// The request itself failed (network, 404). A reviewer that could not run is
  /// [AiReview.error] instead.
  final String? failure;
}

class AiReviewNotifier extends Notifier<AiReviewState> {
  AiReviewNotifier(this.workspaceId);

  final String workspaceId;

  @override
  AiReviewState build() => const AiReviewState();

  Future<void> run() async {
    if (state.busy) return;
    state = const AiReviewState(busy: true);
    try {
      final review = await ref
          .read(workspaceActionsProvider(workspaceId))
          .runReview();
      state = AiReviewState(review: review);
    } catch (e) {
      state = AiReviewState(failure: e is HaroApiException ? e.message : '$e');
    }
  }
}

final aiReviewProvider =
    NotifierProvider.family<AiReviewNotifier, AiReviewState, String>(
      AiReviewNotifier.new,
    );
