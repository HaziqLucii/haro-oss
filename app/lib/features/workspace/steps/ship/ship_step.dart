import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart' show GitCommit;
import '../../../../data/workspace_actions.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_detail_lazy.dart';
import '../../../../state/display_state.dart';
import '../../../../state/workspace_flow.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/haro_skeleton.dart';
import '../../../settings/xp_prefs_provider.dart';
import '../../rail/workspace_rail.dart' show workspaceUrlOpenerProvider;
import '../../workspace_ui.dart';
import '../agent/composer_state.dart' show composerDraftProvider;
import '../verify/verify_model.dart' show codePath;
import 'ai_review_panel.dart';
import 'ai_review_state.dart';
import 'commit_section.dart';
import 'merge_panel.dart';
import 'receipt_card.dart';
import 'ship_model.dart';
import 'ship_widgets.dart';

/// Spec 5.7: PR title and summary, the merge panel, the gate receipt card, the commit line.
/// The page hands this bounded constraints and no scroll view, so it scrolls itself.
class ShipStep extends ConsumerStatefulWidget {
  const ShipStep(this.workspaceId, {super.key});

  final String workspaceId;

  @override
  ConsumerState<ShipStep> createState() => _ShipStepState();
}

class _ShipStepState extends ConsumerState<ShipStep>
    with WidgetsBindingObserver {
  bool _merging = false;
  bool _openingPr = false;
  bool _continuing = false;
  bool _posting = false;
  bool _committing = false;
  bool _copied = false;
  String? _panelError;
  String? _panelNote;
  String? _receiptNote;
  String? _commitError;
  String? _commitNote;
  Timer? _copiedTimer;

  String get _id => widget.workspaceId;
  WorkspaceActions get _actions => ref.read(workspaceActionsProvider(_id));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _copiedTimer?.cancel();
    super.dispose();
  }

  // Coming back from github.com: re-read now instead of waiting for the next poll tick.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    ref.invalidate(workspacePrProvider(_id));
    ref.invalidate(workspaceGitStatusProvider(_id));
  }

  String _message(Object e) => e is HaroApiException ? e.message : '$e';

  void _open(String? url) {
    if (url == null || url.isEmpty) return;
    ref.read(workspaceUrlOpenerProvider)(Uri.parse(url));
  }

  Future<void> _openPr() async {
    if (_openingPr) return;
    setState(() {
      _openingPr = true;
      _panelError = null;
      _panelNote = null;
    });
    try {
      final res = await _actions.openPr();
      if (!mounted) return;
      setState(
        () => _panelNote = res.alreadyExists
            ? 'A pull request is already open for this branch.'
            : 'Pull request opened.',
      );
      _open(res.url);
    } catch (e) {
      if (mounted) setState(() => _panelError = _message(e));
    } finally {
      if (mounted) setState(() => _openingPr = false);
    }
  }

  Future<void> _merge() async {
    if (_merging) return;
    setState(() {
      _merging = true;
      _panelError = null;
      _panelNote = null;
    });
    try {
      final res = await _actions.merge();
      if (!mounted) return;
      setState(() {
        if (res.merged) {
          _panelNote = res.prUrl != null
              ? 'Merged via ${res.method} · ${res.prUrl}'
              : (res.detail.isEmpty ? null : res.detail);
        } else {
          _panelError = res.detail.isEmpty
              ? 'The merge did not complete.'
              : res.detail;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _panelError = _message(e));
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  Future<void> _continue() async {
    if (_continuing) return;
    setState(() {
      _continuing = true;
      _panelError = null;
      _panelNote = null;
    });
    try {
      await _actions.continueOnNewBranch();
      if (!mounted) return;
      final manual =
          ref.read(workspaceDetailProvider(_id)).workspace?.manual ?? false;
      context.go(workspaceStepPath(_id, manual ? StepKey.code : StepKey.agent));
      if (!manual) {
        ref.read(workspaceUiProvider.notifier).requestComposerFocus();
      }
    } catch (e) {
      if (mounted) setState(() => _panelError = _message(e));
    } finally {
      if (mounted) setState(() => _continuing = false);
    }
  }

  void _resolveConflict(ShipModel m) {
    final branch = ref.read(workspaceGitStatusProvider(_id)).value?.branch;
    final ws = ref.read(workspaceDetailProvider(_id)).workspace;
    ref
        .read(composerDraftProvider(_id).notifier)
        .fill(
          conflictPrompt(
            head: branch ?? ws?.branch ?? '',
            base: m.baseRef,
            prNumber: m.prNumber,
          ),
        );
    context.go(workspaceStepPath(_id, StepKey.agent));
    ref.read(workspaceUiProvider.notifier).requestComposerFocus();
  }

  Future<bool> _commit(String message) async {
    if (_committing) return false;
    setState(() {
      _committing = true;
      _commitError = null;
      _commitNote = null;
    });
    try {
      final res = await _actions.commit(message);
      if (!mounted) return false;
      setState(() {
        if (res.nothingToCommit) {
          _commitNote = 'Nothing to commit.';
        } else {
          final sha = res.committed ?? '';
          _commitNote = sha.isEmpty
              ? 'Committed.'
              : 'Committed ${sha.length > 7 ? sha.substring(0, 7) : sha}';
        }
      });
      return !res.nothingToCommit;
    } catch (e) {
      if (mounted) setState(() => _commitError = _message(e));
      return false;
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  Future<void> _copyMarkdown(String markdown) async {
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _postToPr() async {
    if (_posting) return;
    setState(() {
      _posting = true;
      _receiptNote = null;
    });
    try {
      final url = await _actions.postReceiptToPr();
      if (mounted) {
        setState(
          () => _receiptNote = url == null
              ? 'Nothing was posted.'
              : 'Posted to the pull request.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _receiptNote = _message(e));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = workspaceDetailProvider(_id);
    final workspace = ref.watch(detail.select((d) => d.workspace));
    final flow = ref.watch(detail.select((d) => d.flow));
    final diff = ref.watch(detail.select((d) => d.diffStats));
    if (workspace == null || flow == null) return const SizedBox.shrink();

    final gitAsync = ref.watch(workspaceGitStatusProvider(_id));
    final prAsync = ref.watch(workspacePrProvider(_id));
    final logAsync = ref.watch(workspaceGitLogProvider(_id));
    final receiptAsync = ref.watch(workspaceReceiptProvider(_id));
    final git = gitAsync.value;
    final pr = prAsync.value;
    final commits = logAsync.value ?? const <GitCommit>[];
    final receipt = receiptAsync.value;
    final hunks = ref.watch(workspaceVerifiedHunksProvider(_id)).value;

    final model = deriveShip(
      workspace: workspace,
      flow: flow,
      git: git,
      pr: pr,
    );
    final summary = deriveSummary(
      workspace: workspace,
      baseRef: model.baseRef,
      git: git,
      pr: pr,
      diff: diff,
    );
    // Ahead (git status), the log and the PR arrive separately, so deriving from whichever
    // came first would swap the title twice. Wait for all three, then derive once.
    final gitLoading = isFirstLoad(gitAsync);
    final prLoading = isFirstLoad(prAsync);
    final logLoading = isFirstLoad(logAsync);
    final title = gitLoading || prLoading || logLoading
        ? null
        : deriveShipTitle(
            workspace: workspace,
            pr: pr,
            git: git,
            commits: commits,
          );
    // Git and the PR only decide the verdict line and buttons once the gate is green; every
    // other state is already known from the gate.
    final mergeLoading =
        (gitLoading || prLoading) && flow.displayState == DisplayState.green;
    final gateRan = const {
      DisplayState.green,
      DisplayState.red,
      DisplayState.merged,
    }.contains(flow.displayState);
    final receiptLoading = isFirstLoad(receiptAsync) && gateRan;

    final review = ref.watch(aiReviewProvider(_id));
    final hasChanges =
        (git?.ahead ?? 0) > 0 || (git?.dirty ?? 0) > 0 || !diff.isEmpty;
    final showReview =
        model.phase != ShipPhase.merged &&
        hasChanges &&
        !(git?.worktreeMissing ?? false);

    final showReceipt = receipt != null && receipt.receipt.verdict != 'none';
    final r = receipt?.receipt;
    final sha = r == null ? null : receiptSha(r, commits);
    final writtenBy = r == null ? null : writtenByText(r, workspace: workspace);
    final manual = flow.manual;

    return SingleChildScrollView(
      key: const ValueKey('ship-scroll'),
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 56),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(title: title, summary: summary),
              const SizedBox(height: 32),
              MergePanel(
                model: model,
                loading: mergeLoading,
                merging: _merging,
                openingPr: _openingPr,
                continuing: _continuing,
                error: _panelError,
                note: _panelNote,
                onGoVerify: () =>
                    context.go(workspaceStepPath(_id, StepKey.verify)),
                onOpenPr: _openPr,
                onViewPr: () => _open(model.prUrl),
                onMerge: _merge,
                onContinue: _continue,
                onResolve: manual ? null : () => _resolveConflict(model),
              ),
              if (showReview) ...[
                const SizedBox(height: 40),
                AiReviewSection(
                  workspaceId: _id,
                  state: review,
                  baseShort: model.baseShort,
                  onRun: () => ref.read(aiReviewProvider(_id).notifier).run(),
                  onOpenDiff: (file, line) =>
                      context.go(codePath(_id, file: file, line: line)),
                ),
              ],
              ShipFade(
                child: showReceipt && r != null
                    ? Column(
                        key: const ValueKey('receipt-ready'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 48),
                          ShipSectionHead(
                            title: 'Gate receipt',
                            sub: 'What reviewers see on the PR',
                            actions: [
                              HaroButton(
                                key: const ValueKey('receipt-copy'),
                                label: _copied ? 'Copied' : 'Copy markdown',
                                variant: HaroButtonVariant.tertiary,
                                height: 28,
                                fontSize: 13,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                ),
                                onPressed: () => _copyMarkdown(
                                  receiptMarkdown(
                                    r,
                                    hunks: hunks,
                                    sha: sha,
                                    writtenBy: writtenBy,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 7),
                              HaroButton(
                                key: const ValueKey('receipt-post'),
                                label: _posting ? 'Posting…' : 'Post to PR',
                                variant: HaroButtonVariant.tertiary,
                                height: 28,
                                fontSize: 13,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                ),
                                foreground: model.hasPr && !_posting
                                    ? HaroTokens.ink
                                    : HaroTokens.ink42,
                                tooltip: model.hasPr
                                    ? null
                                    : 'Open a pull request to post the receipt',
                                onPressed: model.hasPr && !_posting
                                    ? _postToPr
                                    : null,
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          ReceiptCard(
                            receipt: r,
                            rows: receiptRows(
                              r,
                              hunks: hunks,
                              writtenBy: writtenBy,
                              showXp: ref.watch(xpPrefsProvider).showXp,
                            ),
                            sha: sha,
                            footer: receiptFooter(r, sha),
                          ),
                          if (_receiptNote != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              _receiptNote!,
                              key: const ValueKey('receipt-note'),
                              style: HaroText.mono(
                                size: 11.5,
                                color: HaroTokens.ink42,
                                tracking: 0,
                              ),
                            ),
                          ],
                        ],
                      )
                    : receiptLoading
                    ? const _ReceiptSkeleton()
                    : const SizedBox.shrink(key: ValueKey('receipt-none')),
              ),
              const SizedBox(height: 48),
              CommitSection(
                commits: commits,
                dirty: git?.dirty ?? 0,
                ahead: git?.ahead ?? 0,
                committing: _committing,
                loading: gitLoading || logLoading,
                primary:
                    model.phase == ShipPhase.cannotShip &&
                    (git?.dirty ?? 0) > 0,
                error: _commitError,
                note: _commitNote,
                onCommit: _commit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _titleSkeletonWidth = 420.0;

/// The width of "2 commits" in the summary line, so the diff stats beside it do not move
/// when the count arrives.
const _commitsSkeletonWidth = 74.0;

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.summary});

  /// `null` while the title's sources are still loading.
  final String? title;
  final ShipSummary summary;

  @override
  Widget build(BuildContext context) {
    final mono = HaroText.mono(size: 12, color: HaroTokens.ink66, tracking: 0);
    final s = summary;
    final titleStyle = HaroText.ui(
      size: 28,
      weight: FontWeight.w500,
      height: 1.2,
    ).copyWith(letterSpacing: -.42);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'PULL REQUEST TITLE',
          style: HaroText.mono(
            size: 10.5,
            color: HaroTokens.ink42,
            tracking: .16,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.only(bottom: 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: HaroTokens.line20)),
          ),
          child: ShipFade(
            child: title == null
                ? SkeletonLine(
                    key: const ValueKey('ship-title-skeleton'),
                    style: titleStyle,
                    width: _titleSkeletonWidth,
                    inset: 5,
                  )
                : Text(
                    title!,
                    key: const ValueKey('ship-pr-title'),
                    style: titleStyle,
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          key: const ValueKey('ship-summary'),
          spacing: 16,
          runSpacing: 4,
          children: [
            Text('${s.branch} → ${s.baseRef}', style: mono),
            if (s.commits != null)
              Text(
                '${s.commits} ${s.commits == 1 ? 'commit' : 'commits'}',
                style: mono,
              )
            else if (title == null)
              SkeletonLine(
                key: const ValueKey('ship-commits-skeleton'),
                style: mono,
                width: _commitsSkeletonWidth,
              ),
            if (s.added != null)
              Text.rich(
                TextSpan(
                  style: mono,
                  children: [
                    TextSpan(
                      text: '+${s.added}',
                      style: mono.copyWith(color: HaroTokens.gate),
                    ),
                    const TextSpan(text: ' '),
                    TextSpan(
                      text: '−${s.removed}',
                      style: mono.copyWith(color: HaroTokens.fail),
                    ),
                  ],
                ),
              ),
            if (s.files != null)
              Text(
                '${s.files} ${s.files == 1 ? 'file' : 'files'}',
                style: mono,
              ),
          ],
        ),
      ],
    );
  }
}

/// The receipt section while the receipt loads: its head and a card-sized block, so the
/// section keeps its place.
class _ReceiptSkeleton extends StatelessWidget {
  const _ReceiptSkeleton();

  @override
  Widget build(BuildContext context) => const Column(
    key: ValueKey('receipt-loading'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(height: 48),
      ShipSectionHead(
        title: 'Gate receipt',
        sub: 'What reviewers see on the PR',
        actions: [
          HaroSkeleton(width: 110, height: 28),
          SizedBox(width: 7),
          HaroSkeleton(width: 82, height: 28),
        ],
      ),
      SizedBox(height: 16),
      HaroSkeleton(
        key: ValueKey('receipt-skeleton'),
        height: HaroTokens.shipReceiptSkeletonHeight,
      ),
    ],
  );
}
