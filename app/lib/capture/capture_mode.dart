import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Screenshot mode for marketing shots (`--dart-define=HARO_CAPTURE=true`, never in release).
/// Hides the macOS window buttons and their inset so a shot shows haro's own UI and no OS
/// chrome, and saves the Flutter view itself on ⌃⌥⌘S, so there are no rounded corners or
/// shadow either.
const bool captureMode = bool.fromEnvironment('HARO_CAPTURE') && !kReleaseMode;

final GlobalKey captureBoundaryKey = GlobalKey();

/// Wraps the whole app so the capture includes overlays and the grain.
class CaptureBoundary extends StatefulWidget {
  const CaptureBoundary({super.key, required this.child, this.onGo});

  final Widget child;

  /// Scripted navigation for capture runs: `<dir>/.go` holds a route (e.g. `/w/<id>/code`).
  final ValueChanged<String>? onGo;

  @override
  State<CaptureBoundary> createState() => _CaptureBoundaryState();
}

class _CaptureBoundaryState extends State<CaptureBoundary> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    if (!captureMode) return;
    HardwareKeyboard.instance.addHandler(_onKey);
    // Scripted shots: dropping `<dir>/.shoot` (its text = the file name) captures once.
    _poll = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _checkTrigger(),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (captureMode) HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _busy = false;

  Future<void> _checkTrigger() async {
    if (_busy) return;
    final go = File('${captureDir().path}/.go');
    if (widget.onGo != null && go.existsSync()) {
      final route = go.readAsStringSync().trim();
      go.deleteSync();
      if (route.isNotEmpty) widget.onGo!(route);
    }
    final trigger = File('${captureDir().path}/.shoot');
    if (!trigger.existsSync()) return;
    _busy = true;
    try {
      final name = trigger.readAsStringSync().trim();
      trigger.deleteSync();
      await saveCapture(name: name.isEmpty ? null : name);
    } finally {
      _busy = false;
    }
  }

  bool _onKey(KeyEvent e) {
    final k = HardwareKeyboard.instance;
    if (e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.keyS &&
        k.isControlPressed &&
        k.isAltPressed &&
        k.isMetaPressed) {
      saveCapture();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: captureBoundaryKey, child: widget.child);
}

/// Writes the current frame as a PNG into `HARO_CAPTURE_DIR` (or `<temp>/haro-captures`)
/// and returns its path.
// The system temp dir, because the macOS sandbox only lets the app write inside its
// container (~/Library/Containers/<bundle id>/Data/tmp there).
Directory captureDir() => Directory(
  Platform.environment['HARO_CAPTURE_DIR'] ??
      '${Directory.systemTemp.path}/haro-captures',
);

Future<String?> saveCapture({double pixelRatio = 2, String? name}) async {
  final boundary =
      captureBoundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
  if (boundary == null) return null;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (bytes == null) return null;
  final dir = captureDir();
  await dir.create(recursive: true);
  final file = File(
    '${dir.path}/${name ?? 'haro-${DateTime.now().millisecondsSinceEpoch}'}.png',
  );
  await file.writeAsBytes(bytes.buffer.asUint8List());
  debugPrint('haro capture: ${file.path}');
  return file.path;
}
