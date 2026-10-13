import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

const double _edge = 8;

/// A small panel anchored at [position] (window coordinates, usually the bottom-left of the button
/// that opened it) that stays open while you use it: no dimmed backdrop, so the page behind stays
/// visible. A press outside it or Esc closes it. [builder] gets a `close` callback for a close
/// button. Unlike a menu, picking something inside does not close it, so several choices can be made
/// in a row.
Future<void> showHaroPopover(
  BuildContext context, {
  required Offset position,
  required double width,
  required double height,
  required Widget Function(BuildContext context, VoidCallback close) builder,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close',
  barrierColor: HaroTokens.transparent,
  transitionDuration: HaroTokens.fadeFast,
  pageBuilder: (dialogContext, _, _) {
    final size = MediaQuery.sizeOf(dialogContext);
    final w = math.min(width, size.width - 2 * _edge);
    final left = math.max(_edge, math.min(position.dx, size.width - w - _edge));
    final top = math.max(_edge, math.min(position.dy, size.height - 120));
    final h = math.min(height, size.height - top - _edge);
    void close() => Navigator.of(dialogContext, rootNavigator: true).maybePop();
    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
        child: Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: w,
              height: h,
              child: Material(
                type: MaterialType.transparency,
                child: DecoratedBox(
                  key: const Key('haro-popover'),
                  decoration: BoxDecoration(
                    color: HaroTokens.raised,
                    border: Border.all(color: HaroTokens.line20),
                    borderRadius: BorderRadius.circular(HaroTokens.panelRadius),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(HaroTokens.panelRadius),
                    child: builder(dialogContext, close),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  },
  transitionBuilder: (context, animation, _, page) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: HaroTokens.curve),
    child: page,
  ),
);
