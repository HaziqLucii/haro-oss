import 'package:flutter/widgets.dart';

import '../../../../api/models/models.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import 'ship_model.dart';

Color _tone(ReceiptTone t) => switch (t) {
  ReceiptTone.pass => HaroTokens.gate,
  ReceiptTone.fail => HaroTokens.fail,
  ReceiptTone.dim => HaroTokens.ink42,
};

/// The shareable gate receipt (spec 5.7): the same rows the PR comment carries.
class ReceiptCard extends StatelessWidget {
  const ReceiptCard({
    super.key,
    required this.receipt,
    required this.rows,
    required this.sha,
    required this.footer,
  });

  final Receipt receipt;
  final List<ReceiptRowData> rows;
  final String? sha;
  final String footer;

  Color get _verdictColor => switch (receipt.verdict) {
    'green' => HaroTokens.gate,
    'red' => HaroTokens.fail,
    _ => HaroTokens.ink66,
  };

  @override
  Widget build(BuildContext context) {
    final word = receiptWord(receipt);
    return DecoratedBox(
      key: const ValueKey('receipt-card'),
      decoration: BoxDecoration(
        color: HaroTokens.panel,
        border: Border.all(color: HaroTokens.line20),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: HaroTokens.line12)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        'haro.',
                        style: HaroText.wordmark.copyWith(fontSize: 18),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          sha == null ? 'GATE RECEIPT' : 'GATE RECEIPT · $sha',
                          key: const ValueKey('receipt-head'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HaroText.mono(
                            size: 11,
                            color: HaroTokens.ink42,
                            tracking: .1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(width: 9, height: 9, color: _verdictColor),
                const SizedBox(width: 8),
                Text(
                  word,
                  key: const ValueKey('receipt-verdict'),
                  style: HaroText.mono(
                    size: 12,
                    weight: FontWeight.w700,
                    color: _verdictColor,
                    tracking: .2,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: LayoutBuilder(
              builder: (context, c) {
                final two = c.maxWidth >= 2 * 280 + 32;
                final cells = [for (final r in rows) _Row(r)];
                if (!two) return Column(children: cells);
                final left = <Widget>[];
                final right = <Widget>[];
                for (var i = 0; i < cells.length; i++) {
                  (i.isEven ? left : right).add(cells[i]);
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Column(children: left)),
                    const SizedBox(width: 32),
                    Expanded(child: Column(children: right)),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20).copyWith(top: 14, bottom: 14),
            child: Text(
              footer,
              key: const ValueKey('receipt-footer'),
              style: HaroText.mono(
                size: 11,
                color: HaroTokens.ink42,
                tracking: 0,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.row);

  final ReceiptRowData row;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 14),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line08)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Container(width: 6, height: 6, color: _tone(row.tone)),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 118,
          child: Text(
            row.label,
            style: HaroText.ui(size: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            row.value,
            key: ValueKey('receipt-row-${row.label}'),
            style: HaroText.mono(
              size: 12,
              color: HaroTokens.ink66,
              tracking: 0,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );
}
