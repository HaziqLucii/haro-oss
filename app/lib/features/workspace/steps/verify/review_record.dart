import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/haro_api.dart';
import '../../../../data/workspace_store.dart';
import '../code/diff_model.dart';
import 'files_viewed.dart';
import 'review_dwell.dart';

/// Per workspace, so the time a diff has been open survives leaving the review step and coming back.
final reviewDwellProvider = Provider.family<ReviewDwell, String>(
  (ref, id) => ReviewDwell(),
);

/// The files marked Viewed on their current diff, with the seconds each was open. A mark saved
/// before seconds were recorded is left out rather than counted as an instant view.
List<({String path, double seconds})> viewedRecord(
  List<DiffFile> files,
  Map<String, String> marks,
  double? Function(String path) secondsFor,
) => [
  for (final f in files)
    if (marks[f.path] == fileSignature(f) && secondsFor(f.path) != null)
      (path: f.path, seconds: secondsFor(f.path)!),
];

/// Sends what the review step saw to the backend so the receipt can say it. Each call replaces
/// the whole list, so one request is in flight per workspace and a newer list waits for it
/// (two in flight could land out of order). Best effort: a failed call loses a line on the
/// receipt, never blocks the review.
class ReviewRecordReporter {
  ReviewRecordReporter(this._api);

  final HaroApi Function() _api;
  final Set<String> _sending = {};
  final Map<String, List<({String path, double seconds})>> _next = {};
  final Map<String, int> _files = {};

  void report(
    String workspaceId,
    List<DiffFile> files,
    Map<String, String> marks,
    double? Function(String path) secondsFor,
  ) {
    _next[workspaceId] = viewedRecord(files, marks, secondsFor);
    _files[workspaceId] = files.length;
    if (_sending.add(workspaceId)) unawaited(_drain(workspaceId));
  }

  Future<void> _drain(String workspaceId) async {
    try {
      while (_next.containsKey(workspaceId)) {
        final viewed = _next.remove(workspaceId)!;
        try {
          await _api().putReviewRecord(
            workspaceId,
            viewed: viewed,
            files: _files[workspaceId],
          );
        } catch (_) {}
      }
    } finally {
      _sending.remove(workspaceId);
    }
  }
}

final reviewRecordReporterProvider = Provider<ReviewRecordReporter>(
  (ref) => ReviewRecordReporter(() => ref.read(haroApiProvider)),
);
