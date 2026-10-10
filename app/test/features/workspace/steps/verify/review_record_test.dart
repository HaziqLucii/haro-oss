import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/features/workspace/steps/code/diff_model.dart';
import 'package:haro_app/features/workspace/steps/verify/review_record.dart';

class _Api extends HaroApi {
  _Api() : super(Uri.parse('http://127.0.0.1:1'));

  final gates = <Completer<void>>[];
  final sent = <List<String>>[];

  @override
  Future<void> putReviewRecord(
    String wsId, {
    List<({String path, double seconds})>? viewed,
    int? files,
    String? reason,
  }) {
    sent.add([for (final v in viewed ?? const []) v.path]);
    final c = Completer<void>();
    gates.add(c);
    return c.future;
  }
}

void main() {
  final files = parseUnifiedDiff(
    'diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1,1 +1,2 @@\n x\n+y\n'
    'diff --git a/b.ts b/b.ts\n--- a/b.ts\n+++ b/b.ts\n@@ -1,1 +1,2 @@\n x\n+y\n',
  );

  test(
    'one request is in flight per workspace and the newest list follows it',
    () async {
      final api = _Api();
      final r = ReviewRecordReporter(() => api);
      double? secs(String _) => 1;
      r.report('w', files, const {}, secs);
      r.report('w', files, const {}, secs);
      r.report('w', files, const {}, secs);
      expect(api.sent, hasLength(1));
      api.gates.first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(api.sent, hasLength(2));
      api.gates.last.completeError(StateError('down'));
      await Future<void>.delayed(Duration.zero);
      expect(api.sent, hasLength(2));
      r.report('w', files, const {}, secs);
      expect(api.sent, hasLength(3));
    },
  );
}
