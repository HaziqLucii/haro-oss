import 'json_util.dart';

class Project {
  const Project({
    required this.id,
    required this.name,
    required this.path,
    required this.defaultBranch,
    this.remoteUrl,
    this.autoPull = true,
    this.pullBranch = '',
    this.stack = const [],
  });

  final String id;
  final String name;
  final String path;
  final String defaultBranch;

  /// `origin` URL if linked to a remote, else `null` (local-only).
  final String? remoteUrl;

  /// Whether haro may fast-forward the checkout in the background. Off: only "Pull now" does.
  final bool autoPull;

  /// Branch kept level with origin; empty follows [defaultBranch].
  final String pullBranch;

  /// Tech-stack logo ids (e.g. `vuejs`, `laravel`).
  final List<String> stack;

  factory Project.fromJson(Json j) => Project(
    id: jStr(j, 'id'),
    name: jStr(j, 'name'),
    path: jStr(j, 'path'),
    defaultBranch: jStr(j, 'default_branch'),
    remoteUrl: jStrN(j, 'remote_url'),
    autoPull: jBool(j, 'auto_pull', true),
    pullBranch: jStr(j, 'pull_branch'),
    stack: jStrList(j, 'stack'),
  );
}

class RemoteConfig {
  const RemoteConfig({this.url, this.webUrl});

  final String? url;

  /// Browsable base (`https://host/owner/repo`); `null` when local-only or unrecognized.
  final String? webUrl;

  factory RemoteConfig.fromJson(Json j) =>
      RemoteConfig(url: jStrN(j, 'url'), webUrl: jStrN(j, 'web_url'));
}

/// Config classes keep enum-like fields as strings so an unknown value round-trips through
/// a PUT untouched. The `*Options` constants list the values the backend documents.
class WorkflowConfig {
  const WorkflowConfig({this.mergeMode = 'both'});

  static const mergeModeOptions = ['both', 'pr', 'merge'];

  final String mergeMode;

  factory WorkflowConfig.fromJson(Json j) =>
      WorkflowConfig(mergeMode: jStr(j, 'merge_mode', 'both'));

  Json toJson() => {'merge_mode': mergeMode};
}

class GateConfig {
  const GateConfig({
    this.runner = 'vitest',
    this.command = '',
    this.format = '',
    this.gateDir = '',
    this.defaultScope = 'all',
    this.mergeResult = false,
    this.flakyRerun = false,
    this.coverageGuard = 'off',
    this.coverageTolerance = 0,
    this.tamperAlarm = 'warn',
    this.codeToCheck = 'warn',
    this.watch = false,
    this.verifiedHunks = true,
    this.secretsScan = true,
    this.runOnSave = false,
    this.autoRun = false,
  });

  static const runnerOptions = ['vitest', 'pytest', 'command', 'offense'];
  static const scopeOptions = ['all', 'impacted'];
  static const guardOptions = ['off', 'warn', 'block'];

  final String runner;
  final String command;
  final String format;
  final String gateDir;
  final String defaultScope;
  final bool mergeResult;
  final bool flakyRerun;
  final String coverageGuard;
  final double coverageTolerance;

  /// `off` | `warn` | `block`. `block` makes a tampered suite red.
  final String tamperAlarm;

  /// `off` | `warn`. There is deliberately no `block`.
  final String codeToCheck;

  /// Live Gate: advisory impacted-only loop, off by default.
  final bool watch;
  final bool verifiedHunks;

  /// Advisory gitleaks pass over the diff; never blocks.
  final bool secretsScan;

  /// The code editor's save also starts a gate run. Off by default: a save then spends a test run.
  final bool runOnSave;

  /// The gate starts by itself when an agent run finishes. Off by default: it is a step you start.
  final bool autoRun;

