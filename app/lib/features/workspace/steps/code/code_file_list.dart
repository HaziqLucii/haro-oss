import 'package:flutter/material.dart';

import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import 'code_tokens.dart';
import 'proof.dart';

/// The file list itself moved to `workbench/` (explorer, search, changes). What stays here is
/// what the explorer rows and the editor header both draw: the proof square and the counts.

String proofTooltip(ProofSquare s) => switch (s) {
  ProofSquare.ran => 'every added line ran in the green suite',
  ProofSquare.partial => 'some added lines never ran',
  ProofSquare.none => 'not code, or no line data',
};

/// The proof square: green filled = ran, hollow ink = some never ran, dim = no claim.
class ProofDot extends StatelessWidget {
  const ProofDot(this.square, {super.key});

  final ProofSquare square;

  @override
  Widget build(BuildContext context) {
    final (fill, border) = switch (square) {
      ProofSquare.ran => (HaroTokens.gate, HaroTokens.gate),
      ProofSquare.partial => (HaroTokens.transparent, HaroTokens.ink),
      ProofSquare.none => (HaroTokens.line20, HaroTokens.line20),
    };
    return Tooltip(
      message: proofTooltip(square),
      child: Container(
        width: CodeTokens.proofSquare,
        height: CodeTokens.proofSquare,
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border),
        ),
      ),
    );
  }
}

/// `+a −d`; a zero side is left out.
class Counts extends StatelessWidget {
  const Counts({super.key, required this.added, required this.removed});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(size: 11, tracking: 0);
    return Text.rich(
      TextSpan(
        children: [
          if (added > 0)
            TextSpan(
              text: '+$added',
              style: TextStyle(color: HaroTokens.gate),
            ),
          if (added > 0 && removed > 0) const TextSpan(text: ' '),
          if (removed > 0)
            TextSpan(
              text: '−$removed',
              style: TextStyle(color: HaroTokens.fail),
            ),
        ],
      ),
      maxLines: 1,
      softWrap: false,
      style: style,
    );
  }
}
