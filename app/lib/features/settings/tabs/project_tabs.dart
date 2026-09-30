import 'package:flutter/material.dart';

import '../../../api/haro_api.dart';
import '../../../api/models/models.dart';
import '../../../shortcuts/app_commands.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_button.dart';
import '../controls/mono_input.dart';
import '../controls/segmented.dart';
import '../controls/select.dart';
import '../controls/toggle.dart';
import '../settings_controller.dart';
import '../settings_logic.dart';
import '../settings_scope.dart';
import '../settings_section.dart';
import '../settings_tab_spec.dart';

const _mergeModeLabels = {
  'pr': 'PR only',
  'merge': 'Merge only',
  'both': 'PR + merge',
};

SettingsTabSpec gitTab(SettingsController c) {
  final s = c.config<GitDraft>(SettingsTab.git);
  return SettingsTabSpec(
    tab: SettingsTab.git,
    title: 'Git',
    intro: 'Where new workspaces branch from and how step 4 delivers.',
    scope: SettingsScope.team,
    rows: [
      SettingRowSpec(
        id: 'base_branch',
        label: 'Base branch',
        help: 'New workspaces fork from the origin/ tip. Kept in haro, not in the repo.',
        control: (_) => SettingSelect<String>(
          options: [for (final b in s.draft.branches) (b, b)],
          value: s.draft.branch,
          onChanged: (v) => s.edit((d) => d.copyWith(branch: v)),
        ),
      ),
      SettingRowSpec(
        id: 'remote',
        label: 'Remote',
        help: 'origin, shared by every workspace. Empty keeps merges local.',
        control: (_) => SettingInput(
          width: 320,
          value: s.draft.remote,
          hint: 'No remote',
          onChanged: (v) => s.edit((d) => d.copyWith(remote: v)),
        ),
      ),
      SettingRowSpec(
        id: 'ship_mode',
        label: 'Ship mode',
        help: 'Which actions the ship step offers',
        control: (_) => SettingSegmented<String>(
          options: [
            for (final m in ['pr', 'merge', 'both']) (m, _mergeModeLabels[m]!),
          ],
          value: s.draft.mergeMode,
          onChanged: (v) => s.edit((d) => d.copyWith(mergeMode: v)),
        ),
      ),
    ],
  );
}

SettingsTabSpec setupTab(SettingsController c) {
  final s = c.loadable<ScriptsConfig>(SettingsTab.setup);
  final v = s.original;
  return SettingsTabSpec(
    tab: SettingsTab.setup,
    title: 'Setup',
    intro: 'Commands each new workspace runs. Scripts get \$HARO_PORT, \$HARO_WORKSPACE_PATH and \$HARO_ROOT_PATH.',
    scope: SettingsScope.readOnly,
    banner: const _Notice(
      'Edit .haro/settings.local.toml directly; saving from here lands when the backend write is non-destructive.',
    ),
    rows: [
      SettingRowSpec(
        id: 'setup',
        label: 'Setup',
        help: 'Runs once when the worktree is created',
        stacked: true,
        control: (_) => SettingCodeView(_orNone(v?.setup)),
      ),
      SettingRowSpec(
        id: 'dev_server',
        label: 'Dev server',
        help: 'Started from the workspace rail',
        stacked: true,
        control: (_) => SettingCodeView(_orNone(v?.run)),
      ),
      SettingRowSpec(
        id: 'login_shell',
        label: 'Use login shell',
        help: 'Needed for nvm, asdf, pyenv',
        control: (_) => SettingToggle(
          value: v?.loginShell ?? false,
          semanticLabel: 'Use login shell',
          onChanged: null,
        ),
      ),
    ],
  );
}

String _orNone(String? v) => (v == null || v.isEmpty) ? '(none)' : v;

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Text(
      text,
      style: HaroText.ui(size: 13.5, color: HaroTokens.ink66, height: 1.5),
    ),
  );
}

