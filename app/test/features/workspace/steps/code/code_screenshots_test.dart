import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/features/workspace/steps/code/diff_model.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/router.dart';
import 'package:re_editor/re_editor.dart';

import '../../harness.dart';
import 'code_harness.dart';

/// Local visual check, not part of the suite: renders PNGs with the real brand fonts.
///   HARO_SHOTS=/some/dir HARO_CODE_FIXTURES=/dir/with/diff.json,file.json,tree.json \
///     flutter test test/features/workspace/steps/code/code_screenshots_test.dart
final _out = Platform.environment['HARO_SHOTS'];
final _fixtures = Platform.environment['HARO_CODE_FIXTURES'];

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File('assets/fonts/$f').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

VerifiedHunksResponse syntheticProof(String diff) {
  final files = <VerifiedFile>[];
  for (final f in parseUnifiedDiff(diff)) {
    final ext = f.path.split('.').last;
    if (!{'ts', 'tsx', 'py'}.contains(ext) || f.hunks.isEmpty) continue;
    final allRan = ext == 'py';
    final lines = <int, int?>{};
    var unexecuted = 0;
    var executed = 0;
    for (final h in f.hunks) {
      for (final n in h.addedLineNos) {
        if (allRan) {
          lines[n] = 3;
          executed++;
        } else if (n % 7 == 0) {
          lines[n] = null;
        } else if (n % 5 == 0) {
          lines[n] = 0;
          unexecuted++;
        } else {
          lines[n] = 2;
          executed++;
        }
      }
    }
    files.add(
      VerifiedFile(
        path: f.path,
        inMap: true,
        added: f.additions,
        executed: executed,
        unexecuted: unexecuted,
        lines: lines,
      ),
    );
  }
  return VerifiedHunksResponse(
    baseRef: 'origin/main',
    supported: true,
    files: files,
  );
}

void main() {
  final key = GlobalKey();

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/code-$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<void> open(
    WidgetTester tester,
    CodeRig rig, {
    Size size = const Size(1400, 900),
    bool terminal = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    final router = buildRouter(initialLocation: '/w/$id/code');
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: rig.overrides,
        child: RepaintBoundary(
          key: key,
          child: HaroApp(router: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/w/$id/code');
    await tester.pumpAndSettle();
    if (terminal) {
      await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('render code step', (tester) async {
    await _font('SpaceGrotesk', [
      'SpaceGrotesk-400.ttf',
      'SpaceGrotesk-500.ttf',
      'SpaceGrotesk-600.ttf',
      'SpaceGrotesk-700.ttf',
    ]);
    await _font('SpaceMono', ['SpaceMono-400.ttf', 'SpaceMono-700.ttf']);
    await _font('Fraunces', ['Fraunces-500.ttf']);
    Directory(_out!).createSync(recursive: true);

    final diff =
        (jsonDecode(File('$_fixtures/diff.json').readAsStringSync())
                as Map)['diff']
            as String;
    final fileJson =
        jsonDecode(File('$_fixtures/file.json').readAsStringSync()) as Map;
    final treeJson =
        jsonDecode(File('$_fixtures/tree.json').readAsStringSync()) as Map;
    final tree = [
      for (final n in treeJson['tree'] as List)
        FileNode.fromJson(n as Map<String, dynamic>),
    ];
    const verdictPath = 'frontend/src/verdict.ts';
    CodeRig rig() => CodeRig(
      diff: diff,
      proof: syntheticProof(diff),
      tree: tree,
      files: {
        verdictPath: FileContent(
          path: verdictPath,
          content: fileJson['content'] as String,
        ),
      },
    );

    await open(tester, rig());
    await tester.tap(find.byKey(const ValueKey('file-row:$verdictPath')));
    await tester.pumpAndSettle();
    await shot(tester, 'diff');

    await tester.tap(
      find.byKey(
        const ValueKey('file-row:frontend/src/components/GatePanel.tsx'),
      ),
    );
    await tester.pumpAndSettle();
    await shot(tester, 'diff-tsx');

    await tester.tap(
      find.byKey(
        const ValueKey('file-row:docs/screenshots/workflow-composer.png'),
      ),
    );
    await tester.pumpAndSettle();
    await shot(tester, 'diff-binary');

    await open(tester, rig(), size: const Size(900, 640), terminal: true);
    await shot(tester, 'narrow-terminal');

    await open(tester, rig());
    await tester.tap(find.byKey(const ValueKey('file-row:$verdictPath')));
    await tester.pumpAndSettle();
    codeEditorHighlighting = true;
    await tester.tap(find.byKey(const ValueKey('mode-edit')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    await shot(tester, 'edit');

    final c = tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    c.text = '${c.text}// edited\n';
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('file-row:frontend/src/App.tsx')),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    await shot(tester, 'edit-unsaved');
    codeEditorHighlighting = false;

    await open(tester, rig());
    await tester.tap(find.byKey(const ValueKey('all-files-toggle')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('all-files-toggle')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tree-row:frontend')));
    await tester.pumpAndSettle();
    await shot(tester, 'all-files');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'verd');
    await tester.pumpAndSettle();
    await shot(tester, 'quick-open');

    await open(tester, CodeRig(diff: ''));
    await shot(tester, 'empty');
  }, skip: _out == null || _fixtures == null);
}
