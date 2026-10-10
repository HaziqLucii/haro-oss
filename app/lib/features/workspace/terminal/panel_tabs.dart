import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/workspace_detail.dart';
import '../../../data/workspace_store.dart' show haroApiProvider;
import '../../../data/workspace_detail_lazy.dart';
import '../../../lsp/lsp_diagnostics.dart' show DiagnosticSeverity;
import '../../../lsp/lsp_providers.dart';
import '../../../state/display_state.dart';
import '../../../state/workspace_flow.dart' show StepKey;
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_pressable.dart';
import '../../../widgets/status_square.dart';
import '../steps/code/editor/editor_tabs.dart';
import '../steps/code/proof_marks.dart';
import '../steps/code/run_on_save.dart';
import '../steps/verify/verify_model.dart';
import '../workspace_ui.dart';
import 'bottom_panel_provider.dart';
import 'panel_model.dart';
import 'related_tests.dart';

const _maxSpots = 6;

TextStyle _body(Color color, {FontWeight weight = FontWeight.w400}) =>
    HaroText.mono(
      size: 12,
      color: color,
      tracking: 0,
      weight: weight,
      height: 1.75,
    );

TextStyle _tag(Color color) =>
    HaroText.mono(size: 10, color: color, tracking: .12);

/// Opens [path] in the editor at [line] and brings the code step forward, so a row clicked
/// from the agent or verify step lands on the file rather than on a hidden editor.
void openFileFromPanel(
  BuildContext context,
  WidgetRef ref,
  String workspaceId,
  String path, {
  int? line,
}) {
  ref.read(editorTabsProvider(workspaceId).notifier).open(path, line: line);
  GoRouter.maybeOf(context)?.go(workspaceStepPath(workspaceId, StepKey.code));
}