/// "Save to" row for tabs whose writes go to the Team or the Personal file. Team is dimmed
/// and unselectable when haro cannot prove a Team write leaves the personal file's values
/// alone.
SettingRowSpec _saveToRow<T>(ConfigSection<ScopedDraft<T>> s) => SettingRowSpec(
  id: 'save_to',
  label: 'Save to',
  help: s.loaded && !s.draft.teamSafe
      ? 'Team is off: your personal file also sets values here, and a Team save would copy them into the committed file.'
      : s.loaded && s.draft.target == 'shared'
      ? 'Committed to the repo, shared with everyone on the project'
      : 'Only you, on this machine (gitignored)',
  control: (_) => SettingSegmented<String>(
    options: const [('local', 'Personal'), ('shared', 'Team')],
    value: s.draft.target,
    disabled: s.draft.teamSafe ? const {} : const {'shared'},
    onChanged: (t) => s.edit((d) => d.withTarget(t)),
  ),
);

const _runners = [
  ('vitest', 'Vitest'),
  ('pytest', 'pytest'),
  ('command', 'Command'),
  ('offense', 'Offense (JSON)'),
];

const _formats = [
  ('theme-check', 'shopify theme check'),
  ('eslint', 'eslint -f json'),
  ('ruff', 'ruff --output-format json'),
];

const _guards = [('off', 'Off'), ('warn', 'Warn'), ('block', 'Block')];

