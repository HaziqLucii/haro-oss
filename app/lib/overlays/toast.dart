import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';

/// One transient line in the bottom-right corner. Fades in and out, never slides. A newer
/// toast replaces the one on screen instead of stacking.
void showHaroToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  final overlay = Navigator.of(context, rootNavigator: true).overlay;
  if (overlay == null) return;
  _current?.dismiss();
  final toast = _ToastHandle();
  final entry = OverlayEntry(
    builder: (_) => _ToastView(message: message, handle: toast),
  );
  toast.entry = entry;
  _current = toast;
  overlay.insert(entry);
  toast.timer = Timer(duration, toast.dismiss);
}

_ToastHandle? _current;

class _ToastHandle {
  OverlayEntry? entry;
  Timer? timer;
  final visible = ValueNotifier<bool>(true);
  bool _gone = false;

  void dismiss() {
    if (_gone) return;
    _gone = true;
    timer?.cancel();
    visible.value = false;
    Timer(HaroTokens.fadeFast, () {
      final e = entry;
      if (e != null && e.mounted) e.remove();
      entry = null;
      if (identical(_current, this)) _current = null;
    });
  }
}

class _ToastView extends StatelessWidget {
  const _ToastView({required this.message, required this.handle});

  final String message;
  final _ToastHandle handle;

  @override
  Widget build(BuildContext context) => Positioned(
    right: 20,
    bottom: 20,
    child: ValueListenableBuilder<bool>(
      valueListenable: handle.visible,
      builder: (context, visible, child) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: visible ? 1 : 0),
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        builder: (context, t, child) => Opacity(opacity: t, child: child),
        child: child,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: DecoratedBox(
            key: const ValueKey('toast'),
            decoration: BoxDecoration(
              color: HaroTokens.raised,
              border: Border.all(color: HaroTokens.line30),
              borderRadius: BorderRadius.circular(HaroTokens.radius),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(
                message,
                style: HaroText.ui(
                  size: 13,
                  color: HaroTokens.ink,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