  factory GateConfig.fromJson(Json j) => GateConfig(
    runner: jStr(j, 'runner', 'vitest'),
    command: jStr(j, 'command'),
    format: jStr(j, 'format'),
    gateDir: jStr(j, 'gate_dir'),
    defaultScope: jStr(j, 'default_scope', 'all'),
    mergeResult: jBool(j, 'merge_result'),
    flakyRerun: jBool(j, 'flaky_rerun'),
    coverageGuard: jStr(j, 'coverage_guard', 'off'),
    coverageTolerance: jDouble(j, 'coverage_tolerance'),
    tamperAlarm: jStr(j, 'tamper_alarm', 'warn'),
    codeToCheck: jStr(j, 'code_to_check', 'warn'),
    watch: jBool(j, 'watch'),
    verifiedHunks: jBool(j, 'verified_hunks', true),
    secretsScan: jBool(j, 'secrets_scan', true),
    runOnSave: jBool(j, 'run_on_save'),
    autoRun: jBool(j, 'auto_run'),
  );

  Json toJson() => {
    'runner': runner,
    'command': command,
    'format': format,
    'gate_dir': gateDir,
    'default_scope': defaultScope,
    'merge_result': mergeResult,
    'flaky_rerun': flakyRerun,
    'coverage_guard': coverageGuard,
    'coverage_tolerance': coverageTolerance,
    'tamper_alarm': tamperAlarm,
    'code_to_check': codeToCheck,
    'watch': watch,
    'verified_hunks': verifiedHunks,
    'secrets_scan': secretsScan,
    'run_on_save': runOnSave,
    'auto_run': autoRun,
  };
}

class AgentConfig {
  const AgentConfig({
    this.defaultModel = 'sonnet',
    this.defaultEffort = '',
    this.maxBudgetUsd = 0,
    this.costWarnUsd = 0,
    this.maxParallel = 0,
    this.protectTests = 'off',
    this.adapter = 'claude-code',
    this.localBaseUrl = '',
    this.localModel = '',
  });

  static const modelOptions = ['opus', 'sonnet', 'haiku', 'fable'];
  static const effortOptions = ['', 'low', 'medium', 'high', 'xhigh', 'max'];
  static const adapterOptions = ['claude-code', 'local'];

  final String defaultModel;
  final String defaultEffort;
  final double maxBudgetUsd;
  final double costWarnUsd;

  /// Agent subprocesses allowed at once install-wide; 0 = unlimited.
  final int maxParallel;

  /// `off` | `existing`: deny the agent's Edit/Write tools on test files tracked at the base
  /// ref. A speed bump, not a guarantee: the agent's shell can still write them.
  final String protectTests;
  final String adapter;
  final String localBaseUrl;
  final String localModel;

  factory AgentConfig.fromJson(Json j) => AgentConfig(
    defaultModel: jStr(j, 'default_model', 'sonnet'),
    defaultEffort: jStr(j, 'default_effort'),
    maxBudgetUsd: jDouble(j, 'max_budget_usd'),
    costWarnUsd: jDouble(j, 'cost_warn_usd'),
    maxParallel: jInt(j, 'max_parallel'),
    protectTests: jStr(j, 'protect_tests', 'off'),
    adapter: jStr(j, 'adapter', 'claude-code'),
    localBaseUrl: jStr(j, 'local_base_url'),
    localModel: jStr(j, 'local_model'),
  );

  Json toJson() => {
    'default_model': defaultModel,
    'default_effort': defaultEffort,
    'max_budget_usd': maxBudgetUsd,
    'cost_warn_usd': costWarnUsd,
    'max_parallel': maxParallel,
    'protect_tests': protectTests,
    'adapter': adapter,
    'local_base_url': localBaseUrl,
    'local_model': localModel,
  };
}

/// Each role is its `model:effort` shorthand (`fable:xhigh`, or just `haiku`); an empty
/// string means "fall back to the Agent tab's default".
class RolesConfig {
  const RolesConfig({
    this.enabled = false,
    this.plan = '',
    this.build = '',
    this.review = '',
    this.scout = '',
  });

  final bool enabled;
  final String plan;
  final String build;
  final String review;
  final String scout;

  factory RolesConfig.fromJson(Json j) => RolesConfig(
    enabled: jBool(j, 'enabled'),
    plan: jStr(j, 'plan'),
    build: jStr(j, 'build'),
    review: jStr(j, 'review'),
    scout: jStr(j, 'scout'),
  );

  Json toJson() => {
    'enabled': enabled,
    'plan': plan,
    'build': build,
    'review': review,
    'scout': scout,
  };
}