SettingsTabSpec gateTab(SettingsController c) {
  final s = c.config<ScopedDraft<GateConfig>>(SettingsTab.gate);
  void set(Map<String, dynamic> patch) => s.edit(
    (d) => d.withValue(GateConfig.fromJson({...d.value.toJson(), ...patch})),
  );
  bool usesCommand() =>
      s.draft.value.runner == 'command' || s.draft.value.runner == 'offense';
  return SettingsTabSpec(
    tab: SettingsTab.gate,
    title: 'Gate',
    intro: 'The project’s definition of correct. Every workspace inherits it and can’t merge until it is green.',
    scope: SettingsScope.team,
    summary: s.loaded ? _GateSentenceLine(gateSummary(s.draft.value)) : null,
    rows: [
      _saveToRow(s),
      SettingRowSpec(
        id: 'runner',
        section: 'Blocks merge',
        label: 'Runner',
        help: 'What runs to decide green',
        control: (_) => SettingSelect<String>(
          options: _runners,
          value: s.draft.value.runner,
          onChanged: (v) => set({'runner': v}),
        ),
      ),
      SettingRowSpec(
        id: 'command',
        label: 'Command',
        help: 'Shell command. Exit 0 is green, anything else is red.',
        visible: usesCommand,
        control: (_) => SettingInput(
          width: 320,
          value: s.draft.value.command,
          hint: 'npm run lint',
          onChanged: (v) => set({'command': v}),
        ),
      ),
      SettingRowSpec(
        id: 'format',
        label: 'Output format',
        help: 'How to read the offenses the command prints',
        visible: () => s.draft.value.runner == 'offense',
        control: (_) => SettingSelect<String>(
          options: _formats,
          value: s.draft.value.format,
          minWidth: 220,
          fallbackLabel: s.draft.value.format.isEmpty
              ? 'Choose a format'
              : null,
          onChanged: (v) => set({'format': v}),
        ),
      ),
      SettingRowSpec(
        id: 'gate_dir',
        label: 'Run in',
        help: 'Subfolder for monorepos',
        control: (_) => SettingInput(
          value: s.draft.value.gateDir,
          hint: 'repo root',
          onChanged: (v) => set({'gate_dir': v}),
        ),
      ),
      SettingRowSpec(
        id: 'scope',
        label: 'Scope',
        help: 'All tests is slower and always trustworthy',
        control: (_) => SettingSegmented<String>(
          options: const [('all', 'All tests'), ('impacted', 'Impacted only')],
          value: s.draft.value.defaultScope,
          onChanged: (v) => set({'default_scope': v}),
        ),
      ),
      SettingRowSpec(
        id: 'run_on_save',
        label: 'Run on save',
        help: 'The gate re-runs when you save a file in the code step',
        control: (_) => SettingToggle(
          value: s.draft.value.runOnSave,
          semanticLabel: 'Run on save',
          onChanged: (v) => set({'run_on_save': v}),
        ),
      ),
      SettingRowSpec(
        id: 'merge_result',
        label: 'Test the merge result',
        help: 'Run on the worktree merged onto the latest base',
        control: (_) => SettingToggle(
          value: s.draft.value.mergeResult,
          semanticLabel: 'Test the merge result',
          onChanged: (v) => set({'merge_result': v}),
        ),
      ),
      SettingRowSpec(
        id: 'flaky_rerun',
        label: 'Flaky guard',
        help: 'Re-run once on red; a pass on retry doesn’t block',
        control: (_) => SettingToggle(
          value: s.draft.value.flakyRerun,
          semanticLabel: 'Flaky guard',
          onChanged: (v) => set({'flaky_rerun': v}),
        ),
      ),
      SettingRowSpec(
        id: 'flaky_retry',
        label: 'Retry known-flaky tests',
        help: 'When every failure is a test already flagged flaky, retry just those once. Green if they pass, marked as retried.',
        control: (_) => SettingToggle(
          value: s.draft.value.flakyRetry,
          semanticLabel: 'Retry known-flaky tests',
          onChanged: (v) => set({'flaky_retry': v}),
        ),
      ),
      SettingRowSpec(
        id: 'known_flaky',
        label: 'Known-flaky tests',
        help: 'Flagged by the flaky check on a workspace. Remove one once it is fixed.',
        stacked: true,
        control: (_) => _KnownFlakyList(api: c.api, projectId: c.projectId!),
      ),
      SettingRowSpec(
        id: 'coverage_guard',
        label: 'Coverage guard',
        help: 'Block when coverage drops by more than the tolerance',
        control: (_) => SettingSegmented<String>(
          options: _guards,
          value: s.draft.value.coverageGuard,
          onChanged: (v) => set({'coverage_guard': v}),
        ),
      ),
      SettingRowSpec(
        id: 'coverage_tolerance',
        label: 'Coverage tolerance',
        help: 'Percentage points of drop allowed',
        visible: () => s.draft.value.coverageGuard != 'off',
        control: (_) => SettingNumberInput(
          value: s.draft.value.coverageTolerance,
          decimals: true,
          hint: '0',
          onChanged: (v) => set({'coverage_tolerance': v}),
        ),
      ),
      SettingRowSpec(
        id: 'tamper_alarm',
        label: 'Tamper alarm',
        help: 'Removed or skipped tests. Warn marks green*, block turns the gate red.',
        control: (_) => SettingSegmented<String>(
          options: _guards,
          value: s.draft.value.tamperAlarm,
          onChanged: (v) => set({'tamper_alarm': v}),
        ),
      ),
      SettingRowSpec(
        id: 'code_to_check',
        section: 'Advisory · never blocks',
        label: 'Things to look at',
        help: 'Added lines no test ran, files no test imports, removed tests, touched secrets',
        control: (_) => SettingToggle(
          value: s.draft.value.codeToCheck != 'off',
          semanticLabel: 'Things to look at',
          onChanged: (v) => set({'code_to_check': v ? 'warn' : 'off'}),
        ),
      ),
      SettingRowSpec(
        id: 'verified_hunks',
        label: 'Per-line proof',
        help: 'Mark which added lines the green suite ran in the ship diff',
        control: (_) => SettingToggle(
          value: s.draft.value.verifiedHunks,
          semanticLabel: 'Per-line proof',
          onChanged: (v) => set({'verified_hunks': v}),
        ),
      ),
      SettingRowSpec(
        id: 'secrets_scan',
        label: 'Secrets scan',
        help: 'Flags possible credentials in the diff with gitleaks, if it’s installed. Never blocks.',
        control: (_) => SettingToggle(
          value: s.draft.value.secretsScan,
          semanticLabel: 'Secrets scan',
          onChanged: (v) => set({'secrets_scan': v}),
        ),
      ),
      SettingRowSpec(
        id: 'watch',
        label: 'Live Gate',
        help: 'Impacted-only run on every save. Costs CPU while you edit.',
        control: (_) => SettingToggle(
          value: s.draft.value.watch,
          semanticLabel: 'Live Gate',
          onChanged: (v) => set({'watch': v}),
        ),
      ),
      SettingRowSpec(
        id: 'mutation',
        label: 'Mutation score',
        help: 'Plant small mistakes in the diff and check the tests notice. Runs on demand.',
        control: (_) => SettingToggle(
          value: s.draft.value.mutation,
          semanticLabel: 'Mutation score',
          onChanged: (v) => set({'mutation': v}),
        ),
      ),
    ],
  );
}

