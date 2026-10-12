import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_transcript.dart';

import 'agent_events.dart';

void main() {
  group('groupTurns', () {
    test('splits at user events and keeps markers', () {
      final g = groupTurns([
        userEv('one', turn: 1),
        tokEv('a'),
        doneEv(),
        userEv('two', turn: 2),
        tokEv('b', turn: 2),
        userEv('fix', turn: 3, runId: 'autofix'),
        tokEv('c', turn: 3),
      ]);
      expect(g, hasLength(3));
      expect(g.map((x) => x.marker?.turn), [1, 2, 3]);
      expect(g.map((x) => x.marker?.kind), ['user', 'user', 'autofix']);
      expect(g.map((x) => x.events.length), [2, 1, 1]);
    });

    test('events before any user event form a marker-less group', () {
      final g = groupTurns([tokEv('legacy'), userEv('now', turn: 2)]);
      expect(g, hasLength(2));
      expect(g.first.user, isNull);
      expect(g.first.marker, isNull);
      expect(g.last.marker?.prompt, 'now');
    });

    test('a user event alone is still a turn', () {
      expect(groupTurns([userEv('just started')]), hasLength(1));
      expect(groupTurns(const []), isEmpty);
    });
  });

  group('deriveStreamRows', () {
    test('prototype transcript', () {
      final rows = deriveStreamRows(
        prototypeTranscript(),
        worktreePath: '/Users/dev/.haro/worktrees/electron',
      );
      expect(rows.map((r) => r.runtimeType.toString()), [
        'UserRow',
        'AgentLabelRow',
        'ToolRow',
        'ToolRow',
        'ProseRow',
        'ToolRow',
        'ToolRow',
        'ToolRow',
        'ToolRow',
        'ProseRow',
        'FooterRow',
      ]);
      expect(
        (rows[1] as AgentLabelRow).text,
        'AGENT · build · sonnet-5 · high',
      );
      // Streamed chunks fold into one markdown block.
      expect(
        (rows[4] as ProseRow).text,
        'Boot takes 3.4s. Most of it is a blocking PATH scrape. '
        'I will make the scrape async.',
      );
      final edit = rows[5] as ToolRow;
      expect(edit.tool, 'Edit');
      expect(edit.target, 'desktop/main.js');
      expect(edit.added, 211);
      expect(edit.removed, 134);
      expect(
        (rows.last as FooterRow).text,
        'done in 14m 1s · 3 files · \$9.89',
      );
    });

    test('effort None and a missing role are left out of the label', () {
      final rows = deriveStreamRows([
        userEv('x'),
        metaEv(effort: 'None', role: null, model: 'claude-fable-5-1'),
        tokEv('hi'),
      ]);
      expect((rows[1] as AgentLabelRow).text, 'AGENT · fable-5-1');
    });

    test('a transcript without meta still labels the agent', () {
      final rows = deriveStreamRows([userEv('x'), tokEv('hi')]);
      expect((rows[1] as AgentLabelRow).text, 'AGENT');
    });

    test('each turn carries its own label', () {
      final rows = deriveStreamRows([
        userEv('plan it', turn: 1),
        metaEv(role: 'plan', model: 'claude-opus-5', turn: 1),
        tokEv('plan', turn: 1),
        doneEv(plan: true, turn: 1),
        userEv('go', turn: 2),
        metaEv(role: 'build', turn: 2),
        tokEv('built', turn: 2),
      ]);
      final labels = rows.whereType<AgentLabelRow>().map((r) => r.text);
      expect(labels, [
        'AGENT · plan · opus-5 · high',
        'AGENT · build · sonnet-5 · high',
      ]);
    });

    test('only the newest tool line is running while the agent runs', () {
      final events = [userEv('x'), toolEv('Read', 'a'), toolEv('Bash', 'b')];
      final live = deriveStreamRows(events, running: true);
      expect(live.whereType<ToolRow>().map((r) => r.running), [false, true]);
      final idle = deriveStreamRows(events);
      expect(idle.whereType<ToolRow>().any((r) => r.running), isFalse);
    });

    test('delegations and long commands', () {
      final rows = deriveStreamRows([
        userEv('x'),
        toolEv('Agent', '↳ Explore: map the repo'),
        toolEv('Bash', 'echo   a\n  b ${'z' * 200}'),
      ]);
      final d = rows[2] as ToolRow;
      expect(d.delegate, isTrue);
      final b = rows[3] as ToolRow;
      expect(b.target.contains('\n'), isFalse);
      expect(b.target.length, lessThanOrEqualTo(97));
      expect(b.target, contains('…'));
    });

    test('an empty done is dropped, a done after edits counts files once', () {
      final rows = deriveStreamRows([
        userEv('x'),
        doneEv(),
        userEv('y', turn: 2),
        editEv('a.ts', turn: 2),
        editEv('a.ts', turn: 2),
        editEv('b.ts', turn: 2),
        doneEv(turn: 2, cost: 0.0021, durationMs: 8300),
      ]);
      expect(rows.whereType<FooterRow>(), hasLength(1));
      expect(
        rows.whereType<FooterRow>().single.text,
        'done in 8.3s · 2 files · \$0.0021',
      );
    });

    test('plan run footer says plan ready and counts no files', () {
      final rows = deriveStreamRows([
        userEv('x'),
        tokEv('the plan'),
        doneEv(plan: true, durationMs: 75000, cost: 4.67),
      ]);
      final f = rows.last as FooterRow;
      expect(f.planReady, isTrue);
      expect(f.text, 'plan ready in 1m 15s · \$4.67');
    });

    test('errors render as rows', () {
      final rows = deriveStreamRows([userEv('x'), errorEv('boom')]);
      expect((rows.last as ErrorRow).message, 'boom');
    });

    test('a running turn with only a bootstrap shows the label', () {
      final rows = deriveStreamRows([userEv('x'), metaEv()], running: true);
      expect(rows.last, isA<AgentLabelRow>());
    });

    test('autofix turns are labelled', () {
      final rows = deriveStreamRows([userEv('fix', runId: 'autofix')]);
      expect((rows.single as UserRow).label, 'AUTOFIX');
    });
  });

  group('questions', () {
    test('full JSON', () {
      final q = parseQuestion(
        '{"questions":[{"question":"Which db?","options":[{"label":"pg"},{"label":"sqlite"}]}]}',
      );
      expect(q.question, 'Which db?');
      expect(q.options, ['pg', 'sqlite']);
    });

    test('truncated summary falls back to the regex', () {
      final q = parseQuestion('{"questions":[{"question":"Use \\"pg\\" or sq');
      expect(q.question, startsWith('Use "pg" or sq'));
    });

    test('rows: waiting only for the newest question', () {
      final rows = deriveStreamRows(
        [
          userEv('x'),
          toolEv('AskUserQuestion', '{"questions":[{"question":"A?"}]}'),
        ],
        running: true,
        waiting: true,
      );
      expect((rows.last as QuestionRow).waiting, isTrue);
      final after = deriveStreamRows([
        userEv('x'),
        toolEv('AskUserQuestion', '{"questions":[{"question":"A?"}]}'),
        toolEv('Read', 'a'),
      ]);
      expect(after.whereType<QuestionRow>().single.waiting, isFalse);
    });
  });

  group('copy helpers', () {
    test('formatWall', () {
      expect(formatWall(const Duration(milliseconds: 420)), '420ms');
      expect(formatWall(const Duration(milliseconds: 8300)), '8.3s');
      expect(formatWall(const Duration(seconds: 42)), '42s');
      expect(formatWall(const Duration(minutes: 14, seconds: 1)), '14m 1s');
      expect(formatWall(const Duration(hours: 1, minutes: 5)), '1h 5m');
    });

    test('formatCost keeps small amounts legible', () {
      expect(formatCost(9.89219), '\$9.89');
      expect(formatCost(0.0021), '\$0.0021');
      expect(formatCost(1.5), '\$1.50');
    });

    test('footer copy with 21 files', () {
      const f = FooterRow(
        duration: Duration(minutes: 14, seconds: 1),
        files: 21,
        costUsd: 9.89,
      );
      expect(f.text, 'done in 14m 1s · 21 files · \$9.89');
      expect(const FooterRow(files: 1).text, 'done · 1 file');
    });

    test('contextPercent reads the newest done', () {
      expect(contextPercent([doneEv()]), 21);
      expect(contextPercent([doneEv(), doneEv(contextTokens: 500000)]), 50);
      expect(contextPercent([doneEv(contextWindow: null)]), isNull);
      expect(contextPercent([tokEv('x')]), isNull);
    });
  });

  group('relativeSummary', () {
    const root = '/Users/someone/.haro/worktrees/proj/ws';

    test('a Read of a file in the worktree shows the relative path', () {
      expect(relativeSummary('$root/lib/shipping.ts', root), 'lib/shipping.ts');
    });

    test('an absolute path inside a Bash command is shortened too', () {
      expect(
        relativeSummary('cd $root && npx vitest run $root/lib/a.test.ts', root),
        'cd . && npx vitest run lib/a.test.ts',
      );
    });

    test('paths outside the worktree and a missing root stay as they are', () {
      expect(relativeSummary('/etc/hosts', root), '/etc/hosts');
      expect(relativeSummary('$root-other/x', root), '$root-other/x');
      expect(relativeSummary('$root/x', null), '$root/x');
    });
  });
}
