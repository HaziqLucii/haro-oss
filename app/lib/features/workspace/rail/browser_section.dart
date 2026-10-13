import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api/haro_api.dart';
import '../../../api/models/models.dart';
import '../../../data/workspace_browser.dart';
import '../../../data/workspace_detail.dart';
import '../../../data/workspace_store.dart';
import '../../../overlays/toast.dart';
import '../../../state/workspace_flow.dart' show AgentPhase;
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/agent_loader.dart';
import '../../../widgets/shell_icons.dart';
import 'browser_activity.dart';

TextStyle _label() =>
    HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .16);

/// One browser for the whole workspace, kept open between the agent's runs. The Playwright plugin
/// opens a browser per run and closes it when the run ends; this one is started here (or by the
/// agent with `haro-app browser start`) and every run after that uses it, so the page the agent
/// left is still there for the next prompt. Per workspace: another workspace never shares it.
class BrowserSection extends ConsumerStatefulWidget {
  const BrowserSection({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<BrowserSection> createState() => _BrowserSectionState();
}

class _BrowserSectionState extends ConsumerState<BrowserSection> {
  bool _busy = false;

  Future<void> _toggle(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final api = ref.read(haroApiProvider);
      if (on) {
        await api.stopBrowser(widget.workspaceId);
      } else {
        await api.startBrowser(widget.workspaceId);
      }
      ref.invalidate(workspaceBrowserProvider(widget.workspaceId));
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st =
        ref.watch(workspaceBrowserProvider(widget.workspaceId)).value ??
        BrowserState.off;
    final starting = _busy && !st.running || st.starting;
    final on = st.running;
    final detail = workspaceDetailProvider(widget.workspaceId);
    final running = ref.watch(
      detail.select((d) => d.agentPhase == AgentPhase.running),
    );
    final events = ref.watch(detail.select((d) => d.events));
    final subEvents = ref.watch(detail.select((d) => d.subEvents));
    final using = on
        ? browserInUse(events, running: running, subEvents: subEvents)
        : null;
    final word = starting
        ? 'STARTING'
        : on
        ? 'ON'
        : 'OFF';
    final hint = starting
        ? 'Starting. The first time it downloads the server.'
        : using != null
        ? 'The agent is using it now: $using.'
        : on
        ? 'Every run here uses it, and it stays open between prompts.'
        : 'A Playwright browser for the agent to interact with. Turn it on '
              'yourself, or let the agent turn it on.';
    return Container(
      key: const ValueKey('rail-browser'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: HaroTokens.line12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('BROWSER', style: _label()),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (using != null) ...[
                    const _InUseBadge(),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    word,
                    key: const ValueKey('rail-browser-state'),
                    style: _label().copyWith(
                      color: on ? HaroTokens.ink : HaroTokens.ink42,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  hint,
                  key: const ValueKey('rail-browser-hint'),
                  style: HaroText.mono(
                    size: 10.5,
                    tracking: 0,
                    color: HaroTokens.ink42,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ShellIconButton(
                key: const ValueKey('rail-browser-toggle'),
                icon: on ? ShellIcon.stop : ShellIcon.play,
                tooltip: on ? 'Close the browser' : 'Open the browser',
                width: 28,
                height: 28,
                iconSize: 15,
                on: on,
                onTap: starting ? null : () => _toggle(on),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The agent has a step going in the browser: the theme's own loader and a word, shaped like a tag.
class _InUseBadge extends StatelessWidget {
  const _InUseBadge();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('rail-browser-in-use'),
    height: 18,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    decoration: BoxDecoration(
      color: HaroTokens.ink02,
      border: Border.all(color: HaroTokens.line14),
      borderRadius: BorderRadius.circular(HaroTokens.radius + 1),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AgentLoader(size: 10, layoutSize: 10),
        const SizedBox(width: 6),
        Text(
          'IN USE',
          maxLines: 1,
          softWrap: false,
          style: HaroText.mono(
            size: 10,
            color: HaroTokens.ink,
            tracking: .16,
            height: 1,
          ),
        ),
      ],
    ),
  );
}
