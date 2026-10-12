import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api/models/models.dart';
import '../../../data/review_queue_provider.dart';
import '../../../data/sub_agents_provider.dart';
import '../../../data/workspace_store.dart' show haroApiProvider;
import '../../../data/workspace_actions.dart';
import '../../../data/workspace_detail.dart';
import '../../../data/workspace_detail_lazy.dart';
import '../../../state/display_state.dart';
import '../../../state/format.dart';
import '../../../state/look_at.dart';
import '../../../state/review_queue.dart';
import '../../../state/verdict.dart';
import '../../../state/workspace_flow.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/agent_loader.dart';
import '../../../widgets/dither_square.dart';
import '../../../widgets/haro_button.dart';
import '../../../widgets/haro_pressable.dart';
import '../../../widgets/kbd.dart';
import '../../../widgets/shell_icons.dart';
import '../../../widgets/status_square.dart';
import '../terminal/bottom_panel_provider.dart';
import 'agents_panel.dart';
import 'issue_section.dart';
import 'queue_section.dart';
import 'manual/manual_rail.dart';
import 'phone_shot.dart';
import 'run_facts.dart';

/// Opens a URL in the user's real browser. Overridden in tests.
final workspaceUrlOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

final workspaceRunFactsProvider = Provider.autoDispose.family<RunFacts, String>(
  (ref, id) {
    final events = ref.watch(
      workspaceDetailProvider(id).select((d) => d.events),
    );
    final elapsed = ref.watch(
      workspaceDetailProvider(id).select((d) => d.agentElapsed),
    );
    return deriveRunFacts(events, elapsed: elapsed);
  },
);

const gateNeverRun = 'never run';

/// `4m ago · 2.0s`, `never run`, or null while the gate is running.
String? gateWhen({
  required DisplayState state,
  TestRun? run,
  double? summaryEndedAt,
  required DateTime now,
}) {
  if (state == DisplayState.gate) return null;
  final ended = run?.endedAt ?? summaryEndedAt;
  if (ended == null) return gateNeverRun;
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
    final facts = ref.watch(workspaceRunFactsProvider(workspaceId));
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
    // NOT RUN already says it: no "Not run yet" under it and no "never run" beside it.
    final neverRun = when == gateNeverRun;
    final showSummary = flow.verdict.rail != VerdictCopy.notRunRail;

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
                              if (showSummary) ...[
                                const SizedBox(height: 10),
                                Text(
                                  flow.verdict.rail,
                                  key: const ValueKey('rail-summary'),
                                  style: HaroText.ui(
                                    size: 14,
                                    color: HaroTokens.ink86,
                                  ),
                                ),
                              ],
                              if (when != null && !neverRun) ...[
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
                        if (flow.openLookCount > 0 ||
                            flow.lookAt.railItems.isNotEmpty)
                          _Clickable(
                            key: const ValueKey('rail-eyes'),
                            onTap: onVerify,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 18,
                            ),
                            child: _NeedsEyes(flow: flow),
                          ),
                        if (!flow.manual)
                          _ReviewLimitNote(workspaceId: workspaceId),
                        IssueSection(
                          workspaceId: workspaceId,
                          compact: flow.manual,
                        ),
                        if (!flow.manual)
                          QueueSection(workspaceId: workspaceId),
                        _AppSection(workspaceId: workspaceId, onError: onError),
                        _PhoneSection(workspaceId: workspaceId),
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
                border: Border(top: BorderSide(color: HaroTokens.line12)),
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
                  Kbd('⌃`', bordered: false),
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
        border: Border(bottom: BorderSide(color: HaroTokens.line12)),
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
                'NEEDS YOUR REVIEW',
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
            'Details in review',
            style: HaroText.ui(size: 13, color: HaroTokens.ink42),
          ),
      ],
    );
  }
}