class _KnownFlakyList extends StatefulWidget {
  const _KnownFlakyList({required this.api, required this.projectId});

  final HaroApi api;
  final String projectId;

  @override
  State<_KnownFlakyList> createState() => _KnownFlakyListState();
}

class _KnownFlakyListState extends State<_KnownFlakyList> {
  List<KnownFlakyTest>? _tests;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tests = await widget.api.getKnownFlaky(widget.projectId);
      if (mounted) setState(() => _tests = tests);
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _remove(KnownFlakyTest t) async {
    try {
      await widget.api.removeKnownFlaky(widget.projectId, t);
      if (mounted) {
        setState(
          () => _tests = [
            for (final k in _tests ?? const <KnownFlakyTest>[])
              if (k.file != t.file || k.name != t.name) k,
          ],
        );
      }
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tests = _tests;
    final style = HaroText.ui(size: 13, color: HaroTokens.ink66);
    if (_error != null) return Text(_error!, style: style);
    if (tests == null) return Text('Loading…', style: style);
    if (tests.isEmpty) return Text('None flagged.', style: style);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final t in tests)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${t.name}  ${t.file}',
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.mono(size: 12, color: HaroTokens.ink66),
                  ),
                ),
                HaroButton(
                  label: 'Remove',
                  variant: HaroButtonVariant.tertiary,
                  onPressed: () => _remove(t),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The one place green appears in Settings: it is the gate's own colour, and this line is
/// about what the gate calls green.
class _GateSentenceLine extends StatelessWidget {
  const _GateSentenceLine(this.summary);

  final GateSentence summary;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 20),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: HaroTokens.bg,
      border: Border.all(color: HaroTokens.line12),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Row(
      children: [
        Container(width: 8, height: 8, color: HaroTokens.gate),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: HaroText.ui(size: 14, height: 1.5),
              children: [
                TextSpan(text: summary.lead),
                TextSpan(
                  text: summary.strong,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                TextSpan(text: summary.tail),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

const _models = [
  ('opus', 'Opus'),
  ('sonnet', 'Sonnet'),
  ('haiku', 'Haiku'),
  ('fable', 'Fable'),
];

const _efforts = [
  ('', 'default'),
  ('low', 'low'),
  ('medium', 'medium'),
  ('high', 'high'),
  ('xhigh', 'xhigh'),
  ('max', 'max'),
];

SettingsTabSpec agentTab(SettingsController c) {
  final s = c.config<ScopedDraft<AgentConfig>>(SettingsTab.agent);
  void set(Map<String, dynamic> patch) => s.edit(
    (d) => d.withValue(AgentConfig.fromJson({...d.value.toJson(), ...patch})),
  );
  bool local() => s.loaded && s.draft.value.adapter == 'local';
  return SettingsTabSpec(
    tab: SettingsTab.agent,
    title: 'Agent',
    intro: 'Defaults for every run. A model or effort picked in the composer still wins.',
    scope: SettingsScope.team,
    rows: [
      _saveToRow(s),
      SettingRowSpec(
        id: 'adapter',
        section: 'Model',
        label: 'Backend',
        help: 'Cloud Claude Code, or a local OpenAI-compatible server',
        control: (_) => SettingSelect<String>(
          options: const [
            ('claude-code', 'Claude Code (cloud)'),
            ('local', 'Local model (Ollama, llama.cpp)'),
          ],
          value: s.draft.value.adapter,
          minWidth: 240,
          onChanged: (v) => set({'adapter': v}),
        ),
      ),
      SettingRowSpec(
        id: 'default_model',
        label: 'Default model',
        help: 'Opus is ~5× the cost; keep it for hard tasks',
        dimmed: local(),
        control: (_) => SettingSegmented<String>(
          options: _models,
          value: s.draft.value.defaultModel,
          onChanged: (v) => set({'default_model': v}),
        ),
      ),
      SettingRowSpec(
        id: 'default_effort',
        label: 'Effort',
        help: 'More effort spends more thinking tokens',
        dimmed: local(),
        control: (_) => SettingSegmented<String>(
          options: _efforts,
          value: s.draft.value.defaultEffort,
          onChanged: (v) => set({'default_effort': v}),
        ),
      ),
      SettingRowSpec(
        id: 'max_budget',
        section: 'Guardrails',
        label: 'Stop a run above',
        help: 'Hard ceiling per run, in USD',
        dimmed: local(),
        control: (_) => SettingNumberInput(
          value: s.draft.value.maxBudgetUsd,
          decimals: true,
          hint: 'no limit',
          onChanged: (v) => set({'max_budget_usd': v}),
        ),
      ),
      SettingRowSpec(
        id: 'cost_warn',
        label: 'Warn when a workspace passes',
        help: 'Soft heads-up on total spend, in USD',
        control: (_) => SettingNumberInput(
          value: s.draft.value.costWarnUsd,
          decimals: true,
          hint: 'off',
          onChanged: (v) => set({'cost_warn_usd': v}),
        ),
      ),
      SettingRowSpec(
        id: 'max_parallel',
        label: 'Agents at once',
        help: 'Across all projects. Extra runs wait in a queue.',
        control: (_) => SettingNumberInput(
          value: s.draft.value.maxParallel,
          hint: 'no limit',
          onChanged: (v) => set({'max_parallel': v.round()}),
        ),
      ),
      SettingRowSpec(
        id: 'protect_tests',
        label: 'Protect existing tests',
        help:
            'Refuses the agent’s file edits on tests that already exist; new tests stay '
            'writable (past 500 test files, patterns like *.test.ts also refuse new ones). '
            'Its shell can still write them; the tamper alarm checks the diff either way.',
        dimmed: local(),
        control: (_) => SettingToggle(
          value: s.draft.value.protectTests == 'existing',
          semanticLabel: 'Protect existing tests',
          onChanged: (v) => set({'protect_tests': v ? 'existing' : 'off'}),
        ),
      ),
      SettingRowSpec(
        id: 'local_base_url',
        section: 'Local model',
        label: 'Server URL',
        help: 'OpenAI-compatible endpoint (Ollama, llama.cpp)',
        dimmed: s.loaded && !local(),
        control: (_) => SettingInput(
          width: 320,
          value: s.draft.value.localBaseUrl,
          hint: 'http://localhost:11434/v1',
          onChanged: (v) => set({'local_base_url': v}),
        ),
      ),
      SettingRowSpec(
        id: 'local_model',
        label: 'Model',
        help: 'The model tag the server should run',
        dimmed: s.loaded && !local(),
        control: (_) => SettingInput(
          value: s.draft.value.localModel,
          hint: 'qwen2.5-coder',
          onChanged: (v) => set({'local_model': v}),
        ),
      ),
    ],
  );
}

SettingsTabSpec rolesTab(SettingsController c) {
  final s = c.config<ScopedDraft<RolesConfig>>(SettingsTab.roles);
  void set(Map<String, dynamic> patch) => s.edit(
    (d) => d.withValue(RolesConfig.fromJson({...d.value.toJson(), ...patch})),
  );
  bool off() => s.loaded && !s.draft.value.enabled;

  Widget pick(String field, String value, {bool effort = true}) {
    final (model, eff) = splitRole(value);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingSelect<String>(
          minWidth: 150,
          options: const [('', 'Agent default'), ..._models],
          value: model,
          fallbackLabel: model,
          onChanged: (m) => set({field: joinRole(m, effortFor(m, eff))}),
        ),
        if (effort && model.isNotEmpty) ...[
          const SizedBox(width: 8),
          SettingSelect<String>(
            minWidth: 100,
            options: _efforts,
            value: eff,
            fallbackLabel: eff,
            onChanged: (e) => set({field: joinRole(model, e)}),
          ),
        ],
      ],
    );
  }

  return SettingsTabSpec(
    tab: SettingsTab.roles,
    title: 'Roles',
    intro: 'Most people never open this page.',
    scope: SettingsScope.team,
    footer: s.loaded ? _ConfigPreview(rolesToml(s.draft.value)) : null,
    rows: [
      _saveToRow(s),
      SettingRowSpec(
        id: 'enabled',
        label: 'Use roles',
        help: 'Off falls back to the single default model on the Agent page',
        control: (_) => SettingToggle(
          value: s.draft.value.enabled,
          semanticLabel: 'Use roles',
          onChanged: (v) => v
              ? s.edit((d) => d.withValue(enableRoles(d.value)))
              : set({'enabled': false}),
        ),
      ),
      SettingRowSpec(
        id: 'plan',
        label: 'Plan',
        help: 'Runs when “plan first” is on',
        dimmed: off(),
        control: (_) => pick('plan', s.draft.value.plan),
      ),
      SettingRowSpec(
        id: 'build',
        label: 'Build',
        help: 'Everything else, including “approve plan”',
        dimmed: off(),
        control: (_) => pick('build', s.draft.value.build),
      ),
      SettingRowSpec(
        id: 'review',
        label: 'Review',
        help: 'The model used by Review with AI on the ship step. Advisory, never part of the gate.',
        dimmed: off(),
        control: (_) => pick('review', s.draft.value.review),
      ),
      SettingRowSpec(
        id: 'scout',
        label: 'Scout',
        help: 'Read-only helper that maps the repo first',
        dimmed: off(),
        control: (_) => pick('scout', s.draft.value.scout, effort: false),
      ),
    ],
  );
}

class _ConfigPreview extends StatefulWidget {
  const _ConfigPreview(this.text);

  final String text;

  @override
  State<_ConfigPreview> createState() => _ConfigPreviewState();
}

class _ConfigPreviewState extends State<_ConfigPreview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IntrinsicWidth(
          child: HaroButton(
            label: _open ? 'Hide config' : 'View config',
            variant: HaroButtonVariant.tertiary,
            padding: EdgeInsets.zero,
            onPressed: () => setState(() => _open = !_open),
          ),
        ),
        if (_open) ...[const SizedBox(height: 8), SettingCodeView(widget.text)],
      ],
    ),
  );
}

