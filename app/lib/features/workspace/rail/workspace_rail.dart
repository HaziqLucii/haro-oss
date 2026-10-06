import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api/models/models.dart';
import '../../../data/sub_agents_provider.dart';
import '../../../data/workspace_actions.dart';
import '../../../data/workspace_detail.dart';
import '../../../data/workspace_detail_lazy.dart';
import '../../../state/display_state.dart';
import '../../../state/format.dart';
import '../../../state/look_at.dart';
import '../../../state/workspace_flow.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/dither_square.dart';
import '../../../widgets/haro_button.dart';
import '../../../widgets/haro_pressable.dart';
import '../../../widgets/kbd.dart';
import '../../../widgets/status_square.dart';
import 'agents_panel.dart';
import 'manual/manual_rail.dart';
import 'run_facts.dart';

/// Opens a URL in the user's real browser. Overridden in tests.
final workspaceUrlOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

final _runFactsProvider = Provider.autoDispose.family<RunFacts, String>((
  ref,
  id,
) {
  final events = ref.watch(workspaceDetailProvider(id).select((d) => d.events));
  final elapsed = ref.watch(
    workspaceDetailProvider(id).select((d) => d.agentElapsed),
  );
  return deriveRunFacts(events, elapsed: elapsed);
});

/// `4m ago · 2.0s`, `never run`, or null while the gate is running.
String? gateWhen({
  required DisplayState state,
  TestRun? run,
  double? summaryEndedAt,
  required DateTime now,
}) {
  if (state == DisplayState.gate) return null;
  final ended = run?.endedAt ?? summaryEndedAt;
  if (ended == null) return 'never run';
  final ago = relativeAgo(ended, now);
  final when = ago == 'now' ? 'just now' : '$ago ago';
  final ms = run?.durationMs;
  return ms == null ? when : '$when · ${formatMs(ms)}';
}

Color _verdictColor(DisplayState s) => switch (s) {
  DisplayState.agent || DisplayState.plan => HaroTokens.ink42,
  _ => s.color,
};

TextStyle _label() =>
    HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .16);

/// Right rail (spec 5.2), visible on every step so the gate is never lost.
class WorkspaceRail extends ConsumerWidget {
  const WorkspaceRail({
    super.key,
    required this.workspaceId,
    required this.flow,
    required this.terminalOpen,
    required this.onVerify,
    required this.onToggleTerminal,
    required this.onError,
  });

  final String workspaceId;
  final WorkspaceFlow flow;
  final bool terminalOpen;
  final VoidCallback onVerify;
  final VoidCallback onToggleTerminal;
  final ValueChanged<Object> onError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(
      workspaceDetailProvider(workspaceId).select((d) => d.gate.run),
    );
    final summaryEnded = ref.watch(
      workspaceDetailProvider(workspaceId)
          .select((d) => d.workspace?.gate?.endedAt),
    );
    final facts = ref.watch(_runFactsProvider(workspaceId));
    final agents = ref.watch(subAgentsProvider(workspaceId));
    final pickedId = ref.watch(selectedSubAgentProvider(workspaceId));
    final picked = pickedId == null
        ? null
        : agents.where((a) => a.id == pickedId).firstOrNull;

    final state = flow.displayState;
    final color = _verdictColor(state);
    final when = gateWhen(
      state: state,
      run: run,
      summaryEndedAt: summaryEnded,
      now: DateTime.now(),
    );

