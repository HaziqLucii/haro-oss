import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/agent/composer_logic.dart';
import 'package:haro_app/features/workspace/steps/agent/composer_state.dart';

void main() {
  group('detectTrigger', () {
    test('@ at a word boundary', () {
      final t = detectTrigger('fix @src/ap', 11)!;
      expect(t.kind, TriggerKind.at);
      expect(t.query, 'src/ap');
      expect(t.start, 4);
    });

    test('an email is not a mention', () {
      expect(detectTrigger('mail a@b', 8), isNull);
    });

    test('/ only triggers at the very start', () {
      expect(detectTrigger('/rev', 4)!.kind, TriggerKind.slash);
      expect(detectTrigger('x /rev', 6), isNull);
      expect(detectTrigger('/review now', 11), isNull);
    });

    test('@ wins over /', () {
      expect(detectTrigger('/x @a', 5)!.kind, TriggerKind.at);
    });
  });

  test('filterSlashCommands', () {
    expect(filterSlashCommands('').length, slashCommands.length);
    expect(filterSlashCommands('rev').map((c) => c.name), ['/review']);
    expect(filterSlashCommands('nope'), isEmpty);
  });

  test('filterFiles ranks basenames first and is stable', () {
    final paths = [
      'components/App.test.tsx',
      'src/lib/app-utils.ts',
      'App.tsx',
      'src/App.tsx',
    ];
    expect(filterFiles(paths, 'app.tsx'), ['App.tsx', 'src/App.tsx']);
    // Equal scores keep list order (the React client's sort is stable).
    expect(filterFiles(paths, 'app'), [
      'components/App.test.tsx',
      'src/lib/app-utils.ts',
      'App.tsx',
      'src/App.tsx',
    ]);
    expect(filterFiles(paths, 'utils'), ['src/lib/app-utils.ts']);
    expect(filterFiles(paths, ''), paths);
    expect(filterFiles(paths, '', limit: 2), hasLength(2));
  });

  test('flattenFiles drops directories', () {
    final files = flattenFiles(const [
      FileNode(
        name: 'src',
        path: 'src',
        dir: true,
        children: [
          FileNode(name: 'a.ts', path: 'src/a.ts'),
          FileNode(
            name: 'lib',
            path: 'src/lib',
            dir: true,
            children: [FileNode(name: 'b.ts', path: 'src/lib/b.ts')],
          ),
        ],
      ),
      FileNode(name: 'c.md', path: 'c.md'),
    ]);
    expect(files, ['src/a.ts', 'src/lib/b.ts', 'c.md']);
  });

  test('applyCompletion replaces the token and adds a space', () {
    final t = detectTrigger('fix @ap tests', 7)!;
    final r = applyCompletion('fix @ap tests', t, '@src/App.tsx');
    expect(r.text, 'fix @src/App.tsx  tests');
    expect(r.caret, 'fix @src/App.tsx '.length);
  });

  group('paste to file', () {
    test('thresholds', () {
      expect(shouldAttachPaste(''), isFalse);
      expect(shouldAttachPaste('short'), isFalse);
      expect(shouldAttachPaste(List.filled(20, 'x').join('\n')), isTrue);
      expect(shouldAttachPaste(List.filled(19, 'x').join('\n')), isFalse);
      expect(shouldAttachPaste('x' * 2000), isTrue);
    });

    test('insertedText finds a pure insertion', () {
      expect(insertedText('ab', 'aXYb'), 'XY');
      expect(insertedText('ab', 'abXY'), 'XY');
      expect(insertedText('ab', 'a'), isNull);
      expect(insertedText('keep OLD', 'keep NEWER'), 'NEWER');
      expect(insertedText('same', 'same'), isNull);
    });

    test('the formatter rejects a big paste and reports it', () {
      String? got;
      final f = LargePasteFormatter((t) => got = t);
      const old = TextEditingValue(text: 'keep');
      final big = 'x' * 2500;
      final out = f.formatEditUpdate(old, TextEditingValue(text: 'keep$big'));
      expect(out.text, 'keep');
      expect(got, big);

      got = null;
      final small = f.formatEditUpdate(
        old,
        const TextEditingValue(text: 'keeps'),
      );
      expect(small.text, 'keeps');
      expect(got, isNull);
    });

    test('composeWithAttachments', () {
      const a = Attachment(path: '.context/p.txt', name: 'p.txt', lines: 42);
      expect(
        composeWithAttachments(' do it ', const [a]),
        'do it\n\n@.context/p.txt',
      );
      expect(composeWithAttachments('', const [a]), '@.context/p.txt');
      expect(composeWithAttachments(' hi ', const []), 'hi');
      expect(a.stat, '42 lines');
      expect(
        const Attachment(path: 'p', name: 'p', kind: 'image', size: 24576).stat,
        '24 KB',
      );
    });
  });

  group('roles', () {
    test('roleLabel and splitRole', () {
      expect(roleLabel('fable:xhigh'), 'fable · xhigh');
      expect(roleLabel('haiku'), 'haiku');
      expect(roleLabel(''), 'not set');
      expect(splitRole('opus:high'), ('opus', 'high'));
      expect(splitRole('haiku'), ('haiku', null));
    });

    test('nextRole follows plan first', () {
      expect(nextRole(planFirst: true), 'plan');
      expect(nextRole(planFirst: false), 'build');
    });

    test('roles on: model and effort are never sent', () {
      final a = resolveRunArgs(
        rolesEnabled: true,
        adapter: 'local',
        model: 'opus',
        effort: 'high',
      );
      expect(a.adapter, 'claude-code');
      expect(a.model, isNull);
      expect(a.effort, isNull);
    });

    test('roles off: picks pass through, default means omit', () {
      final a = resolveRunArgs(
        rolesEnabled: false,
        adapter: 'claude-code',
        model: 'opus',
        effort: 'default',
      );
      expect((a.model, a.effort), ('opus', null));
      final l = resolveRunArgs(
        rolesEnabled: false,
        adapter: 'local',
        localModel: 'qwen',
        model: 'opus',
      );
      expect((l.adapter, l.model, l.effort), ('local', 'qwen', null));
    });

    test('isAgentBusy', () {
      expect(isAgentBusy(WorkspaceStatus.agentRunning), isTrue);
      expect(isAgentBusy(WorkspaceStatus.testsRunning), isTrue);
      expect(isAgentBusy(WorkspaceStatus.settingUp), isFalse);
      expect(isAgentBusy(WorkspaceStatus.idle), isFalse);
    });
  });

  group('pickSuggestions', () {
    TodoFile file(String label, List<TodoItem> items) =>
        TodoFile(path: label, label: label, items: items);
    TodoItem item(String t, {bool done = false, String? seeded}) =>
        TodoItem(text: t, done: done, seededWorkspace: seeded, seedKey: t);

    test('open items only, files with progress first, capped at three', () {
      final todo = TodoResponse(
        files: [
          file('fresh.md', [item('f1'), item('f2')]),
          file('started.md', [
            item('s-done', done: true),
            item('s1'),
            item('s2'),
          ]),
          file('taken.md', [item('t1', seeded: 'ws_9')]),
        ],
      );
      final s = pickSuggestions(todo);
      expect(s.map((x) => x.text), ['s1', 's2', 'f1']);
      expect(s.map((x) => x.source), ['started.md', 'started.md', 'fresh.md']);
    });

    test('nothing open, no suggestions', () {
      expect(pickSuggestions(const TodoResponse()), isEmpty);
    });
  });
}
