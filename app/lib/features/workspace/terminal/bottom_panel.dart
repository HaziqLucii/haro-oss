import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/workspace_detail.dart';
import '../../../theme/display_scope.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_pressable.dart';
import '../fade_in.dart';
import 'bottom_panel_provider.dart';
import 'haro_terminal_theme.dart';
import 'panel_tabs.dart';
import 'selectable_terminal.dart';
import 'terminal_sessions.dart';

TextStyle _tabStyle(Color color) =>
    HaroText.mono(size: 10.5, color: color, tracking: .1);

/// The bottom panel of the workspace page (spec 5.3, Finalized UI): Terminal, Gate and
/// Problems, plus Dev log once a dev server has run. The sessions belong to the page, so
/// hiding the panel keeps the shell and the log scrollback. Open it from anywhere with
/// `bottomPanelProvider(workspaceId)`.
class BottomPanel extends ConsumerStatefulWidget {
  const BottomPanel({
    super.key,
    required this.workspaceId,
    required this.shell,
    required this.devLog,
    required this.tab,
    required this.onTab,
    required this.onHide,
    this.height = HaroTokens.terminalHeight,
  });

  final String workspaceId;
  final ShellSession shell;
  final DevLogTerminal devLog;
  final BottomTab tab;
  final ValueChanged<BottomTab> onTab;
  final VoidCallback onHide;
  final double height;

  @override
  ConsumerState<BottomPanel> createState() => _BottomPanelState();
}

class _BottomPanelState extends ConsumerState<BottomPanel> {
  @override
  void initState() {
    super.initState();
    widget.devLog.sync(ref.read(workspaceDevLogProvider(widget.workspaceId)));
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.workspaceId;
    ref.listen(workspaceDevLogProvider(id), (_, log) {
      widget.devLog.sync(log);
    });
    final showDevLog = ref.watch(workspaceDevLogAvailableProvider(id));
    final tab = effectiveBottomTab(widget.tab, devLog: showDevLog);
    if (tab == BottomTab.terminal && widget.shell.phase == ShellPhase.idle) {
      // The socket opens on first sight of the Terminal tab; starting notifies listeners,
      // which must not happen mid-build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.shell.start();
      });
    }

    final tabs = <(BottomTab, String, String)>[
      (BottomTab.terminal, 'TERMINAL', 'term-tab-shell'),
      (BottomTab.gate, 'GATE', 'term-tab-gate'),
      (BottomTab.problems, 'PROBLEMS', 'term-tab-problems'),
      if (showDevLog) (BottomTab.devLog, 'DEV LOG', 'term-tab-devlog'),
    ];
    return FadeIn(
      child: SizedBox(
        height: widget.height,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: HaroTokens.bg,
            border: Border(top: BorderSide(color: HaroTokens.line14)),
          ),
          child: Column(
            children: [
              Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: HaroTokens.line08)),
                ),
                child: Row(
                  children: [
                    for (final (t, label, key) in tabs)
                      _Tab(
                        key: ValueKey(key),
                        label: label,
                        active: tab == t,
                        onTap: () => widget.onTab(t),
                      ),
                    const Spacer(),
                    HaroPressable(
                      onTap: widget.onHide,
                      semanticLabel: 'Hide panel',
                      builder: (context, hovered) => Text(
                        'hide ⌃`',
                        key: const ValueKey('term-hide'),
                        style: HaroText.mono(
                          size: 10.5,
                          color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                          tracking: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: switch (tab) {
                  BottomTab.terminal => _ShellBody(session: widget.shell),
                  BottomTab.gate => GateTab(workspaceId: id),
                  BottomTab.problems => ProblemsTab(workspaceId: id),
                  BottomTab.devLog => SelectableTerminal(
                    widget.devLog.terminal,
                    viewKey: const ValueKey('devlog-view'),
                    readOnly: true,
                    theme: haroTerminalTheme,
                    textStyle: haroTerminalStyleFor(
                      DisplayScope.codingFontOf(context),
                    ),
                    padding: haroTerminalPadding,
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: label,
    builder: (context, hovered) => Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: active ? HaroTokens.ink : HaroTokens.transparent,
          ),
        ),
      ),
      child: Text(
        label,
        style: _tabStyle(active || hovered ? HaroTokens.ink : HaroTokens.ink42),
      ),
    ),
  );
}

class _ShellBody extends StatelessWidget {
  const _ShellBody({required this.session});

  final ShellSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Column(
      children: [
        Expanded(
          child: SelectableTerminal(
            session.terminal,
            viewKey: const ValueKey('shell-view'),
            autofocus: true,
            theme: haroTerminalTheme,
            textStyle: haroTerminalStyleFor(DisplayScope.codingFontOf(context)),
            padding: haroTerminalPadding,
          ),
        ),
        if (session.phase == ShellPhase.ended)
          Container(
            key: const ValueKey('shell-ended'),
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: HaroTokens.line08)),
            ),
            child: Row(
              children: [
                Text('SHELL ENDED', style: _tabStyle(HaroTokens.ink42)),
                Text(' · ', style: _tabStyle(HaroTokens.ink42)),
                HaroPressable(
                  onTap: session.restart,
                  semanticLabel: 'Restart shell',
                  builder: (context, hovered) => Text(
                    'RESTART',
                    key: const ValueKey('shell-restart'),
                    style: _tabStyle(
                      hovered ? HaroTokens.ink : HaroTokens.ink66,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
