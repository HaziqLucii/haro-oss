import 'package:flutter/material.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_button.dart';
import 'overlay.dart';

/// Asks before something that cannot be undone, in a modal over the page (Esc or a click outside
/// answers no). Resolves true only when the confirm button is pressed. The cancel button has the
/// focus, so pressing Enter by reflex never deletes.
Future<bool> showConfirm(
  BuildContext context, {
  required String title,
  required String body,
  String confirm = 'Delete',
  String cancel = 'Cancel',
  bool destructive = true,
}) async {
  final answer = await showHaroOverlay<bool>(
    context,
    width: 440,
    child: _Confirm(
      title: title,
      body: body,
      confirm: confirm,
      cancel: cancel,
      destructive: destructive,
    ),
  );
  return answer == true;
}

class _Confirm extends StatelessWidget {
  const _Confirm({
    required this.title,
    required this.body,
    required this.confirm,
    required this.cancel,
    required this.destructive,
  });

  final String title;
  final String body;
  final String confirm;
  final String cancel;
  final bool destructive;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          key: const Key('confirm-title'),
          style: HaroText.ui(size: 20, weight: FontWeight.w500),
        ),
        const SizedBox(height: 10),
        Text(
          body,
          key: const Key('confirm-body'),
          style: HaroText.ui(size: 14, color: HaroTokens.ink66, height: 1.55),
        ),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Focus(
              autofocus: true,
              child: HaroButton(
                key: const Key('confirm-cancel'),
                label: cancel,
                onPressed: () => closeHaroOverlay<bool>(context, false),
              ),
            ),
            const SizedBox(width: 8),
            HaroButton(
              key: const Key('confirm-ok'),
              label: confirm,
              variant: destructive
                  ? HaroButtonVariant.destructive
                  : HaroButtonVariant.primary,
              onPressed: () => closeHaroOverlay<bool>(context, true),
            ),
          ],
        ),
      ],
    ),
  );
}