    return ColoredBox(
      color: HaroTokens.bg,
      child: Column(
        children: [
          Expanded(
            child: picked != null
                ? SubAgentDetail(
                    key: ValueKey('agent-${picked.id}'),
                    workspaceId: workspaceId,
                    agent: picked,
                  )
                : LayoutBuilder(
                    builder: (context, box) {
                      final top = <Widget>[
                        _Clickable(
                          key: const ValueKey('rail-gate'),
                          onTap: onVerify,
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('GATE', style: _label()),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  if (state == DisplayState.gate)
                                    DitherSquare(
                                      key: const ValueKey('rail-gate-running'),
                                      size: HaroTokens.markGateHero,
                                      color: color,
                                    )
                                  else
                                    StatusSquare(
                                      size: HaroTokens.markGateHero,
                                      color: color,
                                      filled: state.settled,
                                    ),
                                  const SizedBox(
                                    width: HaroTokens.markGateHeroGap,
                                  ),
                                  Expanded(
                                    child: Text(
                                      flow.verdict.word,
                                      key: const ValueKey('rail-verdict'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: HaroText.mono(
                                        size: 15,
                                        weight: FontWeight.w700,
                                        color: color,
                                        tracking: .2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                flow.verdict.rail,
                                key: const ValueKey('rail-summary'),
                                style: HaroText.ui(
                                  size: 14,
                                  color: HaroTokens.ink86,
                                ),
                              ),
                              if (when != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  when,
                                  key: const ValueKey('rail-when'),
                                  style: HaroText.mono(
                                    size: 11,
                                    color: HaroTokens.ink42,
                                    tracking: 0,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        _Clickable(
                          key: const ValueKey('rail-eyes'),
                          onTap: onVerify,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 18,
                          ),
                          child: _NeedsEyes(flow: flow),
                        ),
                        _AppSection(workspaceId: workspaceId, onError: onError),
                        AgentsSection(workspaceId: workspaceId),
                        if (!flow.manual && !facts.isEmpty)
                          _RunSection(facts: facts),
                      ];
                      // A manual workspace works in the rail: give Plan / Search / Docs the rest of
                      // its height (each tab scrolls) instead of a fixed box, unless the window is
                      // too short, where the whole rail scrolls as before.
                      if (flow.manual && box.maxHeight >= manualRailMinFill) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ...top,
                            Expanded(
                              child: ManualRail(
                                workspaceId: workspaceId,
                                fill: true,
                              ),
                            ),
                          ],
                        );
                      }
                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ...top,
                            if (flow.manual)
                              ManualRail(workspaceId: workspaceId),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          HaroPressable(
            onTap: onToggleTerminal,
            semanticLabel: terminalOpen ? 'Hide terminal' : 'Terminal',
            builder: (context, hovered) => AnimatedContainer(
              key: const ValueKey('rail-terminal-toggle'),
              duration: HaroTokens.fadeFast,
              curve: HaroTokens.curve,
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: hovered ? HaroTokens.panel : HaroTokens.transparent,
                border: const Border(top: BorderSide(color: HaroTokens.line12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      terminalOpen ? 'Hide terminal' : 'Terminal',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaroText.ui(size: 13.5),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Kbd('⌃`', bordered: false),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A full-width rail section that is a button: hairline below, panel fill on hover.
class _Clickable extends StatelessWidget {
  const _Clickable({
    super.key,
    required this.onTap,
    required this.padding,
    required this.child,
  });

  final VoidCallback onTap;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    builder: (context, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      padding: padding,
      decoration: BoxDecoration(
        color: hovered ? HaroTokens.panel : HaroTokens.transparent,
        border: const Border(bottom: BorderSide(color: HaroTokens.line12)),
      ),
      child: child,
    ),
  );
}

class _NeedsEyes extends StatelessWidget {
  const _NeedsEyes({required this.flow});

  final WorkspaceFlow flow;

  @override
  Widget build(BuildContext context) {
    final items = flow.lookAt.railItems;
    final count = flow.openLookCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                'NEEDS YOUR EYES',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _label(),
              ),
            ),
            Text(
              '$count',
              key: const ValueKey('rail-eyes-count'),
              style: _label().copyWith(color: HaroTokens.ink),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (items.isNotEmpty)
          for (final (i, item) in items.indexed) ...[
            if (i > 0) const SizedBox(height: 6),
            _EyesRow(item),
          ]
        else
          Text(
            count > 0 ? 'Details in verify' : 'Nothing yet',
            style: HaroText.ui(size: 13, color: HaroTokens.ink42),
          ),
      ],
    );
  }
}

class _EyesRow extends StatelessWidget {
  const _EyesRow(this.item);

  final LookAtItem item;

  @override
  Widget build(BuildContext context) => Text(
    '${item.glyph} ${item.shortFile}',
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    style: HaroText.mono(size: 11.5, color: HaroTokens.ink66, tracking: 0),
  );
}

class _RailBlock extends StatelessWidget {
  const _RailBlock({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line12)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: _label()),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );
}

class _AppSection extends ConsumerStatefulWidget {
  const _AppSection({required this.workspaceId, required this.onError});

  final String workspaceId;
  final ValueChanged<Object> onError;

  @override
  ConsumerState<_AppSection> createState() => _AppSectionState();
}

class _AppSectionState extends ConsumerState<_AppSection> {
  bool _busy = false;

  Future<void> _toggle(bool running) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final actions = ref.read(workspaceActionsProvider(widget.workspaceId));
      if (running) {
        await actions.stopDevServer();
      } else {
        await actions.startDevServer();
      }
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.workspaceId;
    final port = ref.watch(workspaceDetailProvider(id).select((d) => d.port));
    final app = ref.watch(workspaceDetailProvider(id).select((d) => d.app));
    final running = app.running;
    final url = app.url ?? (port == null ? null : 'http://localhost:$port');
    final problem = running
        ? null
        : ref.watch(workspaceRunProblemProvider(id)).value;

    final mono = HaroText.mono(size: 12, color: HaroTokens.ink, tracking: 0);
    return _RailBlock(
      label: 'APP',
      child: port == null
          ? Text(
              'No dev server port',
              style: HaroText.ui(size: 13, color: HaroTokens.ink42),
            )
          : Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 8,
              spacing: 8,
              children: [
                Text.rich(
                  key: const ValueKey('rail-app-status'),
                  TextSpan(
                    text: ':$port · ',
                    style: mono,
                    children: [
                      TextSpan(
                        text: running ? 'running' : 'stopped',
                        style: mono.copyWith(color: HaroTokens.ink42),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HaroButton(
                      key: const ValueKey('rail-app-toggle'),
                      label: running ? 'Stop' : 'Run',
                      height: 26,
                      fontSize: 12.5,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      foreground: HaroTokens.ink,
                      onPressed: _busy || problem != null
                          ? null
                          : () => _toggle(running),
                    ),
                    const SizedBox(width: 4),
                    HaroButton(
                      key: const ValueKey('rail-app-open'),
                      label: 'Open ↗',
                      height: 26,
                      fontSize: 12.5,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onPressed: running && url != null
                          ? () => ref.read(workspaceUrlOpenerProvider)(
                              Uri.parse(url),
                            )
                          : null,
                    ),
                  ],
                ),
                if (problem != null)
                  SizedBox(
                    width: double.infinity,
                    child: Text(
                      problem,
                      key: const ValueKey('rail-app-problem'),
                      style: HaroText.mono(
                        size: 11.5,
                        color: HaroTokens.ink42,
                        tracking: 0,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _RunSection extends StatelessWidget {
  const _RunSection({required this.facts});

  final RunFacts facts;

  @override
  Widget build(BuildContext context) {
    final k = HaroText.mono(size: 11.5, color: HaroTokens.ink42, tracking: 0);
    final v = HaroText.mono(size: 11.5, color: HaroTokens.ink, tracking: 0);

    Widget row(String key, Widget value) => Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 70, child: Text(key, style: k)),
          Expanded(child: value),
        ],
      ),
    );

    Widget text(String s) =>
        Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: v);

    final spent = facts.spentUsd;
    final dur = facts.duration;
    final spentLine = [
      if (spent != null) '\$${spent.toStringAsFixed(2)}',
      if (dur != null) formatDuration(dur),
    ].join(' · ');
    final ctx = facts.contextFraction;

    return _RailBlock(
      label: 'RUN',
      child: Column(
        key: const ValueKey('rail-run'),
        children: [
          if (facts.modelLine != null) row('model', text(facts.modelLine!)),
          if (spentLine.isNotEmpty) row('spent', text(spentLine)),
          if (ctx != null)
            row(
              'context',
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 3,
                      child: Stack(
                        children: [
                          const Positioned.fill(
                            child: ColoredBox(color: HaroTokens.line12),
                          ),
                          Positioned.fill(
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: ctx,
                              child: const ColoredBox(color: HaroTokens.ink66),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(ctx * 100).round()}%', style: v),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