class LocalModelsResponse {
  const LocalModelsResponse({
    required this.reachable,
    this.models = const [],
    this.baseUrl = '',
  });

  final bool reachable;
  final List<String> models;
  final String baseUrl;

  factory LocalModelsResponse.fromJson(Json j) => LocalModelsResponse(
    reachable: jBool(j, 'reachable'),
    models: jStrList(j, 'models'),
    baseUrl: jStr(j, 'base_url'),
  );
}

class EnvConfig {
  const EnvConfig({this.content = ''});

  final String content;

  factory EnvConfig.fromJson(Json j) => EnvConfig(content: jStr(j, 'content'));
}

class InstructionsConfig {
  const InstructionsConfig({this.shared = '', this.local = ''});

  /// Committed, team-wide.
  final String shared;

  /// Personal, gitignored.
  final String local;

  factory InstructionsConfig.fromJson(Json j) =>
      InstructionsConfig(shared: jStr(j, 'shared'), local: jStr(j, 'local'));
}

class RunScriptInfo {
  const RunScriptInfo({
    required this.id,
    this.command = '',
    this.isDefault = false,
    this.icon,
    this.running = false,
    this.url,
    this.problem,
  });

  final String id;
  final String command;
  final bool isDefault;
  final String? icon;
  final bool running;
  final String? url;

  /// Why the command cannot start, from a static read of `package.json` (for example
  /// "no `dev` script in package.json"). Null means nothing was found missing, not that
  /// the command works.
  final String? problem;

  factory RunScriptInfo.fromJson(Json j) => RunScriptInfo(
    id: jStr(j, 'id'),
    command: jStr(j, 'command'),
    isDefault: jBool(j, 'default'),
    icon: jStrN(j, 'icon'),
    running: jBool(j, 'running'),
    url: jStrN(j, 'url'),
    problem: jStrN(j, 'problem'),
  );
}

class ScriptsConfig {
  const ScriptsConfig({
    this.setup,
    this.run,
    this.runs = const [],
    this.archive,
    this.runMode = '',
    this.loginShell = false,
  });

  final String? setup;

  /// The default run command.
  final String? run;

  /// All named runs. Read-only display data; not sent back on save.
  final List<RunScriptInfo> runs;
  final String? archive;
  final String runMode;
  final bool loginShell;

  factory ScriptsConfig.fromJson(Json j) => ScriptsConfig(
    setup: jStrN(j, 'setup'),
    run: jStrN(j, 'run'),
    runs: jList(j, 'runs', RunScriptInfo.fromJson),
    archive: jStrN(j, 'archive'),
    runMode: jStr(j, 'run_mode'),
    loginShell: jBool(j, 'login_shell'),
  );

  Json toJson() => {
    'setup': setup,
    'run': run,
    'archive': archive,
    'run_mode': runMode,
    'login_shell': loginShell,
  };
}

enum SetupStatus {
  running('running'),
  ok('ok'),
  failed('failed'),
  unknown('unknown');

  const SetupStatus(this.wire);
  final String wire;

  static SetupStatus parse(Object? raw) =>
      enumFromWire(values, (e) => e.wire, raw, unknown);
}

class SetupState {
  const SetupState({
    required this.status,
    this.exit,
    this.note,
    this.tail = '',
  });

  final SetupStatus status;
  final int? exit;
  final String? note;

  /// The last lines the setup script printed, kept when it failed.
  final String tail;

  factory SetupState.fromJson(Json j) => SetupState(
    status: SetupStatus.parse(j['status']),
    exit: jIntN(j, 'exit'),
    note: jStrN(j, 'note'),
    tail: jStr(j, 'tail'),
  );
}

class StackPreset {
  const StackPreset({
    required this.id,
    required this.label,
    this.blurb = '',
    this.setup,
    this.run,
    this.gate = const {},
    this.toml = '',
  });

  final String id;
  final String label;
  final String blurb;
  final String? setup;
  final String? run;
  final Map<String, String> gate;

  /// The settings.toml fragment this preset would write, for inspection.
  final String toml;

