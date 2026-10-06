import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/models/models.dart' show WorkspaceMode;
import '../features/open_in/editors_provider.dart';
import '../features/workspace/workspace_ui.dart';
import '../shell/shell_layout.dart';
import '../shell/shell_providers.dart';
import '../shortcuts/app_commands.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_text_field.dart';
import '../widgets/status_square.dart';
import 'overlay.dart';
import 'palette_model.dart';

Future<void> showCommandPalette(BuildContext context) =>
    showHaroOverlay<void>(context, width: 620, child: const CommandPalette());

/// ⌘K (§6.2). Lives inside [showHaroOverlay]; picking an item closes it, then runs the item.
class CommandPalette extends ConsumerStatefulWidget {
  const CommandPalette({super.key});

  @override
  ConsumerState<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<CommandPalette> {
  final _controller = TextEditingController();
  final _selectedKey = GlobalKey();
  String _query = '';
  int _selected = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<PaletteItem> _items(GoRouter router) => buildPaletteItems(
    data: ref.read(shellDataProvider),
    commands: () => ref.read(appCommandsProvider),
    openWorkspace: (id, step) => router.go('/w/$id/$step'),
    worktreeLabel: ref.read(workspaceUiProvider).activeWorkspaceId == null
        ? null
        : 'Open worktree in ${ref.read(defaultEditorProvider)?.label ?? '…'}',
    openWorkspaceMode: _openWorkspaceMode(),
    focusAvailable: _onCodeStep(router),
    codeAvailable: _onCodeStep(router),
    definitionAvailable:
        _onCodeStep(router) &&
        ref.read(appCommandsProvider).goToDefinition !=
            const AppCommands().goToDefinition,
    railAvailable: _railAvailable(router),
  );

  List<String> _segments(GoRouter router) =>
      router.routerDelegate.currentConfiguration.uri.pathSegments;

  bool _onCodeStep(GoRouter router) {
    final segments = _segments(router);
    return segments.length >= 3 && segments[0] == 'w' && segments[2] == 'code';
  }

  /// The rail exists on a workspace route, and not in focus mode (which hides it). The route
  /// is the truth here: the active workspace id can outlive the page for a frame.
  bool _railAvailable(GoRouter router) {
    final segments = _segments(router);
    if (segments.length < 2 || segments[0] != 'w') return false;
    final layout = ref.read(shellLayoutProvider);
    return !layout.focusOn(
      workspaceId: segments[1],
      codeStep: _onCodeStep(router),
    );
  }

  WorkspaceMode? _openWorkspaceMode() {
    final id = ref.read(workspaceUiProvider).activeWorkspaceId;
    return id == null
        ? null
        : ref.read(shellDataProvider).workspaceById(id)?.mode;
  }

  void _run(PaletteItem item) {
    closeHaroOverlay(context);
    item.run();
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _selected = (_selected + delta).clamp(0, count - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(shellDataProvider);
    if (ref.watch(workspaceUiProvider.select((u) => u.activeWorkspaceId)) !=
        null) {
      ref.watch(defaultEditorProvider);
    }
    final router = GoRouter.of(context);
    final groups = filterPalette(_items(router), _query);
    final flat = [for (final g in groups) ...g.$2];
    final selected = flat.isEmpty ? 0 : _selected.clamp(0, flat.length - 1);

    KeyEventResult onKey(FocusNode _, KeyEvent e) {
      if (e is KeyUpEvent) return KeyEventResult.ignored;
      final key = e.logicalKey;
      if (key == LogicalKeyboardKey.arrowDown) {
        _move(1, flat.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _move(-1, flat.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        if (e is KeyDownEvent && flat.isNotEmpty) _run(flat[selected]);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    var index = 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: HaroTokens.line12)),
          ),
          child: Focus(
            onKeyEvent: onKey,
            child: HaroTextField(
              controller: _controller,
              autofocus: true,
              bordered: false,
              height: 52,
              fontSize: 16,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              hintText: 'Jump to a workspace, run an action, open a setting…',
              onChanged: (v) => setState(() {
                _query = v;
                _selected = 0;
              }),
            ),
          ),
        ),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: flat.isEmpty
                ? const _NoMatches()
                : ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(6),
                    children: [
                      for (final g in groups) ...[
                        _GroupHead(g.$1.title),
                        for (final item in g.$2)
                          () {
                            final i = index++;
                            return _ItemRow(
                              key: i == selected ? _selectedKey : null,
                              item: item,
                              selected: i == selected,
                              onHover: () => setState(() => _selected = i),
                              onTap: () => _run(item),
                            );
                          }(),
                      ],
                    ],
                  ),
          ),
        ),
        const _Footer(),
      ],
    );
  }
}

class _GroupHead extends StatelessWidget {
  const _GroupHead(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
    child: Text(
      title.toUpperCase(),
      maxLines: 1,
      style: HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .16),
    ),
  );
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.selected,
    required this.onHover,
    required this.onTap,
  });

  final PaletteItem item;
  final bool selected;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onHover: (_) {
      if (!selected) onHover();
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Semantics(
        button: true,
        selected: selected,
        label: item.label,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? HaroTokens.raised : HaroTokens.transparent,
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
          child: Row(
            children: [
              item.state == null
                  ? const StatusSquare(color: HaroTokens.line12, filled: false)
                  : StatusSquare.forState(item.state!),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.ui(),
                ),
              ),
              if (item.meta.isNotEmpty) ...[
                const SizedBox(width: 10),
                Text(
                  item.meta,
                  maxLines: 1,
                  style: HaroText.mono(color: HaroTokens.ink42, tracking: 0),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28),
    child: Center(
      child: Text(
        'NO MATCHES',
        style: HaroText.mono(color: HaroTokens.ink42, tracking: .16),
      ),
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(
      size: 10.5,
      color: HaroTokens.ink42,
      tracking: 0,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line12)),
      ),
      child: Row(
        children: [
          Text('↑↓ move', style: style),
          const SizedBox(width: 16),
          Text('↵ open', style: style),
          const SizedBox(width: 16),
          Text('esc close', style: style),
        ],
      ),
    );
  }
}
