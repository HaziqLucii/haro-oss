import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/shell/shell_models.dart';
import 'package:haro_app/shell/sidebar_fold.dart';
import 'package:haro_app/state/display_state.dart';

SidebarWorkspace w(String id, DisplayState s) =>
    SidebarWorkspace(id: id, name: id, state: s);

final project = SidebarProject(
  id: 'p',
  name: 'p',
  workspaces: [
    w('a', DisplayState.idle),
    w('m1', DisplayState.merged),
    w('b', DisplayState.green),
    w('m2', DisplayState.merged),
  ],
);

List<String> ids(SidebarProjectView v) => [for (final r in v.rows) r.id];

void main() {
  group('sidebarProjectView', () {
    test('merged ones collapse into a count, the rest keep their order', () {
      final v = sidebarProjectView(project, const SidebarFold(), null);
      expect(ids(v), ['a', 'b']);
      expect(v.mergedCount, 2);
      expect(v.mergedOpen, isFalse);
      expect(v.folded, isFalse);
    });

    test('rows keep the order they came in, merged or not', () {
      final shown = sidebarProjectView(
        project,
        const SidebarFold(mergedShown: {'p'}),
        null,
      );
      expect(ids(shown), ['a', 'm1', 'b', 'm2']);
      final open = sidebarProjectView(project, const SidebarFold(), 'm2');
      expect(ids(open), ['a', 'b', 'm2']);
    });

    test('opening merged lists them in place', () {
      final v = sidebarProjectView(
        project,
        const SidebarFold(mergedShown: {'p'}),
        null,
      );
      expect(ids(v), ['a', 'm1', 'b', 'm2']);
      expect(v.mergedOpen, isTrue);
    });

    test('the open merged workspace stays and is not counted twice', () {
      final v = sidebarProjectView(project, const SidebarFold(), 'm2');
      expect(ids(v), ['a', 'b', 'm2']);
      expect(v.mergedCount, 1);
    });

    test('with only the open merged one left there is no toggle row', () {
      final one = SidebarProject(
        id: 'p',
        name: 'p',
        workspaces: [w('m1', DisplayState.merged)],
      );
      final v = sidebarProjectView(one, const SidebarFold(), 'm1');
      expect(ids(v), ['m1']);
      expect(v.mergedCount, 0);
    });

    test('a folded project keeps the open workspace and anything live', () {
      const fold = SidebarFold(folded: {'p'});
      expect(ids(sidebarProjectView(project, fold, null)), isEmpty);
      final v = sidebarProjectView(project, fold, 'b');
      expect(ids(v), ['b']);
      expect(v.folded, isTrue);
      expect(v.mergedCount, 0);

      final live = SidebarProject(
        id: 'p',
        name: 'p',
        workspaces: [
          w('idle', DisplayState.idle),
          w('red', DisplayState.red),
          w('plan', DisplayState.plan),
          w('agent', DisplayState.agent),
          w('gate', DisplayState.gate),
          w('green', DisplayState.green),
          w('done', DisplayState.merged),
        ],
      );
      expect(ids(sidebarProjectView(live, fold, null)), [
        'red',
        'plan',
        'agent',
        'gate',
      ]);
    });
  });

  test('the notifier toggles projects and merged lists independently', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(sidebarFoldProvider.notifier);
    n.toggleProject('p');
    n.toggleMerged('p');
    expect(c.read(sidebarFoldProvider).folded, {'p'});
    expect(c.read(sidebarFoldProvider).mergedShown, {'p'});
    n.toggleProject('p');
    expect(c.read(sidebarFoldProvider).folded, isEmpty);
    expect(c.read(sidebarFoldProvider).mergedShown, {'p'});
  });
}
