import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/models/models.dart';
import '../../../../state/diff_stats.dart';
import '../../../../state/display_state.dart';
import '../../../../state/format.dart';
import '../../../../state/manual_rail.dart';
import '../../../../state/workspace_flow.dart';
import '../../../../theme/tokens.dart';

// Pure derivation for the ship step (spec 5.7): what the merge panel says and offers, the
// receipt rows, the markdown. No widgets, so the copy and the gating are unit-testable.

/// True only until a source has answered once. A refetch (the PR poll, a focus re-read) keeps
/// its previous value and a failed load has settled, so neither brings a skeleton back.
bool isFirstLoad(AsyncValue<Object?> v) =>
    v.isLoading && !v.hasValue && !v.hasError;

enum ShipPhase {
  /// Gate green, tree clean, work to ship.
  ready,

  /// The gate itself is what blocks: red, not run, or still running.
  gateBlocked,

  /// Gate green but git says no: dirty tree, conflicts, nothing ahead, no worktree.
  /// One-primary rule: dirty offers Commit and conflict offers "Help resolve with AI" as the
  /// primary; nothing ahead, no worktree and a still-loading status have no action, so this
  /// step renders zero primaries there (the reason line is the whole message).
  cannotShip,
  merged,
}

class ShipModel {
  const ShipModel({
    required this.phase,
    required this.title,
    required this.sub,
    required this.dot,
    required this.baseRef,
    required this.baseShort,
    required this.showPr,
    required this.showMerge,
    this.prNumber,
    this.prUrl,
    this.openLook = 0,
    this.showGoVerify = false,
    this.showResolve = false,
  });

  final ShipPhase phase;
  final String title;
  final String sub;

  /// Colour of the panel's square. Green is gate meaning: only a green gate paints it.
  final Color dot;
  final String baseRef;

  /// `main` for `origin/main`: the label on the merge button.
  final String baseShort;

  /// `[workflow] merge_mode` decides which of these the panel offers.
  final bool showPr;
  final bool showMerge;

  /// The PR that exists for this branch, if any.
  final int? prNumber;
  final String? prUrl;
  final int openLook;
  final bool showGoVerify;

  /// Green gate, but the PR conflicts with its base: offer to seed the agent with a fix.
  final bool showResolve;

  bool get hasPr => prNumber != null && prUrl != null && prUrl!.isNotEmpty;
}

String baseShortOf(String baseRef) =>
    baseRef.startsWith('origin/') ? baseRef.substring(7) : baseRef;