  factory StackPreset.fromJson(Json j) => StackPreset(
    id: jStr(j, 'id'),
    label: jStr(j, 'label'),
    blurb: jStr(j, 'blurb'),
    setup: jStrN(j, 'setup'),
    run: jStrN(j, 'run'),
    gate: {
      for (final e in asJson(j['gate']).entries)
        if (e.value != null) e.key: '${e.value}',
    },
    toml: jStr(j, 'toml'),
  );
}

class StackCandidate {
  const StackCandidate({required this.preset, this.confidence = 0});

  final StackPreset preset;

  /// 0 to 1.
  final double confidence;

  factory StackCandidate.fromJson(Json j) => StackCandidate(
    preset: StackPreset.fromJson(asJson(j['preset'])),
    confidence: jDouble(j, 'confidence'),
  );
}

class StackDetection {
  const StackDetection({
    this.ambiguous = false,
    this.proposal,
    this.candidates = const [],
  });

  final bool ambiguous;

  /// A clear winner to auto-fill; `null` when ambiguous.
  final StackCandidate? proposal;
  final List<StackCandidate> candidates;

  factory StackDetection.fromJson(Json j) => StackDetection(
    ambiguous: jBool(j, 'ambiguous'),
    proposal: j['proposal'] is Map
        ? StackCandidate.fromJson(asJson(j['proposal']))
        : null,
    candidates: jList(j, 'candidates', StackCandidate.fromJson),
  );
}

class FsEntry {
  const FsEntry({
    required this.name,
    required this.path,
    this.isGitRepo = false,
  });

  final String name;
  final String path;
  final bool isGitRepo;

  factory FsEntry.fromJson(Json j) => FsEntry(
    name: jStr(j, 'name'),
    path: jStr(j, 'path'),
    isGitRepo: jBool(j, 'is_git_repo'),
  );
}

class FsListing {
  const FsListing({
    required this.root,
    required this.path,
    this.parent,
    this.isGitRepo = false,
    this.entries = const [],
  });

  final String root;
  final String path;
  final String? parent;
  final bool isGitRepo;
  final List<FsEntry> entries;

  factory FsListing.fromJson(Json j) => FsListing(
    root: jStr(j, 'root'),
    path: jStr(j, 'path'),
    parent: jStrN(j, 'parent'),
    isGitRepo: jBool(j, 'is_git_repo'),
    entries: jList(j, 'entries', FsEntry.fromJson),
  );
}

class BranchList {
  const BranchList({this.branches = const [], this.defaultBranch = ''});

  final List<String> branches;
  final String defaultBranch;

  factory BranchList.fromJson(Json j) => BranchList(
    branches: jStrList(j, 'branches'),
    defaultBranch: jStr(j, 'default'),
  );
}

class FirewallResult {
  const FirewallResult({
    this.firewall = 'off',
    this.strict = false,
    this.hooks = const [],
    this.configPath = '',
  });

  final String firewall;
  final bool strict;
  final List<String> hooks;
  final String configPath;

  factory FirewallResult.fromJson(Json j) => FirewallResult(
    firewall: jStr(j, 'firewall', 'off'),
    strict: jBool(j, 'strict'),
    hooks: jStrList(j, 'hooks'),
    configPath: jStr(j, 'config_path'),
  );
}

/// The newest result of haro's automatic checkout sync (`GET/POST /projects/{id}/sync`): why
/// the project's main checkout was or was not fast-forwarded to origin.
class ProjectSync {
  const ProjectSync({
    this.state,
    this.branch,
    this.defaultBranch = 'main',
    this.behind = 0,
    this.ahead = 0,
    this.pulled = 0,
    this.detail,
  });

  /// `pulled` | `up_to_date` | `no_remote` | `fetch_failed` | `other_branch` | `dirty` |
  /// `diverged` | `blocked`; null before the first sync has run.
  final String? state;
  final String? branch;
  final String defaultBranch;
  final int behind;
  final int ahead;
  final int pulled;
  final String? detail;

  factory ProjectSync.fromJson(Json j) => ProjectSync(
    state: jStrN(j, 'state'),
    branch: jStrN(j, 'branch'),
    defaultBranch: jStr(j, 'default_branch', 'main'),
    behind: jInt(j, 'behind'),
    ahead: jInt(j, 'ahead'),
    pulled: jInt(j, 'pulled'),
    detail: jStrN(j, 'detail'),
  );
}