/// The Gate tab: the live verdict line, what the gate says about the focused editor file,
/// and where added lines never ran (each one opens the file at that line).
class GateTab extends ConsumerWidget {
  const GateTab({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(workspaceFlowProvider(workspaceId));
    if (flow == null) return const SizedBox.shrink();
    final d = workspaceDetailProvider(workspaceId);
    final diff = ref.watch(d.select((x) => x.diff?.diff ?? ''));
    final active = ref.watch(
      editorTabsProvider(workspaceId).select((s) => s.activePath),
    );
    final proof = ref.watch(workspaceVerifiedHunksProvider(workspaceId)).value;
    final impact = ref.watch(workspaceImpactProvider(workspaceId)).value;
    final onSave = runOnSaveEnabled(ref, workspaceId);

    final state = flow.displayState;
    final color = switch (state) {
      DisplayState.agent || DisplayState.plan => HaroTokens.ink42,
      _ => state.color,
    };
    final fileLine = fileProofLine(
      path: active,
      state: state,
      proof: proof,
      changed: changedPaths(diff),
    );
    final untested = state == DisplayState.green
        ? deriveUntested(proof, diff)
        : UntestedSummary.none;
    final spots = untested.available && !untested.stale
        ? untested.spots
        : const <UntestedSpot>[];
    final impactText = impactLine(active, impact);

    return SingleChildScrollView(
      key: const ValueKey('panel-gate'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusSquare(
                size: HaroTokens.markPanelTab,
                color: color,
                filled: state.settled,
              ),
              const SizedBox(width: 10),
              Text(
                flow.verdict.word,
                key: const ValueKey('panel-gate-word'),
                style: HaroText.mono(
                  size: 12,
                  color: color,
                  tracking: .14,
                  height: 1.75,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  flow.verdict.rail,
                  key: const ValueKey('panel-gate-line'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _body(HaroTokens.ink),
                ),
              ),
            ],
          ),
          Text(
            'This file: $fileLine',
            key: const ValueKey('panel-gate-file'),
            style: _body(HaroTokens.ink66),
          ),
          Text(
            [runOnSaveLine(onSave), ?impactText].join(' '),
            key: const ValueKey('panel-gate-save'),
            style: _body(HaroTokens.ink42),
          ),
          if (canRunRelated(active, impact))
            _RelatedRow(
              key: ValueKey('panel-gate-related:$active'),
              workspaceId: workspaceId,
              path: active!,
            ),
          if (spots.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '${untested.unexecuted} of ${untested.added} added lines never ran',
              style: _tag(HaroTokens.ink42),
            ),
            const SizedBox(height: 2),
            for (final s in spots.take(_maxSpots))
              _RowShell(
                key: ValueKey('panel-spot-${s.path}:${s.start}'),
                onTap: () => openFileFromPanel(
                  context,
                  ref,
                  workspaceId,
                  s.path,
                  line: s.start,
                ),
                semanticLabel: 'Open ${s.label}',
                mark: const _Mark(ProofMarkKind.eyes),
                title: s.label,
                detail: s.unmapped
                    ? 'no test imports this file'
                    : '${s.lines} ${s.lines == 1 ? 'line' : 'lines'} never ran',
                trailing: s.path,
              ),
            if (spots.length > _maxSpots)
              Text(
                '${spots.length - _maxSpots} more in Review',
                style: _body(HaroTokens.ink42),
              ),
          ],
          const SizedBox(height: 6),
          HaroPressable(
            key: const ValueKey('panel-gate-verify'),
            onTap: () =>
                GoRouter.maybeOf(context)
                    ?.go(workspaceStepPath(workspaceId, StepKey.verify)),
            semanticLabel: 'Open review',
            builder: (context, hovered) => Text(
              'Open review',
              style: _body(hovered ? HaroTokens.ink : HaroTokens.ink66),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Run the tests touching this file" under the `This file:` line. The run is advisory and
/// streams on the Live Gate channel, so the result is a line here and the verdict above never
/// changes. A refusal (busy, unsupported) is shown in place.
class _RelatedRow extends ConsumerStatefulWidget {
  const _RelatedRow({super.key, required this.workspaceId, required this.path});

  final String workspaceId;
  final String path;

  @override
  ConsumerState<_RelatedRow> createState() => _RelatedRowState();
}

class _RelatedRowState extends ConsumerState<_RelatedRow> {
  bool _starting = false;
  String? _refusal;

  /// The file this row started a run for, and the settled advisory run that was showing at the
  /// time. The watch channel also carries Live Gate runs and other files' related runs, so only
  /// a run that began here, for this path, may show as this file's evidence.
  String? _startedFor;
  String? _staleRunId;

  Future<void> _run() async {
    if (_starting) return;
    final path = widget.path;
    final stale = ref
        .read(workspaceDetailProvider(widget.workspaceId))
        .watch
        .run
        ?.id;
    setState(() {
      _starting = true;
      _refusal = null;
    });
    final msg = await startRelatedRun(
      ref.read(haroApiProvider),
      widget.workspaceId,
      widget.path,
    );
    if (!mounted) return;
    setState(() {
      _starting = false;
      _refusal = msg;
      _startedFor = msg == null ? path : null;
      _staleRunId = stale;
    });
  }

  @override
  void didUpdateWidget(_RelatedRow old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _startedFor = null;
      _refusal = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final watch = ref.watch(
      workspaceDetailProvider(widget.workspaceId).select((d) => d.watch),
    );
    final status =
        _refusal ??
        (_startedFor == widget.path
            ? advisoryRunLine(watch, staleRunId: _staleRunId) ??
                  'Related run started.'
            : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HaroPressable(
          key: const ValueKey('panel-gate-related'),
          onTap: _starting ? null : _run,
          semanticLabel: 'Run the tests touching this file',
          builder: (context, hovered) => Text(
            'Run the tests touching this file',
            style: _body(hovered ? HaroTokens.ink : HaroTokens.ink66),
          ),
        ),
        if (status != null)
          Text(
            status,
            key: const ValueKey('panel-gate-related-status'),
            style: _body(
              _refusal != null ? HaroTokens.ink66 : HaroTokens.ink42,
            ),
          ),
      ],
    );
  }
}

/// The Problems tab: the open needs-your-eyes items and the TypeScript
/// server's live diagnostics for the open files. Diagnostics are advisory and never touch the
/// gate; lint was cut from the gate.
class ProblemsTab extends ConsumerWidget {
  const ProblemsTab({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(workspaceFlowProvider(workspaceId));
    if (flow == null) return const SizedBox.shrink();
    final view = ref.watch(codeProblemsProvider(workspaceId));
    final sections = deriveDiagnosticSections(
      ref.watch(lspDiagnosticsProvider(workspaceId)),
    );
    final focus = ref.watch(problemsFocusProvider(workspaceId));

    if (view.isEmpty && sections.isEmpty) {
      return Padding(
        key: const ValueKey('panel-problems-empty'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              emptyLookAtText(flow.displayState),
              style: _body(HaroTokens.ink42),
            ),
          ],
        ),
      );
    }

    void open(ProblemRow r) {
      final path = r.path;
      if (path != null) {
        openFileFromPanel(context, ref, workspaceId, path, line: r.line);
      }
    }

    var revealed = false;
    Widget section(String title, List<ProblemRow> rows, {int? count}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(
            '$title · ${count ?? rows.length}',
            style: _tag(HaroTokens.ink42),
          ),
        ),
        for (final r in rows)
          () {
            final hit =
                focus != null &&
                !revealed &&
                r.path == focus.path &&
                r.line == focus.line;
            if (hit) revealed = true;
            final shell = _RowShell(
              key: ValueKey('problem-${r.key}'),
              onTap: r.path == null ? null : () => open(r),
              semanticLabel: r.path == null ? r.title : 'Open ${r.title}',
              mark: _Mark(switch (r.severity) {
                DiagnosticSeverity.error => ProofMarkKind.error,
                DiagnosticSeverity.warning => ProofMarkKind.warning,
                DiagnosticSeverity.information ||
                DiagnosticSeverity.hint => ProofMarkKind.info,
                null => ProofMarkKind.eyes,
              }),
              title: r.title,
              tag: r.label,
              tagColor: r.blocking ? HaroTokens.fail : HaroTokens.ink42,
              detail: r.detail,
              trailing: r.path,
              focused: hit,
            );
            if (!hit) return shell;
            return _Reveal(
              serial: focus.serial,
              take: () => ref
                  .read(problemsFocusProvider(workspaceId).notifier)
                  .takeReveal(focus.serial),
              child: shell,
            );
          }(),
      ],
    );

    return SingleChildScrollView(
      key: const ValueKey('panel-problems'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (view.eyes.isNotEmpty) section('NEEDS YOUR REVIEW', view.eyes),
          for (final s in sections) section(s.title, s.rows, count: s.count),
        ],
      ),
    );
  }
}