ShipModel deriveShip({
  required Workspace workspace,
  required WorkspaceFlow flow,
  GitStatusResponse? git,
  PrStatusResponse? pr,
}) {
  final baseRef = workspace.baseRef.isEmpty ? 'origin/main' : workspace.baseRef;
  final base = git != null && git.baseRef.isNotEmpty ? git.baseRef : baseRef;
  final baseShort = baseShortOf(base);

  final prSupported = pr?.supported ?? false;
  final mode = git?.mergeMode ?? 'both';
  final showPr = prSupported && mode != 'merge';
  final showMerge = mode != 'pr' || !prSupported;
  final prExists = (pr?.exists ?? false) && (pr?.url ?? '').isNotEmpty;
  final prNumber = prExists ? pr!.number : null;
  final prUrl = prExists ? pr!.url : null;

  ShipModel make(
    ShipPhase phase,
    String title,
    String sub,
    Color dot, {
    bool goVerify = false,
    bool resolve = false,
    int? number,
  }) => ShipModel(
    phase: phase,
    title: title,
    sub: sub,
    dot: dot,
    baseRef: base,
    baseShort: baseShort,
    showPr: showPr,
    showMerge: showMerge,
    prNumber: number ?? prNumber,
    prUrl: prUrl,
    openLook: flow.openLookCount,
    showGoVerify: goVerify,
    showResolve: resolve,
  );

  final merged =
      flow.displayState == DisplayState.merged ||
      (pr?.workspaceMerged ?? false);
  if (merged) {
    final number = workspace.lastPrNumber ?? pr?.number;
    return make(
      ShipPhase.merged,
      number == null ? 'Merged into $base' : 'Merged into $base as #$number',
      flow.verdict.sub,
      HaroTokens.merged,
      number: number,
    );
  }

  switch (flow.displayState) {
    case DisplayState.green:
      break;
    case DisplayState.red:
      final first = flow.blockers.isEmpty ? null : flow.blockers.first.text;
      final reason = first ?? flow.verdict.headline;
      return make(
        ShipPhase.gateBlocked,
        'Merging is blocked',
        '${_sentence(reason)} The gate must be green before this branch can merge.',
        HaroTokens.fail,
        goVerify: true,
      );
    case DisplayState.gate:
      return make(
        ShipPhase.gateBlocked,
        'Merging is blocked',
        'The gate is still running. It must pass before this branch can merge.',
        HaroTokens.ink42,
        goVerify: true,
      );
    case DisplayState.idle:
    case DisplayState.plan:
    case DisplayState.agent:
    case DisplayState.merged:
      return make(
        ShipPhase.gateBlocked,
        'Merging is blocked',
        'The gate hasn’t passed on this tree yet.',
        HaroTokens.ink42,
        goVerify: true,
      );
  }

  final conflicting =
      git != null &&
      !git.worktreeMissing &&
      git.dirty == 0 &&
      pr?.mergeable == 'CONFLICTING';
  final String? why;
  if (git == null) {
    why = 'Checking the working tree.';
  } else if (git.worktreeMissing) {
    why = 'No worktree on disk, so git actions aren’t available.';
  } else if (git.dirty > 0) {
    why =
        '${git.dirty} uncommitted ${plural(git.dirty, 'change')}. Commit them before you ship.';
  } else if (pr?.mergeable == 'CONFLICTING') {
    why =
        'This branch has merge conflicts with $base. Resolve them before it can merge.';
  } else if (git.ahead == 0) {
    why = 'Nothing to merge: this branch is up to date with $base.';
  } else {
    why = null;
  }
  if (why != null) {
    return make(
      ShipPhase.cannotShip,
      'Merging is blocked',
      why,
      HaroTokens.ink42,
      resolve: conflicting,
    );
  }

  final n = flow.openLookCount;
  return make(
    ShipPhase.ready,
    'Gate is green. Ready to merge.',
    n > 0
        ? '$n ${plural(n, 'item')} to look at · won’t block the merge'
        : 'Everything flagged has been reviewed.',
    HaroTokens.gate,
  );
}

/// What "Help resolve with AI" puts in the composer. The user runs it; nothing is sent.
String conflictPrompt({
  required String head,
  required String base,
  int? prNumber,
}) {
  final ref = prNumber != null ? '#$prNumber' : '`$head`';
  return [
    'The pull request $ref (`$head` → `$base`) has merge conflicts with its base branch and can’t be merged until they’re resolved.',
    '',
    'Please resolve them in this worktree:',
    '1. Fetch the latest base: `git fetch origin`',
    '2. Merge it into this branch: `git merge $base`',
    '3. Resolve every conflicted file: keep both sides’ intent; where they overlap, integrate them so no change is lost. Remove all conflict markers.',
    '4. Stage the resolved files (`git add`) and make sure the test gate passes.',
    '',
    'Leave the merge staged, don’t commit or push, so I can review the resolution before shipping.',
  ].join('\n');
}

String _sentence(String s) {
  final t = s.trim();
  if (t.isEmpty) return '';
  final cap = t[0].toUpperCase() + t.substring(1);
  return RegExp(r'[.!?]$').hasMatch(cap) ? cap : '$cap.';
}

/// `branch → origin/main · 2 commits · +367 −130 · 21 files`, as separate chunks so the
/// widget can colour the diff counts.
class ShipSummary {
  const ShipSummary({
    required this.branch,
    required this.baseRef,
    this.commits,
    this.added,
    this.removed,
    this.files,
  });

  final String branch;
  final String baseRef;
  final int? commits;
  final int? added;
  final int? removed;
  final int? files;
}

ShipSummary deriveSummary({
  required Workspace workspace,
  required String baseRef,
  GitStatusResponse? git,
  PrStatusResponse? pr,
  DiffStats diff = DiffStats.empty,
}) {
  int? added;
  int? removed;
  int? files;
  if (!diff.isEmpty) {
    added = diff.added;
    removed = diff.removed;
    files = diff.files;
  } else if (pr != null && pr.exists && pr.additions + pr.deletions > 0) {
    added = pr.additions;
    removed = pr.deletions;
  }
  final ahead = git?.ahead ?? 0;
  return ShipSummary(
    branch: (git?.branch.isNotEmpty ?? false) ? git!.branch : workspace.branch,
    baseRef: baseRef,
    commits: ahead > 0 ? ahead : null,
    added: added,
    removed: removed,
    files: files,
  );
}

