import 'package:flutter/material.dart';

import '../../../shell/shell_models.dart';
import '../../../shell/sidebar.dart';
import '../../../state/display_state.dart';
import '../../../theme/display_scope.dart';
import '../../../theme/tokens.dart';

/// Three sidebar rows at the draft density, so the row height can be judged before saving.
/// They are the real sidebar rows: a nested [DisplayScope] swaps only the density.
class DensityPreview extends StatelessWidget {
  const DensityPreview({super.key, required this.density});

  final String density;

  static const _samples = [
    SidebarWorkspace(
      id: 'preview-idle',
      name: 'shipping-bar',
      state: DisplayState.idle,
    ),
    SidebarWorkspace(
      id: 'preview-red',
      name: 'rates-refactor',
      state: DisplayState.red,
    ),
    SidebarWorkspace(
      id: 'preview-merged',
      name: 'checkout-copy',
      state: DisplayState.merged,
    ),
  ];

  static const double width = 240;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      key: const ValueKey('density-preview'),
      width: width,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: HaroTokens.bg,
        border: Border.all(color: HaroTokens.line12),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: DisplayScope(
        codingFont: DisplayScope.codingFontOf(context),
        syntaxColour: DisplayScope.syntaxColourOf(context),
        density: DensityScale.of(density),
        child: ExcludeSemantics(
          child: IgnorePointer(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final ws in _samples)
                  SidebarWorkspaceRow(
                    workspace: ws,
                    selected: false,
                    onTap: () {},
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
