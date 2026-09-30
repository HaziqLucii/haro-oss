import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/new_workspace/branch_naming.dart';

void main() {
  group('slugify', () {
    test('lowercases and joins runs of non-alphanumerics with one dash', () {
      expect(slugify('Add multiply helper'), 'add-multiply-helper');
      expect(slugify('Fix: shipping   total (v2)!'), 'fix-shipping-total-v2');
    });

    test('trims dashes and falls back to task', () {
      expect(slugify('  --hello--  '), 'hello');
      expect(slugify(''), 'task');
      expect(slugify('***'), 'task');
    });
  });

  group('workspace name', () {
    test('short single-line text is kept as typed', () {
      expect(workspaceNameFor('  Add a - b support '), 'Add a - b support');
    });

    test('long text is cut at a word boundary, not mid-word', () {
      final name = workspaceNameFor(
        'Stream results as tests finish so the developer can watch the gate resolve',
      );
      expect(name.length, lessThanOrEqualTo(48));
      expect(name, 'Stream results as tests finish so the developer');
    });

    test('multi-line text keeps the lead phrase before a spaced dash', () {
      expect(
        workspaceNameFor('**Adapter flag** - add a plan param\nmore detail'),
        'Adapter flag',
      );
    });
  });

  group('withPrefix', () {
    test('swaps the leading segment and keeps the tail', () {
      expect(withPrefix('feat/add-thing', 'fix/', 'x'), 'fix/add-thing');
    });

    test('a branch without a slash is treated as all tail', () {
      expect(withPrefix('add-thing', 'docs/', 'x'), 'docs/add-thing');
    });

    test('empty tail falls back', () {
      expect(withPrefix('feat/', 'test/', 'fallback'), 'test/fallback');
    });
  });

  group('branchPrefixForTask', () {
    test(
      'fix for a whole word fix, bug, bugfix or hotfix, anywhere, any case',
      () {
        for (final t in [
          'Fix the rounding',
          'the totals BUG on checkout',
          'ship a hotfix now',
          'Bugfix: null date',
          'rounding fix',
        ]) {
          expect(branchPrefixForTask(t), 'fix/', reason: t);
        }
      },
    );

    test('feat otherwise, and never for a word that merely contains one', () {
      for (final t in [
        'Add multiply helper',
        'prefix the labels',
        'debug logging',
        'fixture loader',
        'bugs bunny theme',
        '',
      ]) {
        expect(branchPrefixForTask(t), 'feat/', reason: t);
      }
    });

    test('a derived draft follows the task; a chosen chip wins', () {
      const d = BranchDraft();
      expect(d.branchFor('Fix login'), 'fix/fix-login');
      expect(d.branchFor('Add login'), 'feat/add-login');
      expect(
        d.withChip('docs/', 'Fix login').branchFor('Fix login'),
        'docs/fix-login',
      );
    });

    test('the branch the user typed always wins', () {
      final d = const BranchDraft().edited('feat/mine');
      expect(d.branchFor('Fix login'), 'feat/mine');
    });
  });

  group('BranchDraft', () {
    test('derives feat/<slug> from the task', () {
      const d = BranchDraft();
      expect(d.branchFor('Add multiply helper'), 'feat/add-multiply-helper');
      expect(d.auto, isTrue);
    });

    test('placeholder slug while the task is empty', () {
      expect(const BranchDraft().branchFor('  '), 'feat/task-name');
    });

    test('a prefix chip re-derives with the new prefix while automatic', () {
      final d = const BranchDraft().withChip('fix/', 'Add multiply helper');
      expect(d.auto, isTrue);
      expect(d.branchFor('Add multiply helper'), 'fix/add-multiply-helper');
      expect(d.branchFor('Something else'), 'fix/something-else');
    });

    test('a manual edit stops the derivation', () {
      final d = const BranchDraft().edited('feat/my-own-name');
      expect(d.auto, isFalse);
      expect(d.branchFor('Completely different task'), 'feat/my-own-name');
    });

    test('a chip after a manual edit swaps the prefix and keeps the tail', () {
      final d = const BranchDraft()
          .edited('feat/my-own-name')
          .withChip('chore/', 'ignored');
      expect(d.branchFor('anything'), 'chore/my-own-name');
      expect(d.auto, isFalse);
    });

    test('clearing the field keeps it manual and empty', () {
      final d = const BranchDraft().edited('');
      expect(d.branchFor('Some task'), '');
    });
  });
}