/// PR title, else the subject of the branch's FIRST commit (the feature; later ones tend
/// to be follow-ups like "test: …"), else the workspace name.
String deriveShipTitle({
  required Workspace workspace,
  PrStatusResponse? pr,
  GitStatusResponse? git,
  List<GitCommit> commits = const [],
}) {
  final t = pr?.title?.trim() ?? '';
  if (pr != null && pr.exists && t.isNotEmpty) return t;
  final ahead = git?.ahead ?? 0;
  if (ahead > 0 && commits.isNotEmpty) {
    // `commits` is newest first; the branch's own commits are the first `ahead` of them.
    final s = commits.take(ahead).last.subject.trim();
    if (s.isNotEmpty) return s;
  }
  return workspace.name.isNotEmpty ? workspace.name : workspace.branch;
}

// ---- receipt ----

enum ReceiptTone { pass, fail, dim }

class ReceiptRowData {
  const ReceiptRowData(this.label, this.value, this.tone);

  final String label;
  final String value;
  final ReceiptTone tone;
}

String _pct(double v) =>
    v == v.roundToDouble() ? '${v.round()}%' : '${v.toStringAsFixed(1)}%';

/// The verdict word on the card. A green run whose suite was weakened is starred, the same
/// way the verify step words it.
String receiptWord(Receipt r) {
  final starred = r.tamper.measured && !r.tamper.clean;
  return switch (r.verdict) {
    'green' => starred ? 'GREEN*' : 'GREEN',
    'red' => 'RED',
    'degraded' => 'DEGRADED',
    _ => 'NOT GATED',
  };
}

/// `361 of 367 added lines ran` from the per-line map when the last green gate produced
/// one, else the receipt's percentage.
String verifiedLinesText(Receipt r, VerifiedHunksResponse? hunks) {
  if (hunks != null && hunks.supported && !hunks.stale) {
    var ran = 0;
    var missed = 0;
    for (final f in hunks.files) {
      ran += f.executed;
      missed += f.unexecuted;
    }
    if (ran + missed > 0) return '$ran of ${ran + missed} added lines ran';
  }
  final v = r.verifiedHunks;
  if (v.supported && v.percentage != null) {
    return '${_pct(v.percentage!)} of added lines ran';
  }
  return 'not measured';
}

String suiteText(Receipt r) {
  final s = r.suite;
  // A command or linter gate has no test count but did run: only an ungated workspace is "not run".
  if (s.total == 0) {
    return r.verdict != 'none' && !runnerReportsCounts(s.runner)
        ? 'ran · no test count'
        : 'not run';
  }
  final base = '${s.passed} / ${s.total} passed';
  return s.failed > 0 ? '${s.passed} / ${s.total} · ${s.failed} failing' : base;
}

String tamperText(Receipt r) {
  final t = r.tamper;
  if (!t.measured) return 'not measured';
  if (t.clean) return 'clean';
  final note = t.note?.trim() ?? '';
  if (note.isNotEmpty) return note;
  return '${t.findingsCount} ${plural(t.findingsCount, 'finding')}';
}

/// `none` when no run was fenced, else the patterns with how many editing runs were fenced,
/// then what was refused before the write, what was reverted and any run that could not be
/// checked.
String scopeText(Receipt r) {
  final c = r.scope;
  if (c.patterns.isEmpty) return 'none';
  final parts = [
    '${c.patterns.join(', ')} (${c.fencedRuns} of ${c.editingRuns} ${plural(c.editingRuns, 'run')})',
    if (c.blocked.isNotEmpty)
      '${c.blocked.length} blocked ${plural(c.blocked.length, 'file')}',
    if (c.reverted.isNotEmpty) '${c.reverted.length} reverted',
    if (c.uncheckedRuns > 0)
      'could not check ${c.uncheckedRuns} ${plural(c.uncheckedRuns, 'run')}',
  ];
  return parts.join(', ');
}

