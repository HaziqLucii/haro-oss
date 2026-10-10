import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/haro_api.dart';
import '../../../../api/models/models.dart';
import '../../../../data/review_queue_provider.dart';
import '../../../../data/workspace_actions.dart';
import '../../../../data/workspace_detail.dart';
import '../../../../data/workspace_store.dart';
import '../../../../shortcuts/app_commands.dart';
import '../../../../shortcuts/platform_keys.dart';
import '../../../../state/review_queue.dart';
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
  late final TextEditingController _scopeCtl;
  late final FocusNode _scopeFocus;
  final _menu = OverlayPortalController();
  final _scopeMenu = OverlayPortalController();
  final _picker = OverlayPortalController();
  final _fieldLink = LayerLink();
  final _scopeLink = LayerLink();
  final _pickerLink = LayerLink();

  Trigger? _trigger;
  String? _dismissed;
  int _sel = 0;
  String? _scopeDismissed;
  int _scopeSel = 0;
  String _scopeLastText = '';
  bool _scopeExpanded = false;
  bool _scopeNav = false;
  List<String>? _memoFiles;
  String? _memoQuery;
  List<ScopeSuggestion> _memoItems = const [];
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
    _scopeCtl = TextEditingController(
      text: ref.read(composerDraftProvider(_id)).scopeInput,
    );
    _scopeLastText = _scopeCtl.text;
    _scopeCtl.addListener(_onScopeEdited);
    _scopeFocus = FocusNode(
      debugLabel: 'composer-scope',
      onKeyEvent: _onScopeKey,
    );
    _scopeFocus.addListener(_onScopeEdited);
  }

  @override
  void dispose() {
    _controller.removeListener(_onEdited);
    _controller.dispose();
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _scopeCtl.removeListener(_onScopeEdited);
    _scopeCtl.dispose();
    _scopeFocus.removeListener(_onScopeEdited);
    _scopeFocus.dispose();
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
    if (!_menuOpen) return KeyEventResult.ignored;
    final items = _currentItems();
    return _menuKey(
      e,
      count: items.length,
      selected: _sel,
      onSelect: (i) => setState(() => _sel = i),
      onPick: () => _choose(items[_sel.clamp(0, items.length - 1)]),
      onDismiss: () => setState(() => _dismissed = _trigger?.key),
    );
  }

  // Both menus never take focus; their field routes Esc, the arrows, and Enter or Tab here.
  KeyEventResult _menuKey(
    KeyEvent e, {
    required int count,
    required int selected,
    required ValueChanged<int> onSelect,
    required VoidCallback onPick,
    required VoidCallback onDismiss,
  }) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final kb = HardwareKeyboard.instance;
    if (k == LogicalKeyboardKey.escape) {
      onDismiss();
      return KeyEventResult.handled;
    }
    if (count == 0) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.arrowDown) {
      onSelect((selected + 1).clamp(0, count - 1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      onSelect((selected - 1).clamp(0, count - 1));
      return KeyEventResult.handled;
    }
    final enter =
        k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter;
    if (enter && (kb.isMetaPressed || kb.isControlPressed)) {
      return KeyEventResult.ignored;
    }
    if (enter || (k == LogicalKeyboardKey.tab && !kb.isShiftPressed)) {
      onPick();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- scope suggestions ----

  String get _scopeValue => ref.read(composerDraftProvider(_id)).scope;

  bool get _scopeActive => _scopeFocus.hasFocus;

  void _onScopeEdited() {
    final text = _scopeCtl.text;
    if (text.contains(',') || text.contains('\n')) {
      final cut = splitScopeInput(text);
      var scope = _scopeValue;
      for (final e in cut.done) {
        scope = addScopeEntry(scope, e);
      }
      _draft.setScope(scope);
      final rest = cut.rest.trimLeft();
      _scopeCtl.value = TextEditingValue(
        text: rest,
        selection: TextSelection.collapsed(offset: rest.length),
      );
      return;
    }
    _draft.setScopeInput(text);
    void apply() {
      if (!mounted) return;
      final items = _currentScopeItems();
      setState(() {
        // The "back" row leads the list but is never the default choice.
        _scopeSel = items.isNotEmpty && items.first.up ? 1 : 0;
        _scopeNav = false;
        // Esc closes the menu for what is typed now: any edit, or leaving the box, reopens it.
        if (!_scopeActive || text != _scopeLastText) _scopeDismissed = null;
        _scopeLastText = text;
      });
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  List<ScopeSuggestion> _scopeItems(AsyncValue<List<String>>? files) {
    final paths = files?.value;
    if (!_scopeActive || paths == null) return const [];
    final q = _scopeCtl.text;
    if (!identical(paths, _memoFiles) || q != _memoQuery) {
      _memoFiles = paths;
      _memoQuery = q;
      final entry = normalizeScopeEntry(q);
      final glob =
          entry.contains('*') || entry.contains('?') || entry.contains('[');
      _memoItems = glob
          ? [ScopeSuggestion(entry, dir: false, pattern: true)]
          : q.trim().endsWith('/**')
          ? [ScopeSuggestion(entry, dir: true, all: true)]
          : _withBack(q, scopeSuggestions(paths, q));
    }
    return _memoItems;
  }

  // Inside a folder the list starts with a way back to the folder above it.
  List<ScopeSuggestion> _withBack(String query, List<ScopeSuggestion> items) {
    final q = normalizeScopeEntry(query);
    final slash = q.lastIndexOf('/');
    if (slash == -1 || items.isEmpty) return items;
    final parent = scopeParent(q.substring(0, slash + 1));
    return [ScopeSuggestion(parent, dir: true, up: true), ...items];
  }

  // An empty box lists the project root but highlights nothing: Tab and Enter pass through
  // until the user moves into the list with an arrow key or the pointer.
  bool get _scopeArmed => _scopeNav || _scopeCtl.text.trim().isNotEmpty;

  // Unlike the prompt's menu this one stays closed when nothing matches: a scope entry is
  // often a file the agent has yet to create.
  bool get _scopeMenuOpen => _scopeActive && _scopeDismissed != _scopeCtl.text;

  List<ScopeSuggestion> _currentScopeItems() =>
      _scopeItems(_scopeActive ? ref.read(worktreeFilesProvider(_id)) : null);

  void _addScope(String entry, {bool refocus = true}) {
    _draft.setScope(addScopeEntry(_scopeValue, entry));
    _scopeCtl.clear();
    if (refocus) _scopeFocus.requestFocus();
  }

  /// Chooses a suggestion: a file or a whole folder becomes a chip; "back" goes up a level.
  void _pickScope(ScopeSuggestion item) =>
      item.up ? _drillScope(item) : _addScope(item.path);

  /// Steps into a folder so its contents are listed.
  void _drillScope(ScopeSuggestion item) {
    _scopeCtl.value = TextEditingValue(
      text: item.path,
      selection: TextSelection.collapsed(offset: item.path.length),
    );
    _scopeFocus.requestFocus();
  }

  void _commitScopeInput({bool refocus = true}) {
    final text = _scopeCtl.text.trim();
    if (text.isEmpty) return;
    _addScope(text, refocus: refocus);
  }

  // A name with an extension is a file the dev means exactly (it may not exist yet), so Enter
  // adds what was typed instead of a longer name that merely starts with it.
  bool _typedIsFile(String typed) =>
      normalizeScopeEntry(typed).split('/').last.contains('.');

  // A single-line field drops the newlines of a pasted list, which would run the paths
  // together; paste is taken here so each line becomes its own entry.
  Future<void> _pasteIntoScope() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final pasted = data?.text;
    if (!mounted || pasted == null || pasted.isEmpty) return;
    final text = pasted.replaceAll(RegExp(r'\r?\n'), ', ');
    final v = _scopeCtl.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    final next = v.text.replaceRange(sel.start, sel.end, text);
    _scopeCtl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
  }

  KeyEventResult _onScopeKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final pressed = HardwareKeyboard.instance;
    if (k == LogicalKeyboardKey.keyV &&
        (pressed.isControlPressed || pressed.isMetaPressed) &&
        !pressed.isShiftPressed) {
      _pasteIntoScope();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace &&
        _scopeCtl.text.isEmpty &&
        parseScope(_scopeValue).isNotEmpty) {
      _draft.setScope(
        removeScopeEntry(_scopeValue, parseScope(_scopeValue).last),
      );
      return KeyEventResult.handled;
    }
    final enter =
        k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter;
    final kb = HardwareKeyboard.instance;
    if (enter && !kb.isMetaPressed && !kb.isControlPressed) {
      final typed = _scopeCtl.text.trim();
      if (typed.isNotEmpty &&
          (!_scopeMenuOpen ||
              _currentScopeItems().isEmpty ||
              (!_scopeNav && _typedIsFile(typed)))) {
        _commitScopeInput();
        return KeyEventResult.handled;
      }
    }
    if (!_scopeMenuOpen) return KeyEventResult.ignored;
    final items = _currentScopeItems();
    if (items.isEmpty) return KeyEventResult.ignored;
    final armed = _scopeArmed;
    final picks = enter || k == LogicalKeyboardKey.tab;
    if (!armed && picks) return KeyEventResult.ignored;
    final tabbed = k == LogicalKeyboardKey.tab && !kb.isShiftPressed;
    final index = _scopeSel.clamp(0, items.length - 1);
    if (tabbed && armed) {
      final item = items[index];
      if (item.dir && !item.all && !item.pattern) {
        _drillScope(item);
        return KeyEventResult.handled;
      }
    }
    return _menuKey(
      e,
      count: items.length,
      selected: armed ? _scopeSel : -1,
      onSelect: (i) => setState(() {
        _scopeSel = i;
        _scopeNav = true;
      }),
      onPick: () => _pickScope(items[index]),
      onDismiss: () => setState(() => _scopeDismissed = _scopeCtl.text),
    );
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
    _commitScopeInput(refocus: false);
    final tf = detail.workspace?.testFirst;
    // With a test-first state on the workspace, a send is feedback for a redraft while the
    // test awaits approval; the toggle only decides how a fresh task starts.
    final testFirst = tf == null ? draft.testFirst : testFirstNeedsYou(tf);

    final args = currentRunArgs(ref, _id);
    final plan = draft.planFirst && !testFirst;
    final fence = plan || (detail.workspace?.manual ?? false)
        ? const <String>[]
        : ref.read(composerDraftProvider(_id)).fence;
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
            plan: plan,
            model: args.model,
            effort: args.effort,
            role: nextRole(planFirst: plan),
            adapter: args.adapter,
            testFirst: testFirst,
            scope: fence,
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
    final manual = ref.watch(
      detailProvider.select((d) => d.workspace?.manual ?? false),
    );
    final capWarning = manual
        ? null
        : reviewCapWarning(ref.watch(reviewQueueProvider).value, _id);
    // Shown while plan-first is on too: the fence applies when the plan is approved.
    final scopeAllowed = !manual;
    final fenced = scopeAllowed && draft.fence.isNotEmpty;
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
    // The short-window layout has no room for the scope row until a scope is set.
    final showScope = scopeAllowed && (!constrained || fenced);
    final extras =
        (draft.attachments.isNotEmpty ? 1 : 0) +
        (_error != null ? 1 : 0) +
        (showScope && constrained ? 1 : 0);
    final minLines = constrained && extras > 0 ? 1 : 2;
    final maxLines = constrained ? minLines : (tall ? 6 : 4);

    final files = _trigger?.kind == TriggerKind.at
        ? ref.watch(worktreeFilesProvider(_id))
        : null;
    final items = _items(files);
    final sel = items.isEmpty ? 0 : _sel.clamp(0, items.length - 1);

    final scopeFiles = _scopeActive || draft.scope.isNotEmpty
        ? ref.watch(worktreeFilesProvider(_id))
        : null;
    final scopeItems = _scopeItems(scopeFiles);
    final scopeSel = scopeItems.isEmpty || !_scopeArmed
        ? -1
        : _scopeSel.clamp(0, scopeItems.length - 1);

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
                if (capWarning != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                    child: Text(
                      capWarning,
                      key: const ValueKey('composer-review-cap'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AgentTokens.tool(color: HaroTokens.ink66),
                    ),
                  ),
                showScope
                    ? OverlayPortal(
                        controller: _scopeMenu,
                        overlayChildBuilder: (context) => CompletionMenu(
                          link: _scopeLink,
                          items: [
                            for (final s in scopeItems)
                              _scopeCompletion(
                                s,
                                scopeFiles?.value ?? const [],
                              ),
                          ],
                          selected: scopeSel,
                          loading: false,
                          onPick: (i) => _pickScope(
                            scopeItems.firstWhere((s) => s.path == i.insert),
                          ),
                          footer: 'click adds a folder or file \u00b7 Open looks inside \u00b7 Esc closes',
                          onDrill: (i) => _drillScope(
                            scopeItems.firstWhere((s) => s.path == i.insert),
                          ),
                          onHover: (i) => setState(() {
                            _scopeSel = i;
                            _scopeNav = true;
                          }),
                        ),
                        child: _scopeRow(
                          armed: fenced,
                          files: scopeFiles?.value ?? const [],
                        ),
                      )
                    : const SizedBox.shrink(),
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
    _syncMenu(scopeOpen: showScope && _scopeMenuOpen && scopeItems.isNotEmpty);
    return result;
  }

  void _syncMenu({required bool scopeOpen}) {
    final open = _menuOpen;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (open && !_menu.isShowing) _menu.show();
      if (!open && _menu.isShowing) _menu.hide();
      if (scopeOpen && !_scopeMenu.isShowing) _scopeMenu.show();
      if (!scopeOpen && _scopeMenu.isShowing) _scopeMenu.hide();
    });
  }

  // Shared by the prompt and the scope input: Ctrl/Cmd+Enter sends from either one.
  Map<ShortcutActivator, VoidCallback> get _sendKeys => {
    const SingleActivator(LogicalKeyboardKey.enter, meta: true): _submit,
    const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit,
    const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true): _submit,
    const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
        _submit,
  };

  Widget _field(int minLines, int maxLines) => CallbackShortcuts(
    bindings: _sendKeys,
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

  static const _collapseAt = 6;
  static const _collapsedChips = 5;

  List<String>? _statsFiles;
  final _kinds = <String, ScopeKind>{};
  final _counts = <String, int?>{};

  // Chips and menu rows are rebuilt on every prompt keystroke; what they say about a path only
  // changes with the file list, so each answer is worked out once per list.
  void _statsFor(List<String> files) {
    if (identical(files, _statsFiles)) return;
    _statsFiles = files;
    _kinds.clear();
    _counts.clear();
  }

  ScopeKind _kindOf(String entry, List<String> files) {
    _statsFor(files);
    return _kinds.putIfAbsent(entry, () => scopeKind(entry, files));
  }

  int? _countOf(String entry, List<String> files) {
    _statsFor(files);
    return _counts.putIfAbsent(entry, () => scopeFileCount(entry, files));
  }

  CompletionItem _scopeCompletion(ScopeSuggestion s, List<String> files) {
    if (s.up) {
      return CompletionItem(
        insert: s.path,
        label: '\u2039 back',
        hint: s.path.isEmpty ? 'to all files' : 'to ${s.path}',
      );
    }
    if (s.pattern) {
      return CompletionItem(
        insert: s.path,
        label: s.path,
        hint: 'a pattern: matches files by name',
      );
    }
    if (!s.dir) return CompletionItem(insert: s.path, label: s.path);
    final n = _countOf(s.path, files);
    final count = n == null ? '' : '$n ${n == 1 ? 'file' : 'files'}';
    return CompletionItem(
      insert: s.path,
      label: s.path,
      hint: s.all
          ? 'add the whole folder${count.isEmpty ? '' : ' \u00b7 $count'}'
          : count,
      drillable: !s.all,
    );
  }

  // The bare field read as a caption and nobody knew it was an input; the box and the rule
  // between label and input make it read as a form field. Each path is a chip, so a second
  // or third entry is one click, and a folder needs no glob: it covers everything inside it.
  Widget _scopeRow({required bool armed, required List<String> files}) {
    final entries = parseScope(_scopeValue);
    final collapsed = entries.length > _collapseAt && !_scopeExpanded;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: ListenableBuilder(
        listenable: _scopeFocus,
        builder: (context, _) {
          final lit = armed || _scopeFocus.hasFocus;
          final line = lit ? HaroTokens.line30 : HaroTokens.line14;
          return GestureDetector(
            key: const ValueKey('scope-box'),
            behavior: HitTestBehavior.opaque,
            onTap: _scopeFocus.requestFocus,
            child: CompositedTransformTarget(
              link: _scopeLink,
              child: AnimatedContainer(
                key: const ValueKey('scope-frame'),
                duration: HaroTokens.fadeFast,
                curve: HaroTokens.curve,
                constraints: const BoxConstraints(minHeight: 26),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(HaroTokens.radius),
                  border: Border.all(color: line),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        child: Tooltip(
                          message:
                              'The agent may only change what you list here. A folder '
                              'covers everything inside it, so you never need *. Anything '
                              'it changes outside is put back when the run ends. Empty '
                              'means all files.',
                          waitDuration: const Duration(milliseconds: 600),
                          child: Text(
                            'SCOPE',
                            style: AgentTokens.label(
                              color: lit ? HaroTokens.ink66 : HaroTokens.ink42,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: AnimatedContainer(
                          key: const ValueKey('scope-divider'),
                          duration: HaroTokens.fadeFast,
                          curve: HaroTokens.curve,
                          decoration: BoxDecoration(
                            border: Border(left: BorderSide(color: line)),
                          ),
                          // The newest entry and the input stay in view when the entries
                          // outgrow the box: it starts scrolled to the end.
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 78),
                            child: SingleChildScrollView(
                              reverse: true,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  for (final e
                                      in collapsed
                                          ? entries.take(_collapsedChips)
                                          : entries)
                                    ScopeChip(
                                      key: ValueKey('scope-chip-$e'),
                                      entry: e,
                                      kind: _kindOf(e, files),
                                      count: _countOf(e, files),
                                      onRemove: () => _draft.setScope(
                                        removeScopeEntry(_scopeValue, e),
                                      ),
                                    ),
                                  if (entries.length > _collapseAt)
                                    ScopeToggle(
                                      key: const ValueKey('scope-more'),
                                      label: collapsed
                                          ? '+${entries.length - _collapsedChips} more'
                                          : 'fewer',
                                      onTap: () => setState(
                                        () => _scopeExpanded = !_scopeExpanded,
                                      ),
                                    ),
                                  SizedBox(
                                    width: 200,
                                    child: CallbackShortcuts(
                                      bindings: _sendKeys,
                                      child: TextField(
                                        key: const ValueKey('composer-scope'),
                                        controller: _scopeCtl,
                                        focusNode: _scopeFocus,
                                        maxLines: 1,
                                        cursorColor: HaroTokens.ink,
                                        cursorWidth: 1,
                                        style: AgentTokens.tool(
                                          color: HaroTokens.ink86,
                                        ),
                                        decoration: InputDecoration(
                                          isCollapsed: true,
                                          border: InputBorder.none,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                vertical: 3,
                                              ),
                                          hintText: entries.isEmpty
                                              ? 'all files \u00b7 pick folders or files, or type a path'
                                              : 'add another\u2026',
                                          hintMaxLines: 1,
                                          hintStyle:
                                              AgentTokens.tool(
                                                color: HaroTokens.ink42,
                                              ).copyWith(
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

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
