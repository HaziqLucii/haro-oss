import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../api/models/models.dart';
import '../../../../data/workspace_actions.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_detail_lazy.dart';
import '../../../../state/display_state.dart';
import '../../../../state/format.dart';
import '../../../../state/gate_facts.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../../open_in/open_in_button.dart';
import '../../../open_in/open_in_notice.dart';
import '../../fade_in.dart';
import 'test_grid.dart';
import 'verify_model.dart';
import 'verify_widgets.dart';

const _maxListed = 30;

/// Zone 4 (spec 5.6): evidence on demand. The first two rows are the ones worth reading, so
/// their names are full ink; the rest are dimmer. Mutation, coverage and flaky each re-run
/// the suite on the backend, so they only ever start from a button.
class EvidenceSection extends ConsumerStatefulWidget {
  const EvidenceSection({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<EvidenceSection> createState() => _EvidenceSectionState();
}

class _EvidenceSectionState extends ConsumerState<EvidenceSection> {
  final Set<String> _open = {'mut'};

  // Impact is a call to the backend, so it waits until the row has been opened once.
  bool _impactWanted = false;

  VerifiedHunksResponse? _hunksKey;
  String? _diffKey;
  UntestedSummary _untested = UntestedSummary.none;

  String get _id => widget.workspaceId;
  WorkspaceActions get _actions => ref.read(workspaceActionsProvider(_id));

  void _toggle(String k) => setState(() {
    if (!_open.remove(k)) {
      _open.add(k);
      if (k == 'impact') _impactWanted = true;
    }
  });

  void _goCode(String file, [int? line]) =>
      context.go(codePath(_id, file: file, line: line));

  // The failure is recorded on the analysis state; nothing to add here.
  Future<void> _run(Future<Object?> Function() f) async {
    try {
      await f();
    } on Object {
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = workspaceDetailProvider(_id);
    final state =
        ref.watch(d.select((x) => x.flow?.displayState)) ?? DisplayState.idle;
    final run = ref.watch(d.select((x) => x.gate.run));
    final cells = ref.watch(d.select((x) => x.gate.cells));
    final analysis = ref.watch(d.select((x) => x.analysis));
    final config = ref.watch(d.select((x) => x.gateConfig));
    final summary = ref.watch(d.select((x) => x.workspace?.gate));
    final diff = ref.watch(d.select((x) => x.diff?.diff));

    final running = state == DisplayState.gate;
    final settled = state.settled;
    final green = state == DisplayState.green;

    final hunks = settled
        ? ref.watch(workspaceVerifiedHunksProvider(_id)).value
        : null;
    final receipt = settled
        ? ref.watch(workspaceReceiptProvider(_id)).value
        : null;
    final impactAsync = _impactWanted && settled
        ? ref.watch(workspaceImpactProvider(_id))
        : null;

    if (!identical(hunks, _hunksKey) || diff != _diffKey) {
      _hunksKey = hunks;
      _diffKey = diff;
      _untested = deriveUntested(hunks, diff ?? '');
    }

    final progress = gateProgress(
      cells,
      expectedTotal: run?.total ?? summary?.total,
    );
    final mutation = mutationView(analysis.mutation, receipt?.receipt.mutation);
    final impact = impactAsync?.value;
    final retriedList = run?.flakyRetried ?? const <String>[];
    final retriedIds = retriedList.isEmpty
        ? const <String>{}
        : retriedList.toSet();

    String meta(String settledMeta, {bool always = false}) {
      if (state == DisplayState.idle ||
          state == DisplayState.plan ||
          state == DisplayState.agent) {
        return '–';
      }
      if (running && !always) return 'after the run';
      return settledMeta;
    }

    final rows = <_Entry>[
      _Entry(
        'mut',
        'Mutation score',
        meta(
          mutationMeta(
            mutation,
            running: analysis.isRunning(AnalysisKind.mutation),
          ),
        ),
        primary: true,
        body: () => _mutationBody(
          state: state,
          view: mutation,
          analysis: analysis,
          canRun: green,
        ),
      ),
      _Entry(
        'untested',
        'Lines no test ran',
        meta(_untested.meta),
        primary: true,
        body: () => _untestedBody(_untested, settled),
      ),
      _Entry(
        'grid',
        'Test grid',
        meta(
          cells.isEmpty
              ? 'no tests yet'
              : '${cells.length} tests${running ? ' · live' : ''}',
          always: true,
        ),
        body: () => cells.isEmpty && !running
            ? _dim('Appears when the gate runs.')
            : TestGrid(
                cells: cells,
                retried: retriedIds,
                expectedTotal: running ? progress.total : 0,
                dim: state == DisplayState.merged,
              ),
      ),
      _Entry(
        'impact',
        'Impact',
        meta(impactMeta(impact), always: true),
        body: () => _impactBody(impactAsync, settled),
      ),
      _Entry(
        'cov',
        'Coverage',
        meta(
          coverageMeta(
            analysis.coverage,
            running: analysis.isRunning(AnalysisKind.coverage),
          ),
        ),
        body: () => _coverageBody(state, analysis, green),
      ),
      _Entry(
        'flaky',
        'Flaky tests',
        meta(
          flakyMeta(
            analysis.flaky,
            run,
            config?.flakyRerun ?? false,
            running: analysis.isRunning(AnalysisKind.flaky),
          ),
        ),
        body: () => _flakyBody(
          state,
          analysis,
          run,
          config?.flakyRerun ?? false,
          green,
        ),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ZoneHeading(
          title: 'Evidence',
          hint: 'Can you trust green? Start with the first two.',
        ),
        const OpenInNoticeText(
          source: 'verify-evidence',
          padding: EdgeInsets.only(bottom: 8),
        ),
        for (final r in rows)
          _Accordion(
            key: ValueKey('evidence-${r.id}'),
            id: r.id,
            name: r.name,
            meta: r.meta,
            primary: r.primary,
            open: _open.contains(r.id),
            onToggle: () => _toggle(r.id),
            body: r.body,
          ),
      ],
    );
  }

  // ---- bodies ----

  Widget _dim(String text) => Text(
    text,
    style: HaroText.ui(size: 14, color: HaroTokens.ink42, height: 1.5),
  );

  Widget _prose(String text) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 620),
    child: Text(
      text,
      style: HaroText.ui(size: 14, color: HaroTokens.ink66, height: 1.5),
    ),
  );

  Widget _runButton(String key, String label, VoidCallback onPressed) =>
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Fit(
            child: HaroButton(
              key: ValueKey(key),
              label: label,
              foreground: HaroTokens.ink86,
              onPressed: onPressed,
            ),
          ),
        ),
      );

  Widget _mutationBody({
    required DisplayState state,
    required MutationView? view,
    required WorkspaceAnalysis analysis,
    required bool canRun,
  }) {
    const intro = 'Would the tests notice if this code were wrong?';
    final error = analysis.errors[AnalysisKind.mutation];
    if (analysis.isRunning(AnalysisKind.mutation)) {
      return _prose(
        '$intro haro is making small, deliberate mistakes in the changed lines and re-running the suite after each. This takes a while.',
      );
    }
    final children = <Widget>[];
    if (error != null) children.add(ErrorLine(error));

    if (view == null) {
      children.add(
        _prose(
          '$intro haro makes small, deliberate mistakes in the changed lines and checks whether the suite fails on each.',
        ),
      );
      if (canRun) {
        children.add(
          _runButton(
            'run-mutation',
            'Run mutation',
            () => _run(_actions.runMutation),
          ),
        );
      } else {
        children.add(const SizedBox(height: 8));
        children.add(_dim(_gatedText(state, 'Not measured for this tree.')));
      }
    } else if (!view.supported) {
      children.add(
        _prose(
          view.note ?? 'Mutation scoring is unavailable for this project.',
        ),
      );
    } else if (view.score == null) {
      children.add(
        _prose(
          'No runnable mutants in the changed lines${view.note == null ? '' : ': ${view.note}'}.',
        ),
      );
    } else {
      final total = view.total;
      final skipped = view.skipped > 0
          ? ' (${view.skipped} didn’t compile and were skipped)'
          : '';
      final tail = view.survivors.isEmpty
          ? ' Every one was caught.'
          : ' These survived:';
      final head = total != null
          ? '$intro haro made $total small, deliberate mistakes in the changed lines$skipped. The suite caught ${view.killed}.'
          : '$intro The suite scored ${view.score!.round()}% on the small, deliberate mistakes haro made in the changed lines.';
      children.add(_prose('$head$tail'));
      if (view.budgetCapped && view.note != null) {
        children.add(const SizedBox(height: 6));
        children.add(_dim(view.note!));
      }
      if (view.survivors.isNotEmpty) {
        children.add(const SizedBox(height: 12));
        final listed = view.survivors.take(_maxListed).toList();
        for (var i = 0; i < listed.length; i++) {
          final s = listed[i];
          children.add(
            _LocationRow(
              // Several mutants can survive on one line, so path:line is not unique.
              key: ValueKey('survivor-$i-${s.path}:${s.line}'),
              label: '${s.path.split('/').last}:${s.line}',
              tooltip: s.path,
              labelWidth: 150,
              text: '${s.operator} went unnoticed',
              onTap: () => _goCode(s.path, s.line),
            ),
          );
        }
        if (view.survivors.length > _maxListed) {
          children.add(_more(view.survivors.length - _maxListed));
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  String _gatedText(DisplayState state, String fallback) => switch (state) {
    DisplayState.red => 'Available once the gate is green.',
    DisplayState.gate ||
    DisplayState.idle ||
    DisplayState.plan ||
    DisplayState.agent => 'Available once the gate has run.',
    _ => fallback,
  };

  Widget _more(int n) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      '+ $n more',
      style: HaroText.mono(size: 12, color: HaroTokens.ink42, tracking: 0),
    ),
  );

  Widget _untestedBody(UntestedSummary u, bool settled) {
    if (!settled) return _dim('Appears when the gate has run.');
    if (!u.available) {
      return _prose(
        u.note ?? 'Not measured. A green gate records which added lines ran.',
      );
    }
    if (u.stale) {
      return _prose(
        'This tree changed since the gate ran, so the line map no longer lines up. Run the gate again.',
      );
    }
    if (u.spots.isEmpty) {
      return _prose('Every coverable added line executed at least once.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in u.spots.take(_maxListed))
          _LocationRow(
            key: ValueKey('untested-${s.path}:${s.start ?? 0}'),
            label: s.label,
            tooltip: s.path,
            labelWidth: 240,
            text: s.unmapped
                ? '${s.lines} added ${plural(s.lines, 'line')} · no test imports this file'
                : s.code == null
                ? '${s.lines} ${plural(s.lines, 'line')} never executed'
                : s.lines > 1
                ? '${s.code} · ${s.lines} lines'
                : s.code!,
            onTap: () => _goCode(s.path, s.start),
            trailing: OpenInLink(
              key: ValueKey('untested-editor-${s.path}:${s.start ?? 0}'),
              workspaceId: _id,
              source: 'verify-evidence',
              path: s.path,
              line: s.start,
            ),
          ),
        if (u.spots.length > _maxListed) _more(u.spots.length - _maxListed),
      ],
    );
  }

  Widget _impactBody(AsyncValue<ImpactResponse>? async, bool settled) {
    if (!settled || async == null) {
      return _dim(
        settled
            ? 'Analyzing which tests touch the change.'
            : 'Appears when the gate has run.',
      );
    }
    if (async.isLoading && !async.hasValue) {
      return _dim('Analyzing which tests touch the change.');
    }
    if (async.hasError && !async.hasValue) {
      return const ErrorLine('Impact analysis failed.');
    }
    final i = async.requireValue;
    if (!i.supported) {
      return _dim('This runner doesn’t support impact analysis.');
    }
    if (i.error != null) return ErrorLine(i.error!);
    final rows = impactByFile(i);
    final n = i.impactedTests.length;
    if (rows.isEmpty) {
      return _dim('No test touches the changed files.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$n of ${i.totalTests} tests touch this change · ${i.totalTests - n} unaffected',
          style: HaroText.ui(size: 14, color: HaroTokens.ink66),
        ),
        const SizedBox(height: 10),
        for (final r in rows.take(_maxListed))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${r.file} · ${r.tests} ${plural(r.tests, 'test')}',
              style: HaroText.mono(
                size: 12.5,
                color: HaroTokens.ink66,
                tracking: 0,
              ),
            ),
          ),
        if (rows.length > _maxListed) _more(rows.length - _maxListed),
      ],
    );
  }

  Widget _coverageBody(
    DisplayState state,
    WorkspaceAnalysis analysis,
    bool canRun,
  ) {
    if (analysis.isRunning(AnalysisKind.coverage)) {
      return _prose('Re-running the suite with coverage, against main.');
    }
    final error = analysis.errors[AnalysisKind.coverage];
    final c = analysis.coverage;
    final children = <Widget>[if (error != null) ErrorLine(error)];
    if (c == null) {
      children.add(
        _prose('Line coverage of this tree compared with the base branch.'),
      );
      if (canRun) {
        children.add(
          _runButton(
            'measure-coverage',
            'Measure coverage',
            () => _run(_actions.measureCoverage),
          ),
        );
      } else {
        children.add(const SizedBox(height: 8));
        children.add(_dim(_gatedText(state, 'Not measured for this tree.')));
      }
    } else if (!c.supported || c.current?.lines == null) {
      children.add(
        _prose(c.note ?? 'Coverage is unavailable for this project.'),
      );
    } else {
      final base = c.baseline?.lines;
      children.add(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            children: [
              if (base != null) ...[
                _CoverageBar('main', base, HaroTokens.ink42),
                const SizedBox(height: 10),
              ],
              _CoverageBar('this tree', c.current!.lines!, HaroTokens.gate),
            ],
          ),
        ),
      );
      if (c.note != null) {
        children.add(const SizedBox(height: 10));
        children.add(_dim(c.note!));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _flakyBody(
    DisplayState state,
    WorkspaceAnalysis analysis,
    TestRun? run,
    bool flakyRerun,
    bool canRun,
  ) {
    if (analysis.isRunning(AnalysisKind.flaky)) {
      return _prose('Re-running the suite to see whether any test flips.');
    }
    final error = analysis.errors[AnalysisKind.flaky];
    final facts = flakyFacts(analysis.flaky, run, flakyRerun);
    final children = <Widget>[if (error != null) ErrorLine(error)];
    const tail =
        'A test that flips between runs shows here and doesn’t count against green.';
    if (facts == null) {
      children.add(_prose(tail));
      if (canRun) {
        children.add(
          _runButton(
            'check-flaky',
            'Check flaky',
            () => _run(() => _actions.checkFlaky()),
          ),
        );
      } else {
        children.add(const SizedBox(height: 8));
        children.add(_dim(_gatedText(state, 'Not measured for this tree.')));
      }
    } else if (facts.count == 0) {
      children.add(
        _prose(
          analysis.flaky == null
              ? 'No test flipped when the gate re-ran the suite. $tail'
              : 'Every test gave the same result across the last ${facts.runs} runs of this tree. $tail',
        ),
      );
    } else {
      final f = analysis.flaky;
      children.add(
        _prose(
          '${facts.count} ${plural(facts.count, 'test')} flipped between runs and ${facts.count == 1 ? 'doesn’t' : 'don’t'} count against green:',
        ),
      );
      children.add(const SizedBox(height: 10));
      if (f != null) {
        for (final t in f.flaky.take(_maxListed)) {
          children.add(
            _LocationRow(
              key: ValueKey('flaky-${t.file}-${t.name}'),
              label: '${t.passed} passed · ${t.failed} failed',
              labelWidth: 200,
              text: t.name,
            ),
          );
        }
      } else {
        for (final name in run!.flakyTests.take(_maxListed)) {
          children.add(
            _LocationRow(
              key: ValueKey('flaky-$name'),
              label: 'flaky',
              labelWidth: 200,
              text: name,
            ),
          );
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _Entry {
  const _Entry(
    this.id,
    this.name,
    this.meta, {
    this.primary = false,
    required this.body,
  });

  final String id;
  final String name;
  final String meta;
  final bool primary;
  final Widget Function() body;
}

class _Accordion extends StatelessWidget {
  const _Accordion({
    super.key,
    required this.id,
    required this.name,
    required this.meta,
    required this.primary,
    required this.open,
    required this.onToggle,
    required this.body,
  });

  final String id;
  final String name;
  final String meta;
  final bool primary;
  final bool open;
  final VoidCallback onToggle;
  final Widget Function() body;

  @override
  Widget build(BuildContext context) {
    final nameStyle = HaroText.ui(
      size: 14.5,
      color: primary ? HaroTokens.ink : HaroTokens.ink66,
    );
    final metaStyle = HaroText.mono(
      size: 12,
      color: HaroTokens.ink66,
      tracking: 0,
    );
    final sign = Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        open ? '−' : '+',
        style: HaroText.mono(size: 13, color: HaroTokens.ink42, tracking: 0),
      ),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: HaroTokens.line08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HaroPressable(
            key: ValueKey('evidence-head-$id'),
            onTap: onToggle,
            semanticLabel: name,
            builder: (context, hovered) => LayoutBuilder(
              builder: (context, c) {
                final narrow = c.maxWidth < narrowWidth;
                return AnimatedContainer(
                  duration: HaroTokens.fadeFast,
                  color: hovered ? HaroTokens.panel : HaroTokens.transparent,
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: EdgeInsets.symmetric(vertical: narrow ? 8 : 0),
                  alignment: Alignment.centerLeft,
                  child: narrow
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 20, child: sign),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name, style: nameStyle),
                                  const SizedBox(height: 2),
                                  Text(meta, style: metaStyle),
                                ],
                              ),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            SizedBox(width: 20, child: sign),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 180,
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: nameStyle,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                meta,
                                key: ValueKey('evidence-meta-$id'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: metaStyle,
                              ),
                            ),
                          ],
                        ),
                );
              },
            ),
          ),
          if (open)
            FadeIn(
              key: ValueKey('evidence-body-$id'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 4, 0, 22),
                child: body(),
              ),
            ),
        ],
      ),
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({
    super.key,
    required this.label,
    required this.text,
    required this.labelWidth,
    this.tooltip,
    this.onTap,
    this.trailing,
  });

  final String label;
  final String text;
  final double labelWidth;
  final String? tooltip;
  final VoidCallback? onTap;

  /// A secondary action at the row's end.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < narrowWidth;
        final labelText = HaroPressable(
          onTap: onTap,
          tooltip: tooltip,
          semanticLabel: label,
          builder: (context, hovered) => Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HaroText.mono(
              size: 12.5,
              color: hovered ? HaroTokens.ink : HaroTokens.ink42,
              tracking: 0,
            ),
          ),
        );
        final value = Text(
          text,
          style: HaroText.mono(size: 12.5, color: HaroTokens.ink, tracking: 0),
        );
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              labelText,
              const SizedBox(height: 2),
              value,
              if (trailing != null) ...[
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerLeft, child: trailing),
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: labelWidth, child: labelText),
            const SizedBox(width: 16),
            Expanded(child: value),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        );
      },
    ),
  );
}

class _CoverageBar extends StatelessWidget {
  const _CoverageBar(this.label, this.value, this.color);

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(
      size: 11.5,
      color: HaroTokens.ink66,
      tracking: 0,
    );
    return Row(
      children: [
        SizedBox(width: 70, child: Text(label, style: style)),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 3,
            child: Stack(
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: HaroTokens.line12),
                ),
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: (value / 100).clamp(0, 1).toDouble(),
                      child: SizedBox(
                        height: 3,
                        child: ColoredBox(color: color),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 50,
          child: Text(percent(value), textAlign: TextAlign.end, style: style),
        ),
      ],
    );
  }
}
