import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/models.dart';
import 'workspace_store.dart';

/// The review queue, read again whenever any workspace changes status (an agent finishing, a
/// merge). Null while loading or when the backend cannot answer: nothing is shown then.
final reviewQueueProvider = FutureProvider.autoDispose<ReviewQueue?>((
  ref,
) async {
  ref.watch(
    workspaceStoreProvider.select(
      (s) => [
        for (final list in s.workspaces.values)
          for (final w in list) '${w.id}:${w.statusRaw}',
      ].join(','),
    ),
  );
  try {
    return await ref.read(haroApiProvider).getReviewQueue();
  } catch (_) {
    return null;
  }
});