/// Scrolls its row into view when a gutter click asks for it (once per click).
class _Reveal extends StatefulWidget {
  const _Reveal({
    required this.serial,
    required this.take,
    required this.child,
  });

  final int serial;
  final bool Function() take;
  final Widget child;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> {
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(_Reveal old) {
    super.didUpdateWidget(old);
    if (old.serial != widget.serial) _schedule();
  }

  void _schedule() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && widget.take()) {
      Scrollable.ensureVisible(context, alignment: .3);
    }
  });

  @override
  Widget build(BuildContext context) => widget.child;
}

class _RowShell extends StatelessWidget {
  const _RowShell({
    super.key,
    required this.onTap,
    required this.semanticLabel,
    required this.mark,
    required this.title,
    this.tag,
    this.tagColor = HaroTokens.ink42,
    this.detail = '',
    this.trailing,
    this.focused = false,
  });

  final bool focused;
  final VoidCallback? onTap;
  final String semanticLabel;
  final _Mark mark;
  final String title;
  final String? tag;
  final Color tagColor;
  final String detail;
  final String? trailing;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: semanticLabel,
    builder: (context, hovered) => Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      color: hovered || focused ? HaroTokens.raised : HaroTokens.transparent,
      child: Row(
        children: [
          mark,
          const SizedBox(width: 10),
          Text(title, style: _body(HaroTokens.ink86)),
          if (tag != null) ...[
            const SizedBox(width: 10),
            Text(tag!, style: _tag(tagColor)),
          ],
          if (detail.isNotEmpty) ...[
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _body(HaroTokens.ink66),
              ),
            ),
          ],
          const Spacer(),
          if (trailing != null)
            Flexible(
              child: Text(
                trailing!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: _body(HaroTokens.ink42),
              ),
            ),
        ],
      ),
    ),
  );
}

/// A drawn 8px mark (hollow circle for a flagged item, cross, triangle or dash for a TS
/// error, warning or info), in ink.
class _Mark extends StatelessWidget {
  const _Mark(this._kind);

  final ProofMarkKind _kind;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 8,
    child: CustomPaint(
      painter: ProofMarkPainter(
        _kind,
        color: proofMarkColor([ProofMark(kind: _kind, label: '')]),
      ),
    ),
  );
}
