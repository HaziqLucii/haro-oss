import 'json_util.dart';

/// Answer of `POST /workspaces/{id}/review`. The backend returns one of two shapes
/// depending on whether a review role is configured; `verdict` vs `findings` tells them
/// apart. Advisory only: nothing here touches the gate.
sealed class AiReview {
  const AiReview({
    required this.ranAt,
    this.model = '',
    this.summary = '',
    this.error,
    this.nothingToReview = false,
  });

  final double ranAt;
  final String model;
  final String summary;

  /// The reviewer could not run. Arrives with HTTP 200.
  final String? error;

  /// The diff against base is empty. Not an error.
  final bool nothingToReview;

  factory AiReview.fromJson(Json j) =>
      j.containsKey('verdict') && !j.containsKey('findings')
      ? ReviewVerdict.fromJson(j)
      : ReviewResult.fromJson(j);

  /// Every located item, for the shared item list.
  List<AiReviewItem> get items;
}

/// One located remark: a must-fix or a finding.
class AiReviewItem {
  const AiReviewItem({
    required this.title,
    this.file = '',
    this.line,
    this.detail = '',
    this.severity,
    this.category,
  });

  final String title;
  final String file;
  final int? line;
  final String detail;

  /// `high | medium | low | nit`, findings only.
  final String? severity;
  final String? category;
}

/// The refuter's shape (roles enabled and a review role set).
class ReviewVerdict extends AiReview {
  const ReviewVerdict({
    required super.ranAt,
    super.model,
    super.summary,
    super.error,
    super.nothingToReview,
    this.pass = true,
    this.mustFix = const [],
    this.notes = const [],
  });

  final bool pass;
  final List<AiReviewItem> mustFix;
  final List<String> notes;

  @override
  List<AiReviewItem> get items => mustFix;

  factory ReviewVerdict.fromJson(Json j) => ReviewVerdict(
    ranAt: jDouble(j, 'ran_at'),
    model: jStr(j, 'model'),
    summary: jStr(j, 'summary'),
    error: jStrN(j, 'error'),
    nothingToReview: jBool(j, 'nothing_to_review'),
    pass: jStr(j, 'verdict', 'pass') != 'fail',
    mustFix: jList(
      j,
      'must_fix',
      (m) => AiReviewItem(
        title: jStr(m, 'title'),
        file: jStr(m, 'file'),
        line: jIntN(m, 'line'),
        detail: jStr(m, 'detail'),
      ),
    ),
    notes: jStrList(j, 'notes'),
  );
}

/// The plain reviewer's shape.
class ReviewResult extends AiReview {
  const ReviewResult({
    required super.ranAt,
    super.model,
    super.summary,
    super.error,
    super.nothingToReview,
    this.findings = const [],
  });

  final List<AiReviewItem> findings;

  @override
  List<AiReviewItem> get items => findings;

  factory ReviewResult.fromJson(Json j) => ReviewResult(
    ranAt: jDouble(j, 'ran_at'),
    model: jStr(j, 'model'),
    summary: jStr(j, 'summary'),
    error: jStrN(j, 'error'),
    nothingToReview: jBool(j, 'nothing_to_review'),
    findings: jList(
      j,
      'findings',
      (f) => AiReviewItem(
        title: jStr(f, 'title'),
        file: jStr(f, 'file'),
        line: jIntN(f, 'line'),
        detail: jStr(f, 'detail'),
        severity: jStr(f, 'severity', 'medium'),
        category: jStrN(f, 'category'),
      ),
    ),
  );
}