/// The review limit, said where you read status: once this many other workspaces wait for your
/// review, the rail says so in the warning colour. It never blocks a run.
class _ReviewLimitNote extends ConsumerWidget {
  const _ReviewLimitNote({required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = reviewCapWarning(
      ref.watch(reviewQueueProvider).value,
      workspaceId,
    );
    if (text == null) return const SizedBox.shrink();
    return _RailBlock(
      label: 'REVIEW LIMIT',
      child: Text(
        text,
        key: const ValueKey('rail-review-cap'),
        style: HaroText.ui(size: 13, color: HaroTokens.warn),
      ),
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
    decoration: BoxDecoration(
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

  Future<void> _reload({required bool restart}) async {
    try {
      await ref
          .read(workspaceActionsProvider(widget.workspaceId))
          .reloadDevServer(
            restart: restart,
            runId: ref.read(workspaceActiveRunProvider(widget.workspaceId)).id,
          );
    } catch (e) {
      widget.onError(e);
    }
  }

  Future<void> _toggle(bool running) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final actions = ref.read(workspaceActionsProvider(widget.workspaceId));
      if (running) {
        await actions.stopDevServer(
          runId: ref.read(workspaceActiveRunProvider(widget.workspaceId)).id,
        );
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
    final active = ref.watch(workspaceActiveRunProvider(id));
    final app = active.run;
    final running = app.running;
    final device = ref.watch(workspaceDeviceRunProvider(id)).value ?? false;
    final hotReload =
        !app.starting &&
        (ref.watch(workspaceHotReloadProvider(id)).value ?? false);
    final logAvailable = ref.watch(workspaceDevLogAvailableProvider(id));
    final logShowing = ref.watch(
      bottomPanelProvider(id).select((s) => s.showing(BottomTab.devLog)),
    );
    final configured = active.isDefault
        ? ref.watch(workspaceRunUrlProvider(id)).value
        : null;
    // The configured address wins over one remembered from an earlier run event, so editing
    // `url` in the settings file shows up without waiting for the next Run.
    final url =
        configured ??
        app.url ??
        (port == null ? null : 'http://localhost:$port');
    final problem = running
        ? null
        : ref.watch(workspaceRunProblemProvider(id)).value;

    final suggestion = ref.watch(
      workspaceDetailProvider(id).select((d) => d.appSuggestion),
    );
    ref.listen(workspaceDetailProvider(id).select((d) => d.appSuggestion), (
      prev,
      next,
    ) {
      final uri = next?.uri;
      final at = next?.at;
      if (next == null || !next.auto || uri == null || next == prev) return;
      // A suggestion the socket replays on connect is old news: only a fresh one opens by itself.
      final now = ref.read(workspaceDetailTuningProvider).now();
      if (at == null || now.difference(at) > _autoOpenWindow) return;
      ref.read(workspaceUrlOpenerProvider)(uri);
    });

    final mono = HaroText.mono(size: 12, color: HaroTokens.ink, tracking: 0);
    return _RailBlock(
      label: 'APP',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          !device && port == null && url == null
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
                    Row(
                      key: const ValueKey('rail-app-status'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!device) ...[
                          Text(
                            appAddress(url, port),
                            key: const ValueKey('rail-app-address'),
                            style: mono,
                          ),
                          const SizedBox(width: 8),
                        ],
                        _StateBadge(running: running, starting: app.starting),
                        if (!active.isDefault) ...[
                          const SizedBox(width: 8),
                          Text(
                            active.id,
                            key: const ValueKey('rail-app-run-name'),
                            style: HaroText.mono(
                              size: 11,
                              color: HaroTokens.ink66,
                              tracking: 0,
                            ),
                          ),
                        ],
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ShellIconButton(
                          key: const ValueKey('rail-app-toggle'),
                          filled: true,
                          icon: running ? ShellIcon.stop : ShellIcon.play,
                          tooltip: running ? 'Stop' : 'Run',
                          on: running,
                          // A press in flight is ignored, not dimmed: the icon must not flicker.
                          onTap: problem != null
                              ? null
                              : () {
                                  if (!_busy) _toggle(running);
                                },
                        ),
                        if (running && hotReload) ...[
                          const SizedBox(width: 6),
                          ShellIconButton(
                            key: const ValueKey('rail-app-reload'),
                            filled: true,
                            icon: ShellIcon.reload,
                            tooltip: 'Hot reload',
                            onTap: () => _reload(restart: false),
                          ),
                          const SizedBox(width: 6),
                          ShellIconButton(
                            key: const ValueKey('rail-app-restart'),
                            filled: true,
                            icon: ShellIcon.restart,
                            tooltip: 'Hot restart',
                            onTap: () => _reload(restart: true),
                          ),
                        ],
                        if (!device) ...[
                          const SizedBox(width: 6),
                          ShellIconButton(
                            key: const ValueKey('rail-app-open'),
                            filled: true,
                            icon: ShellIcon.openExternal,
                            tooltip: 'Open in browser',
                            onTap: running && url != null
                                ? () => ref.read(workspaceUrlOpenerProvider)(
                                    Uri.parse(url),
                                  )
                                : null,
                          ),
                        ],
                        const SizedBox(width: 6),
                        ShellIconButton(
                          key: const ValueKey('rail-app-log'),
                          filled: true,
                          icon: ShellIcon.log,
                          tooltip: 'Dev log',
                          on: logAvailable && logShowing,
                          onTap: logAvailable
                              ? () => ref
                                    .read(bottomPanelProvider(id).notifier)
                                    .toggleTab(BottomTab.devLog)
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
          if (suggestion != null)
            _AppSuggestionLine(
              suggestion: suggestion,
              onOpen: () {
                final uri = suggestion.uri;
                if (uri != null) ref.read(workspaceUrlOpenerProvider)(uri);
              },
              onDismiss: () => ref
                  .read(workspaceDetailProvider(id).notifier)
                  .dismissAppSuggestion(),
            ),
        ],
      ),
    );
  }
}

const _autoOpenWindow = Duration(seconds: 15);

/// A page the agent offered with `haro-app open`: what it is, a bone Open, a dim dismiss.
class _AppSuggestionLine extends StatelessWidget {
  const _AppSuggestionLine({
    required this.suggestion,
    required this.onOpen,
    required this.onDismiss,
  });

  final AppSuggestion suggestion;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      key: const ValueKey('rail-app-suggestion'),
      children: [
        Expanded(
          child: Text(
            'Agent suggests ${suggestion.label}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HaroText.mono(
              size: 11.5,
              color: HaroTokens.ink66,
              tracking: 0,
            ),
          ),
        ),
        const SizedBox(width: 8),
        HaroButton(
          key: const ValueKey('rail-app-suggestion-open'),
          label: 'Open',
          trailing: ShellIcon.openExternal,
          variant: HaroButtonVariant.control,
          height: 28,
          fontSize: 12.5,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          onPressed: suggestion.uri == null ? null : onOpen,
        ),
        const SizedBox(width: 4),
        ShellIconButton(
          key: const ValueKey('rail-app-suggestion-dismiss'),
          icon: ShellIcon.close,
          tooltip: 'Dismiss',
          iconSize: 14,
          onTap: onDismiss,
        ),
      ],
    ),
  );
}

/// The phone card of a device app: the latest screenshot of the phone or emulator, a button for
/// a new one, and one that opens the project's mirror tool (scrcpy) in its own window. It
/// refreshes by itself when the app comes up, after a hot reload and when an agent run ends.
class _PhoneSection extends ConsumerWidget {
  const _PhoneSection({required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = workspaceId;
    final device = ref.watch(workspaceDeviceRunProvider(id)).value ?? false;
    if (!device) return const SizedBox.shrink();
    final shot = ref.watch(phoneShotProvider(id));
    final notifier = ref.read(phoneShotProvider(id).notifier);
    ref.listen(workspaceActiveRunProvider(id).select((a) => a.run.starting), (
      was,
      now,
    ) {
      // The app came up, not a start that failed or was stopped (nothing is on the phone then).
      if (was == true &&
          !now &&
          ref.read(workspaceActiveRunProvider(id)).run.running) {
        notifier.takeSoon(const Duration(seconds: 3));
      }
    });
    ref.listen(workspaceDetailProvider(id).select((d) => d.workspace?.status), (
      was,
      now,
    ) {
      if (was == WorkspaceStatus.agentRunning &&
          now != WorkspaceStatus.agentRunning &&
          ref.read(workspaceActiveRunProvider(id)).run.running) {
        notifier.takeSoon();
      }
    });
    final raw = ref.read(haroApiProvider).rawUrl(id, phoneShotPath);
    final url = raw.replace(
      queryParameters: {...raw.queryParameters, 'v': '${shot.revision}'},
    );
    return _RailBlock(
      label: 'PHONE',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ShellIconButton(
                key: const ValueKey('rail-phone-shot'),
                filled: true,
                icon: ShellIcon.camera,
                tooltip: 'Take a screenshot',
                onTap: shot.busy ? null : () => notifier.take(),
              ),
              const SizedBox(width: 6),
              ShellIconButton(
                key: const ValueKey('rail-phone-mirror'),
                filled: true,
                icon: ShellIcon.mirror,
                tooltip: 'Mirror the phone in its own window',
                onTap: notifier.mirror,
              ),
              if (shot.busy) ...[
                const SizedBox(width: 10),
                const AgentLoader(size: 14, layoutSize: 14),
              ],
            ],
          ),
          if (shot.error != null) ...[
            const SizedBox(height: 8),
            Text(
              shot.error!,
              key: const ValueKey('rail-phone-error'),
              style: HaroText.mono(
                size: 11.5,
                color: HaroTokens.ink42,
                tracking: 0,
              ),
            ),
          ],
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: Align(
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: HaroTokens.line12),
                ),
                child: Image(
                  key: const ValueKey('rail-phone-image'),
                  image: phoneImageProvider(url.toString()),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'No screenshot yet',
                      key: const ValueKey('rail-phone-empty'),
                      style: HaroText.mono(
                        size: 11.5,
                        color: HaroTokens.ink42,
                        tracking: 0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether the app is running, as a badge: bone-filled while it runs, hollow and dim when it
/// does not (green stays the gate's).
class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.running, this.starting = false});

