import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/state/sub_agents.dart';

import '../features/workspace/steps/agent/agent_events.dart';

void main() {
  group('splitNested', () {
    test('tagged events leave the main transcript', () {
      final all = [
        userEv('go'),
        delegateStartEv('t1', 'Explore', 'Map the stage'),
        nestedToolEv('t1', 'Read', 'a.dart'),
        toolEv('Bash', 'ls'),
      ];
      final (main, nested) = splitNested(all);
      expect(main.map((e) => e.type.name), ['user', 'toolCall', 'toolCall']);
      expect(nested, hasLength(1));
      expect(isNestedEvent(nested.single), isTrue);
      expect(isNestedEvent(main.last), isFalse);
    });
  });

  group('deriveSubAgents', () {
    test('a delegation carries its type, description and steps, in order', () {
      final all = [
        delegateStartEv('t1', 'Explore', 'Map the code stage'),
        delegateStartEv('t2', 'scout', 'Find the routes'),
        nestedToolEv('t1', 'Read', 'lib/a.dart'),
        nestedToolEv('t2', 'Grep', 'router'),
        nestedToolEv('t1', 'Bash', 'ls lib'),
      ];
      final (main, nested) = splitNested(all);
      final agents = deriveSubAgents(main, nested, live: true);
      expect(agents.map((a) => a.type), ['Explore', 'scout']);
      expect(agents.first.description, 'Map the code stage');
      expect(agents.first.steps.map((s) => s.tool), ['Read', 'Bash']);
      expect(agents.first.latestTool, 'Bash ls lib');
      expect(agents.last.steps.single.text, 'router');
      expect(agents.every((a) => a.running), isTrue);
    });

    test('the hand-back settles it and records when', () {
      final all = [
        delegateStartEv('t1', 'Explore', 'Map it'),
        nestedToolEv('t1', 'Read', 'a'),
        delegateDoneEv('t1', 'Explore'),
        delegateStartEv('t2', 'code-review', 'Review the diff'),
        delegateDoneEv('t2', 'code-review', status: 'error'),
      ];
      final (main, nested) = splitNested(all);
      final agents = deriveSubAgents(main, nested, live: true);
      expect(agents[0].status, SubAgentStatus.done);
      expect(agents[0].endedAt, isNotNull);
      expect(
        agents[0].description,
        'Map it',
        reason: 'kept from the start row',
      );
      expect(agents[1].status, SubAgentStatus.error);
    });

    test('a stopped hand-back marks it stopped with an end time', () {
      final all = [
        delegateStartEv('t1', 'Explore', 'Map it'),
        delegateDoneEv('t1', 'Explore', status: 'stopped'),
      ];
      final (main, nested) = splitNested(all);
      final a = deriveSubAgents(main, nested, live: true).single;
      expect(a.status, SubAgentStatus.stopped);
      expect(a.endedAt, isNotNull);
      expect(a.running, isFalse);
    });

    test('a delegation still running when the run is over was stopped', () {
      final (main, nested) = splitNested([delegateStartEv('t1', 'scout', 'x')]);
      final agents = deriveSubAgents(main, nested, live: false);
      expect(agents.single.status, SubAgentStatus.stopped);
    });

    test('streamed text chunks join into one step; its last words are the hand-back', () {
      final all = [
        delegateStartEv('t1', 'Explore', 'Map it'),
        nestedToolEv('t1', 'Read', 'a'),
        nestedTokEv('t1', 'Found '),
        nestedTokEv('t1', 'three files.'),
      ];
      final (main, nested) = splitNested(all);
      final a = deriveSubAgents(main, nested, live: true).single;
      expect(a.steps, hasLength(2));
      expect(a.steps.last.prose, isTrue);
      expect(a.finalText, 'Found three files.');
    });

    test(
      'a step whose delegation row is missing is ignored, not crashed on',
      () {
        final (main, nested) = splitNested([
          nestedToolEv('ghost', 'Read', 'a'),
        ]);
        expect(deriveSubAgents(main, nested, live: true), isEmpty);
      },
    );
  });
}
