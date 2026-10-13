import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/haro_text_field.dart';

/// A one-line name field that takes the place of what it names (a row in a list) while it is being
/// renamed, or sits at the top of a list while a new one is named. Enter confirms, Esc and
/// clicking away cancel.
class InlineNameField extends StatefulWidget {
  const InlineNameField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onSubmit,
    required this.onCancel,
    this.height = 30,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;
  final double height;

  @override
  State<InlineNameField> createState() => _InlineNameFieldState();
}

class _InlineNameFieldState extends State<InlineNameField> {
  bool _hadFocus = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    if (widget.focusNode.hasFocus) {
      _hadFocus = true;
    } else if (_hadFocus) {
      _hadFocus = false;
      // Clicking away ends the edit without renaming (Enter is what confirms).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onCancel();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
    },
    child: Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            widget.onCancel();
            return null;
          },
        ),
      },
      child: HaroTextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        height: widget.height,
        fontSize: 13,
        hintText: widget.hint,
        onSubmitted: widget.onSubmit,
      ),
    ),
  );
}

/// Selects the part of a path a rename most often changes: the file name without its extension.
TextSelection nameStemSelection(String text) {
  final slash = text.lastIndexOf('/') + 1;
  final dot = text.lastIndexOf('.');
  return TextSelection(
    baseOffset: slash,
    extentOffset: dot > slash ? dot : text.length,
  );
}