const maxReasonLength = 300;

/// One line of plain text: runs of whitespace (newlines included) become one space, so the
/// text cannot break a markdown list or open a heading.
String collapseSpace(String s) =>
    s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

/// The approval reason as the receipt shows it: one line, at most [maxReasonLength] characters,
/// the same cut the backend makes.
String normalizeReason(String s) {
  final one = collapseSpace(s);
  return one.length > maxReasonLength ? one.substring(0, maxReasonLength) : one;
}

/// The first prompt as typed, or null when the workspace never had one.
String? firstPromptOf(List<AgentEvent> events) {
  for (final e in events) {
    if (e.type != AgentEventType.user) continue;
    final text = e.payload['text'];
    return text is String && text.trim().isNotEmpty ? text : null;
  }
  return null;
}

String _seconds(double v) =>
    v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

/// What the review step recorded, as a fact about the screen: `Viewed 3 of 5 files, median 12 s
/// open per file, 1 marked Viewed in under 5 s`. It never says the files were read.
String readingText(ReceiptReading g) {
  if (!g.recorded) return 'no Viewed marks were recorded';
  final parts = [
    'Viewed ${g.viewed} of ${g.files} ${plural(g.files, 'file')}',
    if (g.medianSeconds != null)
      'median ${_seconds(g.medianSeconds!)} s open per file',
    if (g.quickViews > 0)
      '${g.quickViews} marked Viewed in under $quickViewSeconds s',
  ];
  return parts.join(', ');
}

/// `package.json: left-padd, tinycolor3`, then what the names mean and what was not checked.
String newDependenciesText(List<ReceiptNewDependency> deps) =>
    '${deps.map((d) => '${d.path}: ${d.names.join(', ')}').join('; ')} '
    '(named there now, not at the base; no registry was checked)';

