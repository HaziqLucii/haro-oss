import 'package:flutter/widgets.dart';

import '../../../../state/display_state.dart';
import '../../../../state/look_at.dart';
import '../../../../theme/display_scope.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../../open_in/open_in_button.dart';
import '../../../open_in/open_in_notice.dart';
import 'verify_model.dart';
import 'verify_widgets.dart';

/// Zone 3 (spec 5.6): what a human still has to look at. Failures block the merge; every
/// other row is advisory.
class LookAtSection extends StatelessWidget {
  const LookAtSection({
    super.key,
    required this.workspaceId,
    required this.state,
    required this.rows,
    required this.editorTarget,
    required this.busy,
    required this.onToggle,
    required this.onOpen,
    required this.onBacklog,
    this.onAsk,
    this.onSendAll,
    this.note,
  });

  final String workspaceId;
  final DisplayState state;
  final List<ReviewRow> rows;

  /// The file and line "Open in editor" jumps to for [LookAtItem], null when it has none.
  final (String, int?)? Function(LookAtItem) editorTarget;
  final bool busy;
  final ValueChanged<ReviewRow> onToggle;
  final ValueChanged<LookAtItem> onOpen;

  /// Null hides "Ask agent" and "Send N to agent": a manual workspace has no agent.
  final ValueChanged<LookAtItem>? onAsk;
  final VoidCallback onBacklog;
  final VoidCallback? onSendAll;

  /// Outcome of the last "Add to backlog", shown beside the buttons.
  final String? note;

  bool get _merged => state == DisplayState.merged;

  @override
  Widget build(BuildContext context) {
    final open = _merged ? 0 : rows.where((r) => !r.reviewed).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZoneHeading(
          title: lookAtTitle(state),
          count: '$open open',
          hint: lookAtHint(state),
        ),
        const OpenInNoticeText(
          source: 'verify-look',
          padding: EdgeInsets.only(bottom: 8),
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 22),
            child: Text(
              emptyLookAtText(state),
              key: const ValueKey('look-empty'),
              style: HaroText.ui(size: 14, color: HaroTokens.ink42),
            ),
          ),
        for (final r in rows)
          _Row(
            key: ValueKey('look-row-${r.item.key}'),
            row: r,
            workspaceId: workspaceId,
            editor: editorTarget(r.item),
            dimmed: r.reviewed || _merged,
            interactive: !_merged,
            onToggle: () => onToggle(r),
            onOpen: () => onOpen(r.item),
            onAsk: onAsk == null ? null : () => onAsk!(r.item),
          ),
        if (rows.isNotEmpty && !_merged)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (note != null)
                  Text(
                    note!,
                    key: const ValueKey('look-note'),
                    style: HaroText.mono(
                      size: 11,
                      color: HaroTokens.ink42,
                      tracking: 0,
                    ),
                  ),
                Fit(
                  child: HaroButton(
                    key: const ValueKey('look-backlog'),
                    label: 'Add to backlog',
                    height: 30,
                    variant: HaroButtonVariant.tertiary,
                    foreground: busy || open == 0 ? HaroTokens.ink42 : null,
                    onPressed: busy || open == 0 ? null : onBacklog,
                  ),
                ),
                if (onSendAll != null)
                  Fit(
                    child: HaroButton(
                      key: const ValueKey('look-send'),
                      label: 'Send $open to agent',
                      height: 30,
                      foreground: busy || open == 0
                          ? HaroTokens.ink42
                          : HaroTokens.ink86,
                      onPressed: busy || open == 0 ? null : onSendAll,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.row,
    required this.workspaceId,
    required this.editor,
    required this.dimmed,
    required this.interactive,
    required this.onToggle,
    required this.onOpen,
    this.onAsk,
  });

  final ReviewRow row;
  final String workspaceId;
  final (String, int?)? editor;
  final bool dimmed;
  final bool interactive;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback? onAsk;

  @override
  Widget build(BuildContext context) {
    final item = row.item;
    final red = item.isFailure || item.blocking || item.isSecret;
    final hasFile = item.file != null;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.label.toUpperCase(),
          style: HaroText.mono(
            size: 10.5,
            color: red ? HaroTokens.fail : HaroTokens.ink66,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          item.title,
          style: HaroText.mono(size: 13, color: HaroTokens.ink, tracking: 0),
        ),
        if (_detail(item).isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            _detail(item),
            style: HaroText.ui(size: 13.5, color: HaroTokens.ink66),
          ),
        ],
      ],
    );

    final actions = Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        if (hasFile)
          _RowButton(
            key: ValueKey('look-open-${item.key}'),
            label: 'Open diff',
            onPressed: onOpen,
          ),
        if (editor != null)
          OpenInLink(
            key: ValueKey('look-editor-${item.key}'),
            workspaceId: workspaceId,
            source: 'verify-look',
            path: editor!.$1,
            line: editor!.$2,
          ),
        if (onAsk != null)
          _RowButton(
            key: ValueKey('look-ask-${item.key}'),
            label: 'Ask agent',
            onPressed: interactive ? onAsk : null,
          ),
      ],
    );

    return Opacity(
      opacity: dimmed ? .45 : 1,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: HaroTokens.line08)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            vertical: DisplayScope.densityOf(context).lookAtPadY,
          ),
          child: LayoutBuilder(
            builder: (context, c) {
              final narrow = c.maxWidth < narrowWidth;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Check(
                    key: ValueKey('look-check-${item.key}'),
                    on: dimmed,
                    onTap: interactive ? onToggle : null,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: narrow
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              body,
                              const SizedBox(height: 10),
                              actions,
                            ],
                          )
                        : body,
                  ),
                  if (!narrow) ...[const SizedBox(width: 14), actions],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static String _detail(LookAtItem i) {
    if (i.isFailure && i.file != null) {
      return i.detail.isEmpty ? i.file! : '${i.detail} · ${i.file}';
    }
    return i.detail;
  }
}

class _Check extends StatelessWidget {
  const _Check({super.key, required this.on, required this.onTap});

  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: 'Mark reviewed',
    tooltip: 'Mark reviewed',
    builder: (context, hovered) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: SizedBox.square(
        dimension: 16,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: on ? HaroTokens.ink : HaroTokens.transparent,
            border: Border.all(
              color: hovered ? HaroTokens.ink66 : HaroTokens.ink42,
            ),
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
          child: on ? const CustomPaint(painter: _TickPainter()) : null,
        ),
      ),
    ),
  );
}

class _RowButton extends StatelessWidget {
  const _RowButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Fit(
    child: HaroButton(
      label: label,
      height: 26,
      fontSize: 12.5,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      foreground: onPressed == null ? HaroTokens.ink42 : HaroTokens.ink86,
      onPressed: onPressed,
    ),
  );
}

/// Drawn rather than typed: the check glyph is not in the UI font.
class _TickPainter extends CustomPainter {
  const _TickPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * .26, size.height * .54)
      ..lineTo(size.width * .43, size.height * .70)
      ..lineTo(size.width * .75, size.height * .32);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.square
        ..color = HaroTokens.bg,
    );
  }

  @override
  bool shouldRepaint(_TickPainter old) => false;
}
