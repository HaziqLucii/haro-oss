import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_actions.dart';
import '../../data/workspace_detail.dart';
import '../../data/workspace_store.dart';
import '../../shell/shell_layout.dart';
import '../../shortcuts/app_commands.dart';
import '../../state/workspace_flow.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import 'fade_in.dart';
import 'header/workspace_header.dart';
import 'rail/rail_frame.dart';
import 'step_bar/next_action.dart';
import 'step_bar/step_bar.dart';
import 'steps/agent/agent_step.dart';
import 'steps/agent/composer_slot.dart';
import 'steps/code/code_buffers.dart';
import 'steps/code/code_step.dart';
import 'steps/code/editor/editor_tabs.dart';
import 'steps/code/run_on_save.dart';
import 'steps/ship/ship_step.dart';
import 'steps/verify/verify_step.dart';
import 'terminal/bottom_panel.dart';
import 'terminal/terminal_sessions.dart';
import 'workspace_ui.dart';

/// `/w/:id/:step`: header, step bar, the step's content, the bottom panel and (agent step
/// only) the composer in the main column; the gate rail beside it (spec 5).
class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key, required this.workspaceId, this.step});

  final String workspaceId;

  /// The route's `:step`. Unknown names fall back to the agent step.
  final String? step;

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  late final WorkspaceUiNotifier _uiForDispose;
  WorkspaceUiNotifier get _ui => ref.read(workspaceUiProvider.notifier);
  late ShellSession _shell;
  late final ShellSessions _shellSessions;
  final _devLog = DevLogTerminal();
  String? _error;
  bool _busy = false;

  String get _id => widget.workspaceId;

  ShellSession _newShell() => ShellSession(
    connect: (shellId) => ref.read(haroWsProvider).terminal(_id, shellId),
  );

  @override
  void initState() {
    super.initState();
    _uiForDispose = ref.read(workspaceUiProvider.notifier);
    _shellSessions = ref.read(shellSessionsProvider);
    _shell = _newShell();
    _shellSessions.register(_id, _shell);
    _register(_id);
  }

  @override
  void didUpdateWidget(WorkspacePage old) {
    super.didUpdateWidget(old);
    if (old.workspaceId != widget.workspaceId) {
      _shellSessions.unregister(old.workspaceId, _shell);
      _shell.dispose();
      _shell = _newShell();
      _shellSessions.register(widget.workspaceId, _shell);
      _error = null;
      _busy = false;
      _register(widget.workspaceId);
    }
  }

  @override
  void dispose() {
    _shellSessions.unregister(_id, _shell);
    _shell.dispose();
    final id = _id;
    final ui = _uiForDispose;
    Future.microtask(() {
      try {
        ui.clearActive(id);
      } catch (_) {
        // The container went down first (app shutdown or a test tearing down).
      }
    });
    super.dispose();
  }

  void _register(String id) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && id == _id) _ui.setActive(id);
    });
  }

  void _goStep(StepKey step) {
    if (!mounted) return;
    final mode =
        ref.read(workspaceFlowProvider(_id))?.mode ?? WorkspaceMode.agent;
    context.go(workspaceStepPath(_id, clampStep(step, mode)));
  }

  void _focusComposer() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ui.requestComposerFocus();
    });
  }

  void _report(Object e) {
    if (!mounted) return;
    setState(() => _error = e is HaroApiException ? e.message : e.toString());
  }

  Future<void> _next(NextAction action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await performNextAction(
        action,
        NextActionEnv(
          actions: ref.read(workspaceActionsProvider(_id)),
          goToStep: _goStep,
          focusComposer: _focusComposer,
          openGateSettings: () =>
              ref.read(appCommandsProvider).openSettings(SettingsTab.gate),
          rerunSetup: () => ref.read(haroApiProvider).rerunSetup(_id),
          home: homeStep(
            ref.read(workspaceFlowProvider(_id))?.mode ?? WorkspaceMode.agent,
          ),
          saveEdits: () => saveDirtyBuffers(
            ref.read(codeBuffersProvider(_id)),
            ref.read(workspaceActionsProvider(_id)),
          ),
        ),
      );
    } catch (e) {
      _report(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = workspaceDetailProvider(_id);
    final flow = ref.watch(workspaceFlowProvider(_id));
    final workspace = ref.watch(detail.select((d) => d.workspace));
    final loadError = ref.watch(detail.select((d) => d.error));

    if (flow == null || workspace == null) {
      return _Unavailable(
        error: loadError,
        onRetry: () => ref.invalidate(detail),
      );
    }

    final projectName = ref.watch(
      workspaceStoreProvider.select((s) {
        for (final p in s.projects) {
          if (p.id == workspace.projectId) return p.name;
        }
        return null;
      }),
    );
    final ui = ref.watch(workspaceUiProvider);
    final routed = stepFromName(widget.step);
    final step = clampStep(routed, flow.mode);
    if (step != routed) {
      // A manual workspace has no agent step: /agent (or a bare /w/id) becomes /code.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go(workspaceStepPath(_id, step));
      });
    }
    final dirty = ref.watch(
      editorTabsProvider(_id).select((s) => s.dirtyPaths.isNotEmpty),
    );
    final next = withUnsavedEdits(
      flow.nextAction,
      active: step,
      dirty: dirty,
      runOnSave: runOnSaveEnabled(ref, _id),
    );
    final focus = ref.watch(
      shellLayoutProvider.select(
        (l) => l.focusOn(workspaceId: _id, codeStep: step == StepKey.code),
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: HaroTokens.line12)),
            ),
            child: LayoutBuilder(
              builder: (context, c) {
                final bottomPanelHeight = math.min(
                  HaroTokens.terminalHeight,
                  math.max(120.0, c.maxHeight * .3),
                );
                return Column(
                  children: [
                    if (!focus) ...[
                      WorkspaceHeader(
                        workspaceId: _id,
                        name: workspace.name,
                        branch: workspace.branch,
                        baseRef: workspace.baseRef,
                        project: projectName,
                        onError: _report,
                      ),
                      const SizedBox(height: 18),
                      StepBar(
                        flow: flow,
                        active: step,
                        busy: _busy,
                        onStep: _goStep,
                        next: next,
                        onNext: () => _next(next),
                      ),
                    ],
                    if (_error != null)
                      _ErrorLine(
                        message: _error!,
                        onDismiss: () => setState(() => _error = null),
                      ),
                    Expanded(
                      child: FadeIn(
                        key: ValueKey('step-body-${step.name}'),
                        child: switch (step) {
                          StepKey.agent => AgentStep(_id),
                          StepKey.code => CodeStep(_id),
                          StepKey.verify => VerifyStep(_id),
                          StepKey.ship => ShipStep(_id),
                        },
                      ),
                    ),
                    if (ui.terminalOpen)
                      BottomPanel(
                        workspaceId: _id,
                        shell: _shell,
                        devLog: _devLog,
                        tab: ui.bottomTab,
                        height: bottomPanelHeight,
                        onTab: _ui.selectBottomTab,
                        onHide: () => _ui.setTerminalOpen(false),
                      ),
                    if (step == StepKey.agent) ComposerSlot(_id),
                  ],
                );
              },
            ),
          ),
        ),
        RailFrame(
          workspaceId: _id,
          flow: flow,
          terminalOpen: ui.terminalOpen,
          hidden: focus,
          onVerify: () => _goStep(StepKey.verify),
          onToggleTerminal: _ui.toggleTerminal,
          onError: _report,
        ),
      ],
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 10, 28, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            message,
            key: const ValueKey('action-error'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: HaroText.mono(size: 11, color: HaroTokens.fail, tracking: 0),
          ),
        ),
        const SizedBox(width: 12),
        HaroButton(
          key: const ValueKey('action-error-dismiss'),
          label: 'Dismiss',
          variant: HaroButtonVariant.tertiary,
          height: 22,
          fontSize: 11.5,
          padding: EdgeInsets.zero,
          onPressed: onDismiss,
        ),
      ],
    ),
  );
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.error, required this.onRetry});

  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(color: HaroTokens.ink42);
    if (error == null) {
      return Center(child: Text('LOADING WORKSPACE', style: style));
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error!,
              key: const ValueKey('load-error'),
              textAlign: TextAlign.center,
              style: HaroText.mono(
                size: 11,
                color: HaroTokens.fail,
                tracking: 0,
              ),
            ),
            const SizedBox(height: 14),
            HaroButton(
              key: const ValueKey('load-retry'),
              label: 'Retry',
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
