import 'dart:math' as math;

import 'package:haro_app/api/haro_api.dart';
import 'package:haro_app/api/models/models.dart';

/// Hands out `replies` to successive `gitPr` reads (the last one repeats). A reply that is an
/// `Exception` is thrown instead of returned.
class PrPollApi extends HaroApi {
  PrPollApi(this.replies) : super(Uri.parse('http://127.0.0.1:1'));

  final List<Object> replies;
  int calls = 0;

  @override
  Future<PrStatusResponse> gitPr(String wsId) async {
    final reply = replies[math.min(calls, replies.length - 1)];
    calls++;
    if (reply is Exception) throw reply;
    return reply as PrStatusResponse;
  }
}