String? agentText(Receipt r) {
  final a = r.agent;
  final parts = [
    if ((a.model ?? '').isNotEmpty) a.model!,
    if ((a.effort ?? '').isNotEmpty) a.effort!,
    if (a.costUsd != null) '\$${a.costUsd!.toStringAsFixed(2)}',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Who wrote the code, in plain words: the backend's `written_by` when it sent one (its
/// ASCII `->` shown as an arrow), else worked out from the workspace's mode and switches.
/// Null when neither is known.
String? writtenByText(Receipt r, {Workspace? workspace}) {
  if (r.writtenBy.isNotEmpty) return r.writtenBy.replaceAll(' -> ', ' → ');
  final ws = workspace;
  if (ws == null) return null;
  if (ws.modeSwitches.isEmpty) {
    if (ws.manual) return 'you';
    final model = r.agent.model ?? '';
    return model.isEmpty ? 'agent' : 'agent · $model';
  }
  var before = ws.modeSwitches.first.to == WorkspaceMode.manual
      ? WorkspaceMode.agent
      : WorkspaceMode.manual;
  final parts = <String>[];
  for (final s in ws.modeSwitches) {
    final at = s.at == null ? '' : ' at ${_hhmm(s.at!)}';
    parts.add('${before.wire} → ${s.to.wire}$at');
    before = s.to;
  }
  return 'you and the agent (${parts.join(', ')})';
}

/// Suite · Written by · Tamper alarm · Scope · Verified lines · Agent. There is no
/// quality row: the Double Gate is not part of this client.
List<ReceiptRowData> receiptRows(
  Receipt r, {
  VerifiedHunksResponse? hunks,
  String? writtenBy,
  bool showXp = false,
  String? reason,
}) {
  final s = r.suite;
  final why = normalizeReason(reason ?? r.reading.reason);
  final tamperBad = r.tamper.measured && !r.tamper.clean;
  final agent = agentText(r);
  return [
    ReceiptRowData(
      'Suite',
      suiteText(r),
      s.failed > 0
          ? ReceiptTone.fail
          : (s.total > 0 ? ReceiptTone.pass : ReceiptTone.dim),
    ),
    if (writtenBy != null && writtenBy.isNotEmpty)
      ReceiptRowData('Written by', writtenBy, ReceiptTone.dim),
    if (r.plan != null)
      ReceiptRowData('Plan', receiptPlanText(r.plan!), ReceiptTone.dim),
    if (r.researchLookups != null)
      ReceiptRowData(
        'Research',
        receiptResearchText(
          r.researchLookups!,
          unverified: r.researchUnverified,
        ),
        ReceiptTone.dim,
      ),
    ReceiptRowData(
      'Tamper alarm',
      tamperText(r),
      tamperBad ? ReceiptTone.fail : ReceiptTone.dim,
    ),
    ReceiptRowData(
      'Scope',
      scopeText(r),
      r.scope.reverted.isNotEmpty || r.scope.uncheckedRuns > 0
          ? ReceiptTone.fail
          : ReceiptTone.dim,
    ),
    ReceiptRowData('Review in haro', readingText(r.reading), ReceiptTone.dim),
    if (r.newDependencies.isNotEmpty)
      ReceiptRowData(
        'New dependencies',
        newDependenciesText(r.newDependencies),
        ReceiptTone.dim,
      ),
    if (r.guardRefused.isNotEmpty)
      ReceiptRowData(
        'Refused before they ran',
        '${r.guardRefused.join(', ')} (a text match, not a complete list)',
        ReceiptTone.dim,
      ),
    if (why.isNotEmpty)
      ReceiptRowData(
        'Approval reason',
        '$why (typed by the developer)',
        ReceiptTone.dim,
      ),
    if (r.tamper.protected)
      const ReceiptRowData(
        'Test edits',
        'Existing tests were edit-protected for the agent (tamper alarm still checks the diff).',
        ReceiptTone.dim,
      ),
    ReceiptRowData(
      'Verified lines',
      verifiedLinesText(r, hunks),
      ReceiptTone.dim,
    ),
    if (agent != null) ReceiptRowData('Agent', agent, ReceiptTone.dim),
    if (showXp && receiptXpText(r) != null)
      ReceiptRowData('XP', receiptXpText(r)!, ReceiptTone.dim),
    if (r.degradedReasons.isNotEmpty)
      ReceiptRowData(
        'Did not run',
        r.degradedReasons.join('; '),
        ReceiptTone.fail,
      ),
  ];
}

/// The backend's `XP: +N (labels)` without its prefix, or null when this merge pays nothing.
/// Only the receipt card shows it: the markdown that goes to a PR has no business with it.
String? receiptXpText(Receipt r) {
  final x = r.xp?.trim();
  if (x == null || x.isEmpty) return null;
  return x.startsWith('XP: ') ? x.substring(4) : x;
}

/// The identifier on the card: the tree the gate measured when the backend recorded one,
/// else the branch's newest commit.
String? receiptSha(Receipt r, List<GitCommit> commits) {
  final g = r.gateSha;
  if (g != null && g.length >= 7) return g.substring(0, 7);
  if (commits.isNotEmpty) {
    final c = commits.first;
    if (c.short.isNotEmpty) return c.short;
    if (c.sha.length >= 7) return c.sha.substring(0, 7);
  }
  return null;
}

String receiptFooter(Receipt r, String? sha) {
  final total = r.suite.total;
  final ran = total > 0
      ? 'Ran $total ${plural(total, 'test')} on this exact tree'
      : 'Measured on this exact tree';
  return sha == null ? ran : '$ran · $sha';
}

String _cell(String s) => s.replaceAll('|', r'\|').replaceAll('\n', ' ');

/// Built here rather than taken from the backend's `markdown`: that one still carries the
/// dropped quality lines and is a bullet list. A compact table reads well in a PR comment
/// and the footer line is the part that advertises haro.
String receiptMarkdown(
  Receipt r, {
  VerifiedHunksResponse? hunks,
  String? sha,
  String? writtenBy,
  String? reason,
}) {
  final rows = receiptRows(
    r,
    hunks: hunks,
    writtenBy: writtenBy,
    reason: reason,
  );
  final b = StringBuffer()
    ..writeln('### haro. gate receipt: ${receiptWord(r)}')
    ..writeln()
    ..writeln('| Check | Result |')
    ..writeln('| :-- | :-- |');
  for (final row in rows) {
    b.writeln('| ${_cell(row.label)} | ${_cell(row.value)} |');
  }
  b
    ..writeln()
    ..write('<sub>${receiptFooter(r, sha)} · gated by haro.</sub>');
  return b.toString();
}
