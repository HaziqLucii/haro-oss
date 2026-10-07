import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart';
import '../../../../data/workspace_actions.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_store.dart';
import '../../../../shortcuts/app_commands.dart';
import '../../../../shortcuts/platform_keys.dart';
import '../../../../state/test_first.dart';
import '../../../../state/workspace_flow.dart' show AgentPhase, NextActionKind;
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../workspace_ui.dart';
import 'agent_tokens.dart';
import 'agent_transcript.dart' show contextPercent;
import 'composer_logic.dart';
import 'composer_state.dart';
import 'composer_widgets.dart';

/// The composer, docked at the bottom of the main column below the bottom panel, shown by
/// the page on the agent step only. It is separate from `AgentStep` because the bottom panel sits
/// between the step's scroll area and the composer (spec 5, prototype), so the composer cannot
/// live inside the step's own box.
///
/// It grows with the text up to a few lines, and drops the least important labels first as
/// the column narrows, so at 900x640 with the terminal open it still fits.
class ComposerSlot extends ConsumerStatefulWidget {
  const ComposerSlot(this.workspaceId, {super.key});

  final String workspaceId;

  @override
  ConsumerState<ComposerSlot> createState() => _ComposerSlotState();
}

class _ComposerSlotState extends ConsumerState<ComposerSlot> {
  late final MentionController _controller;
  late final FocusNode _focus;
  final _menu = OverlayPortalController();
  final _picker = OverlayPortalController();
  final _fieldLink = LayerLink();
  final _pickerLink = LayerLink();

  Trigger? _trigger;
  String? _dismissed;
  int _sel = 0;
  bool _sending = false;
  bool _stopping = false;
  String? _error;

  String get _id => widget.workspaceId;
  ComposerDraftNotifier get _draft =>
      ref.read(composerDraftProvider(_id).notifier);

