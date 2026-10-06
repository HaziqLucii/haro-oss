import 'package:flutter/material.dart'
    show InputDecoration, Material, MaterialType, TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/models/models.dart';
import '../../../../shortcuts/platform_keys.dart';
import '../../../../state/manual_rail.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../../../widgets/haro_text_field.dart';
import '../../../../widgets/kbd.dart';
import 'manual_controller.dart';
import 'manual_widgets.dart';

/// Plan tab: your plan -> running -> review -> saved checklist.
class PlanTab extends ConsumerStatefulWidget {
  const PlanTab({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<PlanTab> createState() => _PlanTabState();
}

class _PlanTabState extends ConsumerState<PlanTab> {
  final _prompt = TextEditingController();
  final _title = TextEditingController();
  final _stepCtls = <TextEditingController>[];
  final _stepDone = <bool>[];
  bool _editing = false;

  ManualRailController get _ctl =>
      ref.read(manualRailProvider(widget.workspaceId).notifier);

  @override
  void dispose() {
    _prompt.dispose();
    _title.dispose();
    for (final c in _stepCtls) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final text = _prompt.text;
    if (text.trim().isEmpty) return;
    _ctl.startPlan(text);
  }

  void _beginEdit(ManualPlan plan) {
    _title.text = plan.title;
    for (final c in _stepCtls) {
      c.dispose();
    }
    _stepCtls
      ..clear()
      ..addAll([
        for (final s in plan.steps) TextEditingController(text: s.text),
      ]);
    _stepDone
      ..clear()
      ..addAll([for (final s in plan.steps) s.done]);
    setState(() => _editing = true);
  }

  Future<void> _saveEdit(ManualPlan plan) async {
    final steps = <PlanStep>[
      for (final (i, c) in _stepCtls.indexed)
        if (c.text.trim().isNotEmpty)
          PlanStep(text: c.text.trim(), done: _stepDone[i]),
    ];
    final title = _title.text.trim().isEmpty ? plan.title : _title.text.trim();
    final ok = await _ctl.saveEdits(plan.id, title: title, steps: steps);
    if (ok && mounted) setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(manualRailProvider(widget.workspaceId));
    final plan = s.activePlan;
    final body = switch (s.phase) {
      PlanPhase.empty => _empty(s),
      PlanPhase.running => _running(s),
      PlanPhase.review => _editing ? _edit(plan!, s) : _review(plan!, s),
      PlanPhase.saved => _saved(plan!, s),
    };
    return SingleChildScrollView(
      key: ValueKey('plan-${s.phase.name}'),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: body,
    );
  }

  // ---- empty ----

  Widget _empty(ManualState s) {
    final canPlan = _prompt.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ManualLabel('YOUR PLAN'),
        const SizedBox(height: 10),
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                _submit,
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                _submit,
          },
          child: Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: HaroTokens.panel,
              border: Border.all(color: HaroTokens.line20),
              borderRadius: BorderRadius.circular(HaroTokens.radius),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: TextField(
                key: const ValueKey('plan-input'),
                controller: _prompt,
                minLines: 4,
                maxLines: 8,
                onChanged: (_) => setState(() {}),
                cursorColor: HaroTokens.ink,
                style: HaroText.mono(
                  size: 11.5,
                  color: HaroTokens.ink,
                  tracking: 0,
                  height: 1.5,
                ),
                decoration: InputDecoration.collapsed(
                  hintText: 'What are you building? haro plans the steps, you write the code.',
                  hintStyle: HaroText.mono(
                    size: 11.5,
                    color: HaroTokens.ink42,
                    tracking: 0,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                '@ files · # issues',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HaroText.mono(
                  size: 10,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
            ),
            Kbd('${primaryLabel('↵')} plan', bordered: false),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PickerChip(
              key: const ValueKey('plan-model'),
              label: 'model',
              value: s.model,
              options: AgentConfig.modelOptions,
              onPick: _ctl.setModel,
            ),
            PickerChip(
              key: const ValueKey('plan-effort'),
              label: 'effort',
              value: s.effort,
              options: [
                for (final e in AgentConfig.effortOptions)
                  if (e.isNotEmpty) e,
              ],
              onPick: _ctl.setEffort,
            ),
            HaroButton(
              key: const ValueKey('plan-it'),
              label: 'Plan it',
              variant: HaroButtonVariant.primary,
              height: 26,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              onPressed: canPlan ? _submit : null,
            ),
          ],
        ),
        if (s.planError != null) ManualError(s.planError!),
        if (s.plans.isNotEmpty) ...[
          const SizedBox(height: 18),
          const ManualLabel('EARLIER PLANS'),
          for (final p in s.plans.reversed)
            HaroPressable(
              key: ValueKey('earlier-${p.id}'),
              onTap: () => _ctl.showPlan(p.id),
              builder: (context, hovered) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${p.title}  ${planProgress(p)}${p.saved ? '' : '  draft'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.ui(
                    size: 13,
                    color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  // ---- running ----

  Widget _running(ManualState s) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ManualLabel('PLANNING', trailing: s.planQueued ? 'QUEUED' : null),
      const SizedBox(height: 10),
      Text(
        s.planQueued
            ? 'Waiting for a free slot.'
            : (s.runText.trim().isEmpty ? 'Reading the repo...' : s.runText),
        key: const ValueKey('plan-stream'),
        style: HaroText.ui(size: 13, color: HaroTokens.ink66, height: 1.5),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: HaroButton(
          key: const ValueKey('plan-stop'),
          label: 'Stop',
          variant: HaroButtonVariant.secondary,
          height: 26,
          fontSize: 12.5,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          onPressed: _ctl.stop,
        ),
      ),
    ],
  );

  // ---- review ----

  Widget _review(ManualPlan plan, ManualState s) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const ManualLabel('PLAN BY HARO · CODE BY YOU'),
      const SizedBox(height: 8),
      Text(
        plan.title,
        key: const ValueKey('plan-title'),
        style: HaroText.mono(
          size: 14,
          weight: FontWeight.w700,
          color: HaroTokens.ink,
          tracking: 0,
        ),
      ),
      const SizedBox(height: 8),
      DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: HaroTokens.line12)),
        ),
        child: Column(
          children: [
            for (final (i, st) in plan.steps.indexed)
              Container(
                key: ValueKey('review-step-$i'),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: HaroTokens.line08)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${i + 1}',
                        style: HaroText.mono(
                          size: 11,
                          color: HaroTokens.ink42,
                          tracking: 0,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        st.text,
                        style: HaroText.ui(
                          size: 13,
                          color: HaroTokens.ink86,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      if (plan.why.isNotEmpty) ...[
        const SizedBox(height: 12),
        const ManualLabel('WHY THIS ORDER'),
        const SizedBox(height: 6),
        Text(
          plan.why,
          key: const ValueKey('plan-why'),
          style: HaroText.ui(size: 13, color: HaroTokens.ink66, height: 1.5),
        ),
      ],
      RunNotes(
        keyPrefix: 'plan',
        guardNote: plan.guardNote,
        blockedCalls: plan.blockedCalls,
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          HaroButton(
            key: const ValueKey('plan-finish'),
            label: 'Finish plan → save to Docs',
            variant: HaroButtonVariant.primary,
            height: 26,
            fontSize: 12.5,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            onPressed: () => _ctl.finishPlan(plan.id),
          ),
          HaroButton(
            key: const ValueKey('plan-edit'),
            label: 'Edit',
            variant: HaroButtonVariant.secondary,
            height: 26,
            fontSize: 12.5,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            onPressed: () => _beginEdit(plan),
          ),
          HaroButton(
            key: const ValueKey('plan-discard'),
            label: 'Discard',
            height: 26,
            fontSize: 12.5,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: () => _ctl.deletePlan(plan.id),
          ),
        ],
      ),
      if (s.planError != null) ManualError(s.planError!),
    ],
  );

  // ---- edit ----

  Widget _edit(ManualPlan plan, ManualState s) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const ManualLabel('EDIT PLAN'),
      const SizedBox(height: 8),
      HaroTextField(
        key: const ValueKey('edit-title'),
        controller: _title,
        mono: true,
        fontSize: 12,
        hintText: 'Title',
      ),
      const SizedBox(height: 8),
      for (final (i, c) in _stepCtls.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: HaroTextField(
                  key: ValueKey('edit-step-$i'),
                  controller: c,
                  fontSize: 13,
                  hintText: 'Step',
                ),
              ),
              const SizedBox(width: 4),
              HaroButton(
                key: ValueKey('edit-remove-$i'),
                label: 'Remove',
                height: 26,
                fontSize: 11.5,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                onPressed: () => setState(() {
                  _stepCtls.removeAt(i).dispose();
                  _stepDone.removeAt(i);
                }),
              ),
            ],
          ),
        ),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          HaroButton(
            key: const ValueKey('edit-add'),
            label: 'Add step',
            variant: HaroButtonVariant.secondary,
            height: 26,
            fontSize: 12.5,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            onPressed: () => setState(() {
              _stepCtls.add(TextEditingController());
              _stepDone.add(false);
            }),
          ),
          HaroButton(
            key: const ValueKey('edit-save'),
            label: 'Save',
            variant: HaroButtonVariant.primary,
            height: 26,
            fontSize: 12.5,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            onPressed: () => _saveEdit(plan),
          ),
          HaroButton(
            key: const ValueKey('edit-cancel'),
            label: 'Cancel',
            height: 26,
            fontSize: 12.5,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: () => setState(() => _editing = false),
          ),
        ],
      ),
      if (s.planError != null) ManualError(s.planError!),
    ],
  );

  // ---- saved ----

  Widget _saved(ManualPlan plan, ManualState s) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ManualLabel('PLAN BY HARO · CODE BY YOU', trailing: planProgress(plan)),
      const SizedBox(height: 8),
      DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: HaroTokens.line12)),
        ),
        child: Column(
          children: [
            for (final (i, st) in plan.steps.indexed)
              KeyedSubtree(
                key: ValueKey('saved-step-$i'),
                child: PlanStepRow(
                  step: st,
                  onTap: () => _ctl.toggleStep(plan.id, i),
                ),
              ),
          ],
        ),
      ),
      RunNotes(
        keyPrefix: 'plan',
        guardNote: plan.guardNote,
        blockedCalls: plan.blockedCalls,
      ),
      const SizedBox(height: 10),
      HaroPressable(
        key: const ValueKey('plan-saved-as'),
        onTap: () => _ctl.selectDocAndShow(DocRef(DocKind.plan, plan.id)),
        builder: (context, hovered) => Text(
          'Saved as ${planFileName(plan)} in Docs',
          style: HaroText.mono(
            size: 10,
            color: hovered ? HaroTokens.ink66 : HaroTokens.ink42,
            tracking: 0,
          ),
        ),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: HaroButton(
          key: const ValueKey('plan-new'),
          label: 'New plan',
          variant: HaroButtonVariant.secondary,
          height: 26,
          fontSize: 12.5,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          onPressed: _ctl.newPlan,
        ),
      ),
      if (s.planError != null) ManualError(s.planError!),
    ],
  );
}
