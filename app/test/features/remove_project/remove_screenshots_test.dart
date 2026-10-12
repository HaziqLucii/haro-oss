import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/add_project/clone_runner.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

import '../../api/fixtures.dart';
import '../creation_harness.dart';
import '../workspace/harness.dart' show FixedDetail;

/// Local visual check, not part of the suite:
///   HARO_SHOTS=/some/dir flutter test test/features/remove_project/remove_screenshots_test.dart
final _out = Platform.environment['HARO_SHOTS'];

Workspace _ws(String id, String name, String status) => Workspace.fromJson(
  workspaceJson(
    id: id,
    status: status,
    overrides: {'project_id': 'p1', 'name': name},
  ),
);

void main() {
  final key = GlobalKey();

  Future<ProviderContainer> pump(
    WidgetTester tester,
    List<Workspace> workspaces,
  ) async {
    tester.view.physicalSize = const Size(1200, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    final store = FakeStore(
      snapshotOf(
        [
          Project(
            id: 'p1',
            name: 'gate-sandbox',
            path: '/Users/me/Projects/gate-sandbox',
            defaultBranch: 'main',
          ),
          Project(
            id: 'p2',
            name: 'haro',
            path: '/Users/me/Projects/haro',
            defaultBranch: 'main',
          ),
        ],
        {'p1': workspaces},
      ),
    );
    final container = ProviderContainer(
      overrides: [
        workspaceStoreProvider.overrideWith(() => store),
        homeDirProvider.overrideWithValue('/Users/me'),
        workspaceDetailProvider.overrideWith2(
          (id) => FixedDetail(id, WorkspaceDetail(id: id)),
        ),
        backendStatusProvider.overrideWith(
          (ref) => Stream.value(BackendStatus.up),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: key,
          child: HaroApp(router: buildRouter()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> snap(WidgetTester tester, String name) =>
      tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$_out/remove-$name.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
      });

  testWidgets('render remove project', (tester) async {
    await loadBrandFonts();
    Directory(_out!).createSync(recursive: true);

    var c = await pump(tester, [
      _ws('a', 'free shipping threshold', 'idle'),
      _ws('b', 'kuro theme', 'merged'),
      _ws('c', 'live gate', 'error'),
    ]);
    c.read(appCommandsProvider).removeProject('p1');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'gate-sa');
    await tester.pumpAndSettle();
    await snap(tester, 'unmerged');

    c = await pump(tester, [
      _ws('b', 'kuro theme', 'merged'),
      _ws('d', 'verified hunks', 'merged'),
    ]);
    c.read(appCommandsProvider).removeProject('p1');
    await tester.pumpAndSettle();
    await snap(tester, 'all-merged');

    await pump(tester, [_ws('a', 'free shipping threshold', 'idle')]);
    await tester.tap(find.text('GATE-SANDBOX'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await snap(tester, 'menu');
  }, skip: _out == null);
}