SettingsTabSpec environmentTab(SettingsController c) {
  final s = c.config<String>(SettingsTab.environment);
  return SettingsTabSpec(
    tab: SettingsTab.environment,
    title: 'Environment',
    intro: 'Seeded into every new workspace’s .env. A fresh worktree doesn’t carry your gitignored secrets, so paste them once here.',
    scope: SettingsScope.env,
    rows: [
      SettingRowSpec(
        id: 'env',
        label: '.haro/.env',
        help:
            'Existing workspaces keep their own copy. Empty removes the seed.',
        stacked: true,
        control: (_) => SettingCodeEditor(
          value: s.draft,
          hint: 'API_KEY=…\nDATABASE_URL=…',
          minLines: 8,
          maxLines: 16,
          onChanged: (v) => s.edit((_) => v),
        ),
      ),
    ],
  );
}

SettingsTabSpec instructionsTab(SettingsController c) {
  final s = c.config<InstructionsDraft>(SettingsTab.instructions);
  return SettingsTabSpec(
    tab: SettingsTab.instructions,
    title: 'Instructions',
    intro: 'A standing prompt appended to every agent run in this project. Team first, then personal.',
    scope: s.scope,
    rows: [
      SettingRowSpec(
        id: 'instructions_scope',
        label: 'Scope',
        help: 'Team is committed for everyone. Personal stays on this machine.',
        control: (_) => SettingSegmented<String>(
          options: const [('local', 'Personal'), ('shared', 'Team')],
          value: s.draft.scope,
          onChanged: (v) => s.edit((d) => d.withScope(v)),
        ),
      ),
      SettingRowSpec(
        id: 'instructions_prompt',
        label: 'Prompt',
        help: 'Markdown. Applies from the next agent run.',
        stacked: true,
        control: (_) => SettingCodeEditor(
          key: ValueKey(s.draft.scope),
          value: s.draft.text,
          hint: 'Standing instructions the agent follows every run…',
          minLines: 12,
          maxLines: 18,
          onChanged: (v) => s.edit((d) => d.withText(v)),
        ),
      ),
    ],
  );
}
