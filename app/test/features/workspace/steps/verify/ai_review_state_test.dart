import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/features/workspace/steps/verify/ai_review_state.dart';
import 'package:haro_app/features/workspace/steps/verify/files_viewed.dart';

class _Sig extends Notifier<String> {
  @override
  String build() => 'aaa';

  void set(String v) => state = v;
}

final _sig = NotifierProvider<_Sig, String>(_Sig.new);

class _Actions extends WorkspaceActions {
  _Actions(super.ref, super.workspaceId);

  @override
  Future<AiReview> runReview({String? model}) async =>
      const ReviewResult(ranAt: 1, model: 'sonnet', summary: 'x');
}

void main() {
  test(
    'a review is dropped when the diff changes, kept when it does not',
    () async {
      final c = ProviderContainer(
        overrides: [
          diffSignatureProvider.overrideWith((ref, id) => ref.watch(_sig)),
          workspaceActionsProvider.overrideWith((ref, id) => _Actions(ref, id)),
        ],
      );
      addTearDown(c.dispose);
      final p = aiReviewProvider('ws');
      c.listen(p, (_, _) {});
      await c.read(p.notifier).run();
      expect(c.read(p).review, isNotNull);

      c.read(_sig.notifier).set('aaa');
      expect(c.read(p).review, isNotNull);

      c.read(_sig.notifier).set('bbb');
      expect(c.read(p).review, isNull);
    },
  );
}
