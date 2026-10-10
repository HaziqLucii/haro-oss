import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/guide/guide_content.dart';
import 'package:haro_app/features/guide/guide_view.dart';

Widget host({String? topic, ValueChanged<String>? onTopic}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 980,
      height: 640,
      child: GuideView(initialTopic: topic, onTopic: onTopic),
    ),
  ),
);

Finder k(String key) => find.byKey(ValueKey(key));

String title(WidgetTester t) => t.widget<Text>(k('guide-title')).data!;

void main() {
  setUp(() {});

  testWidgets('opens on the welcome and lists every topic by group', (t) async {
    await t.binding.setSurfaceSize(const Size(980, 640));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(host());
    expect(title(t), 'What haro is');
    // The list is lazy, so only the groups near the top are built.
    expect(find.text(guideGroups[0]), findsWidgets);
    expect(find.text(guideGroups[1]), findsOneWidget);
    expect(k('guide-topic-welcome'), findsOneWidget);
  });

  testWidgets('a topic can be opened first, and an unknown one falls back', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(980, 640));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(host(topic: 'gate'));
    expect(title(t), 'The test gate');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(topic: 'nope'));
    await t.pumpAndSettle();
    expect(title(t), 'What haro is');
  });

  testWidgets('clicking a topic opens it and tells the overlay', (t) async {
    await t.binding.setSurfaceSize(const Size(980, 640));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final seen = <String>[];
    await t.pumpWidget(host(onTopic: seen.add));
    await t.tap(k('guide-topic-words'));
    await t.pumpAndSettle();
    expect(title(t), 'Plain words');
    expect(seen, ['words']);
  });

  testWidgets('a path card takes you to the topic for that kind of reader', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(980, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(host());
    await t.ensureVisible(k('guide-path-words'));
    await t.pumpAndSettle();
    await t.tap(k('guide-path-words'));
    await t.pumpAndSettle();
    expect(title(t), 'Plain words');
  });

  testWidgets('See also and Next move on, and the page starts at the top', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(980, 640));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(host(topic: 'words'));
    await t.ensureVisible(k('guide-next'));
    await t.pumpAndSettle();
    await t.tap(k('guide-next'));
    await t.pumpAndSettle();
    expect(title(t), 'Your first task');
    final scroll = t.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView).first,
    );
    expect(scroll.controller!.offset, 0);
    await t.ensureVisible(k('guide-see-review'));
    await t.pumpAndSettle();
    await t.tap(k('guide-see-review'));
    await t.pumpAndSettle();
    expect(title(t), 'Reviewing the work');
  });

  testWidgets(
    'search narrows the list, opens the first hit, and says so when nothing matches',
    (t) async {
      await t.binding.setSurfaceSize(const Size(980, 640));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(host());
      await t.enterText(k('guide-search'), 'restore');
      await t.pumpAndSettle();
      expect(k('guide-topic-safety'), findsOneWidget);
      expect(k('guide-topic-welcome'), findsNothing);
      expect(title(t), 'When things go wrong');
      await t.enterText(k('guide-search'), 'zzzxqv');
      await t.pumpAndSettle();
      expect(k('guide-no-match'), findsOneWidget);
      expect(k('guide-title'), findsNothing);
      await t.enterText(k('guide-search'), '');
      await t.pumpAndSettle();
      expect(k('guide-topic-welcome'), findsOneWidget);
    },
  );

  testWidgets(
    'bold, code and the platform key are rendered, not shown as markup',
    (t) async {
      await t.binding.setSurfaceSize(const Size(980, 640));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(host(topic: 'first-task'));
      expect(find.textContaining('**', findRichText: true), findsNothing);
      expect(find.textContaining('{mod}', findRichText: true), findsNothing);
      expect(
        find.textContaining(RegExp(r'(Cmd|Ctrl)\+N'), findRichText: true),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'a link that leaves the search clears it instead of doing nothing',
    (t) async {
      await t.binding.setSurfaceSize(const Size(980, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(host());
      await t.enterText(k('guide-search'), 'where do you want');
      await t.pumpAndSettle();
      expect(title(t), 'What haro is');
      await t.ensureVisible(k('guide-path-words'));
      await t.pumpAndSettle();
      await t.tap(k('guide-path-words'));
      await t.pumpAndSettle();
      expect(title(t), 'Plain words');
      expect(
        t
            .widget<TextField>(
              find.descendant(
                of: k('guide-search'),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '',
      );
      expect(k('guide-topic-projects'), findsOneWidget);
    },
  );
}
