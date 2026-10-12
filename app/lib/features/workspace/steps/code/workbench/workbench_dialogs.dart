import 'package:flutter/material.dart';

import '../../../../../api/haro_api.dart';
import '../../../../../overlays/overlay.dart';
import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../../../../../widgets/haro_button.dart';
import '../../../../../widgets/haro_text_field.dart';

/// A request's error as a line of text for a dialog.
String errorText(Object e) => e is HaroApiException ? e.message : '$e';

/// Asks for one line of text (a new file name, a rename) and runs [submit] with it. The dialog
/// stays open and shows the message when [submit] returns one, and closes on null. Resolves to
/// true when it submitted.
Future<bool> promptDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required Future<String?> Function(String value) submit,
  String initial = '',
  String? hint,
  String? caption,
}) async {
  final done = await showHaroOverlay<bool>(
    context,
    width: 440,
    child: _Dialog(
      title: title,
      caption: caption,
      confirmLabel: confirmLabel,
      initial: initial,
      hint: hint,
      submit: submit,
    ),
  );
  return done ?? false;
}

/// A yes or no with a body line. [submit] runs on confirm, same contract as [promptDialog].
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  required Future<String?> Function() submit,
  bool destructive = false,
}) async {
  final done = await showHaroOverlay<bool>(
    context,
    width: 440,
    child: _Dialog(
      title: title,
      caption: body,
      confirmLabel: confirmLabel,
      destructive: destructive,
      submit: (_) => submit(),
    ),
  );
  return done ?? false;
}

class _Dialog extends StatefulWidget {
  const _Dialog({
    required this.title,
    required this.confirmLabel,
    required this.submit,
    this.caption,
    this.initial,
    this.hint,
    this.destructive = false,
  });

  final String title;
  final String? caption;
  final String confirmLabel;
  final Future<String?> Function(String value) submit;

  /// Null for a confirm without an input.
  final String? initial;
  final String? hint;
  final bool destructive;

  @override
  State<_Dialog> createState() => _DialogState();
}

class _DialogState extends State<_Dialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial ?? '',
  );
  bool _busy = false;
  String? _error;

  bool get _hasInput => widget.initial != null;

  @override
  void initState() {
    super.initState();
    if (_hasInput) {
      // Selecting the name, not the extension, is what a rename wants.
      final name = _text.text;
      final dot = name.lastIndexOf('.');
      final slash = name.lastIndexOf('/');
      _text.selection = TextSelection(
        baseOffset: slash + 1,
        extentOffset: dot > slash + 1 ? dot : name.length,
      );
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final value = _text.text.trim();
    if (_busy || (_hasInput && value.isEmpty)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.submit(value);
    } catch (e) {
      error = errorText(e);
    }
    if (!mounted) return;
    if (error == null) {
      closeHaroOverlay(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Padding(
      key: const ValueKey('workbench-dialog'),
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: HaroText.ui(size: 17, weight: FontWeight.w500),
          ),
          if (widget.caption != null) ...[
            const SizedBox(height: 8),
            Text(
              widget.caption!,
              style: HaroText.ui(
                size: 13,
                color: HaroTokens.ink66,
                height: 1.4,
              ),
            ),
          ],
          if (_hasInput) ...[
            const SizedBox(height: 14),
            HaroTextField(
              key: const ValueKey('dialog-input'),
              controller: _text,
              autofocus: true,
              mono: true,
              hintText: widget.hint,
              onSubmitted: (_) => _go(),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              key: const ValueKey('dialog-error'),
              style: HaroText.mono(
                size: 11.5,
                color: HaroTokens.fail,
                tracking: 0,
              ),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              HaroButton(
                key: const ValueKey('dialog-cancel'),
                label: 'Cancel',
                variant: HaroButtonVariant.tertiary,
                height: 28,
                fontSize: 13,
                onPressed: _busy ? null : () => closeHaroOverlay(context),
              ),
              const SizedBox(width: 8),
              HaroButton(
                key: const ValueKey('dialog-confirm'),
                label: widget.confirmLabel,
                variant: widget.destructive
                    ? HaroButtonVariant.destructive
                    : HaroButtonVariant.primary,
                height: 28,
                fontSize: 13,
                onPressed: _busy ? null : _go,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
