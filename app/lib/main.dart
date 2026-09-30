import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import 'backend/backend_health.dart';
import 'backend/backend_launcher.dart';
import 'backend/boot_gate.dart';
import 'capture/capture_mode.dart';
import 'features/settings/display_prefs_provider.dart';
import 'router.dart';
import 'theme/display_scope.dart';
import 'theme/grain.dart';
import 'theme/haro_theme.dart';
import 'theme/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  // Linux keeps its native title bar (it carries the only window controls); macOS hides
  // it and the top bar takes over, leaving room for the traffic lights.
  final options = WindowOptions(
    size: const Size(1360, 860),
    minimumSize: HaroTokens.minWindow,
    center: true,
    title: 'haro',
    backgroundColor: HaroTokens.bg,
    titleBarStyle: defaultTargetPlatform == TargetPlatform.macOS
        ? TitleBarStyle.hidden
        : TitleBarStyle.normal,
    windowButtonVisibility: !captureMode,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(
    BootGate(
      launcher: BackendLauncher(),
      appBuilder: (config) => ProviderScope(
        overrides: [backendConfigProvider.overrideWithValue(config)],
        child: const HaroApp(),
      ),
    ),
  );
}

class HaroApp extends ConsumerStatefulWidget {
  const HaroApp({super.key, this.router});

  final GoRouter? router;

  @override
  ConsumerState<HaroApp> createState() => _HaroAppState();
}

class _HaroAppState extends ConsumerState<HaroApp> {
  late final GoRouter _router = widget.router ?? buildRouter();

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'haro',
    debugShowCheckedModeBanner: false,
    theme: buildHaroTheme(),
    routerConfig: _router,
    builder: (context, child) {
      final display = ref.watch(displayPrefsProvider);
      return DisplayScope(
        codingFont: display.codingFont,
        density: DensityScale.of(display.density),
        syntaxColour: display.syntaxColour,
        child: CaptureBoundary(
          onGo: captureMode ? _router.go : null,
          child: Stack(
            children: [
              ?child,
              AnimatedOpacity(
                opacity: display.filmGrain ? 1 : 0,
                duration: HaroTokens.fadeFast,
                curve: HaroTokens.curve,
                child: const GrainOverlay(),
              ),
            ],
          ),
        ),
      );
    },
  );
}