  @override
  void initState() {
    super.initState();
    _controller = MentionController(
      text: ref.read(composerDraftProvider(_id)).text,
    );
    _controller.addListener(_onEdited);
    _focus = FocusNode(debugLabel: 'composer', onKeyEvent: _onKey);
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _controller.removeListener(_onEdited);
    _controller.dispose();
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  void _onEdited() {
    _draft.setText(_controller.text);
    final sel = _controller.selection;
    final next = _focus.hasFocus && sel.isValid && sel.isCollapsed
        ? detectTrigger(_controller.text, sel.baseOffset)
        : null;
    if (next?.key == _trigger?.key) return;
    void apply() {
      if (!mounted) return;
      setState(() {
        _trigger = next;
        _sel = 0;
      });
    }

    // The field can touch its controller while the tree is building (focus, IME).
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _onFocus() {
    if (!_focus.hasFocus && _trigger != null) {
      setState(() => _trigger = null);
    } else if (_focus.hasFocus) {
      _onEdited();
    }
  }

  bool get _menuOpen => _trigger != null && _trigger!.key != _dismissed;

  List<CompletionItem> _items(AsyncValue<List<String>>? files) {
    final t = _trigger;
    if (t == null) return const [];
    if (t.kind == TriggerKind.slash) {
      return [
        for (final c in filterSlashCommands(t.query))
          CompletionItem(insert: c.name, label: c.name, hint: c.description),
      ];
    }
    final paths = files?.value;
    if (paths == null) return const [];
    return [
      for (final p in filterFiles(paths, t.query))
        CompletionItem(insert: '@$p', label: p),
    ];
  }

  List<CompletionItem> _currentItems() => _items(
    _trigger?.kind == TriggerKind.at
        ? ref.read(worktreeFilesProvider(_id))
        : null,
  );

  void _choose(CompletionItem item) {
    final t = _trigger;
    if (t == null) return;
    final res = applyCompletion(_controller.text, t, item.insert);
    _controller.value = TextEditingValue(
      text: res.text,
      selection: TextSelection.collapsed(offset: res.caret),
    );
    setState(() {
      _trigger = null;
      _dismissed = null;
    });
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent || !_menuOpen) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final kb = HardwareKeyboard.instance;
    final items = _currentItems();
    if (k == LogicalKeyboardKey.escape) {
      setState(() => _dismissed = _trigger?.key);
      return KeyEventResult.handled;
    }
    if (items.isEmpty) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _sel = (_sel + 1).clamp(0, items.length - 1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() => _sel = (_sel - 1).clamp(0, items.length - 1));
      return KeyEventResult.handled;
    }
    final enter =
        k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter;
    if (enter && (kb.isMetaPressed || kb.isControlPressed)) {
      return KeyEventResult.ignored;
    }
    if (enter || k == LogicalKeyboardKey.tab) {
      _choose(items[_sel.clamp(0, items.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- run arguments ----

  bool get _rolesOn => _rolesConfig()?.enabled ?? false;

  RolesConfig? _rolesConfig() {
    final pid = ref.read(workspaceDetailProvider(_id)).workspace?.projectId;
    return pid == null ? null : ref.read(agentRolesProvider(pid)).value;
  }

  AgentConfig? _agentConfig() {
    final pid = ref.read(workspaceDetailProvider(_id)).workspace?.projectId;
    return pid == null ? null : ref.read(agentConfigProvider(pid)).value;
  }

  Future<void> _submit() async {
    final detail = ref.read(workspaceDetailProvider(_id));
    if (!canStartRun(
      status: detail.workspace?.status,
      phase: detail.agentPhase,
      sending: _sending,
    )) {
      return;
    }
    final draft = ref.read(composerDraftProvider(_id));
    final task = composeWithAttachments(_controller.text, draft.attachments);
    if (task.isEmpty) return;
    final tf = detail.workspace?.testFirst;
    // With a test-first state on the workspace, a send is feedback for a redraft while the
    // test awaits approval; the toggle only decides how a fresh task starts.
    final testFirst = tf == null ? draft.testFirst : testFirstNeedsYou(tf);

    final args = currentRunArgs(ref, _id);
    setState(() {
      _sending = true;
      _error = null;
      _trigger = null;
    });
    try {
      await ref
          .read(workspaceActionsProvider(_id))
          .startAgent(
            task,
            plan: draft.planFirst && !testFirst,
            model: args.model,
            effort: args.effort,
            role: nextRole(planFirst: draft.planFirst && !testFirst),
            adapter: args.adapter,
            testFirst: testFirst,
          );
      if (!mounted) return;
      _controller.clear();
      _draft.clearSent();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is HaroApiException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() {
      _stopping = true;
      _error = null;
    });
    try {
      await ref.read(workspaceActionsProvider(_id)).stopAgent();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is HaroApiException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  // ---- attachments ----

  Future<void> _attachText(String text) async {
    try {
      final res = await ref.read(haroApiProvider).attachContext(_id, text);
      if (mounted) _draft.addAttachment(Attachment.from(res));
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is HaroApiException
              ? e.message
              : 'Could not attach the text.',
        );
      }
    }
  }

  Future<void> _attachClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (!mounted) return;
    if (text.trim().isEmpty) {
      setState(() => _error = 'The clipboard has no text to attach.');
      return;
    }
    setState(() => _error = null);
    await _attachText(text);
  }

  // ---- build ----

  String _chipLabel(ComposerDraft draft, {required bool compact}) {
    final roles = _rolesConfig();
    final agent = _agentConfig();
    if (roles?.enabled ?? false) {
      final role = nextRole(planFirst: draft.planFirst);
      if (compact) return role;
      final short = roleLabel(draft.planFirst ? roles!.plan : roles!.build);
      return short == 'not set' ? role : '$role · $short';
    }
    final model = draft.model ?? agent?.defaultModel;
    final effort = draft.effort ?? agent?.defaultEffort;
    final parts = [
      if (model != null && model.isNotEmpty) model,
      if (effort != null && effort.isNotEmpty) effort,
    ];
    if (parts.isEmpty) return 'default';
    if (compact) return parts.first;
    return parts.join(' · ');
  }

  void _openRoleSettings() {
    _picker.hide();
    ref
        .read(appCommandsProvider)
        .openSettings(_rolesOn ? SettingsTab.roles : SettingsTab.agent);
  }

  List<PickerSection> _pickerSections(ComposerDraft draft) {
    final roles = _rolesConfig();
    if (roles != null && roles.enabled) {
      return roleSections(
        roles,
        planFirst: draft.planFirst,
        onPlanFirst: (on) {
          _draft.setPlanFirst(on);
          _picker.hide();
        },
      );
    }
    final agent = _agentConfig();
    return modelSections(
      model: draft.model,
      effort: draft.effort,
      defaultModel: agent?.defaultModel ?? '',
      defaultEffort: agent?.defaultEffort ?? '',
      onModel: _draft.setModel,
      onEffort: _draft.setEffort,
    );
  }

  @override
  Widget build(BuildContext context) {
    final detailProvider = workspaceDetailProvider(_id);
    final status = ref.watch(detailProvider.select((d) => d.workspace?.status));
    final phase = ref.watch(detailProvider.select((d) => d.agentPhase));
    final projectId = ref.watch(
      detailProvider.select((d) => d.workspace?.projectId),
    );
    final events = ref.watch(detailProvider.select((d) => d.events));
    final draft = ref.watch(composerDraftProvider(_id));
    final tfState = ref.watch(
      detailProvider.select((d) => d.workspace?.testFirst),
    );
    if (projectId != null) {
      ref.watch(agentRolesProvider(projectId));
      ref.watch(agentConfigProvider(projectId));
    }

    ref.listen(
      workspaceUiProvider.select((u) => u.composerFocusRequest),
      (_, _) => _focus.requestFocus(),
    );
    ref.listen(composerDraftProvider(_id).select((d) => d.fillRevision), (
      _,
      _,
    ) {
      final text = ref.read(composerDraftProvider(_id)).text;
      if (_controller.text != text) {
        _controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    });

    final running =
        phase == AgentPhase.running || status == WorkspaceStatus.agentRunning;
    final gateRunning = status == WorkspaceStatus.testsRunning;
    final canStart = canStartRun(
      status: status,
      phase: phase,
      sending: _sending,
    );
    final canRun = canStart && !draft.isEmpty;
    // Where the step bar hides its action because it lands on this step, `Run agent` is the
    // one primary on screen (and focuses the field when there is nothing to send yet).
    final ownsPrimary =
        ref.watch(workspaceFlowProvider(_id))?.nextAction.kind ==
        NextActionKind.runAgent;
    final contextPct = contextPercent(events);
    final terminalOpen = ref.watch(
      workspaceUiProvider.select((u) => u.terminalOpen),
    );
    // With the terminal open on a short window the column has about 130px to spare, so the
    // field stops growing and gives up a line to the attachment row or the error line.
    final tall = MediaQuery.sizeOf(context).height >= 760;
    final constrained = !tall && terminalOpen;
    final extras =
        (draft.attachments.isNotEmpty ? 1 : 0) + (_error != null ? 1 : 0);
    final minLines = constrained && extras > 0 ? 1 : 2;
    final maxLines = constrained ? minLines : (tall ? 6 : 4);

    final files = _trigger?.kind == TriggerKind.at
        ? ref.watch(worktreeFilesProvider(_id))
        : null;
    final items = _items(files);
    final sel = items.isEmpty ? 0 : _sel.clamp(0, items.length - 1);

    final result = Container(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line08)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AgentTokens.columnMax),
          child: Container(
            key: const ValueKey('composer'),
            decoration: BoxDecoration(
              color: HaroTokens.panel,
              border: Border.all(color: HaroTokens.line20),
              borderRadius: BorderRadius.circular(HaroTokens.radius),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (draft.attachments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final a in draft.attachments)
                          AttachmentChip(
                            key: ValueKey('attachment-${a.path}'),
                            attachment: a,
                            onRemove: () => _draft.removeAttachment(a.path),
                          ),
                      ],
                    ),
                  ),
                OverlayPortal(
                  controller: _menu,
                  overlayChildBuilder: (context) => CompletionMenu(
                    link: _fieldLink,
                    items: items,
                    selected: sel,
                    loading: files?.isLoading ?? false,
                    onPick: _choose,
                    onHover: (i) => setState(() => _sel = i),
                  ),
                  child: CompositedTransformTarget(
                    link: _fieldLink,
                    child: _field(minLines, maxLines),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                    child: Text(
                      _error!,
                      key: const ValueKey('composer-error'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AgentTokens.tool(color: HaroTokens.fail),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
                  child: LayoutBuilder(
                    builder: (context, c) => _controls(
                      c.maxWidth,
                      draft: draft,
                      running: running,
                      canRun: canRun,
                      canStart: canStart,
                      ownsPrimary: ownsPrimary,
                      gateRunning: gateRunning,
                      contextPct: contextPct,
                      testFirstState: tfState,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _syncMenu();
    return result;
  }

  void _syncMenu() {
    final open = _menuOpen;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (open && !_menu.isShowing) _menu.show();
      if (!open && _menu.isShowing) _menu.hide();
    });
  }

  Widget _field(int minLines, int maxLines) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.enter, meta: true): _submit,
      const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit,
      const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true):
          _submit,
      const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
          _submit,
    },
    child: Material(
      type: MaterialType.transparency,
      child: TextField(
        key: const ValueKey('composer-field'),
        controller: _controller,
        focusNode: _focus,
        minLines: minLines,
        maxLines: maxLines,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        inputFormatters: [LargePasteFormatter(_attachText)],
        cursorColor: HaroTokens.ink,
        cursorWidth: 1,
        style: AgentTokens.composerMono(),
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          hintText: 'Describe the next task for the agent…',
          hintStyle: AgentTokens.composerMono(color: HaroTokens.ink42),
        ),
      ),
    ),
  );

  Widget _controls(
    double width, {
    required ComposerDraft draft,
    required bool running,
    required bool canRun,
    required bool canStart,
    required bool ownsPrimary,
    required bool gateRunning,
    required int? contextPct,
    required TestFirstState? testFirstState,
  }) {
    final showHint = width >= 690;
    final showContext = contextPct != null && width >= 560;
    final compact = width < 500;
    final pickerLabel = '${_chipLabel(draft, compact: compact)} ▾';
    final planLabel = '${draft.planFirst ? '●' : '○'} plan first';
    final attachLabel = compact ? '+' : '+ attach';
    final testLabel = '${draft.testFirst ? '●' : '○'} test first';
    final redrafting = testFirstNeedsYou(testFirstState);
    // A chip's natural width grows with its label plus a constant for padding, so sharing
    // the row by these weights lets each chip keep its full label until space runs out.
    int weight(String l) => l.length + 3;
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                flex: weight(pickerLabel),
                child: CompositedTransformTarget(
                  link: _pickerLink,
                  child: OverlayPortal(
                    controller: _picker,
                    overlayChildBuilder: (_) => PickerPanel(
                      link: _pickerLink,
                      sections: _pickerSections(draft),
                      footer: _rolesOn
                          ? 'Edit roles in settings →'
                          : 'Roles are off. Turn them on in settings →',
                      onFooter: _openRoleSettings,
                      onClose: _picker.hide,
                    ),
                    child: ComposerChip(
                      key: const ValueKey('role-picker'),
                      label: pickerLabel,
                      onTap: _picker.toggle,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                flex: weight(planLabel),
                child: ComposerChip(
                  key: const ValueKey('plan-first'),
                  label: planLabel,
                  active: draft.planFirst,
                  tooltip:
                      'Plan only: the agent edits nothing until you approve',
                  onTap: () => _draft.setPlanFirst(!draft.planFirst),
                ),
              ),
              if (testFirstState == null) ...[
                const SizedBox(width: 4),
                Flexible(
                  flex: weight(testLabel),
                  child: ComposerChip(
                    key: const ValueKey('test-first'),
                    label: testLabel,
                    active: draft.testFirst,
                    tooltip: 'The agent drafts a failing acceptance test first. You approve it, then it builds',
                    onTap: () => _draft.setTestFirst(!draft.testFirst),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              Flexible(
                flex: weight(attachLabel),
                child: ComposerChip(
                  key: const ValueKey('attach'),
                  label: attachLabel,
                  bordered: false,
                  tooltip: 'Attach the clipboard text as a file',
                  onTap: _attachClipboard,
                ),
              ),
            ],
          ),
        ),
        if (showHint) Text('/ commands · @ files', style: AgentTokens.hint),
        if (showContext)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '$contextPct% context',
              key: const ValueKey('composer-context'),
              style: AgentTokens.hint,
            ),
          ),
        const SizedBox(width: 4),
        if (running)
          HaroButton(
            key: const ValueKey('composer-stop'),
            label: _stopping ? 'Stopping…' : 'Stop',
            height: AgentTokens.composerButtonHeight,
            fontSize: 13.5,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            onPressed: _stopping ? null : _stop,
          )
        else
          Opacity(
            opacity: ownsPrimary ? (canStart ? 1 : .4) : (canRun ? 1 : .4),
            child: HaroButton(
              key: const ValueKey('composer-run'),
              label: _sending
                  ? 'Starting…'
                  : (redrafting ? 'Redraft test' : 'Run agent'),
              kbd: primaryLabel('↵'),
              variant: ownsPrimary && canStart
                  ? HaroButtonVariant.primary
                  : HaroButtonVariant.secondary,
              height: AgentTokens.composerButtonHeight,
              fontSize: 13.5,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              tooltip: gateRunning ? 'The gate is running' : null,
              onPressed: ownsPrimary && canStart
                  ? (draft.isEmpty ? _focus.requestFocus : _submit)
                  : (canRun ? _submit : null),
            ),
          ),
      ],
    );
  }
}
