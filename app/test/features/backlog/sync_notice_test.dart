import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/backlog/sync_notice.dart';

void main() {
  test('good and empty states say nothing', () {
    expect(syncNotice(null), isNull);
    for (final s in ['up_to_date', 'pulled', 'no_remote']) {
      expect(syncNotice(ProjectSync(state: s)), isNull, reason: s);
    }
    expect(
      syncNotice(const ProjectSync(state: 'other_branch')),
      isNull,
      reason: 'on another branch but not behind: nothing stale',
    );
  });

  test('each problem has one plain sentence', () {
    expect(
      syncNotice(
        const ProjectSync(
          state: 'other_branch',
          branch: 'docs/x',
          behind: 2,
          defaultBranch: 'main',
        ),
      ),
      'Checkout is on docs/x, 2 behind main: ticks may be out of date.',
    );
    expect(
      syncNotice(const ProjectSync(state: 'dirty')),
      'The checkout has uncommitted changes, so haro did not update it from main.',
    );
    expect(
      syncNotice(const ProjectSync(state: 'diverged', ahead: 1)),
      'main has 1 commit that are not on origin, so it cannot be fast-forwarded.',
    );
    expect(
      syncNotice(
        const ProjectSync(
          state: 'blocked',
          detail: 'the update would overwrite untracked files here: todo.md',
        ),
      ),
      'the update would overwrite untracked files here: todo.md',
    );
    expect(
      syncNotice(const ProjectSync(state: 'fetch_failed', detail: 'no route')),
      'Could not reach GitHub: no route',
    );
  });

  test('only the other-branch notice offers the switch', () {
    expect(
      canSwitchToDefault(const ProjectSync(state: 'other_branch', behind: 1)),
      isTrue,
    );
    expect(
      canSwitchToDefault(const ProjectSync(state: 'other_branch')),
      isFalse,
    );
    expect(
      canSwitchToDefault(const ProjectSync(state: 'dirty', behind: 3)),
      isFalse,
    );
    expect(canSwitchToDefault(null), isFalse);
  });
}
