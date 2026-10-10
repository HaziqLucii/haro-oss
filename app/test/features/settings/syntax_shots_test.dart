import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/settings/controls/grain_preview.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/settings_layers.dart';
import 'package:haro_app/features/settings/settings_register.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_markdown.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:haro_app/router.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:haro_app/theme/display_scope.dart';
import 'package:haro_app/theme/grain.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/theme/tokens.dart';

import '../workspace/harness.dart' show id;
import '../workspace/steps/code/code_harness.dart';
import 'settings_harness.dart';

/// Local visual check, not part of the suite: renders PNGs with the real brand fonts.
///   HARO_SHOTS=/some/dir flutter test test/features/settings/syntax_shots_test.dart
final _out = Platform.environment['HARO_SHOTS'];

const _diff = '''diff --git a/src/rates.ts b/src/rates.ts
index 1111111..2222222 100644
--- a/src/rates.ts
+++ b/src/rates.ts
@@ -1,9 +1,14 @@ export
 import { zone } from './zones';
-const FREE_OVER = 100;
+const FREE_OVER: number = 120;
+type Rate = { code: string; cents: number };
 // free shipping kicks in at the threshold
-export function shippingFor(total: number) {
-  return total >= FREE_OVER ? 0 : rates['standard'];
+export class RateTable extends Map<string, Rate> {
+  static shippingFor(total: number, label = 'standard'): number {
+    if (total >= FREE_OVER || label === 'free') return 0;
+    return this.get(label)?.cents ?? Math.round(total * 0.05);
+  }
 }
 export const zones = zone('eu');
''';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File('assets/fonts/$f').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

class _FakeStore extends WorkspaceStore {
  @override
  WorkspaceSnapshot build() => const WorkspaceSnapshot(loaded: true);
}

class _Host extends ConsumerStatefulWidget {
  const _Host();

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => registerSettingsCommands(ref, () => context),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  final key = GlobalKey();

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/syntax-$name.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  setUpAll(() async {
    if (_out == null) return;
    await _font('SpaceGrotesk', [
      'SpaceGrotesk-400.ttf',
      'SpaceGrotesk-500.ttf',
      'SpaceGrotesk-600.ttf',
      'SpaceGrotesk-700.ttf',
    ]);
    await _font('SpaceMono', ['SpaceMono-400.ttf', 'SpaceMono-700.ttf']);
    await _font('Fraunces', ['Fraunces-500.ttf']);
    Directory(_out!).createSync(recursive: true);
  });

  Future<void> diff(WidgetTester tester, bool colour, String name) async {
    tester.view.physicalSize = const Size(1400, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    final rig = CodeRig(diff: _diff);
    rig.prefs = MemoryDevicePrefsStore({
      'display': {'syntax_colour': colour},
    });
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
    await shot(tester, name);
  }

  testWidgets(
    'diff view in colour',
    (tester) => diff(tester, true, 'diff'),
    skip: _out == null,
  );
  testWidgets(
    'diff view in monochrome',
    (tester) => diff(tester, false, 'diff-mono'),
    skip: _out == null,
  );

  testWidgets('Display tab', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    haroOverlayDepth.value = 0;
    final container = ProviderContainer(
      overrides: [
        workspaceStoreProvider.overrideWith(_FakeStore.new),
        haroApiProvider.overrideWithValue(FakeBackend().api()),
        devicePrefsStoreProvider.overrideWithValue(MemoryDevicePrefsStore()),
        settingsLayersProvider.overrideWithValue(FakeLayers()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: key,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: buildHaroTheme(),
            routerConfig: GoRouter(
              routes: [GoRoute(path: '/', builder: (_, _) => const _Host())],
            ),
            builder: (context, child) =>
                Stack(children: [?child, const GrainOverlay()]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container.read(appCommandsProvider).openSettings(SettingsTab.display);
    await tester.pumpAndSettle();
    await shot(tester, 'display');
    await tester.ensureVisible(find.byType(GrainPreview));
    await tester.pumpAndSettle();
    await shot(tester, 'display-bottom');
    await tester.ensureVisible(find.text('Monochrome'));
    await tester.tap(find.text('Monochrome'));
    await tester.tap(find.text('Compact'));
    await tester.pumpAndSettle();
    await shot(tester, 'display-mono-compact');
    await tester.ensureVisible(find.byType(GrainPreview));
    await tester.pumpAndSettle();
    await shot(tester, 'display-mono-compact-bottom');
  }, skip: _out == null);

  testWidgets('agent code block', (tester) async {
    tester.view.physicalSize = const Size(760, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: buildHaroTheme(),
          home: Scaffold(
            backgroundColor: HaroTokens.bg,
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: DisplayScope(
                codingFont: 'Space Mono',
                density: DensityScale.comfortable,
                child: const AgentProse(
                  'The threshold now reads from `FREE_OVER`:\n\n'
                  '```ts\nexport function shippingFor(total: number): number {\n'
                  '  // free shipping kicks in at the threshold\n'
                  "  return total >= 120 ? 0 : rates['standard'];\n}\n```",
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await shot(tester, 'agent');
  }, skip: _out == null);
}
