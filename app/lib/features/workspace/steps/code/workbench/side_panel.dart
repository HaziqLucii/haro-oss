import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../../../../open_in/editors_provider.dart';
import '../../../../open_in/open_in_launcher.dart';
import '../../../../../widgets/haro_pressable.dart';
import '../diff_model.dart';
import '../editor/editor_tabs.dart';
import '../proof.dart';
import 'changes_panel.dart';
import 'explorer_panel.dart';
import 'search_panel.dart';
import 'workbench_icons.dart';
import 'workbench_state.dart';
import 'workbench_widgets.dart';

/// The resizable column between the activity bar and the editor: one of Files, Search or
/// Changes, a legend and the "Also open in…" escape hatch underneath, and a drag handle on its
/// right edge.
class SidePanel extends ConsumerWidget {
  const SidePanel({
    super.key,
    required this.workspaceId,
    required this.changed,
    required this.proof,
    this.width,
  });

  final String workspaceId;

  /// The width to draw at when the window cannot afford the dragged one.
  final double? width;
  final List<DiffFile> changed;
  final ProofIndex? proof;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wb = ref.watch(workbenchProvider(workspaceId));
    return SizedBox(
      key: const ValueKey('side-panel'),
      width: width ?? wb.sideWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: HaroTokens.line12)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: switch (wb.view) {
                      WorkbenchView.files => ExplorerPanel(
                        workspaceId: workspaceId,
                        changed: changed,
                        proof: proof,
                      ),
                      WorkbenchView.search => SearchPanel(
                        workspaceId: workspaceId,
                      ),
                      WorkbenchView.changes => ChangesPanel(
                        workspaceId: workspaceId,
                        diff: changed,
                      ),
                    },
                  ),
                  _Footer(workspaceId: workspaceId),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: WorkbenchTokens.resizeHandle,
            child: _ResizeHandle(
              onDrag: (dx) => ref
                  .read(workbenchProvider(workspaceId).notifier)
                  .setWidth((width ?? wb.sideWidth) + dx),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      key: const ValueKey('side-resize'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => setState(() => _drag = true),
      onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
      onHorizontalDragEnd: (_) => setState(() => _drag = false),
      child: ColoredBox(
        color: _hover || _drag ? HaroTokens.line14 : HaroTokens.transparent,
      ),
    ),
  );
}

class _Footer extends ConsumerWidget {
  const _Footer({required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferred = ref.watch(defaultEditorProvider);
    final active = ref.watch(
      editorTabsProvider(workspaceId).select((s) => s.activePath),
    );
    return Container(
      key: const ValueKey('side-footer'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Legend(),
          const SizedBox(height: 7),
          HaroPressable(
            onTap: () => ref
                .read(openInLauncherProvider)
                .launch(
                  context,
                  workspaceId: workspaceId,
                  source: 'code',
                  path: active,
                  forceMenu: true,
                ),
            semanticLabel: 'Also open in',
            builder: (context, hovered) => Container(
              key: const ValueKey('also-open-in'),
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                border: Border.all(color: HaroTokens.line12),
                borderRadius: BorderRadius.circular(HaroTokens.radius),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      preferred == null
                          ? 'Also open in…'
                          : 'Also open in… ${preferred.label}',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: HaroText.ui(
                        size: 12,
                        color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                      ),
                    ),
                  ),
                  WorkbenchIconView(
                    WorkbenchIcon.chevronDown,
                    size: 10,
                    color: hovered ? HaroTokens.ink : HaroTokens.ink66,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `A added  M modified  • has changes`. The A is green: an added line is a gate colour.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final dim = HaroText.mono(size: 9.5, color: HaroTokens.ink42, tracking: 0);
    TextSpan key(String glyph, String label, Color color) => TextSpan(
      children: [
        TextSpan(
          text: glyph,
          style: TextStyle(color: color),
        ),
        TextSpan(text: ' $label'),
      ],
    );
    return Text.rich(
      key: const ValueKey('side-legend'),
      TextSpan(
        children: [
          key('A', 'added', HaroTokens.gate),
          const TextSpan(text: '   '),
          key('M', 'modified', HaroTokens.ink),
          const TextSpan(text: '   '),
          key('•', 'has changes', HaroTokens.ink),
        ],
      ),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: dim,
    );
  }
}
