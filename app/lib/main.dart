import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import 'backend/backend_health.dart';
import 'backend/backend_launcher.dart';
import 'backend/boot_gate.dart';
import 'capture/capture_mode.dart';
import 'api/models/json_util.dart' show asJson;
import 'features/settings/device_prefs.dart';
import 'features/settings/display_prefs_provider.dart';
import 'router.dart';
import 'shell/notifier.dart';
import 'shell/window_controls.dart';
import 'theme/display_scope.dart';
import 'theme/grain.dart';
import 'theme/haro_theme.dart';
import 'theme/palette.dart';
import 'theme/tokens.dart';
import 'theme/ui_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final file = await FileDevicePrefsStore().read();
  initialDisplayPrefs = DisplayPrefs.fromJson(asJson(file['display']));
  HaroTokens.apply(
    HaroPalette.resolve(
      initialDisplayPrefs.theme,
      initialDisplayPrefs.m3Colour,
    ),
  );
  await windowManager.ensureInitialized();
  // macOS and Linux hide the native title bar and the top bar takes over, so the window reads
  // as one surface. macOS leaves room for its traffic lights; Linux draws its own controls
  // (`WindowControls`) and resize edges (`DragToResizeArea`).
  final options = WindowOptions(
    size: const Size(1360, 860),
    minimumSize: HaroTokens.minWindow,
    center: true,
    title: 'haro',
    backgroundColor: HaroTokens.bg,
    titleBarStyle:
        defaultTargetPlatform == TargetPlatform.macOS || useWindowControls
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

/// The Interface and Text font families the prefs pick, null for the theme's own.
(String?, String?) _fontsOf(DisplayPrefs d) => (
  uiFontFamily(d.interfaceFont, d.interfaceFontCustom),
  uiFontFamily(d.textFont, d.textFontCustom),
);

class HaroApp extends ConsumerStatefulWidget {
  const HaroApp({super.key, this.router});

  final GoRouter? router;

  @override
  ConsumerState<HaroApp> createState() => _HaroAppState();
}

class _HaroAppState extends ConsumerState<HaroApp> {
  late final GoRouter _router = widget.router ?? buildRouter();

  // Without the native frame there is nothing to grab at the window's edge: thin transparent
  // handles around the app start a resize (Linux only; other platforms keep their frame).
  Widget _resizable(Widget child) =>
      useWindowControls ? DragToResizeArea(child: child) : child;

  @override
  void initState() {
    super.initState();
    HaroPalette resolved(DisplayPrefs d) =>
        HaroPalette.resolve(d.theme, d.m3Colour);
    final now = resolved(ref.read(displayPrefsProvider));
    if (!identical(HaroTokens.palette, now)) HaroTokens.apply(now);
    final fonts = _fontsOf(ref.read(displayPrefsProvider));
    HaroTokens.applyFonts(ui: fonts.$1, text: fonts.$2);
    ref.listenManual(displayPrefsProvider.select(_fontsOf), (_, next) {
      HaroTokens.applyFonts(ui: next.$1, text: next.$2);
      _rebuildAll();
    });
    ref.listenManual(displayPrefsProvider.select(resolved), (_, next) {
      if (identical(HaroTokens.palette, next)) return;
      HaroTokens.apply(next);
      _rebuildAll();
    });
  }

  /// Every widget reads [HaroTokens] directly, so all of them rebuild after a theme or font change,
  /// not only the ones that depend on the Material theme. State is kept.
  void _rebuildAll() {
    setState(() {});
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
  }

  @override
  Widget build(BuildContext context) => _app();

  Widget _app() => MaterialApp.router(
    title: 'haro',
    debugShowCheckedModeBanner: false,
    theme: buildHaroTheme(),
    routerConfig: _router,
    builder: (context, child) {
      final display = ref.watch(displayPrefsProvider);
      return NotifierHost(
        child: DisplayScope(
          codingFont: display.codingFont,
          density: DensityScale.of(display.density),
          syntaxColour: display.syntaxColour,
          child: CaptureBoundary(
            onGo: captureMode ? _router.go : null,
            child: _resizable(
              Stack(
                children: [
                  ?child,
                  AnimatedOpacity(
                    opacity: display.filmGrain && HaroTokens.palette.grain
                        ? 1
                        : 0,
                    duration: HaroTokens.fadeFast,
                    curve: HaroTokens.curve,
                    child: const GrainOverlay(),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
