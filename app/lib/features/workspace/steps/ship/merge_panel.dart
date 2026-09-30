import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import 'ship_model.dart';

/// Merge is irreversible, so the button arms first and reverts if it is not confirmed.
const mergeConfirmWindow = Duration(seconds: 4);

/// The one box that says whether this branch can merge and offers the next move (spec 5.7).
/// Exactly one bone-filled button lives in it at a time: `Merge into main` when ready,
/// `Continue on a new branch` once merged, none while blocked.
class MergePanel extends StatefulWidget {
  const MergePanel({
    super.key,
    required this.model,
    required this.onGoVerify,
    required this.onOpenPr,
    required this.onViewPr,
    required this.onMerge,
    required this.onContinue,
    this.onResolve,
    this.merging = false,
    this.openingPr = false,
    this.continuing = false,
    this.error,
    this.note,
  });

  final ShipModel model;
  final VoidCallback onGoVerify;
  final VoidCallback onOpenPr;
  final VoidCallback onViewPr;
  final VoidCallback onMerge;
  final VoidCallback onContinue;
  final VoidCallback? onResolve;
  final bool merging;
  final bool openingPr;
  final bool continuing;
  final String? error;
  final String? note;

  @override
  State<MergePanel> createState() => _MergePanelState();
}

class _MergePanelState extends State<MergePanel> {
  Timer? _timer;
  bool _armed = false;

  @override
  void didUpdateWidget(MergePanel old) {
    super.didUpdateWidget(old);
    if (_armed && (widget.merging || old.model.phase != widget.model.phase)) {
      _disarm();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _disarm() {
    _timer?.cancel();
    _armed = false;
  }

  void _mergeTap() {
    if (widget.merging) return;
    if (_armed) {
      setState(_disarm);
      widget.onMerge();
      return;
    }
    setState(() => _armed = true);
    _timer?.cancel();
    _timer = Timer(mergeConfirmWindow, () {
      if (mounted) setState(() => _armed = false);
    });
  }

  static const _h = 36.0;
  static const _fs = 14.0;
  static const _pad = EdgeInsets.symmetric(horizontal: 14);

  Widget _secondary(String key, String label, VoidCallback? onTap) =>
      HaroButton(
        key: ValueKey(key),
        label: label,
        height: _h,
        fontSize: _fs,
        padding: _pad,
        onPressed: onTap,
        foreground: onTap == null ? HaroTokens.ink42 : HaroTokens.ink86,
      );

  Widget _primary(String key, String label, VoidCallback? onTap) => HaroButton(
    key: ValueKey(key),
    label: label,
    height: _h,
    fontSize: _fs,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    variant: onTap == null
        ? HaroButtonVariant.secondary
        : HaroButtonVariant.primary,
    foreground: HaroTokens.ink42,
    onPressed: onTap,
  );

  List<Widget> _buttons() {
    final m = widget.model;
    switch (m.phase) {
      case ShipPhase.ready:
        final busyPr = widget.openingPr;
        final view = m.hasPr && m.showPr;
        final prLabel = view ? 'View #${m.prNumber} ↗' : 'Open pull request';
        final prTap = busyPr || widget.merging
            ? null
            : (view ? widget.onViewPr : widget.onOpenPr);
        final pr = m.showPr
            ? (m.showMerge
                  ? _secondary(
                      view ? 'ship-view-pr' : 'ship-open-pr',
                      busyPr ? 'Opening…' : prLabel,
                      prTap,
                    )
                  : _primary(
                      view ? 'ship-view-pr' : 'ship-open-pr',
                      busyPr ? 'Opening…' : prLabel,
                      prTap,
                    ))
            : null;
        final merge = m.showMerge
            ? _primary(
                'ship-merge',
                widget.merging
                    ? 'Merging…'
                    : (_armed ? 'Confirm merge' : 'Merge into ${m.baseShort}'),
                widget.merging ? null : _mergeTap,
              )
            : null;
        return [?pr, ?merge];
      case ShipPhase.gateBlocked:
        return [
          if (m.showGoVerify)
            _secondary('ship-go-verify', 'Go to verify', widget.onGoVerify),
          const _BlockedPill(),
        ];
      case ShipPhase.cannotShip:
        return [
          if (m.showResolve && widget.onResolve != null)
            _primary('ship-resolve', 'Help resolve with AI', widget.onResolve),
          const _BlockedPill(),
        ];
      case ShipPhase.merged:
        return [
          if (m.hasPr)
            _secondary(
              'ship-view-pr',
              'View #${m.prNumber} ↗',
              widget.onViewPr,
            ),
          _primary(
            'ship-continue',
            widget.continuing ? 'Continuing…' : 'Continue on a new branch',
            widget.continuing ? null : widget.onContinue,
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final ready = m.phase == ShipPhase.ready;
    final border = ready
        ? HaroTokens.gate.withValues(alpha: .45)
        : HaroTokens.line20;

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              key: const ValueKey('ship-dot'),
              width: 8,
              height: 8,
              color: m.dot,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                m.title,
                key: const ValueKey('ship-title'),
                style: HaroText.ui(size: 18, weight: FontWeight.w500),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          m.sub,
          key: const ValueKey('ship-sub'),
          style: HaroText.ui(size: 14, color: HaroTokens.ink66, height: 1.4),
        ),
        if (widget.error != null) ...[
          const SizedBox(height: 10),
          Text(
            widget.error!,
            key: const ValueKey('ship-error'),
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
            key: const ValueKey('ship-note'),
            style: HaroText.mono(
              size: 11.5,
              color: HaroTokens.ink42,
              tracking: 0,
              height: 1.45,
            ),
          ),
        ],
      ],
    );

    return AnimatedContainer(
      key: const ValueKey('merge-panel'),
      duration: HaroTokens.fade,
      curve: HaroTokens.curve,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
      decoration: BoxDecoration(
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final buttons = Wrap(spacing: 8, runSpacing: 8, children: _buttons());
          if (c.maxWidth >= 620) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: text),
                const SizedBox(width: 20),
                buttons,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [text, const SizedBox(height: 16), buttons],
          );
        },
      ),
    );
  }
}

/// The disabled stand-in for the merge button: dashed, not a button, so it cannot be
/// mistaken for one that is merely dimmed.
class _BlockedPill extends StatelessWidget {
  const _BlockedPill();

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('ship-merge-blocked'),
    painter: _DashedBorder(HaroTokens.line20),
    child: Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      child: Text(
        'Merge blocked',
        style: HaroText.ui(size: 14, color: HaroTokens.ink42),
      ),
    ),
  );
}

class _DashedBorder extends CustomPainter {
  _DashedBorder(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const dash = 4.0;
    const gap = 3.0;
    final r = Rect.fromLTWH(.5, .5, size.width - 1, size.height - 1);
    void line(Offset a, Offset b) {
      final total = (b - a).distance;
      final dir = (b - a) / total;
      for (var d = 0.0; d < total; d += dash + gap) {
        final end = d + dash > total ? total : d + dash;
        canvas.drawLine(a + dir * d, a + dir * end, paint);
      }
    }

    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}
