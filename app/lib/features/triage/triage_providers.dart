import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/workspace_store.dart';
import 'triage_model.dart';

/// Session-only: a fresh app start goes back to All.
class TriageFilterNotifier extends Notifier<TriageFilter> {
  @override
  TriageFilter build() => TriageFilter.all;

  void pick(TriageFilter f) => state = f;
}

final triageFilterProvider =
    NotifierProvider<TriageFilterNotifier, TriageFilter>(
      TriageFilterNotifier.new,
    );

final triageViewProvider = Provider<TriageView>(
  (ref) => buildTriageView(ref.watch(workspaceStoreProvider)),
);
