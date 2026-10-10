import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/guide/guide_content.dart';
import 'package:haro_app/features/guide/guide_model.dart';
import 'package:haro_app/overlays/shortcuts_overlay.dart';
import 'package:haro_app/shortcuts/platform_keys.dart';

void main() {
  final ids = [for (final t in guideTopics) t.id];

  test('every topic has a unique id, a known group and some content', () {
    expect(ids.toSet().length, ids.length);
    for (final t in guideTopics) {
      expect(guideGroups, contains(t.group), reason: t.id);
      expect(t.blocks, isNotEmpty, reason: t.id);
      expect(t.title.trim(), isNotEmpty);
      expect(t.summary.length, lessThan(240), reason: '${t.id} summary');
    }
  });

  test('every link and path points at a topic that exists', () {
    for (final t in guideTopics) {
      for (final b in t.blocks) {
        if (b is GuideSeeAlso) {
          for (final id in b.topics) {
            expect(ids, contains(id), reason: '${t.id} -> $id');
          }
        }
        if (b is GuidePaths) {
          for (final p in b.paths) {
            expect(ids, contains(p.topic), reason: '${t.id} -> ${p.topic}');
          }
        }
      }
    }
  });

  test('the groups appear in order and no group is empty', () {
    final seen = <String>[];
    for (final t in guideTopics) {
      if (seen.isEmpty || seen.last != t.group) seen.add(t.group);
    }
    expect(seen, guideGroups);
  });

  test(
    'the first topic is the welcome, with a way in for every kind of reader',
    () {
      final first = guideTopics.first;
      expect(first.id, 'welcome');
      final paths = first.blocks.whereType<GuidePaths>().single.paths;
      expect(
        paths.map((p) => p.topic),
        containsAll(['who-writes', 'agent', 'words']),
      );
    },
  );

  test('it reads like a person wrote it, not a manual', () {
    const stiff = [
      '—',
      'utilize',
      'leverage',
      'in order to',
      'please note',
      'it should be noted',
      'the following',
      'prior to',
      'subsequently',
      'facilitate',
    ];
    for (final t in guideTopics) {
      final text = t.texts.join('\n').toLowerCase();
      for (final word in stiff) {
        expect(text, isNot(contains(word)), reason: '${t.id}: "$word"');
      }
    }
  });

  test('every shortcut the guide names is one the app really has', () {
    final real = {
      for (final e in shortcutEntries(modifier: PrimaryModifier.control)) e.$2,
    };
    final token = RegExp(r'\{mod\}\+((?:Shift\+)?)([A-Za-z]+|`)');
    var found = 0;
    for (final t in guideTopics) {
      for (final s in t.texts) {
        for (final m in token.allMatches(s)) {
          found++;
          var key = m.group(2)!;
          if (key == 'Enter') key = '↵';
          final label = 'Ctrl+${m.group(1)}$key';
          expect(real, contains(label), reason: '${t.id}: $label');
        }
      }
    }
    expect(found, greaterThan(8));
  });

  group('guideText', () {
    test('names the platform key', () {
      expect(
        guideText('Press {mod}+K', modifier: PrimaryModifier.meta),
        'Press Cmd+K',
      );
      expect(
        guideText('Press {mod}+K', modifier: PrimaryModifier.control),
        'Press Ctrl+K',
      );
    });
  });

  group('searchGuide', () {
    test('a blank query keeps everything in order', () {
      expect(searchGuide(guideTopics, '  ').map((t) => t.id), ids);
    });

    test('finds a topic by a word in its text, any case', () {
      final hits = searchGuide(guideTopics, 'RESTORE').map((t) => t.id);
      expect(hits, contains('safety'));
    });

    test('needs every word, and says nothing for nonsense', () {
      expect(
        searchGuide(guideTopics, 'fence scope').map((t) => t.id),
        contains('fence'),
      );
      expect(searchGuide(guideTopics, 'zzzxqv'), isEmpty);
    });
  });

  group('what the reader sees', () {
    test('a search finds the key as it is shown, not the placeholder', () {
      expect(
        searchGuide(
          guideTopics,
          'cmd+k',
          modifier: PrimaryModifier.meta,
        ).map((t) => t.id),
        contains('settings'),
      );
      expect(
        searchGuide(
          guideTopics,
          'ctrl+k',
          modifier: PrimaryModifier.control,
        ).map((t) => t.id),
        contains('settings'),
      );
      expect(searchGuide(guideTopics, '{mod}'), isEmpty);
    });

    test('markup is not searched', () {
      expect(searchGuide(guideTopics, '**'), isEmpty);
      expect(searchGuide(guideTopics, 'stage'), isNotEmpty);
    });

    test('plainGuideText drops the markup and names the key', () {
      expect(
        plainGuideText(
          'Press **{mod}+K** for `x`',
          modifier: PrimaryModifier.control,
        ),
        'Press Ctrl+K for x',
      );
    });
  });

  group('claims stay bounded', () {
    String text(String id) => guideTopics
        .firstWhere((t) => t.id == id)
        .texts
        .join('\n')
        .toLowerCase();

    test('the fence does not promise more than it does', () {
      final fence = text('fence');
      expect(fence, isNot(contains('never touched')));
      expect(fence, contains('usually stops it'));
      expect(fence, contains('edit a file outside the fence'));
      expect(fence, contains('plan run changes nothing'));
    });

    test('closing haro is described one way, everywhere', () {
      final all = guideTopics
          .map((t) => t.texts.join('\n').toLowerCase())
          .join('\n');
      expect(all, isNot(contains("doesn't stop an agent")));
      expect(text('agent'), contains('asks you first'));
      expect(text('help'), contains('asks first if work is running'));
    });

    test('the privacy answer names every place code can go', () {
      final a = text('help');
      expect(a, contains('claude'));
      expect(a, contains('model on your own machine'));
      expect(a, contains('github'));
      expect(a, isNot(contains('is only used if you open')));
    });
  });
}
