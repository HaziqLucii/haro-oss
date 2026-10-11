import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/state/diff_stats.dart';
import 'package:haro_app/state/workspace_flow.dart';

import '../api/fixtures.dart';

const bigDiff = DiffStats(files: 21, added: 367, removed: 130);

TestRun run({
  String status = 'passed',
  int total = 594,
  int passed = 594,
  int failed = 0,
  List<Map<String, dynamic>> cases = const [],
  List<Map<String, dynamic>> tamper = const [],
  Object? unchecked = const <Object>[],
  Map<String, dynamic>? overrides,
}) => TestRun.fromJson(
  testRunJson(
    status: status,
    total: total,
    passed: passed,
    failed: failed,
    cases: cases,
    tamper: tamper,
    unchecked: unchecked,
    overrides: overrides,
  ),
);

TestRun redRun({
  int failed = 3,
  int total = 16,
  List<Map<String, dynamic>> tamper = const [],
}) => run(
  status: 'failed',
  total: total,
  passed: total - failed,
  failed: failed,
  unchecked: null,
  tamper: tamper,
  cases: [
    for (var i = 0; i < failed; i++)
      caseJson(
        'case $i',
        'failed',
        file: 'lib/shipping.test.ts',
        message: 'expected 0, received 499\n  at line',
      ),
    caseJson('ok', 'passed', file: 'lib/shipping.test.ts'),
  ],
);

Map<String, dynamic> untestedRow(String file, int count) => {
  'kind': 'untested_lines',
  'file': file,
  'detail': '$count added lines never executed',
  'count': count,
  'key': 'untested_lines:$file:$count',
};

Map<String, dynamic> vacuousRow(String file, String test) => {
  'kind': 'vacuous_test',
  'file': file,
  'detail':
      '$test already passes on main: it guards existing behaviour, not this change',
  'count': 0,
  'key': 'vacuous_test:$file:$test',
};

Map<String, dynamic> secretRow(
  String file,
  int line, {
  String rule = 'aws-access-token',
}) => {
  'kind': 'secret_found',
  'file': file,
  'line': line,
  'rule': rule,
  'detail': 'possible credential',
  'count': 0,
  'key': 'secret_found:$file:$line:$rule',
};

Map<String, dynamic> removedTest = {
  'kind': 'removed',
  'file': 'lib/shipping.test.ts',
  'detail': 'test deleted',
  'test': 'is free at exactly the \$100 boundary',
};

FlowInput input(
  WorkspaceStatus status, {
  AgentPhase agent = AgentPhase.done,
  bool activity = true,
  DiffStats diff = bigDiff,
  TestRun? run,
  List<Cell> cells = const [],
  GateSummary? summary,
  Duration? elapsed = const Duration(minutes: 14),
  bool planReady = false,
  bool waiting = false,
  int? pr,
  int? expectedTotal,
  List<String> checked = const [],
  String? activityFile,
  String? planText,
  WorkspaceKind kind = WorkspaceKind.managed,
  TestFirstState? testFirst,
  WorkspaceMode mode = WorkspaceMode.agent,
}) => FlowInput(
  mode: mode,
  status: status,
  kind: kind,
  agent: agent,
  hasAgentActivity: activity,
  planReady: planReady,
  waitingOnInput: waiting,
  agentElapsed: elapsed,
  agentActivity: activityFile,
  planText: planText,
  testFirst: testFirst,
  diff: diff,
  run: run,
  cells: cells,
  summary: summary,
  expectedTotal: expectedTotal,
  checkedKeys: checked,
  prNumber: pr,
);

List<Cell> cells(int done, {int running = 0, int failed = 0}) => [
  for (var i = 0; i < done; i++)
    Cell.fromJson(cellJson('c$i', i < failed ? 'failed' : 'passed')),
  for (var i = 0; i < running; i++) Cell.fromJson(cellJson('r$i', 'running')),
];

String ticks(WorkspaceFlow f) => f.steps
    .map(
      (s) => switch (s.tick) {
        StepStatus.pending => 'o',
        StepStatus.current => 'c',
        StepStatus.done => 'd',
        StepStatus.red => 'r',
        StepStatus.green => 'g',
        StepStatus.merged => 'm',
      },
    )
    .join();

List<String> lines(WorkspaceFlow f) => f.steps.map((s) => s.line).toList();

class DiffStatsEmpty {
  const DiffStatsEmpty();
  DiffStats get value => DiffStats.empty;
}