  final bool running;

  /// Running but not ready (`flutter run` still building): the loader and STARTING.
  final bool starting;

  @override
  Widget build(BuildContext context) {
    final solid = running && !starting;
    final fg = solid
        ? HaroTokens.bg
        : starting
        ? HaroTokens.ink
        : HaroTokens.ink42;
    return AnimatedContainer(
      key: const ValueKey('rail-app-badge'),
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: solid ? HaroTokens.ink : HaroTokens.transparent,
        borderRadius: BorderRadius.circular(HaroTokens.radius),
        border: Border.all(color: running ? HaroTokens.ink : HaroTokens.line20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (starting) ...[
            const AgentLoader(size: 12, layoutSize: 12),
            const SizedBox(width: 5),
          ],
          Text(
            starting
                ? 'STARTING'
                : running
                ? 'RUNNING'
                : 'STOPPED',
            style: HaroText.mono(
              size: 9.5,
              weight: FontWeight.w700,
              color: fg,
              tracking: .1,
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
                          Positioned.fill(
                            child: ColoredBox(color: HaroTokens.line12),
                          ),
                          Positioned.fill(
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: ctx,
                              child: ColoredBox(color: HaroTokens.ink66),
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

/// What the APP row calls the app's address: `:4200` for the URL it answers on, falling back
/// to the reserved port. A URL without a port shows its host.
String appAddress(String? url, int? port) {
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri != null && uri.hasAuthority && uri.host.isNotEmpty) {
    return uri.hasPort ? ':${uri.port}' : uri.host;
  }
  return port == null ? '' : ':$port';
}
