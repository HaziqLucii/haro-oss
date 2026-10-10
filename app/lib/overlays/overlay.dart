import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// Number of overlays currently open. The global shortcuts stand down while it is above zero
/// so a key pressed inside a dialog is never also handled by the app behind it.
final ValueNotifier<int> haroOverlayDepth = ValueNotifier<int>(0);

/// Shows [child] in a panel over a dimmed, blurred backdrop (§6): fade in 180ms, Esc and a
/// click outside close it. [width] and [height] are upper bounds and shrink to 92% and 80%
/// of the window. A null [height] sizes the panel to its content. [fullscreen] ignores both
/// and fills the window edge to edge.
///
/// Esc and the backdrop go through `maybePop`, so a `PopScope(canPop: false)` inside the child
/// (a request in flight) holds the overlay open. Close from inside with [closeHaroOverlay]. The panel is a [Material] with a transparent
/// type, so text fields and other Material widgets work without a Scaffold.
Future<T?> showHaroOverlay<T>(
  BuildContext context, {
  required double width,
  double? height,
  required Widget child,
  bool dismissible = true,
  bool fullscreen = false,
}) {
  haroOverlayDepth.value++;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'Close',
    barrierColor: HaroTokens.backdrop,
    transitionDuration: HaroTokens.fadeFast,
    pageBuilder: (context, _, _) => _OverlayFrame(
      width: width,
      height: height,
      dismissible: dismissible,
      fullscreen: fullscreen,
      child: child,
    ),
    transitionBuilder: (context, animation, _, page) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: HaroTokens.curve,
      );
      return AnimatedBuilder(
        animation: curved,
        builder: (context, page) {
          final sigma = HaroTokens.backdropBlur * curved.value;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (sigma > 0)
                IgnorePointer(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: const SizedBox.expand(),
                  ),
                ),
              FadeTransition(opacity: curved, child: page),
            ],
          );
        },
        child: page,
      );
    },
  ).whenComplete(() => haroOverlayDepth.value--);
}

/// Pops the overlay that contains [context], optionally returning [result].
void closeHaroOverlay<T>(BuildContext context, [T? result]) =>
    Navigator.of(context, rootNavigator: true).pop(result);

class _OverlayFrame extends StatelessWidget {
  const _OverlayFrame({
    required this.width,
    required this.height,
    required this.dismissible,
    required this.fullscreen,
    required this.child,
  });

  final double width;
  final double? height;
  final bool dismissible;
  final bool fullscreen;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final panel = Material(
      type: MaterialType.transparency,
      child: Container(
        width: fullscreen ? size.width : math.min(width, size.width * .92),
        height: fullscreen
            ? size.height
            : height == null
            ? null
            : math.min(height!, size.height * .8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: fullscreen ? HaroTokens.bg : HaroTokens.panel,
          border: fullscreen ? null : Border.all(color: HaroTokens.line20),
          borderRadius: BorderRadius.circular(
            fullscreen ? 0 : HaroTokens.radius,
          ),
        ),
        child: child,
      ),
    );
    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          if (dismissible)
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(context, rootNavigator: true).maybePop(),
        },
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.only(top: fullscreen ? 0 : size.height * .09),
            child: panel,
          ),
        ),
      ),
    );
  }
}
