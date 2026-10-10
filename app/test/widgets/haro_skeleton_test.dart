import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/haro_skeleton.dart';

Widget host(Widget child, {bool reduceMotion = false}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Center(child: child),
  ),
);

double opacityOf(WidgetTester tester) =>
    tester.widget<Opacity>(find.byType(Opacity)).opacity;

void main() {
  tearDown(() => HaroSkeleton.animate = false);

  testWidgets('takes exactly the size it is given', (tester) async {
    await tester.pumpWidget(host(const HaroSkeleton(width: 120, height: 36)));
    expect(tester.getSize(find.byType(HaroSkeleton)), const Size(120, 36));
  });

  testWidgets('fills the parent when it has no size of its own', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const SizedBox(width: 200, height: 40, child: HaroSkeleton())),
    );
    expect(tester.getSize(find.byType(HaroSkeleton)), const Size(200, 40));
  });

  testWidgets('animate = false: drawn at once, nothing keeps frames coming', (
    tester,
  ) async {
    HaroSkeleton.animate = false;
    await tester.pumpWidget(host(const HaroSkeleton(width: 50, height: 10)));
    expect(find.byType(Opacity), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('reduce motion: still and visible at once', (tester) async {
    HaroSkeleton.animate = true;
    await tester.pumpWidget(
      host(const HaroSkeleton(width: 50, height: 10), reduceMotion: true),
    );
    expect(find.byType(Opacity), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('animated: invisible for the delay, then fades in and pulses', (
    tester,
  ) async {
    HaroSkeleton.animate = true;
    await tester.pumpWidget(host(const HaroSkeleton(width: 50, height: 10)));
    expect(opacityOf(tester), 0);
    await tester.pump(HaroTokens.skeletonDelay);
    expect(opacityOf(tester), 0);
    await tester.pump(HaroTokens.fade);
    expect(opacityOf(tester), 1);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
