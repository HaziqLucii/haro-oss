import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/router.dart';

void main() {
  testWidgets('the leaving page is gone at once, only the arriving one fades', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (_, s) => fadePage(s, const Text('old page')),
        ),
        GoRoute(
          path: '/b',
          pageBuilder: (_, s) => fadePage(s, const Text('new page')),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        debugShowCheckedModeBanner: false,
      ),
    );
    await tester.pumpAndSettle();

    router.go('/b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('old page'), findsNothing);
    expect(find.text('new page'), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
