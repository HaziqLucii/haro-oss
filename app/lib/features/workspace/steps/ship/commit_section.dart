import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../api/models/models.dart';
import '../../../../shortcuts/platform_keys.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/haro_text_field.dart';
import 'ship_widgets.dart';

/// Newest commit(s) as `sha  subject … age`, plus a commit box when (and only when) the
/// working tree is dirty. `⌘↵` inside the field commits and stops there, so it never also
/// fires an app-level ⌘↵.
class CommitSection extends StatefulWidget {
  const CommitSection({
    super.key,
    required this.commits,
    required this.dirty,
    required this.ahead,
    required this.onCommit,
    this.committing = false,
    this.primary = false,
    this.error,
    this.note,
  });

  final List<GitCommit> commits;
  final int dirty;
  final int ahead;
  final Future<bool> Function(String message) onCommit;
  final bool committing;

  /// The gate is green and only this uncommitted work stands in the way, so Commit is the
  /// step's one primary and the message field takes focus.
  final bool primary;
  final String? error;
  final String? note;

  @override
  State<CommitSection> createState() => _CommitSectionState();
}

class _CommitSectionState extends State<CommitSection> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final message = _text.text.trim();
    if (widget.committing) return;
    if (message.isEmpty) {
      _focus.requestFocus();
      return;
    }
    final ok = await widget.onCommit(message);
    if (ok && mounted) _text.clear();
  }

  String get _sub {
    if (widget.dirty > 0) {
      return '${widget.dirty} uncommitted ${widget.dirty == 1 ? 'change' : 'changes'}';
    }
    final n = widget.ahead;
    return n > 0
        ? 'Working tree is clean · everything is in $n ${n == 1 ? 'commit' : 'commits'}'
        : 'Working tree is clean';
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.commits
        .take(widget.ahead > 0 ? widget.ahead.clamp(1, 3) : 1)
        .toList();
    final dirty = widget.dirty > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ShipSectionHead(title: 'Commit', sub: _sub),
        if (dirty) ...[
          const SizedBox(height: 16),
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _submit,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _submit,
            },
            child: Row(
              children: [
                Expanded(
                  child: HaroTextField(
                    key: const ValueKey('commit-field'),
                    controller: _text,
                    focusNode: _focus,
                    height: 36,
                    fontSize: 14,
                    enabled: !widget.committing,
                    autofocus: widget.primary,
                    hintText:
                        'Commit ${widget.dirty} changed ${widget.dirty == 1 ? 'file' : 'files'}…',
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(width: 8),
                HaroButton(
                  key: const ValueKey('commit-button'),
                  label: widget.committing ? 'Committing…' : 'Commit',
                  kbd: primaryLabel('↵'),
                  height: 36,
                  fontSize: 14,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  variant: widget.primary && !widget.committing
                      ? HaroButtonVariant.primary
                      : HaroButtonVariant.secondary,
                  foreground: widget.committing
                      ? HaroTokens.ink42
                      : HaroTokens.ink86,
                  onPressed: widget.committing ? null : _submit,
                ),
              ],
            ),
          ),
        ],
        if (widget.error != null) ...[
          const SizedBox(height: 10),
          Text(
            widget.error!,
            key: const ValueKey('commit-error'),
            style: HaroText.mono(
              size: 11.5,
              color: HaroTokens.fail,
              tracking: 0,
              height: 1.45,
            ),
          ),
        ] else if (widget.note != null) ...[
          const SizedBox(height: 10),
          Text(
            widget.note!,
            key: const ValueKey('commit-note'),
            style: HaroText.mono(
              size: 11.5,
              color: HaroTokens.ink42,
              tracking: 0,
            ),
          ),
        ],
        for (final c in shown)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Row(
              key: ValueKey('commit-row-${c.short}'),
              children: [
                Text(
                  c.short,
                  style: HaroText.mono(
                    size: 12.5,
                    color: HaroTokens.ink66,
                    tracking: 0,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    c.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.mono(
                      size: 12.5,
                      color: HaroTokens.ink66,
                      tracking: 0,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  c.when,
                  maxLines: 1,
                  style: HaroText.mono(
                    size: 12.5,
                    color: HaroTokens.ink42,
                    tracking: 0,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
