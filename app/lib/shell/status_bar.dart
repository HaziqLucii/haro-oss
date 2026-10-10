import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/workspace_detail.dart';
import '../features/workspace/steps/code/code_buffers.dart';
import '../features/workspace/steps/code/editor/deferred_listenable.dart';
import '../features/workspace/steps/code/editor/editor_status.dart';
import '../features/workspace/workspace_ui.dart';
import '../shortcuts/platform_keys.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_pressable.dart';
import '../widgets/shell_icons.dart';
import '../widgets/status_square.dart';
import 'gate_chip.dart';

TextStyle _style([Color color = HaroTokens.ink66]) =>
    HaroText.mono(size: 10.5, color: color, tracking: 0);

/// The 24px strip along the bottom of the window.
class StatusBarFrame extends StatelessWidget {
  const StatusBarFrame({super.key, required this.left, this.right});

  final List<Widget> left;
  final Widget? right;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('status-bar'),
    height: HaroTokens.statusBarHeight,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: HaroTokens.line12)),
    ),
    child: Row(
      children: [
        for (final (i, w) in left.indexed) ...[
          if (i > 0) const SizedBox(width: 16),
          w,
        ],
        const Spacer(),
        if (right != null)
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: right,
            ),
          ),
      ],
    ),
  );
}

/// Triage, first run and other screens without a workspace: only the backend, the one field
/// that still applies.
class BackendStatusBar extends StatelessWidget {
  const BackendStatusBar({super.key, required this.down, this.host});

  final bool down;
  final String? host;

  @override
  Widget build(BuildContext context) => StatusBarFrame(
    left: [
      Text(
        down ? 'backend down' : 'backend ${host ?? ''}'.trim(),
        key: const ValueKey('status-backend'),
        maxLines: 1,
        softWrap: false,
        style: _style(down ? HaroTokens.ink42 : HaroTokens.ink66),
      ),
    ],
  );
}

/// The status bar over a workspace: branch, gate chip, terminal toggle, and on the code step
/// the open file's cursor, indent, language, encoding and save state.
class WorkspaceStatusBar extends ConsumerWidget {
  const WorkspaceStatusBar({
    super.key,
    required this.workspaceId,
    required this.codeStep,
    required this.onGate,
  });

  final String workspaceId;
  final bool codeStep;
  final VoidCallback onGate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = workspaceId;
    final branch = ref.watch(
      workspaceDetailProvider(id).select((d) => d.workspace?.branch),
    );
    final flow = ref.watch(workspaceFlowProvider(id));
    final terminalOpen = ref.watch(
      workspaceUiProvider.select((u) => u.terminalOpen),
    );
    final gate = flow == null ? null : gateChipFor(flow);
    return StatusBarFrame(
      left: [
        if (branch != null && branch.isNotEmpty)
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ShellIconView(
                  ShellIcon.branch,
                  size: 12,
                  color: HaroTokens.ink66,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    branch,
                    key: const ValueKey('status-branch'),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: _style(),
                  ),
                ),
              ],
            ),
          ),
        if (gate != null) _GateButton(gate: gate, onTap: onGate),
        _TerminalButton(
          open: terminalOpen,
          onTap: ref.read(workspaceUiProvider.notifier).toggleTerminal,
        ),
      ],
      right: codeStep ? EditorStatusFields(workspaceId: id) : null,
    );
  }
}

class _GateButton extends StatelessWidget {
  const _GateButton({required this.gate, required this.onTap});

  final FocusGate gate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: 'Open review',
    semanticLabel: 'Gate ${gate.word}',
    builder: (context, hovered) => Row(
      key: const ValueKey('status-gate'),
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusSquare(size: 6, color: gate.color, filled: gate.filled),
        const SizedBox(width: 6),
        Text(
          'gate ${gate.word.toLowerCase()}',
          maxLines: 1,
          softWrap: false,
          style: _style(hovered ? HaroTokens.ink : HaroTokens.ink66),
        ),
      ],
    ),
  );
}

class _TerminalButton extends StatelessWidget {
  const _TerminalButton({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    tooltip: open ? 'Hide terminal' : 'Terminal',
    semanticLabel: open ? 'Hide terminal' : 'Terminal',
    builder: (context, hovered) {
      final color = open || hovered ? HaroTokens.ink : HaroTokens.ink66;
      return Row(
        key: const ValueKey('status-terminal'),
        mainAxisSize: MainAxisSize.min,
        children: [
          ShellIconView(ShellIcon.terminal, size: 12, color: color),
          const SizedBox(width: 6),
          Text('terminal', maxLines: 1, softWrap: false, style: _style(color)),
          const SizedBox(width: 6),
          Text(
            controlLabel('`'),
            maxLines: 1,
            softWrap: false,
            style: _style(HaroTokens.ink42),
          ),
        ],
      );
    },
  );
}

/// Cursor, indent, language, encoding and save state of the file in the focused editor pane.
/// Renders nothing when that pane shows a diff or no file.
class EditorStatusFields extends ConsumerWidget {
  const EditorStatusFields({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = focusedEditPath(ref, workspaceId);
    if (path == null) return const SizedBox.shrink();
    final store = ref.watch(codeBuffersProvider(workspaceId));
    return DeferredListenableBuilder(
      listenable: store,
      builder: (context) {
        final buffer = store.bufferFor(path);
        if (buffer == null) return const SizedBox.shrink();
        return DeferredListenableBuilder(
          listenable: Listenable.merge([buffer, ?buffer.controller]),
          builder: (context) {
            final status = editorStatusOf(buffer);
            if (status == null) return const SizedBox.shrink();
            final save = switch (status.save) {
              EditorSave.saved => ('saved', HaroTokens.ink42),
              EditorSave.unsaved => ('● unsaved', HaroTokens.ink),
              EditorSave.saving => ('saving…', HaroTokens.ink66),
            };
            Widget field(String key, String text, [Color? color]) => Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                text,
                key: ValueKey(key),
                maxLines: 1,
                softWrap: false,
                style: _style(color ?? HaroTokens.ink66),
              ),
            );
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                field('status-position', status.position),
                field('status-spaces', 'Spaces: ${status.spaces}'),
                field('status-language', status.language),
                field('status-encoding', status.encoding),
                field('status-save', save.$1, save.$2),
              ],
            );
          },
        );
      },
    );
  }
}
